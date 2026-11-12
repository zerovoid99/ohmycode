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
    @ObservationIgnored private var indexTask: Task<Void, Never>?

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
        rebuildFileIndex()
    }

    func rebuildFileIndex() {
        guard let rootURL else { return }
        indexTask?.cancel()
        fileIndex = nil
        indexTask = Task {
            let index = await Task.detached(priority: .userInitiated) {
                FileIndexer.build(root: rootURL)
            }.value
            guard !Task.isCancelled, self.rootURL == rootURL else { return }
            self.fileIndex = index
            if self.palette?.mode == .files { self.palette?.refresh() }
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
