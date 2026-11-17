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

    private var header: some View {
        HStack(spacing: 6) {
            Text("AGENT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Picker("Agent", selection: Binding(get: { panel.selectedAgent?.id }, set: { panel.selectedAgentID = $0 })) {
                ForEach(store.definitions) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Spacer(minLength: 0)
            if let client = panel.client {
                AgentStateBadge(state: client.state)
            }
            Menu {
                Button("New Thread") { panel.newThread() }
                    .disabled(workspace.rootURL == nil)
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
                    .disabled(client.state == .starting)
                }
                Button("Restart Agent") { panel.start() }
                    .disabled(workspace.rootURL == nil)
                Button("Stop Agent") { panel.stop() }
                    .disabled(panel.client == nil)
                Divider()
                SettingsLink { Text("Agent Settings…") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
    }

    private var start: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            Text(panel.selectedAgent?.name ?? "No agent").font(.headline)
            Text("The agent works in this folder. It reads files as the editor has them (unsaved changes too), and asks before it edits or runs anything.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Start \(panel.selectedAgent?.name ?? "Agent")") { panel.start() }
                .buttonStyle(.borderedProminent)
                .disabled(panel.selectedAgent == nil)
            if let command = panel.selectedAgent?.command {
                Text(command).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentStateBadge: View {
    let state: AgentClient.State

    var body: some View {
        switch state {
        case .starting: ProgressView().controlSize(.mini).help("Starting…")
        case .working: ProgressView().controlSize(.mini).help("Working…")
        case .ready: Circle().fill(.green).frame(width: 7, height: 7).help("Ready")
        case .needsAuthentication: Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange).help("Sign in needed")
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Failed")
        case .stopped: Circle().fill(.secondary).frame(width: 7, height: 7).help("Stopped")
        }
    }
}

/// The conversation, what the agent asks, and the prompt.
private struct AgentConversationView: View {
    @Bindable var panel: AgentPanel
    let client: AgentClient
    let workspace: Workspace
    @State private var showsLog = false

    var body: some View {
        VStack(spacing: 0) {
            switch client.state {
            case .failed(let message):
                failure(message)
            case .needsAuthentication:
                authentication
            default:
                transcript
                if !client.plan.isEmpty { AgentPlanView(plan: client.plan) }
                ForEach(client.permissions) { permission in
                    AgentPermissionCard(permission: permission, client: client, workspace: workspace)
                }
                AgentPromptView(panel: panel, client: client)
            }
        }
        .sheet(isPresented: $showsLog) { AgentLogView(log: client.log, name: client.definition.name) }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if client.entries.isEmpty {
                        Text(client.state == .starting ? "Starting \(client.definition.name)…" : "Ask \(client.agentTitle ?? client.definition.name) to do something in this folder.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                    ForEach(client.entries) { entry in
                        AgentEntryView(entry: entry, client: client, workspace: workspace).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(10)
            }
            .onChange(of: client.entries.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: lastEntryLength) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    /// Grows as the reply streams in (to keep its end in view).
    private var lastEntryLength: Int {
        guard let last = client.entries.last else { return 0 }
        switch last.kind {
        case .message(let text), .thought(let text): return text.count
        default: return 0
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
            Text(message).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
            HStack {
                Button("Try Again") { panel.start() }
                if !client.log.isEmpty { Button("Show Log") { showsLog = true } }
            }
            Text("The command is set in Settings ▸ Agents.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var authentication: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to \(client.definition.name)").font(.headline)
            if client.authMethods.isEmpty {
                Text("The agent asks to sign in but offers no way to here. Sign in with its own command line tool, then restart it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(client.authMethods) { method in
                VStack(alignment: .leading, spacing: 4) {
                    Button(method.name) { Task { await client.authenticate(method) } }
                    if let description = method.description {
                        Text(description).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Button("Restart Agent") { panel.start() }.padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AgentEntryView: View {
    let entry: AgentEntry
    let client: AgentClient
    let workspace: Workspace
    @State private var showsThought = false

    var body: some View {
        switch entry.kind {
        case .user(let text, let attachments):
            VStack(alignment: .leading, spacing: 4) {
                if !text.isEmpty { Text(text).textSelection(.enabled) }
                if !attachments.isEmpty {
                    Text(attachments.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .message(let text):
            AgentMarkdownView(text: text)
        case .thought(let text):
            DisclosureGroup(isExpanded: $showsThought) {
                Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Label("Thinking", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
            }
        case .tool(let call):
            AgentToolCallView(call: call, client: client, workspace: workspace)
        case .notice(let text):
            Text(text).font(.caption).foregroundStyle(.secondary).italic()
        }
    }
}

private struct AgentToolCallView: View {
    let call: AgentToolCall
    let client: AgentClient
    let workspace: Workspace
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: call.symbolName).foregroundStyle(.secondary).frame(width: 14)
                    Text(workspace.shortenedPaths(in: call.title)).lineLimit(isExpanded ? nil : 2).frame(maxWidth: .infinity, alignment: .leading)
                    status
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            if isExpanded || hasTerminal {
                ForEach(Array(call.content.enumerated()), id: \.offset) { _, content in
                    AgentToolContentView(content: content, client: client, workspace: workspace)
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
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var hasTerminal: Bool {
        call.content.contains { if case .terminal = $0 { true } else { false } }
    }

    @ViewBuilder private var status: some View {
        switch call.status {
        case .pending, .inProgress: ProgressView().controlSize(.mini)
        case .completed: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
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
            Text(URL(filePath: path).lastPathComponent).font(.caption.weight(.medium))
            Text("+\(added)").font(.caption.monospacedDigit()).foregroundStyle(.green)
            Text("−\(removed)").font(.caption.monospacedDigit()).foregroundStyle(.red)
            Spacer(minLength: 0)
            Button("View Diff") {
                workspace.showProposedChange(ProposedChange(title: "", source: source, old: old, new: new), for: URL(filePath: path))
            }
            .buttonStyle(.link).font(.caption)
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
            Text("$ " + terminal.commandLine).font(.caption.monospaced().weight(.medium)).lineLimit(2)
            if !terminal.output.isEmpty {
                ScrollView {
                    Text(terminal.output.suffix(8_000)).font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            if let status = terminal.exitStatus {
                Text(status.signal.map { "Ended by \($0)" } ?? "Exit code \(status.exitCode ?? 0)")
                    .font(.caption2).foregroundStyle(status.exitCode == 0 ? Color.secondary : Color.red)
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct AgentPlanView: View {
    let plan: [AgentPlanEntry]
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(plan.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: entry.status == "completed" ? "checkmark.circle.fill"
                                  : entry.status == "in_progress" ? "circle.dotted.circle" : "circle")
                                .foregroundStyle(entry.status == "completed" ? .green : .secondary)
                            Text(entry.content).strikethrough(entry.status == "completed").font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                let done = plan.count { $0.status == "completed" }
                Text("Plan · \(done)/\(plan.count)").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

private struct AgentPermissionCard: View {
    let permission: AgentPermissionRequest
    let client: AgentClient
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(workspace.shortenedPaths(in: permission.title), systemImage: "hand.raised").font(.callout.weight(.medium))
            ForEach(Array(permission.content.enumerated()), id: \.offset) { _, content in
                if case .diff(let path, let old, let new) = content {
                    AgentDiffSummary(path: path, old: old, new: new, source: client.definition.name, workspace: workspace)
                } else if case .text(let text) = content {
                    Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8)
                }
            }
            FlowButtons(options: permission.options) { client.respond(to: permission, with: $0) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .top) { Divider() }
    }

    private struct FlowButtons: View {
        let options: [AgentPermissionRequest.Option]
        let choose: (AgentPermissionRequest.Option) -> Void

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack { buttons }
                VStack(alignment: .leading) { buttons }
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
            Divider()
            if !panel.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(panel.attachments) { attachment in
                            HStack(spacing: 3) {
                                Text(attachment.label).font(.caption)
                                Button { panel.removeAttachment(attachment) } label: { Image(systemName: "xmark").font(.caption2) }
                                    .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            ZStack(alignment: .topLeading) {
                if panel.draft.isEmpty {
                    Text(client.commands.isEmpty ? "Ask the agent… (⌘↩ to send)" : "Ask the agent, or / for commands… (⌘↩ to send)")
                        .foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $panel.draft)
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            if panel.draft.hasPrefix("/"), !matchingCommands.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingCommands.prefix(6)) { command in
                        Button {
                            panel.draft = "/\(command.name) "
                        } label: {
                            HStack {
                                Text("/" + command.name).font(.caption.monospaced())
                                Text(command.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
            }
            if !client.configOptions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(client.configOptions) { AgentConfigControl(option: $0, client: client) }
                    }
                    .padding(.horizontal, 8)
                }
            }
            HStack(spacing: 8) {
                Button { panel.attachSelection() } label: { Image(systemName: "paperclip") }
                    .help("Attach the Selection (or the Current File)")
                // Settings supersede modes: shown instead, when the agent has them.
                if client.configOptions.isEmpty, !client.modes.isEmpty {
                    Picker("Mode", selection: Binding(get: { client.currentModeID ?? "" }, set: { client.setMode($0) })) {
                        ForEach(client.modes) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                    .help(client.modes.first { $0.id == client.currentModeID }?.description ?? "Mode")
                }
                Spacer()
                if client.state == .working {
                    Button("Stop") { client.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                        .controlSize(.small)
                } else {
                    Button("Send") { panel.send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(client.state != .ready
                                  || (panel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && panel.attachments.isEmpty))
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .onAppear { isFocused = true }
    }

    private var matchingCommands: [AgentCommand] {
        let typed = panel.draft.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        guard !panel.draft.contains(" ") else { return [] }
        return client.commands.filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed) }
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
                Text(log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            Divider()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(10)
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
