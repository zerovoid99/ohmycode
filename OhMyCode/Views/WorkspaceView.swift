import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Sidebar", selection: $workspace.sidebarMode) {
                    Image(systemName: "folder").help("Explorer (⇧⌘E)").tag(Workspace.SidebarMode.files)
                    Image(systemName: "magnifyingglass").help("Search (⇧⌘F)").tag(Workspace.SidebarMode.search)
                    Image(systemName: "arrow.triangle.branch").help(changeCountLabel + " (⌃⇧G)")
                        .tag(Workspace.SidebarMode.sourceControl)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                switch workspace.sidebarMode {
                case .files:
                    if let root = workspace.rootNode {
                        FileTreeView(root: root, workspace: workspace)
                    }
                case .search:
                    SearchView(model: workspace.search)
                case .sourceControl:
                    SourceControlView(workspace: workspace)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 480)
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

    private var changeCountLabel: String {
        let count = workspace.gitStatus?.changedFileCount ?? 0
        return count > 0 ? "Source Control (\(count))" : "Source Control"
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
