import AppKit
import Observation

/// Compare Files and Folders: what was picked in the Explorer to compare, and the open folder
/// comparison tabs.
@MainActor
@Observable
final class CompareController {
    @ObservationIgnored private weak var workspace: Workspace?
    /// Explorer: Select for Compare (a file or a folder), until Compare with Selected.
    var selected: URL?
    private(set) var folderTabs: [FolderComparisonSession] = []

    init(workspace: Workspace) { self.workspace = workspace }

    func folderTab(id: UUID?) -> FolderComparisonSession? {
        guard let id else { return nil }
        return folderTabs.first { $0.id == id }
    }

    /// Two folders' files, in a tab (the one already comparing them, if any).
    @discardableResult
    func compareFolders(_ left: URL, _ right: URL) -> FolderComparisonSession? {
        guard let workspace else { return nil }
        if let existing = folderTabs.first(where: { $0.left == left && $0.right == right }) {
            workspace.activeGroup.show(existing.id)
            return existing
        }
        let tab = FolderComparisonSession(left: left, right: right)
        folderTabs.append(tab)
        tab.refresh()
        workspace.activeGroup.show(tab.id)
        return tab
    }

    /// Closing the last tab of a comparison stops it.
    func closeFolderTab(_ tab: FolderComparisonSession, in group: EditorGroup) {
        group.remove(tab.id)
        if !(workspace?.groups.contains { $0.contains(tab.id) } ?? false) {
            tab.cancel()
            folderTabs.removeAll { $0 === tab }
        }
        workspace?.tabClosed(in: group)
    }
}

extension Workspace {
    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: Explorer

    /// Explorer: Compare with Selected is offered (the picked item is another of the same kind).
    func canCompareWithSelected(_ url: URL) -> Bool {
        guard let selected = comparisons.selected, selected != url else { return false }
        return Self.isDirectory(selected) == Self.isDirectory(url)
    }

    /// Explorer: Compare with Selected: the picked item on the left, `url` on the right.
    func compareWithSelected(_ url: URL) {
        guard let selected = comparisons.selected, canCompareWithSelected(url) else { NSSound.beep(); return }
        if Self.isDirectory(url) {
            comparisons.compareFolders(selected, url)
        } else {
            compareFiles(selected, url)
        }
    }

    // MARK: Files

    /// `right` against `left`: the right side is the editor's text (live, edited in its tab);
    /// the left is `left`'s text when compared. Files that aren't both text only say whether
    /// they differ.
    @discardableResult
    func compareFiles(_ left: URL, _ right: URL) -> DiffSession? {
        let comparison = FileComparison.file(left)
        let canonical = FileWatcher.canonicalPath(right)
        if let existing = diffSessions.first(where: { $0.mode == .files(comparison) && FileWatcher.canonicalPath($0.url) == canonical }) {
            activeGroup.show(existing.id)
            return existing
        }
        let leftText = document(matching: left).map { $0.textStorage.string } ?? Self.text(of: left)
        guard let leftText, FileKind.detect(right) == .text || document(matching: right) != nil else {
            let same = FileManager.default.contentsEqual(atPath: left.path, andPath: right.path)
            let session = DiffSession(binary: comparison, of: right, identical: same)
            addDiffSession(session)
            return session
        }
        let wasOpen = document(matching: right) != nil
        guard let document = document(matching: right) ?? openWithoutTab(right) else { return nil }
        let session = DiffSession(document: document, ownsDocument: !wasOpen, comparing: comparison)
        session.setLoaded(base: leftText, current: nil, isNewFile: false)
        addDiffSession(session)
        return session
    }

    /// A text file's content (nil: not text, or unreadable).
    nonisolated static func text(of url: URL) -> String? {
        guard FileKind.detect(url) == .text, let data = try? Data(contentsOf: url) else { return nil }
        return EditorDocument.decode(data)?.text
    }

    /// The comparison with the sides the other way round, in its place.
    func swapSides(of session: DiffSession) {
        guard case .files(.file(let left)) = session.mode,
              let group = groups.first(where: { $0.contains(session.id) }) else { return }
        let index = group.documentIDs.firstIndex(of: session.id)
        activeGroupID = group.id
        guard let swapped = compareFiles(session.url, left) else { return }
        if let index { group.insert(swapped.id, at: index) }
        closeDiffSessions { $0 === session }
        group.show(swapped.id)
    }

    /// The clipboard's text (or `text`) against the file's text in the editor.
    @discardableResult
    func compareWithClipboard(_ url: URL, text: String? = nil) -> DiffSession? {
        guard let clip = text ?? NSPasteboard.general.string(forType: .string) else {
            errorMessage = "The clipboard has no text to compare with."
            return nil
        }
        return compareText(clip, as: .clipboard, with: url)
    }

    /// The file on disk against its unsaved edits.
    @discardableResult
    func compareWithSaved(_ url: URL) -> DiffSession? {
        guard let saved = Self.text(of: url) else {
            errorMessage = "\(url.lastPathComponent) can't be read from disk."
            return nil
        }
        return compareText(saved, as: .saved, with: url)
    }

    /// `text` on the left (in the tab already comparing the same, if any) against the editor's.
    private func compareText(_ text: String, as comparison: FileComparison, with url: URL) -> DiffSession? {
        let canonical = FileWatcher.canonicalPath(url)
        if let existing = diffSessions.first(where: { $0.mode == .files(comparison) && FileWatcher.canonicalPath($0.url) == canonical }) {
            existing.setLoaded(base: text, current: nil, isNewFile: false)
            activeGroup.show(existing.id)
            return existing
        }
        let wasOpen = document(matching: url) != nil
        guard let document = document(matching: url) ?? openWithoutTab(url) else { return nil }
        let session = DiffSession(document: document, ownsDocument: !wasOpen, comparing: comparison)
        session.setLoaded(base: text, current: nil, isNewFile: false)
        addDiffSession(session)
        return session
    }

    /// Compare Active File with…: a pick of the folder's files (like Go to File); the one picked
    /// goes on the left.
    func pickFileToCompare(with url: URL) async {
        guard let index = fileIndex, !index.files.isEmpty else {
            errorMessage = rootNode == nil ? "Open a folder to pick a file to compare with." : "The folder's files are still being listed."
            return
        }
        let items = index.files.map { QuickPickItem(label: $0.text) }
        guard let picked = await showQuickPick(items, placeholder: "File to compare \(url.lastPathComponent) with"),
              index.files.indices.contains(picked) else { return }
        compareFiles(index.url(for: index.files[picked]), url)
    }

    // MARK: Folders

    /// Compare Folder with…: picks folders anywhere. Two picked: they're compared; one: the
    /// folder selected for compare (or the workspace's) against it.
    func presentCompareFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a folder to compare with, or two folders to compare"
        panel.prompt = "Compare"
        guard panel.runModal() == .OK, let first = panel.urls.first else { return }
        if panel.urls.count >= 2 {
            comparisons.compareFolders(first, panel.urls[1])
            return
        }
        let selectedFolder = comparisons.selected.flatMap { Self.isDirectory($0) ? $0 : nil }
        guard let left = selectedFolder ?? rootURL else {
            errorMessage = "Open a folder (or pick two) to compare."
            return
        }
        comparisons.compareFolders(left, first)
    }
}
