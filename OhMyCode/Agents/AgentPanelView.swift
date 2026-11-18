import SwiftUI

/// The Agent sidebar: pick an agent, talk to it, answer what it asks.
struct AgentPanelView: View {
    @Bindable var panel: AgentPanel
    let workspace: Workspace
    private let store = AgentStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if workspace.rootURL == nil {
                ContentUnavailableView("No Folder Open", systemImage: "folder",
                                       description: Text("An agent works in a folder: open one first."))
            } else if let client = panel.client {
                AgentConversationView(panel: panel, client: client, workspace: workspace)
            } else {
                start
            }
        }
    }

    /// As `SidebarPanelHeader` lays out the other panels' (the agent picker after the title).
    private var header: some View {
        HStack(spacing: 6) {
            Text("AGENT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            agentPicker
            Spacer(minLength: 4)
            Group { headerActions }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
    }

    private var agentPicker: some View {
        Menu {
            Picker("Agent", selection: Binding(get: { panel.selectedAgent?.id }, set: { panel.selectedAgentID = $0 })) {
                ForEach(store.definitions) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(panel.selectedAgent?.name ?? "No Agent")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The agent to start")
        .disabled(store.definitions.isEmpty)
    }

    @ViewBuilder private var headerActions: some View {
        if let client = panel.client {
            AgentStateBadge(state: client.state, title: client.agentTitle ?? client.definition.name)
        }
        Button { panel.newThread() } label: { Image(systemName: "square.and.pencil") }
            .help("New Thread")
            .disabled(workspace.rootURL == nil || panel.selectedAgent == nil)
        Menu {
            if let client = panel.client, client.canLoadSessions {
                Menu("Open Earlier Thread") {
                    if client.recentSessions.isEmpty { Text("None in this folder") }
                    ForEach(client.recentSessions) { session in
                        Button {
                            Task { await client.loadSession(session) }
                        } label: {
                            Text(session.title)
                            if let date = session.updatedAt { Text(date.formatted(.relative(presentation: .named))) }
                        }
                    }
                }
                .disabled(client.state == .starting || client.state == .working)
                Divider()
            }
            Button("Restart Agent") { panel.start() }
                .disabled(workspace.rootURL == nil || panel.selectedAgent == nil)
            Button("Stop Agent") { panel.stop() }
                .disabled(panel.client == nil)
            if let client = panel.client {
                Button("Show Log") { panel.showsLog = true }
                    .disabled(client.log.isEmpty)
            }
            Divider()
            SettingsLink { Text("Agent Settings…") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private var start: some View {
        AgentPlaceholder(systemImage: "sparkles") {
            if let agent = panel.selectedAgent {
                Text(agent.name).font(.headline)
                Text("The agent works in this folder. It reads files as the editor has them (unsaved changes too), and asks before it edits or runs anything.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Start \(agent.name)") { panel.start() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                Text(agent.command)
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(2).truncationMode(.middle)
                    .help(agent.command)
            } else {
                Text("No Agents").font(.headline)
                Text("Add an agent that speaks the Agent Client Protocol in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                SettingsLink { Text("Agent Settings…") }
                    .padding(.top, 4)
            }
        }
    }
}

/// A centered state (no agent running, failed, signing in): an icon, then what's given.
private struct AgentPlaceholder<Content: View>: View {
    let systemImage: String
    var tint: Color = .secondary
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(tint)
                    .padding(.bottom, 4)
                content
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }
}

private struct AgentStateBadge: View {
    let state: AgentClient.State
    let title: String

    var body: some View {
        Group {
            switch state {
            case .starting, .working: ProgressView().controlSize(.mini)
            case .ready: Circle().fill(.green).frame(width: 7, height: 7)
            case .needsAuthentication: Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .stopped: Circle().fill(.secondary).frame(width: 7, height: 7)
            }
        }
        .frame(width: 16, height: 16)
        .help("\(title): \(description)")
    }

    private var description: String {
        switch state {
        case .starting: "Starting…"
        case .working: "Working…"
        case .ready: "Ready"
        case .needsAuthentication: "Sign in needed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

/// Following a transcript's end: it scrolls to show what comes in only while the reader is at
/// the end already (not once they scrolled up to read something).
enum AgentTranscriptScroll {
    struct Geometry: Equatable {
        var visibleMaxY: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
    }

    /// How near the end counts as at it (the last line, about).
    static let slack: CGFloat = 32

    static func isAtEnd(_ geometry: Geometry) -> Bool {
        geometry.visibleMaxY >= geometry.contentHeight - slack
    }

    /// The content (or the room for it) changed with the end in view, and the very end isn't
    /// in view any more: scroll to it again. (Even by a little: small changes left unfollowed
    /// would add up to the end out of view.)
    static func follows(from old: Geometry, to new: Geometry) -> Bool {
        let resized = old.contentHeight != new.contentHeight || old.containerHeight != new.containerHeight
        return resized && isAtEnd(old) && new.visibleMaxY < new.contentHeight - 1
    }
}

/// The conversation, what the agent asks, and the prompt.
private struct AgentConversationView: View {
    @Bindable var panel: AgentPanel
    let client: AgentClient
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            switch client.state {
            case .failed(let message):
                failure(message)
            case .needsAuthentication:
                authentication
            default:
                if let title = client.sessionTitle, !title.isEmpty, client.state != .starting {
                    Text(title)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .help(title)
                    Divider()
                }
                AgentTranscriptView(client: client, workspace: workspace)
                if !client.plan.isEmpty { AgentPlanView(plan: client.plan) }
                ForEach(client.permissions) { permission in
                    AgentPermissionCard(permission: permission, client: client, workspace: workspace)
                }
                if panel.selectionDiffersFromRunning, let agent = panel.selectedAgent {
                    switchBanner(agent)
                }
                AgentPromptView(panel: panel, client: client)
            }
        }
        .sheet(isPresented: $panel.showsLog) { AgentLogView(log: client.log, name: client.definition.name) }
    }

    /// The picker names another agent than the one in this conversation.
    private func switchBanner(_ agent: AgentDefinition) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.swap").foregroundStyle(.secondary)
            Text("\(agent.name) is picked; this thread is \(client.definition.name)'s.")
                .foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 4)
            Button("Start") { panel.start() }.controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .overlay(alignment: .top) { Divider() }
    }

    private func failure(_ message: String) -> some View {
        AgentPlaceholder(systemImage: "exclamationmark.triangle", tint: .orange) {
            Text("\(client.definition.name) Isn’t Running").font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Try Again") { panel.start() }.buttonStyle(.borderedProminent)
                if !client.log.isEmpty { Button("Show Log") { panel.showsLog = true } }
            }
            .padding(.top, 4)
            SettingsLink { Text("Agent Settings…") }
                .buttonStyle(.link).font(.caption)
                .padding(.top, 2)
        }
    }

    private var authentication: some View {
        AgentPlaceholder(systemImage: "person.crop.circle.badge.exclamationmark", tint: .orange) {
            Text("Sign in to \(client.definition.name)").font(.headline)
            if client.authMethods.isEmpty {
                Text("The agent asks to sign in but offers no way to here. Sign in with its own command line tool, then restart it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                ForEach(client.authMethods) { method in
                    VStack(spacing: 3) {
                        Button { Task { await client.authenticate(method) } } label: {
                            Text(method.name).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if let description = method.description {
                            Text(description).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: 260)
            .disabled(client.isAuthenticating)
            .padding(.top, 4)
            if client.isAuthenticating {
                ProgressView("Signing in…").controlSize(.small).font(.caption)
            } else if let error = client.authenticationError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Button("Restart Agent") { panel.start() }
                .buttonStyle(.link).font(.caption)
                .padding(.top, 4)
        }
    }
}

/// The conversation so far, following its end as it streams in.
private struct AgentTranscriptView: View {
    let client: AgentClient
    let workspace: Workspace
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(client.entries) { entry in
                    AgentEntryView(entry: entry, client: client, workspace: workspace,
                                   isStreaming: client.state == .working && entry.id == client.entries.last?.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollPosition($position)
        // Back in the panel (switched away and back): at the end, where the conversation is.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: AgentTranscriptScroll.Geometry.self) { geometry in
            .init(visibleMaxY: geometry.visibleRect.maxY, contentHeight: geometry.contentSize.height,
                  containerHeight: geometry.containerSize.height)
        } action: { old, new in
            if AgentTranscriptScroll.follows(from: old, to: new) { position.scrollTo(edge: .bottom) }
        }
        // What the user sends is always shown, wherever they were reading.
        .onChange(of: client.entries.last?.id) {
            if case .user = client.entries.last?.kind { position.scrollTo(edge: .bottom) }
        }
        .overlay {
            if client.entries.isEmpty { emptyState }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            if client.state == .starting {
                ProgressView().controlSize(.small)
                Text(client.sessionTitle.map { "Opening \"\($0)\"…" } ?? "Starting \(client.definition.name)…")
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                Text("Ask \(client.agentTitle ?? client.definition.name) to do something in this folder.")
            }
        }
        .font(.callout).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(20)
        .allowsHitTesting(false)
    }
}

private struct AgentEntryView: View {
    let entry: AgentEntry
    let client: AgentClient
    let workspace: Workspace
    /// The last entry of a turn under way (a thought still coming in).
    let isStreaming: Bool
    @State private var showsThought = false

    var body: some View {
        switch entry.kind {
        case .user(let text, let attachments):
            VStack(alignment: .leading, spacing: 5) {
                if !text.isEmpty { Text(text).textSelection(.enabled) }
                if !attachments.isEmpty {
                    AgentChipRow(labels: attachments)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .message(let text):
            AgentMarkdownView(text: text)
        case .thought(let text):
            VStack(alignment: .leading, spacing: 4) {
                Button { showsThought.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showsThought ? 90 : 0))
                            .frame(width: 10)
                        Text(isStreaming ? "Thinking…" : "Thought")
                        if isStreaming { ProgressView().controlSize(.mini) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                if showsThought {
                    Text(text)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.leading, 14)
                }
            }
        case .tool(let call):
            AgentToolCallView(call: call, client: client, workspace: workspace)
        case .notice(let text):
            Label(text, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// Names of attached files, as small chips.
private struct AgentChipRow: View {
    let labels: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                    Label(label, systemImage: "paperclip")
                        .font(.caption).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
        }
    }
}

private struct AgentToolCallView: View {
    let call: AgentToolCall
    let client: AgentClient
    let workspace: Workspace
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if isExpandable { isExpanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: call.symbolName).foregroundStyle(.secondary).frame(width: 14)
                    Text(workspace.shortenedPaths(in: call.title))
                        .lineLimit(isExpanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    status
                    if isExpandable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            if isExpanded || hasTerminal {
                ForEach(Array(call.content.enumerated()), id: \.offset) { _, content in
                    if isExpanded || content.isTerminal {
                        AgentToolContentView(content: content, client: client, workspace: workspace)
                    }
                }
            }
            if isExpanded {
                ForEach(Array(call.locations.enumerated()), id: \.offset) { _, location in
                    Button {
                        workspace.agentOpen(path: location.path, line: location.line)
                    } label: {
                        Text(workspace.relativePath(of: URL(filePath: location.path)) ?? location.path)
                            + Text(location.line.map { ":\($0)" } ?? "")
                    }
                    .buttonStyle(.link).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isHovering && isExpandable ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = $0 }
    }

    /// There's more than the title to show (what's always shown aside).
    private var isExpandable: Bool {
        call.content.contains { !$0.isTerminal } || !call.locations.isEmpty
    }

    private var hasTerminal: Bool { call.content.contains(where: \.isTerminal) }

    @ViewBuilder private var status: some View {
        switch call.status {
        case .pending, .inProgress: ProgressView().controlSize(.mini)
        case .completed: Image(systemName: "checkmark").foregroundStyle(.green).help("Done")
        case .failed: Image(systemName: "xmark").foregroundStyle(.red).help("Failed")
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary).help("Cancelled")
        }
    }
}

private extension AgentToolContent {
    var isTerminal: Bool { if case .terminal = self { true } else { false } }
}

private struct AgentToolContentView: View {
    let content: AgentToolContent
    let client: AgentClient
    let workspace: Workspace

    var body: some View {
        switch content {
        case .text(let text):
            Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(30)
        case .diff(let path, let old, let new):
            AgentDiffSummary(path: path, old: old, new: new, source: client.definition.name, workspace: workspace)
        case .terminal(let id):
            if let terminal = client.terminal(id: id) {
                AgentTerminalView(terminal: terminal)
            }
        }
    }
}

/// A change to a file: its name, how many lines it adds and removes, and the diff on request.
struct AgentDiffSummary: View {
    let path: String
    let old: String?
    let new: String
    let source: String
    let workspace: Workspace

    var body: some View {
        let (added, removed) = Self.counts(old: old, new: new)
        HStack(spacing: 6) {
            Image(systemName: old == nil ? "doc.badge.plus" : "doc.badge.ellipsis").foregroundStyle(.secondary)
            Text(URL(filePath: path).lastPathComponent)
                .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                .help(workspace.shortenedPaths(in: path))
            Text("+\(added)").font(.caption.monospacedDigit()).foregroundStyle(.green)
            Text("−\(removed)").font(.caption.monospacedDigit()).foregroundStyle(.red)
            Spacer(minLength: 4)
            Button("View Diff") {
                workspace.showProposedChange(ProposedChange(title: "", source: source, old: old, new: new), for: URL(filePath: path))
            }
            .buttonStyle(.link).font(.caption)
            .fixedSize()
        }
    }

    static func counts(old: String?, new: String) -> (added: Int, removed: Int) {
        let hunks = LineDiff.hunks(base: old.map(LineDiff.lines) ?? [], current: LineDiff.lines(new))
        return (hunks.reduce(0) { $0 + $1.newCount }, hunks.reduce(0) { $0 + $1.oldCount })
    }
}

private struct AgentTerminalView: View {
    let terminal: AgentTerminal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("$ " + terminal.commandLine)
                .font(.caption.monospaced().weight(.medium)).lineLimit(2).truncationMode(.middle)
                .help(terminal.commandLine)
            if !terminal.output.isEmpty {
                ScrollView {
                    Text(terminal.output.suffix(8_000)).font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                // A command still printing: its latest lines in view.
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let status = terminal.exitStatus {
                Text(status.signal.map { "Ended by \($0)" } ?? "Exit code \(status.exitCode ?? 0)")
                    .font(.caption2).foregroundStyle(status.exitCode == 0 ? Color.secondary : Color.red)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct AgentPlanView: View {
    let plan: [AgentPlanEntry]
    @State private var isExpanded = true

    /// More steps than this scroll, so a long plan doesn't push the prompt off.
    private static let visibleSteps = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text("Plan").font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    let done = plan.count { $0.status == "completed" }
                    Text("\(done) of \(plan.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if isExpanded {
                if plan.count > Self.visibleSteps {
                    ScrollView { steps }.frame(height: CGFloat(Self.visibleSteps) * 19)
                } else {
                    steps
                }
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(plan.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: entry.status == "completed" ? "checkmark.circle.fill"
                          : entry.status == "in_progress" ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(entry.status == "completed" ? Color.green
                                         : entry.status == "in_progress" ? Color.accentColor : Color.secondary)
                    Text(entry.content)
                        .strikethrough(entry.status == "completed")
                        .foregroundStyle(entry.status == "completed" ? .secondary : .primary)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 27)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
    }
}

private struct AgentPermissionCard: View {
    let permission: AgentPermissionRequest
    let client: AgentClient
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("\(client.definition.name) asks to", systemImage: "hand.raised.fill")
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(AccentedIconLabelStyle(tint: .orange))
            Text(workspace.shortenedPaths(in: permission.title))
                .font(.callout.weight(.medium))
                .lineLimit(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(permission.content.enumerated()), id: \.offset) { _, content in
                if case .diff(let path, let old, let new) = content {
                    AgentDiffSummary(path: path, old: old, new: new, source: client.definition.name, workspace: workspace)
                } else if case .text(let text) = content {
                    Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8)
                }
            }
            FlowButtons(options: permission.options) { client.respond(to: permission, with: $0) }
                .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private struct AccentedIconLabelStyle: LabelStyle {
        let tint: Color
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 5) {
                configuration.icon.foregroundStyle(tint)
                configuration.title
            }
        }
    }

    private struct FlowButtons: View {
        let options: [AgentPermissionRequest.Option]
        let choose: (AgentPermissionRequest.Option) -> Void

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
        }

        @ViewBuilder private var buttons: some View {
            ForEach(options) { option in
                if option.kind == "allow_once" {
                    Button(option.name) { choose(option) }.buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button(option.name) { choose(option) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}

private struct AgentPromptView: View {
    @Bindable var panel: AgentPanel
    let client: AgentClient
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if panel.draft.hasPrefix("/"), !matchingCommands.isEmpty {
                commandSuggestions
            }
            VStack(alignment: .leading, spacing: 4) {
                if !panel.attachments.isEmpty { attachmentChips }
                ZStack(alignment: .topLeading) {
                    if panel.draft.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary).padding(.horizontal, 5)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $panel.draft)
                        .focused($isFocused)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 36, maxHeight: 140)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                toolbar
            }
            .padding(.horizontal, 6)
            .padding(.top, 7)
            .padding(.bottom, 5)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12))
            )
        }
        .padding(8)
        .overlay(alignment: .top) { Divider() }
        .onAppear { isFocused = true }
    }

    private var placeholder: String {
        client.commands.isEmpty ? "Ask the agent…" : "Ask the agent, or / for commands…"
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(panel.attachments) { attachment in
                    HStack(spacing: 3) {
                        Image(systemName: "paperclip").foregroundStyle(.secondary)
                        Text(attachment.label).lineLimit(1)
                        Button { panel.removeAttachment(attachment) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                    }
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .help(attachment.url.path)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { panel.attachSelection() } label: { Image(systemName: "paperclip") }
                .help("Attach the Selection (or the Current File)")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Settings supersede modes: shown instead, when the agent has them.
                    if !client.configOptions.isEmpty {
                        ForEach(client.configOptions) { AgentConfigControl(option: $0, client: client) }
                    } else if !client.modes.isEmpty {
                        Picker("Mode", selection: Binding(get: { client.currentModeID ?? "" }, set: { client.setMode($0) })) {
                            if client.currentModeID == nil { Text("Mode").tag("") }
                            ForEach(client.modes) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().controlSize(.small).fixedSize()
                        .help(client.modes.first { $0.id == client.currentModeID }?.description ?? "Mode")
                    }
                }
            }
            if client.state == .working {
                Button { client.cancel() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 17))
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")
            } else {
                if panel.canSend { Text("⌘↩").font(.caption2).foregroundStyle(.tertiary) }
                Button { panel.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 17))
                        .foregroundStyle(panel.canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                }
                // Only from the prompt: ⌘↩ in the editor (or another panel) isn't for the agent.
                .keyboardShortcut(isFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .disabled(!panel.canSend)
                .help(client.state == .ready ? "Send (⌘↩)" : "The agent isn't ready")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    private var commandSuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matchingCommands.prefix(6)) { command in
                AgentCommandRow(command: command) {
                    panel.draft = "/\(command.name) "
                    isFocused = true
                }
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }

    private var matchingCommands: [AgentCommand] {
        let typed = panel.draft.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        guard !panel.draft.contains(" ") else { return [] }
        return client.commands.filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed) }
    }
}

/// A slash command to pick, highlighted under the pointer.
private struct AgentCommandRow: View {
    let command: AgentCommand
    let choose: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Text("/" + command.name).font(.caption.monospaced()).foregroundStyle(.primary)
                Text(command.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(command.hint.map { "\(command.description) (\($0))" } ?? command.description)
    }
}

/// One of the session's settings: a menu of its choices (grouped as the agent groups them), or
/// a checkbox.
private struct AgentConfigControl: View {
    let option: AgentConfigOption
    let client: AgentClient

    var body: some View {
        switch option.kind {
        case .select(let current, let choices):
            Menu {
                let groups = choices.reduce(into: [String?]()) { if !$0.contains($1.group) { $0.append($1.group) } }
                ForEach(groups, id: \.self) { group in
                    Section(group ?? "") {
                        ForEach(choices.filter { $0.group == group }) { choice in
                            Button {
                                client.setConfigOption(option.id, to: choice.value)
                            } label: {
                                if choice.value == current { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                            }
                            .help(choice.description ?? "")
                        }
                    }
                }
            } label: {
                Text(option.currentName).font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help([option.name, option.description].compactMap { $0 }.joined(separator: ": "))
        case .boolean(let on):
            Toggle(option.name, isOn: Binding(get: { on }, set: { client.setConfigOption(option.id, to: $0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .fixedSize()
                .help(option.description ?? option.name)
        }
    }
}

private struct AgentLogView: View {
    let log: String
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(name) Log").font(.headline).padding(12)
            Divider()
            ScrollView {
                Text(log.isEmpty ? "Nothing logged." : log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .defaultScrollAnchor(.bottom)
            Divider()
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                }
                .disabled(log.isEmpty)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 620, height: 420)
    }
}

extension Workspace {
    /// `text` with paths inside the folder made relative to it (agents name files by their
    /// full paths, too long for the sidebar).
    /// With several folders, a path is shortened to its folder's label and the rest.
    func shortenedPaths(in text: String) -> String {
        var result = text
        // Deeper folders first (one may be inside another).
        for root in folders.sorted(by: { $0.path.count > $1.path.count }) {
            let replacement = isMultiRoot ? label(of: root) + "/" : ""
            for prefix in Set([root.path, root.resolvingSymlinksInPath().path, "/private" + root.path]) {
                result = result.replacingOccurrences(of: prefix + "/", with: replacement)
            }
        }
        return result
    }

    /// Opens a file an agent points at (at a 1-based line).
    func agentOpen(path: String, line: Int?) {
        let url = URL(filePath: path)
        open(fileAt: url)
        if let line, let document = document(matching: url) { document.revealLine(line) }
    }
}
