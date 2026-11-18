import AppKit
import Observation

/// What a viewer's zoom commands (⌘+, ⌘-, ⌘0, the footer's buttons) act on: the view showing it.
@MainActor
protocol ViewerZoomable: AnyObject {
    func zoomIn()
    func zoomOut()
    func zoomToFit()
    func zoomToActualSize()
}

/// A tab for a file the text editor doesn't show: an image, an SVG's picture, a PDF, or the bytes
/// of a binary file. It shares tab ids with documents and diff tabs (its id is a tab id in the
/// groups) but has no text: saving, find, language servers and git markers never see it.
@MainActor
@Observable
final class FileViewer: Identifiable {
    enum Kind: Equatable {
        case image, svg, pdf, hex
        /// A SQLite file: its tables, a query on it (see DatabaseFileView).
        case database

        /// The viewer for a kind of file (none for text).
        init?(_ kind: FileKind) {
            switch kind {
            case .text: return nil
            case .image: self = .image
            case .svg: self = .svg
            case .pdf: self = .pdf
            case .binary: self = .hex
            case .sqlite: self = .database
            }
        }
    }

    let id = UUID()
    let kind: Kind
    private(set) var url: URL
    private(set) var fileSize = 0
    /// Bumped when the file changes on disk: the view reads it again.
    private(set) var version = 0
    /// The zoom shown, as a fraction (1 is actual size), when the view has one.
    var displayedScale: CGFloat?
    /// The view zoom commands go to (the last one shown, with a split).
    @ObservationIgnored weak var zoomTarget: ViewerZoomable?
    /// Resolved while the file is there: once it's trashed, symlinks in its path can't be.
    @ObservationIgnored private(set) var canonicalPath: String
    @ObservationIgnored private var modificationDate: Date?

    var fileName: String { url.lastPathComponent }

    init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
        canonicalPath = FileWatcher.canonicalPath(url)
        readAttributes()
    }

    /// The file changed on disk (the watcher saw it): shown again if it really did.
    func reloadIfChanged() {
        let previous = (modificationDate, fileSize)
        readAttributes()
        if previous.0 != modificationDate || previous.1 != fileSize { version += 1 }
    }

    /// The file was moved or renamed: the tab follows it.
    func move(to url: URL) {
        self.url = url
        canonicalPath = FileWatcher.canonicalPath(url)
        reloadIfChanged()
    }

    private func readAttributes() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        modificationDate = attributes?[.modificationDate] as? Date
        fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Zoom commands, or false when this kind has no zoom of its own (the hex view follows the
    /// editor's font size, so the editor's zoom applies).
    @discardableResult
    func zoom(_ action: ZoomAction) -> Bool {
        guard kind != .hex, let target = zoomTarget else { return false }
        switch action {
        case .zoomIn: target.zoomIn()
        case .zoomOut: target.zoomOut()
        case .fit: target.zoomToFit()
        case .actualSize: target.zoomToActualSize()
        }
        return true
    }

    enum ZoomAction { case zoomIn, zoomOut, fit, actualSize }

    /// "245 KB": file sizes in the footer.
    static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: Viewer tabs

extension Workspace {
    func viewer(id: UUID?) -> FileViewer? {
        guard let id else { return nil }
        return viewers.first { $0.id == id }
    }

    /// ⌘+, ⌘-, ⌘0: an image or PDF tab zooms itself; elsewhere the editor's and terminal's
    /// text does (the hex view's too, as it uses the editor's font).
    static func zoom(_ action: FileViewer.ZoomAction, in workspace: Workspace?) {
        if workspace?.activeViewer?.zoom(action) == true { return }
        switch action {
        case .zoomIn: AppSettings.shared.zoom(by: 1)
        case .zoomOut: AppSettings.shared.zoom(by: -1)
        case .fit, .actualSize: AppSettings.shared.resetZoom()
        }
    }

    /// The active group's tab, when it's a viewer.
    var activeViewer: FileViewer? { viewer(id: activeGroup.activeDocumentID) }

    func viewer(matching url: URL) -> FileViewer? {
        let path = FileWatcher.canonicalPath(url)
        return viewers.first { $0.canonicalPath == path }
    }

    /// Opens a viewer tab for `url` (or shows the one open), in the active group.
    @discardableResult
    func openViewer(for url: URL, kind: FileViewer.Kind) -> FileViewer {
        if let existing = viewer(matching: url), existing.kind == kind {
            activeDocumentID = existing.id
            return existing
        }
        let viewer = FileViewer(url: url, kind: kind)
        let isFirst = documents.isEmpty && viewers.isEmpty
        viewers.append(viewer)
        // Right after the tab it was opened from, like a preview.
        if let current = activeGroup.activeDocumentID, let index = activeGroup.documentIDs.firstIndex(of: current) {
            activeGroup.insert(viewer.id, at: index + 1)
        }
        activeDocumentID = viewer.id
        if isFirst, rootURL == nil { restoreFolderlessSession(firstFile: url) }
        return viewer
    }

    /// An SVG's picture, beside its text (the editor's preview button).
    func openPreview(of document: EditorDocument) {
        guard FileKind.kind(forExtension: document.url.pathExtension) == .svg else { return }
        openViewer(for: document.url, kind: .svg)
    }

    /// Open as Text (Anyway): the viewer's tab becomes a text editor for the file, in the same
    /// place in each group. A binary file is read as UTF-8 with what isn't replaced.
    @discardableResult
    func openAsText(_ viewer: FileViewer) -> EditorDocument? {
        let document: EditorDocument
        if let existing = self.document(matching: viewer.url) {
            document = existing
        } else {
            do {
                document = try EditorDocument(url: viewer.url, allowingBinary: true)
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
            addDocument(document)
        }
        for group in groups where group.contains(viewer.id) {
            if group.contains(document.id) {
                if group.activeDocumentID == viewer.id { group.show(document.id) }
                group.remove(viewer.id)
            } else {
                group.replace(viewer.id, with: document.id)
            }
        }
        viewers.removeAll { $0 === viewer }
        activeDocumentID = document.id
        return document
    }

    /// Closes a viewer's tab in `group`; the viewer goes once no group shows it.
    func closeViewer(_ viewer: FileViewer, in group: EditorGroup) {
        group.remove(viewer.id)
        if !groups.contains(where: { $0.contains(viewer.id) }) { viewers.removeAll { $0 === viewer } }
        tabClosed(in: group)
    }

    /// Viewers of a file that's gone (moved to the Trash) close.
    func discardViewers(at path: String) {
        for viewer in viewers where viewer.canonicalPath == path || viewer.canonicalPath.hasPrefix(path + "/") {
            for group in groups where group.contains(viewer.id) { closeViewer(viewer, in: group) }
        }
    }

    /// Viewers at (or under) a moved path follow it.
    func moveViewers(from oldPath: String, to destination: URL) {
        for viewer in viewers where viewer.canonicalPath == oldPath || viewer.canonicalPath.hasPrefix(oldPath + "/") {
            let rest = viewer.canonicalPath.dropFirst(oldPath.count + 1)
            viewer.move(to: rest.isEmpty ? destination : destination.appending(path: String(rest)))
        }
    }
}
