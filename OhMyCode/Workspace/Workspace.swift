import AppKit
import Observation

/// State for one editor window: the opened folder and its open documents (tabs).
@MainActor
@Observable
final class Workspace {
    private(set) var rootURL: URL?
    private(set) var rootNode: FileNode?
    private(set) var documents: [EditorDocument] = []
    var activeDocumentID: EditorDocument.ID?
    var errorMessage: String?
    private(set) var fileIndex: FileIndex?
    /// Most recently opened first.
    private(set) var recentFiles: [URL] = []
    private(set) var palette: PaletteModel?
    private(set) var gitStatus: GitStatus?
    @ObservationIgnored private(set) var gitRepository: Git.Repository?
    @ObservationIgnored private var gitTask: Task<Void, Never>?
    /// Replaces server discovery per language (tests point a workspace at a fake server).
    @ObservationIgnored var languageServerOverrides: [SourceLanguage: LanguageServerConfig] = [:]
    /// One client per language server, shared by all documents it handles.
    private(set) var languageClients: [String: LanguageClient] = [:]
    private(set) var terminals: [TerminalSession] = []
    var activeTerminalID: TerminalSession.ID?
    private(set) var isTerminalVisible = false
    /// Bumped to move keyboard focus into the terminal.
    private(set) var terminalFocusRequest = 0
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    /// Root as FSEvents reports paths (symlinks resolved).
    @ObservationIgnored private var canonicalRootPath = ""

    init() {
        NotificationCenter.default.addObserver(forName: .omcGoToDefinition, object: nil, queue: .main) { [weak self] note in
            let document = note.object as? EditorDocument
            MainActor.assumeIsolated {
                guard let self, let document, self.documents.contains(where: { $0 === document }) else { return }
                self.goToDefinition(in: document)
            }
        }
    }

    var activeDocument: EditorDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    var displayName: String {
        rootURL?.lastPathComponent ?? "Oh My Code"
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openFolder(_ url: URL) {
        guard documents.allSatisfy({ confirmClose($0) }) else { return }
        rootURL = url
        rootNode = FileNode(url: url, isDirectory: true)
        documents.removeAll()
        activeDocumentID = nil
        recentFiles.removeAll()
        fileIndex = nil
        rebuildFileIndex()
        terminals.forEach { $0.terminate() }
        terminals.removeAll()
        activeTerminalID = nil
        isTerminalVisible = false

        gitStatus = nil
        gitRepository = nil
        refreshGit()
        languageClients.values.forEach { $0.shutdown() }
        languageClients.removeAll()
        // Resolve the login-shell PATH now, so the first file opened doesn't wait for it.
        Task.detached(priority: .utility) { _ = await ShellEnvironment.shared.environment() }

        canonicalRootPath = FileWatcher.canonicalPath(url)
        watcher = FileWatcher(path: canonicalRootPath) { [weak self] events in
            self?.handleFileEvents(events)
        }
    }

    /// Rebuilds the quick-open index in the background. The previous index stays usable until
    /// the new one is ready; `delay` debounces bursts of file-system events.
    func rebuildFileIndex(after delay: Duration = .zero) {
        guard let rootURL else { return }
        indexTask?.cancel()
        indexTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let index = await Task.detached(priority: .userInitiated) {
                FileIndexer.build(root: rootURL)
            }.value
            guard !Task.isCancelled, self.rootURL == rootURL else { return }
            self.fileIndex = index
            if self.palette?.mode == .files { self.palette?.refresh() }
        }
    }

    // MARK: File system changes

    func handleFileEvents(_ events: [FileWatcher.Event]) {
        guard let rootNode else { return }
        let prefix = canonicalRootPath + "/"
        var directoriesToReload = Set<String>()
        var changedPaths = Set<String>()
        var needsIndexRebuild = false
        var needsGitRefresh = false

        for event in events {
            if event.requiresRescan || event.path == canonicalRootPath {
                rootNode.reloadLoadedSubtree()
                needsIndexRebuild = true
                changedPaths.formUnion(documents.map { FileWatcher.canonicalPath($0.url) })
                continue
            }
            guard event.path.hasPrefix(prefix) else { continue }
            let relative = String(event.path.dropFirst(prefix.count))
            let components = relative.split(separator: "/").map(String.init)
            // Git rewrites .git/index, locks etc. constantly; none of it changes the file list,
            // but it does change status (commits, staging, checkouts).
            if components.first == ".git" {
                needsGitRefresh = true
                continue
            }
            needsGitRefresh = true

            changedPaths.insert(event.path)
            if event.isStructural {
                directoriesToReload.insert(components.dropLast().joined(separator: "/"))
                needsIndexRebuild = true
            }
        }

        for directory in directoriesToReload {
            let components = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
            rootNode.loadedNode(atRelativePath: components)?.reloadChildren()
        }
        if needsIndexRebuild {
            rebuildFileIndex(after: .milliseconds(300))
        }
        if needsGitRefresh {
            refreshGit(after: .milliseconds(300))
        }
        for document in documents where changedPaths.contains(FileWatcher.canonicalPath(document.url)) {
            document.reloadFromDiskIfChanged()
        }
    }

    // MARK: Language servers

    private func attachLanguageServer(to document: EditorDocument) {
        guard let rootURL else { return }
        Task { [weak self] in
            let environment = await ShellEnvironment.shared.environment()
            guard let self, self.rootURL == rootURL, self.documents.contains(where: { $0 === document }),
                  let config = LanguageServers.config(for: document.language, path: environment["PATH"] ?? "",
                                                      overrides: self.languageServerOverrides)
            else { return }
            let client: LanguageClient
            if let existing = languageClients[config.name] {
                client = existing
            } else {
                do {
                    client = try LanguageClient(name: config.name, command: config.command, rootURL: rootURL,
                                                environment: environment)
                } catch {
                    return // server missing or failed to launch: the editor works without it
                }
                client.onDiagnostics = { [weak self] url, diagnostics in
                    self?.document(matching: url)?.setDiagnostics(diagnostics)
                }
                languageClients[config.name] = client
            }
            document.languageClient = client
            client.didOpen(url: document.url, languageId: document.languageId,
                           text: document.textStorage.mutableString as String)
        }
    }

    /// Servers report symlink-resolved paths (/private/var/…); map them back under the
    /// workspace root so the file isn't opened twice under different names.
    private func workspaceURL(for url: URL) -> URL {
        let path = FileWatcher.canonicalPath(url)
        if let rootURL, path.hasPrefix(canonicalRootPath + "/") {
            return rootURL.appending(path: String(path.dropFirst(canonicalRootPath.count + 1)))
        }
        return URL(filePath: path)
    }

    private func document(matching url: URL) -> EditorDocument? {
        let path = FileWatcher.canonicalPath(url)
        return documents.first { $0.canonicalPath == path }
    }

    /// Jumps to the definition of the symbol at the cursor (F12, ⌘-click).
    func goToDefinition(in target: EditorDocument? = nil) {
        guard let document = target ?? activeDocument, let client = document.languageClient,
              let selection = document.editor?.textView.selectedRange() else { return }
        let position = document.lspPosition(at: selection.location)
        Task {
            guard let location = try? await client.definition(url: document.url, position: position).first else {
                NSSound.beep()
                return
            }
            open(fileAt: workspaceURL(for: location.url))
            guard let target = activeDocument else { return }
            target.reveal(target.range(for: location.range))
        }
    }

    // MARK: Git

    /// Re-reads `git status` (debounced by `delay`), then refreshes open documents' diff bases,
    /// since staging or committing changes what their gutter markers compare against.
    func refreshGit(after delay: Duration = .zero) {
        guard let rootURL else { return }
        gitTask?.cancel()
        let knownRepository = gitRepository
        gitTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let result = await Task.detached(priority: .utility) { () -> (Git.Repository, GitStatus)? in
                guard let repository = knownRepository ?? Git.repository(at: rootURL),
                      let status = Git.status(of: repository) else { return nil }
                return (repository, status)
            }.value
            guard !Task.isCancelled, self.rootURL == rootURL else { return }
            self.gitRepository = result?.0
            if self.gitStatus != result?.1 { self.gitStatus = result?.1 }
            for document in self.documents { self.loadDiffBase(for: document) }
        }
    }

    func gitStatus(for url: URL, isDirectory: Bool) -> GitFileStatus? {
        guard let gitStatus, let path = relativePath(of: url) else { return nil }
        return gitStatus.status(forRelativePath: path, isDirectory: isDirectory)
    }

    func relativePath(of url: URL) -> String? {
        guard let rootURL else { return nil }
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    private func loadDiffBase(for document: EditorDocument) {
        guard let repository = gitRepository, let path = relativePath(of: document.url) else {
            document.setDiffBase(nil)
            return
        }
        Task {
            let base = await Task.detached(priority: .utility) {
                Git.indexContent(ofRelativePath: path, in: repository)
            }.value
            document.setDiffBase(base)
        }
    }

    // MARK: Terminal

    func toggleTerminal() {
        if isTerminalVisible {
            isTerminalVisible = false
            activeDocument?.editor?.focus()
        } else {
            showTerminal()
        }
    }

    /// The terminal shown in the panel.
    var terminal: TerminalSession? {
        terminals.first { $0.id == activeTerminalID }
    }

    func showTerminal() {
        if terminals.isEmpty {
            newTerminal()
            return
        }
        isTerminalVisible = true
        terminalFocusRequest += 1
    }

    func newTerminal() {
        guard let session = makeTerminal() else { return }
        terminals.append(session)
        selectTerminal(session)
    }

    func selectTerminal(_ session: TerminalSession) {
        activeTerminalID = session.id
        isTerminalVisible = true
        terminalFocusRequest += 1
    }

    func closeTerminal(_ session: TerminalSession) {
        guard let index = terminals.firstIndex(where: { $0.id == session.id }) else { return }
        session.terminate()
        terminals.remove(at: index)
        if terminals.isEmpty {
            activeTerminalID = nil
            isTerminalVisible = false
            activeDocument?.editor?.focus()
        } else if activeTerminalID == session.id {
            selectTerminal(terminals[min(index, terminals.count - 1)])
        }
    }

    /// Replaces the active terminal with a fresh shell in the same tab position.
    func restartTerminal() {
        guard let current = terminal, let index = terminals.firstIndex(where: { $0.id == current.id }) else {
            return newTerminal()
        }
        guard let session = makeTerminal() else { return }
        current.terminate()
        terminals[index] = session
        selectTerminal(session)
    }

    private func makeTerminal() -> TerminalSession? {
        do {
            return try TerminalSession(directory: rootURL ?? FileManager.default.homeDirectoryForCurrentUser)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Palette

    func showPalette(_ mode: PaletteModel.Mode) {
        if let palette {
            palette.query = mode.prefix
        } else {
            palette = PaletteModel(workspace: self, mode: mode)
        }
    }

    func closePalette() {
        guard palette != nil else { return }
        palette = nil
        activeDocument?.editor?.focus()
    }

    func open(fileAt url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 { recentFiles.removeLast() }

        let canonical = FileWatcher.canonicalPath(url)
        if let existing = documents.first(where: { $0.url == url || $0.canonicalPath == canonical }) {
            activeDocumentID = existing.id
            return
        }
        do {
            let document = try EditorDocument(url: url)
            documents.append(document)
            activeDocumentID = document.id
            loadDiffBase(for: document)
            attachLanguageServer(to: document)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func close(_ document: EditorDocument) {
        guard confirmClose(document),
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        document.languageClient?.didClose(url: document.url)
        if activeDocumentID == document.id {
            activeDocumentID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
        }
    }

    func closeAll() {
        for document in documents.reversed() {
            close(document)
            if documents.contains(where: { $0.id == document.id }) { return } // cancelled
        }
    }

    func selectAdjacentDocument(offset: Int) {
        guard !documents.isEmpty else { return }
        let current = documents.firstIndex { $0.id == activeDocumentID } ?? 0
        activeDocumentID = documents[(current + offset + documents.count) % documents.count].id
    }

    func saveAll() {
        for document in documents where document.isDirty {
            guard save(document) else { return }
        }
    }

    func saveActive() {
        guard let document = activeDocument else { return }
        save(document)
    }

    @discardableResult
    func save(_ document: EditorDocument) -> Bool {
        do {
            try document.save()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Asks to save unsaved changes. Returns `false` if the user cancelled.
    private func confirmClose(_ document: EditorDocument) -> Bool {
        guard document.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(document.fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(document)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}
