import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        NavigationSplitView {
            if let root = workspace.rootNode {
                FileTreeView(root: root, workspace: workspace)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 480)
            }
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    editorArea
                        .frame(minHeight: 120)
                    if workspace.isTerminalVisible, let terminal = workspace.terminal {
                        TerminalPanel(workspace: workspace, session: terminal)
                            .frame(minHeight: 90, idealHeight: 260)
                    }
                }
                Divider()
                StatusBarView(document: workspace.activeDocument, gitStatus: workspace.gitStatus)
            }
        }
        .navigationTitle(workspace.displayName)
        .navigationSubtitle(workspace.activeDocument?.fileName ?? "")
    }

    private var editorArea: some View {
        VStack(spacing: 0) {
            if !workspace.documents.isEmpty {
                TabBarView(workspace: workspace)
                Divider()
            }
            if let document = workspace.activeDocument {
                CodeEditorView(document: document)
                    .id(document.id)
            } else {
                ContentUnavailableView(
                    "No Open Editors",
                    systemImage: "doc.text",
                    description: Text("Select a file in the sidebar to open it.")
                )
            }
        }
    }
}
