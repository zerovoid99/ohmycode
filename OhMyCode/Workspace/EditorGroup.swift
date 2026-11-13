import Foundation
import Observation

/// One pane of the split editor: its own tabs and active tab. The documents themselves are
/// shared; a document open in two groups is one buffer shown in two editors.
@MainActor
@Observable
final class EditorGroup: Identifiable {
    let id = UUID()
    private(set) var documentIDs: [EditorDocument.ID] = []
    private(set) var activeDocumentID: EditorDocument.ID?
    /// Scroll position and selection per document, kept while a tab is hidden.
    @ObservationIgnored var viewStates: [EditorDocument.ID: EditorViewState] = [:]

    func contains(_ id: EditorDocument.ID) -> Bool { documentIDs.contains(id) }

    /// Shows a document, adding a tab for it if needed (nil shows nothing).
    func show(_ id: EditorDocument.ID?) {
        if let id, !documentIDs.contains(id) { documentIDs.append(id) }
        activeDocumentID = id
    }

    /// Removes a tab; the next one (or the previous, at the end) becomes active.
    func remove(_ id: EditorDocument.ID) {
        guard let index = documentIDs.firstIndex(of: id) else { return }
        documentIDs.remove(at: index)
        viewStates[id] = nil
        if activeDocumentID == id {
            activeDocumentID = documentIDs.isEmpty ? nil : documentIDs[min(index, documentIDs.count - 1)]
        }
    }

    func removeAll() {
        documentIDs.removeAll()
        viewStates.removeAll()
        activeDocumentID = nil
    }
}
