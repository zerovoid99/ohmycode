import SwiftUI

/// One pane of the split editor: its tab bar and the active tab's editor.
struct EditorGroupView: View {
    let workspace: Workspace
    let group: EditorGroup

    private var isActive: Bool { workspace.activeGroupID == group.id }
    private var showsActiveMarker: Bool { isActive && workspace.groups.count > 1 }

    private func editor(_ document: EditorDocument) -> some View {
        CodeEditorView(document: document, group: group,
                       onFocus: { [weak workspace, weak group] in
                           guard let workspace, let group else { return }
                           if workspace.activeGroupID != group.id { workspace.activeGroupID = group.id }
                       })
            .id(document.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !group.documentIDs.isEmpty, !workspace.isZenMode {
                TabBarView(workspace: workspace, group: group)
                    .overlay(alignment: .top) {
                        // Which pane has focus, when there are several.
                        if showsActiveMarker { Color.accentColor.frame(height: 2) }
                    }
                Divider()
            }
            if let document = workspace.document(id: group.activeDocumentID) {
                if AppSettings.shared.showsBreadcrumbs, !workspace.isZenMode {
                    BreadcrumbsView(workspace: workspace, document: document)
                    Divider()
                }
                if workspace.showsMarkdownPreview(document) {
                    HSplitView {
                        editor(document)
                            .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                        MarkdownPreviewView(workspace: workspace, document: document)
                            .id(document.id)
                            .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    editor(document)
                        .overlay(alignment: .topTrailing) {
                            if document.language == .markdown {
                                Button { workspace.toggleMarkdownPreview(document) } label: {
                                    Image(systemName: "doc.richtext")
                                }
                                .buttonStyle(.borderless)
                                .help("Open Preview to the Side (⇧⌘V)")
                                // Left of the minimap (and the scroller), not on it.
                                .padding(.trailing, 22 + (AppSettings.shared.showsMinimap ? MinimapView.width : 0))
                                .padding(.top, 6)
                            }
                        }
                }
            } else if let session = workspace.diffSession(id: group.activeDocumentID) {
                DiffView(session: session, workspace: workspace)
                    .id(session.id)
            } else {
                ContentUnavailableView(
                    "No Open Editors",
                    systemImage: "doc.text",
                    description: Text("Select a file in the sidebar to open it.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .editorBackground()
            }
        }
    }
}
