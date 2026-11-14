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
                    Image(systemName: "clock.arrow.circlepath").help("Timeline").tag(Workspace.SidebarMode.history)
                    Image(systemName: "ladybug").help("Run and Debug (⇧⌘D)").tag(Workspace.SidebarMode.debug)
                    Image(systemName: "puzzlepiece.extension").help("Extensions").tag(Workspace.SidebarMode.extensions)
                    if workspace.references != nil {
                        Image(systemName: "link").help("References").tag(Workspace.SidebarMode.references)
                    }
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
                case .references:
                    ReferencesView(workspace: workspace)
                case .history:
                    TimelineView(workspace: workspace)
                case .extensions:
                    ExtensionsView(workspace: workspace)
                case .debug:
                    DebugView(workspace: workspace)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .themedBackground(.sidebar, fallback: .clear)
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 480)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    editorArea
                        // Fill the split's height: without a max, an empty editor area (no
                        // ideal height) let VSplitView collapse it and misplace the status bar.
                        .frame(minHeight: 120, maxHeight: .infinity)
                    if workspace.isTerminalVisible, workspace.bottomPanel == .tasks {
                        TasksView(workspace: workspace)
                            .frame(minHeight: 90, idealHeight: 260)
                    } else if workspace.isTerminalVisible, workspace.bottomPanel == .problems {
                        ProblemsView(workspace: workspace)
                            .frame(minHeight: 90, idealHeight: 260)
                    } else if workspace.isTerminalVisible, workspace.bottomPanel == .debugConsole {
                        DebugConsoleView(workspace: workspace)
                            .frame(minHeight: 90, idealHeight: 260)
                    } else if workspace.isTerminalVisible, let terminal = workspace.terminal {
                        TerminalPanel(workspace: workspace, session: terminal)
                            .frame(minHeight: 90, idealHeight: 260)
                    }
                }
                Divider()
                StatusBarView(document: workspace.activeDocument, gitStatus: workspace.gitStatus,
                              problems: workspace.rootURL == nil ? nil : workspace.problems,
                              showProblems: { workspace.toggleProblems() },
                              tasks: workspace.taskRuns.filter { $0.state.isRunning },
                              showTasks: { workspace.showTasks() },
                              items: workspace.extensions.statusItems) { workspace.extensions.run($0) }
            }
            .overlay(alignment: .bottomTrailing) {
                NotificationsOverlay(workspace: workspace).padding(.bottom, 22)
            }
        }
        .sheet(item: $workspace.pendingEdit) { preview in
            EditPreviewView(preview: preview, workspace: workspace)
        }
        .sheet(item: $workspace.pendingRebase) { plan in
            InteractiveRebaseView(workspace: workspace, plan: plan)
        }
        .navigationTitle(workspace.displayName)
        .navigationSubtitle(workspace.activeDocument?.fileName ?? "")
    }

    private var changeCountLabel: String {
        let count = workspace.gitStatus?.changedFileCount ?? 0
        return count > 0 ? "Source Control (\(count))" : "Source Control"
    }

    /// Editor groups side by side (split editor); a single group fills the area.
    private var editorArea: some View {
        HSplitView {
            ForEach(workspace.groups) { group in
                EditorGroupView(workspace: workspace, group: group)
                    .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
