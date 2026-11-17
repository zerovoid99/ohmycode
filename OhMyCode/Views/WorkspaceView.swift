import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        NavigationSplitView(columnVisibility: $workspace.sidebarVisibility) {
            HStack(spacing: 0) {
                ActivityBar(workspace: workspace)
                Divider()
                VStack(spacing: 0) {
                    // The Agent panel's header is its own (the agent picker).
                    if workspace.sidebarMode != .agent {
                        SidebarPanelHeader(title: panelTitle, subtitle: panelSubtitle) { panelActions }
                    }
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
                    case .testing:
                        TestingView(workspace: workspace)
                    case .outline:
                        OutlineView(workspace: workspace)
                    case .callHierarchy:
                        CallHierarchyView(workspace: workspace)
                    case .pullRequests:
                        PullRequestsView(workspace: workspace)
                    case .agent:
                        AgentPanelView(panel: workspace.agentPanel, workspace: workspace)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            // Whatever a mode's content asks for, the sidebar never sets the window's minimum
            // height: a taller minimum than the screen pushed the whole sidebar (its picker
            // too) up under the title bar.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .themedBackground(.sidebar, fallback: .clear)
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 520)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    ZenCentered(isZen: workspace.isZenMode) { editorArea }
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
                if !workspace.isZenMode {
                Divider()
                ActiveStatusBar(workspace: workspace)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                NotificationsOverlay(workspace: workspace).padding(.bottom, 22)
            }
        }
        .sheet(item: $workspace.pendingEdit) { preview in
            EditPreviewView(preview: preview, workspace: workspace)
        }
        .sheet(item: $workspace.pendingMerge) { session in
            MergeEditorView(session: session, workspace: workspace)
        }
        .sheet(item: $workspace.pendingRebase) { plan in
            InteractiveRebaseView(workspace: workspace, plan: plan)
        }
        // Zen mode: no title bar either (full screen shows it again on hover at the top).
        .toolbar(workspace.isZenMode ? .hidden : .automatic, for: .windowToolbar)
        .navigationTitle(workspace.displayName)
        .modifier(ActiveDocumentSubtitle(workspace: workspace))
    }

    private var panelTitle: String {
        workspace.sidebarMode == .files ? "Explorer" : workspace.sidebarMode.rawValue
    }

    private var panelSubtitle: String? {
        switch workspace.sidebarMode {
        case .files: workspace.rootURL?.lastPathComponent
        case .sourceControl: workspace.gitStatus?.branch
        default: nil
        }
    }

    @ViewBuilder private var panelActions: some View {
        switch workspace.sidebarMode {
        case .files where workspace.rootNode != nil:
            Button { workspace.promptNewFile(in: nil) } label: { Image(systemName: "doc.badge.plus") }
                .help("New File…")
            Button { workspace.promptNewFolder(in: nil) } label: { Image(systemName: "folder.badge.plus") }
                .help("New Folder…")
        case .sourceControl where workspace.rootNode != nil:
            Button { workspace.refreshGit() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        default:
            EmptyView()
        }
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

// The active document is read in these views' own bodies, not in `WorkspaceView`'s: switching
// tabs then updates them, not the whole window (the sidebar and its picker included).

/// The status bar, for the active document.
private struct ActiveStatusBar: View {
    let workspace: Workspace

    var body: some View {
        StatusBarView(document: workspace.activeDocument, gitStatus: workspace.gitStatus,
                      problems: workspace.rootURL == nil ? nil : workspace.problems,
                      showProblems: { workspace.toggleProblems() },
                      tasks: workspace.taskRuns.filter { $0.state.isRunning },
                      showTasks: { workspace.showTasks() },
                      items: workspace.extensions.statusItems,
                      run: { workspace.extensions.run($0) },
                      claudeCodeSessions: workspace.claudeCode.connectedCount,
                      agentActivity: agentActivity,
                      showAgent: { workspace.sidebarMode = .agent; workspace.sidebarVisibility = .all },
                      goToLine: { workspace.showPalette(.goToLine) },
                      showSourceControl: { workspace.sidebarMode = .sourceControl; workspace.sidebarVisibility = .all })
    }

    private var agentActivity: StatusBarView.AgentActivity? {
        guard let client = workspace.agentPanel.client else { return nil }
        if !client.permissions.isEmpty { return .waiting }
        return client.state == .working ? .working : nil
    }
}

/// The window's subtitle: the active document's name.
private struct ActiveDocumentSubtitle: ViewModifier {
    let workspace: Workspace

    func body(content: Content) -> some View {
        content.navigationSubtitle(workspace.activeDocument?.fileName ?? "")
    }
}
