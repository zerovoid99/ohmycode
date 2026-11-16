import AppKit

/// The editors of an editor group's tabs, kept while their tabs are hidden: switching tabs
/// swaps which editor is shown (~2 ms) instead of taking one editor apart and building another
/// (SwiftUI and AppKit tearing down and setting up the view tree, then laying out and drawing
/// a screenful of text: ~20 ms).
///
/// A hidden ("parked") editor stays in the group's view, hidden: it isn't drawn or resized,
/// and shown again it needn't join the window or redraw. It still follows its document (edits,
/// folds, diagnostics, settings) like a split's second editor does.
///
/// Kept: the `capacity` most recently shown editors, and of the hidden ones only as many as
/// fit `parkedMemoryBudget` (always the last one, so going back and forth stays quick). An
/// older tab gets a new editor when it's shown again, back at its scroll position and
/// selection, as before. A closed tab's editor goes right away (`remove`), and with it the
/// last hold on its document.
@MainActor
final class EditorCache {
    /// How many editors a group keeps, the shown one included.
    nonisolated(unsafe) static var defaultCapacity = 8
    /// What the hidden editors of a group may cost, by `estimatedCost`.
    nonisolated(unsafe) static var defaultParkedMemoryBudget = 64 << 20

    /// An editor's memory, on the safe side: a 5 MB file's editor holds about 15 MB (measured
    /// ~0.1 MB for 1 MB files; so the 8 most recent of ordinary files are always kept).
    static func estimatedCost(of document: EditorDocument) -> Int {
        256 << 10 + document.textStorage.length * 3
    }

    private struct Entry {
        let controller: EditorController
        let view: EditorContainerView
        /// The editor's size when it was hidden: shown at another size, it scrolls back to
        /// where it was (word wrap may have moved the lines).
        var parkedSize: NSSize?
    }

    var capacity: Int
    var parkedMemoryBudget = EditorCache.defaultParkedMemoryBudget
    private var entries: [EditorDocument.ID: Entry] = [:]
    /// Least recently shown first.
    private var order: [EditorDocument.ID] = []

    init(capacity: Int = EditorCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// The documents that have an editor here, least recently shown first.
    var documentIDs: [EditorDocument.ID] { order }

    func controller(for id: EditorDocument.ID) -> EditorController? { entries[id]?.controller }

    /// Puts `document`'s editor in `host`, hiding the one there. The editor is made the first
    /// time; after that it's the same editor, as it was left.
    func show(_ document: EditorDocument, group: EditorGroup?, onFocus: (() -> Void)?, in host: EditorHostView) {
        let id = document.id
        // SwiftUI may update a view on its way out with what it showed last: a tab that's
        // gone (closed, moved) doesn't get its editor back.
        if let group, !group.contains(id) { park(in: host); return }
        if host.shownID == id, let entry = entries[id], entry.controller.document === document,
           entry.view.superview === host, !entry.view.isHidden {
            entry.controller.onFocus = onFocus
            return
        }
        let previous = host.shownID
        host.shownID = nil

        var isNew = false
        if entries[id]?.controller.document !== document { drop(id) }
        if entries[id] == nil {
            let controller = EditorController(document: document, group: group)
            controller.onFocus = onFocus
            entries[id] = Entry(controller: controller, view: controller.makeView())
            isNew = true
        }
        order.removeAll { $0 == id }
        order.append(id)

        guard let entry = entries[id] else { return }
        let controller = entry.controller
        controller.onFocus = onFocus
        let resized = entry.parkedSize.map { $0 != host.bounds.size } ?? false
        if entry.view.superview !== host { host.addSubview(entry.view) }
        entry.view.frame = host.bounds
        entry.view.autoresizingMask = [.width, .height]
        entry.view.isHidden = false
        host.shownID = id
        if !isNew { // (a new one finishes setting itself up in `makeView`, and takes the focus then)
            controller.isParked = false
            if resized {
                entry.view.layoutSubtreeIfNeeded()
                controller.restoreViewState()
            }
            entries[id]?.parkedSize = nil
            controller.document.editor = controller // and any reveal waiting for it
            // Before the other one hides: the focus moves once, straight here.
            controller.focus()
        }
        if let previous, previous != id { park(previous, in: host) }
        evict(keeping: id)
    }

    /// Drops the least recently shown editors beyond `capacity` and the memory budget.
    private func evict(keeping shown: EditorDocument.ID) {
        var parked = order.filter { $0 != shown }
        var cost = parked.reduce(0) { $0 + (entries[$1].map { Self.estimatedCost(of: $0.controller.document) } ?? 0) }
        while let oldest = parked.first, parked.count + 1 > capacity || (cost > parkedMemoryBudget && parked.count > 1) {
            cost -= entries[oldest].map { Self.estimatedCost(of: $0.controller.document) } ?? 0
            parked.removeFirst()
            drop(oldest)
        }
    }

    /// Hides the editor `host` shows, keeping it (in the view, hidden: shown again, it needn't
    /// join the window again or redraw).
    func park(in host: EditorHostView) {
        guard let id = host.shownID else { return }
        host.shownID = nil
        park(id, in: host)
    }

    private func park(_ id: EditorDocument.ID, in host: EditorHostView) {
        guard var entry = entries[id], entry.view.superview === host, !entry.view.isHidden else { return }
        entry.controller.saveViewState()
        entry.controller.dismissPopups()
        entry.controller.isParked = true
        entry.parkedSize = entry.view.frame.size
        entries[id] = entry
        resignFocus(in: entry.view)
        entry.view.isHidden = true
        // Not resized with the window while hidden (it's laid out again when it's shown).
        entry.view.autoresizingMask = []
    }

    /// Hiding or removing the focused view has AppKit look for the next key view in the whole
    /// window (through SwiftUI's focus tree, which takes long). The editor shown next takes the
    /// focus anyway.
    private func resignFocus(in view: NSView) {
        if let window = view.window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
    }

    /// `host` goes (SwiftUI took it down): the editors in it leave it, for the next one.
    func detach(from host: EditorHostView) {
        park(in: host)
        for entry in entries.values where entry.view.superview === host { entry.view.removeFromSuperview() }
    }

    /// The tab closed (or moved to another group): its editor goes.
    func remove(_ id: EditorDocument.ID) { drop(id) }

    func removeAll() {
        for id in order { drop(id) }
    }

    private func drop(_ id: EditorDocument.ID) {
        order.removeAll { $0 == id }
        guard let entry = entries.removeValue(forKey: id) else { return }
        // Out of its superview before it goes: AppKit keeps a view that's still in one.
        if let host = entry.view.superview as? EditorHostView, host.shownID == id { host.shownID = nil }
        resignFocus(in: entry.view)
        entry.view.removeFromSuperview()
    }
}

/// The view an editor group's editor is shown in; the editors come and go (`EditorCache`).
@MainActor
final class EditorHostView: NSView {
    /// The document whose editor is shown.
    fileprivate(set) var shownID: EditorDocument.ID?
}
