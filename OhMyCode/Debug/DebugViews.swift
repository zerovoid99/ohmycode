import AppKit
import SwiftUI

/// The Run and Debug sidebar: what to run, the controls, variables, call stack, breakpoints.
struct DebugView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                WatchSection(workspace: workspace)
                if let session = workspace.debugSession, session.state == .stopped {
                    Section("Variables") {
                        if session.scopes.isEmpty {
                            Text("No variables").foregroundStyle(.secondary)
                        }
                        ForEach(session.scopes) { scope in
                            VariableRow(session: session, variable: scope, workspace: workspace, startsExpanded: scope.id == session.scopes.first?.id)
                        }
                    }
                    Section("Call Stack") {
                        ForEach(session.frames) { frame in
                            FrameRow(frame: frame, isSelected: frame.id == session.selectedFrameID)
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await session.select(frame) } }
                        }
                    }
                }
                Section {
                    ForEach(workspace.breakpoints.exceptionFilters) { filter in
                        Toggle(filter.label, isOn: Binding(get: { workspace.breakpoints.enabledExceptionFilters.contains(filter.filter) },
                                                           set: { workspace.breakpoints.setException(filter.filter, enabled: $0) }))
                            .toggleStyle(.checkbox)
                            .help("Stop when \(filter.label.lowercased()) happens")
                    }
                    ForEach(workspace.breakpoints.all.map { ("\($0.path):\($0.breakpoint.line)", $0) }, id: \.0) { _, entry in
                        BreakpointRow(workspace: workspace, path: entry.path, breakpoint: entry.breakpoint)
                    }
                } header: {
                    HStack {
                        Text("Breakpoints")
                        Spacer()
                        Button("Remove All", systemImage: "trash") { workspace.breakpoints.removeAll() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(workspace.breakpoints.byPath.isEmpty)
                            .help("Remove all breakpoints")
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .task(id: workspace.rootURL) { await workspace.loadLaunchConfigurations() }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let session = workspace.debugSession, session.isActive {
                DebugToolbar(workspace: workspace, session: session)
                Text(status(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if workspace.launchConfigurations.isEmpty {
                Text("Nothing to run yet. A Swift package's executables are found by themselves; for anything else, say what to run in launch.json.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Create launch.json") { workspace.createLaunchFile() }
                    Button("Attach to Process…") { Task { await workspace.attachToProcess() } }
                }
            } else {
                HStack(spacing: 6) {
                    Button { Task { await workspace.startDebugging() } } label: {
                        Image(systemName: "play.fill").foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                    .help("Start Debugging (F5)")
                    Picker("Configuration", selection: Binding(
                        get: { workspace.selectedLaunchName ?? workspace.launchConfigurations.first?.name ?? "" },
                        set: { workspace.selectedLaunchName = $0 })) {
                        ForEach(workspace.launchConfigurations) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    Menu {
                        Button("Edit launch.json") { workspace.createLaunchFile() }
                        Button("Attach to Process…") { Task { await workspace.attachToProcess() } }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Edit launch.json or attach to a running process")
                }
                if let session = workspace.debugSession, let code = session.exitCode {
                    Text("Last run exited with code \(code).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
    }

    private func status(_ session: DebugSession) -> String {
        switch session.state {
        case .building: "Building…"
        case .starting: "Starting \(session.configuration.name)…"
        case .running: "Running"
        case .stopped: "Paused on \(session.stopReason ?? "a stop")"
        case .terminated: "Ended"
        }
    }
}

/// Continue/pause, step over/into/out, restart, stop.
struct DebugToolbar: View {
    let workspace: Workspace
    let session: DebugSession

    var body: some View {
        let stopped = session.state == .stopped
        HStack(spacing: 10) {
            if stopped {
                button("Continue (F5)", "play.fill", .green) { session.resume() }
            } else {
                button("Pause", "pause.fill", .primary) { session.pause() }.disabled(session.state != .running)
            }
            button("Step Over (F10)", "arrow.uturn.forward", .primary) { session.stepOver() }.disabled(!stopped)
            button("Step Into (F11)", "arrow.down.to.line", .primary) { session.stepInto() }.disabled(!stopped)
            button("Step Out (⇧F11)", "arrow.up.to.line", .primary) { session.stepOut() }.disabled(!stopped)
            Spacer(minLength: 0)
            button("Restart (⇧⌘F5)", "arrow.clockwise", .primary) { workspace.restartDebugging() }
            button("Stop (⇧F5)", "stop.fill", .red) { workspace.stopDebugging() }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
    }

    private func button(_ help: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).foregroundStyle(color) }.help(help)
    }
}

private struct VariableRow: View {
    let session: DebugSession
    let variable: DebugSession.Variable
    var workspace: Workspace?
    var startsExpanded = false
    @State private var isExpanded = false

    var body: some View {
        if variable.reference > 0 {
            DisclosureGroup(isExpanded: $isExpanded) {
                if let children = session.children[variable.reference] {
                    ForEach(children) { child in VariableRow(session: session, variable: child, workspace: workspace) }
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                label
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded { Task { await session.loadChildren(of: variable.reference) } }
            }
            .onAppear { if startsExpanded { isExpanded = true } }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Text(variable.name).foregroundStyle(variable.value.isEmpty ? .primary : Color.purple)
            if !variable.value.isEmpty {
                Text("=").foregroundStyle(.secondary)
                Text(variable.value).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .help(variable.type.map { "\(variable.name): \($0) = \(variable.value)" } ?? variable.value)
        .contextMenu {
            if variable.parent > 0 {
                Button("Set Value…") { setValue() }.disabled(!session.supportsSetVariable)
                Button("Copy Value") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(variable.value, forType: .string)
                }
                Button("Add to Watch") { workspace?.breakpoints.addWatch(variable.name) }
            }
        }
    }

    private func setValue() {
        guard let workspace else { return }
        Task {
            guard let value = await workspace.showInputBox(prompt: "New value of \(variable.name)", value: variable.value, placeholder: nil)
            else { return }
            do { try await session.setValue(of: variable, to: value) } catch { workspace.errorMessage = error.localizedDescription }
        }
    }
}

private struct FrameRow: View {
    let frame: DebugSession.Frame
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSelected ? "arrowtriangle.right.fill" : "circle.fill")
                .font(.system(size: isSelected ? 9 : 4))
                .foregroundStyle(isSelected ? Color.yellow : .secondary)
                .frame(width: 10)
            Text(frame.name).lineLimit(1).foregroundStyle(frame.path == nil ? .secondary : .primary)
            Spacer(minLength: 4)
            if let path = frame.path {
                Text("\((path as NSString).lastPathComponent):\(frame.line)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help(frame.path.map { "\($0):\(frame.line)" } ?? "No source")
    }
}

private struct BreakpointRow: View {
    let workspace: Workspace
    let path: String
    let breakpoint: BreakpointStore.Breakpoint

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Enabled", isOn: Binding(get: { breakpoint.isEnabled },
                                            set: { workspace.breakpoints.setEnabled(path, line: breakpoint.line, $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: breakpoint.logMessage == nil ? "circle.fill" : "diamond.fill")
                .font(.system(size: 8))
                .foregroundStyle(breakpoint.isEnabled ? Color.red : Color.gray)
            Text((path as NSString).lastPathComponent).lineLimit(1)
            Text("\(breakpoint.line)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let condition = breakpoint.condition {
                Text(condition).font(.caption.monospaced()).foregroundStyle(.orange).lineLimit(1)
            }
            if let message = breakpoint.logMessage {
                Text("log: " + message).font(.caption.monospaced()).foregroundStyle(.blue).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.open(fileAt: URL(filePath: path))
            workspace.document(matching: URL(filePath: path))?.revealLine(breakpoint.line)
        }
        .contextMenu {
            Button("Edit Condition…") { editCondition() }
            Button("Edit Log Message…") { editLogMessage() }
            Button("Remove", role: .destructive) { workspace.breakpoints.remove(path, line: breakpoint.line) }
        }
        .help("\(path):\(breakpoint.line)")
    }

    private func editLogMessage() {
        Task {
            let message = await workspace.showInputBox(prompt: "Print this instead of stopping; {expressions} are filled in. Empty to stop again",
                                                       value: breakpoint.logMessage ?? "", placeholder: "x is {x}")
            if let message { workspace.breakpoints.setLogMessage(path, line: breakpoint.line, message) }
        }
    }

    private func editCondition() {
        Task {
            let condition = await workspace.showInputBox(prompt: "Stop only when this is true (e.g. i > 10); empty for always",
                                                         value: breakpoint.condition ?? "", placeholder: "Condition")
            if let condition { workspace.breakpoints.setCondition(path, line: breakpoint.line, condition) }
        }
    }
}

/// The debug console: the program's output and the debugger's messages, and expressions to
/// evaluate in the selected frame.
struct DebugConsoleView: View {
    let workspace: Workspace
    @State private var expression = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BottomPanelSwitcher(workspace: workspace)
                Spacer()
                Button { workspace.debugSession?.clearConsole() } label: { Image(systemName: "trash") }
                    .help("Clear the console")
                Button { workspace.toggleTerminal() } label: { Image(systemName: "chevron.down") }
                    .help("Hide the panel")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .themedBackground(.panel, fallback: .bar)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(workspace.debugSession?.console ?? []) { line in
                            Text(prefix(line.kind) + line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: workspace.debugSession?.console.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                TextField(workspace.debugSession?.state == .stopped ? "Evaluate in the selected frame" : "Pause the program to evaluate",
                          text: $expression)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(workspace.debugSession?.isActive != true)
                    .onSubmit {
                        let text = expression
                        expression = ""
                        Task { await workspace.debugSession?.evaluate(text) }
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
        }
    }

    private func prefix(_ kind: DebugSession.ConsoleLine.Kind) -> String {
        switch kind {
        case .input: "> "
        case .result: "< "
        default: ""
        }
    }

    private func color(_ kind: DebugSession.ConsoleLine.Kind) -> Color {
        switch kind {
        case .error: .red
        case .info: .secondary
        case .input: .accentColor
        default: .primary
        }
    }
}

/// "Terminal | Debug Console" at the top of the bottom panel.
struct BottomPanelSwitcher: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 2) {
            tab("Terminal", .terminal) { workspace.showTerminal() }
            tab("Debug Console", .debugConsole) { workspace.showDebugConsole() }
        }
    }

    private func tab(_ title: String, _ panel: Workspace.BottomPanel, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(workspace.bottomPanel == panel ? .primary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(workspace.bottomPanel == panel ? Color.secondary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

/// Expressions shown whenever the program stops.
private struct WatchSection: View {
    let workspace: Workspace
    @State private var newExpression = ""

    var body: some View {
        Section("Watch") {
            ForEach(Array(workspace.breakpoints.watches.enumerated()), id: \.offset) { index, expression in
                HStack(spacing: 4) {
                    Text(expression).foregroundStyle(Color.purple)
                    Text("=").foregroundStyle(.secondary)
                    switch workspace.debugSession?.watchResults[expression] {
                    case .value(let value): Text(value).lineLimit(1).textSelection(.enabled)
                    case .error(let message): Text(message).foregroundStyle(.secondary).lineLimit(1).help(message)
                    case nil: Text("not available").foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(.callout, design: .monospaced))
                .contextMenu {
                    Button("Edit…") {
                        Task {
                            if let text = await workspace.showInputBox(prompt: "Watch expression", value: expression, placeholder: nil) {
                                workspace.breakpoints.replaceWatch(at: index, with: text)
                            }
                        }
                    }
                    Button("Remove", role: .destructive) { workspace.breakpoints.removeWatch(at: index) }
                }
            }
            TextField("Add expression", text: $newExpression, prompt: Text("+ Add expression").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .onSubmit {
                    workspace.breakpoints.addWatch(newExpression)
                    newExpression = ""
                }
        }
    }
}
