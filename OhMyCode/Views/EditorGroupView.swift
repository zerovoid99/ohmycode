import SwiftUI

/// One pane of the split editor: its tab bar and the active tab's editor.
struct EditorGroupView: View {
    let workspace: Workspace
    let group: EditorGroup

    private var isActive: Bool { workspace.activeGroupID == group.id }
    private var showsActiveMarker: Bool { isActive && workspace.groups.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            if !group.documentIDs.isEmpty {
                TabBarView(workspace: workspace, group: group)
                    .overlay(alignment: .top) {
                        // Which pane has focus, when there are several.
                        if showsActiveMarker { Color.accentColor.frame(height: 2) }
                    }
                Divider()
            }
            if let document = workspace.document(id: group.activeDocumentID) {
                CodeEditorView(document: document, group: group,
                               onFocus: { [weak workspace, weak group] in
                                   guard let workspace, let group else { return }
                                   if workspace.activeGroupID != group.id { workspace.activeGroupID = group.id }
                               })
                    .id(document.id)
            } else {
                ContentUnavailableView(
                    "No Open Editors",
                    systemImage: "doc.text",
                    description: Text("Select a file in the sidebar to open it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}
