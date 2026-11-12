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
    private(set) var terminal: TerminalSession?
    private(set) var isTerminalVisible = false
    /// Bumped to move keyboard focus into the terminal.
    private(set) var terminalFocusRequest = 0
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    /// Root as FSEvents reports paths (symlinks resolved).
    @ObservationIgnored private var canonicalRootPath = ""

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
        terminal?.terminate()
        terminal = nil
        isTerminalVisible = false

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
            // Git rewrites .git/index, locks etc. constantly; none of it changes the file list.
            if components.first == ".git" { continue }

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
        for document in documents where changedPaths.contains(FileWatcher.canonicalPath(document.url)) {
            document.reloadFromDiskIfChanged()
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

    func showTerminal() {
        if terminal == nil { terminal = makeTerminal() }
        guard terminal != nil else { return }
        isTerminalVisible = true
        terminalFocusRequest += 1
    }

    func restartTerminal() {
        terminal?.terminate()
        terminal = makeTerminal()
        isTerminalVisible = terminal != nil
        terminalFocusRequest += 1
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

        if let existing = documents.first(where: { $0.url == url }) {
            activeDocumentID = existing.id
            return
        }
        do {
            let document = try EditorDocument(url: url)
            documents.append(document)
            activeDocumentID = document.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func close(_ document: EditorDocument) {
        guard confirmClose(document),
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
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
