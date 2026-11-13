import AppKit
import Observation

/// State for one editor window: the opened folder and its open documents (tabs).
@MainActor
@Observable
final class Workspace {
    private(set) var rootURL: URL?
    private(set) var rootNode: FileNode?
    /// Every open document, in any editor group.
    private(set) var documents: [EditorDocument] = []
    /// Split editor panes, left to right; there is always at least one.
    private(set) var groups: [EditorGroup]
    var activeGroupID: EditorGroup.ID {
        didSet { if activeGroupID != oldValue { retargetEditor() } }
    }
    static let maxGroups = 4

    var activeGroup: EditorGroup { groups.first { $0.id == activeGroupID } ?? groups[0] }

    /// The active group's current tab. Setting it shows that document in the active group.
    var activeDocumentID: EditorDocument.ID? {
        get { activeGroup.activeDocumentID }
        set {
            activeGroup.show(newValue)
            retargetEditor()
        }
    }
    var errorMessage: String?
    private(set) var fileIndex: FileIndex?
    /// Most recently opened first.
    private(set) var recentFiles: [URL] = []
    private(set) var palette: PaletteModel?
    enum SidebarMode: String, CaseIterable {
        case files = "Files"
        case search = "Search"
        case sourceControl = "Source Control"
        case references = "References"
    }

    @ObservationIgnored private(set) lazy var search = SearchModel(workspace: self)

    /// ⇧⌘F (⇧⌘H with `replace`): show the search panel, seeded with the editor's selection.
    func showSearch(replace: Bool = false) {
        sidebarMode = .search
        var selected: String?
        if let editor = activeDocument?.editor, let textView = editor.textView {
            let range = textView.selectedRange()
            if range.length > 0, range.length < 200 {
                selected = (textView.string as NSString).substring(with: range)
            }
        }
        search.focus(prefill: selected, replace: replace)
    }

    /// Files for Find in Files: the quick-open index (git-aware), built first if needed.
    func searchableFiles() async -> [String] {
        if fileIndex == nil, let rootURL {
            let index = await Task.detached(priority: .userInitiated) { FileIndexer.build(root: rootURL) }.value
            if self.rootURL == rootURL, fileIndex == nil { fileIndex = index }
        }
        return fileIndex?.files.map(\.text) ?? []
    }

    var sidebarMode = SidebarMode.files
    /// Last Find All References result, shown in the sidebar.
    var references: ReferenceList?
    /// Replaces the rename dialog (tests): gets the current name, returns the new one or nil.
    @ObservationIgnored var renamePrompt: ((String) -> String?)?
    private(set) var gitStatus: GitStatus?
    private(set) var isRunningGitCommand = false
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
        let group = EditorGroup()
        groups = [group]
        activeGroupID = group.id
        NotificationCenter.default.addObserver(forName: .omcEditorCommand, object: nil, queue: .main) { [weak self] note in
            let document = note.object as? EditorDocument
            let command = (note.userInfo?["command"] as? String).flatMap(EditorCommand.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, let document, let command, self.documents.contains(where: { $0 === document }) else { return }
                self.perform(command, in: document)
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
        let group = EditorGroup()
        groups = [group]
        activeGroupID = group.id
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
    func workspaceURL(for url: URL) -> URL {
        let path = FileWatcher.canonicalPath(url)
        if let rootURL, path.hasPrefix(canonicalRootPath + "/") {
            return rootURL.appending(path: String(path.dropFirst(canonicalRootPath.count + 1)))
        }
        return URL(filePath: path)
    }

    func document(matching url: URL) -> EditorDocument? {
        let path = FileWatcher.canonicalPath(url)
        return documents.first { $0.canonicalPath == path }
    }

    func perform(_ command: EditorCommand, in document: EditorDocument) {
        switch command {
        case .goToDefinition: goToDefinition(in: document)
        case .findReferences: findReferences(in: document)
        case .rename: renameSymbol(in: document)
        case .format: formatDocument(document)
        }
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

    func stage(_ paths: [String]) { runGit { try Git.stage(paths, in: $0) } }
    func unstage(_ paths: [String]) { runGit { try Git.unstage(paths, in: $0) } }

    /// Discards unstaged changes. Untracked files go to the Trash rather than being deleted.
    func discard(_ changes: [GitChange]) {
        guard let rootURL, !changes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = changes.count == 1
            ? "Discard changes in \(changes[0].path)?" : "Discard changes in \(changes.count) files?"
        alert.informativeText = changes.contains(where: \.isUntracked)
            ? "Untracked files will be moved to the Trash. Other changes can't be undone." : "This can't be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard Self.confirmDiscard?(changes) ?? (alert.runModal() == .alertFirstButtonReturn) else { return }

        let tracked = changes.filter { !$0.isUntracked }.map(\.path)
        let untracked = changes.filter(\.isUntracked).map { rootURL.appending(path: $0.path) }
        let trash = Self.moveToTrash
        runGit { repository in
            for url in untracked { try trash(url) }
            if !tracked.isEmpty { try Git.discard(tracked, in: repository) }
        }
    }

    /// Tests replace the confirmation dialog and the Trash (so runs don't fill the user's Trash).
    @ObservationIgnored static var confirmDiscard: (([GitChange]) -> Bool)?
    @ObservationIgnored nonisolated(unsafe) static var moveToTrash: @Sendable (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }

    /// Commits what is staged. Returns false (and shows the error) if git refused.
    func commit(message: String) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let repository = gitRepository else { return false }
        isRunningGitCommand = true
        defer { isRunningGitCommand = false }
        do {
            try await Task.detached { try Git.commit(message: trimmed, in: repository) }.value
            refreshGit()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func runGit(_ operation: @escaping @Sendable (Git.Repository) throws -> Void) {
        guard let repository = gitRepository else { return }
        isRunningGitCommand = true
        Task {
            do {
                try await Task.detached { try operation(repository) }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunningGitCommand = false
            refreshGit()
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

    /// Closes a document's tab in `group` (by default the active group, or wherever it is
    /// shown). The document itself closes, asking to save, once no group shows it.
    func close(_ document: EditorDocument, in group: EditorGroup? = nil) {
        guard let group = group ?? (activeGroup.contains(document.id) ? activeGroup
                                    : groups.first { $0.contains(document.id) }) else { return }
        let shownElsewhere = groups.contains { $0 !== group && $0.contains(document.id) }
        if !shownElsewhere {
            guard confirmClose(document) else { return }
            documents.removeAll { $0.id == document.id }
            document.languageClient?.didClose(url: document.url)
        }
        group.remove(document.id)
        if group.documentIDs.isEmpty { closeGroup(group) }
        retargetEditor()
    }

    func closeAll() {
        for group in groups.reversed() {
            for id in group.documentIDs.reversed() {
                guard let document = document(id: id) else { continue }
                close(document, in: group)
                if group.contains(id) { return } // cancelled
            }
        }
    }

    func selectAdjacentDocument(offset: Int) {
        let ids = activeGroup.documentIDs
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == activeDocumentID } ?? 0
        activeDocumentID = ids[(current + offset + ids.count) % ids.count]
    }

    func document(id: EditorDocument.ID?) -> EditorDocument? {
        guard let id else { return nil }
        return documents.first { $0.id == id }
    }

    func documents(in group: EditorGroup) -> [EditorDocument] {
        group.documentIDs.compactMap { document(id: $0) }
    }

    // MARK: Editor groups (split editor)

    /// ⌘\: opens the active document in a new group to the right.
    func splitEditor() {
        guard let document = activeDocument, groups.count < Self.maxGroups,
              let index = groups.firstIndex(where: { $0.id == activeGroupID }) else { NSSound.beep(); return }
        document.editor(inGroup: activeGroup)?.saveViewState()
        let group = EditorGroup()
        if let state = activeGroup.viewStates[document.id] { group.viewStates[document.id] = state }
        group.show(document.id)
        groups.insert(group, at: index + 1)
        activeGroupID = group.id
    }

    /// Moves the active tab to the next group (`offset` 1) or previous (-1), creating a group
    /// at the edge if there is none.
    func moveActiveEditor(by offset: Int) {
        guard let document = activeDocument, let index = groups.firstIndex(where: { $0.id == activeGroupID }) else { return }
        let source = activeGroup
        let targetIndex = index + offset
        let target: EditorGroup
        if groups.indices.contains(targetIndex) {
            target = groups[targetIndex]
        } else {
            guard source.documentIDs.count > 1, groups.count < Self.maxGroups else { NSSound.beep(); return }
            target = EditorGroup()
            groups.insert(target, at: offset > 0 ? index + 1 : index)
        }
        document.editor(inGroup: source)?.saveViewState()
        if let state = source.viewStates[document.id] { target.viewStates[document.id] = state }
        target.show(document.id)
        source.remove(document.id)
        if source.documentIDs.isEmpty { closeGroup(source) }
        activeGroupID = target.id
        retargetEditor()
    }

    /// ⌘1…⌘4: focuses a group's editor.
    func focusGroup(at index: Int) {
        guard groups.indices.contains(index) else { return }
        activeGroupID = groups[index].id
        activeDocument?.editor(inGroup: groups[index])?.focus()
    }

    private func closeGroup(_ group: EditorGroup) {
        guard groups.count > 1, let index = groups.firstIndex(where: { $0 === group }) else { return }
        groups.remove(at: index)
        if activeGroupID == group.id { activeGroupID = groups[max(0, index - 1)].id }
    }

    /// Cursor-based actions (go to definition, reveal) act on the active group's editor of the
    /// active document. If that group has no editor for it yet, reveals wait for the one SwiftUI
    /// is about to create. (Editors outside any group, as in tests, are left alone.)
    private func retargetEditor() {
        guard let document = activeDocument else { return }
        if let editor = document.editor(inGroup: activeGroup) {
            document.editor = editor
        } else if document.editor?.group != nil {
            document.editor = nil
        }
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
