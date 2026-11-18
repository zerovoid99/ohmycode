import AppKit
import SwiftUI

/// The Run and Debug sidebar: what to run, the controls, watches, variables, call stack,
/// breakpoints.
struct DebugView: View {
    let workspace: Workspace
    @State private var isLoading = false
    @State private var showsWatch = true
    @State private var showsVariables = true
    @State private var showsCallStack = true
    @State private var showsBreakpoints = true
    @State private var newWatch = ""
    @FocusState private var isAddingWatch: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            List {
                Section(isExpanded: $showsWatch) {
                    watchRows
                } header: {
                    DebugSectionHeader(title: "Watch", count: workspace.breakpoints.watches.count) {
                        Button("Add Expression", systemImage: "plus") {
                            showsWatch = true
                            isAddingWatch = true
                        }
                        .help("Add an expression to watch")
                    }
                }
                if let session = workspace.debugSession, session.state == .stopped {
                    Section(isExpanded: $showsVariables) {
                        if session.scopes.isEmpty {
                            DebugEmptyRow(text: "No variables here")
                        }
                        ForEach(session.scopes) { scope in
                            VariableRow(session: session, variable: scope, workspace: workspace, startsExpanded: scope.id == session.scopes.first?.id)
                        }
                    } header: {
                        DebugSectionHeader(title: "Variables") {}
                    }
                    Section(isExpanded: $showsCallStack) {
                        ForEach(session.frames) { frame in
                            FrameRow(frame: frame, isSelected: frame.id == session.selectedFrameID)
                                .contentShape(Rectangle())
                                .onTapGesture { Task { await session.select(frame) } }
                        }
                    } header: {
                        DebugSectionHeader(title: "Call Stack", count: session.frames.count) {}
                    }
                }
                Section(isExpanded: $showsBreakpoints) {
                    breakpointRows
                } header: {
                    let all = workspace.breakpoints.all
                    let allEnabled = all.allSatisfy(\.breakpoint.isEnabled)
                    DebugSectionHeader(title: "Breakpoints", count: all.count) {
                        Button(allEnabled ? "Disable All" : "Enable All", systemImage: allEnabled ? "circle.slash" : "circle.inset.filled") {
                            workspace.breakpoints.setAllEnabled(!allEnabled)
                        }
                        .help(allEnabled ? "Turn every breakpoint off (they stay where they are)" : "Turn every breakpoint on")
                        .disabled(all.isEmpty)
                        Button("Remove All", systemImage: "trash") { workspace.breakpoints.removeAll() }
                            .help("Remove all breakpoints")
                            .disabled(all.isEmpty)
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)
        }
        .task(id: workspace.folders) {
            isLoading = true
            await workspace.loadLaunchConfigurations()
            isLoading = false
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let session = workspace.debugSession, session.isActive {
            VStack(alignment: .leading, spacing: 8) {
                DebugToolbar(workspace: workspace, session: session)
                HStack(spacing: 6) {
                    DebugStateDot(state: session.state)
                    Text(status(session)).foregroundStyle(.secondary)
                    Text(session.configuration.name).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .lineLimit(1)
            }
        } else if workspace.launchConfigurations.isEmpty {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for programs to run…").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Nothing to run yet", systemImage: "play.circle")
                        .font(.callout.weight(.medium))
                    Text("Swift packages, Xcode projects and Python files are found by themselves. For anything else, say what to run in launch.json.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Create launch.json") { workspace.createLaunchFile() }
                        Button("Attach to Process…") { Task { await workspace.attachToProcess() } }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button { Task { await workspace.startDebugging() } } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.green.opacity(0.85)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Start Debugging (F5)")
                    Picker("Configuration", selection: Binding(
                        get: { workspace.selectedLaunchName ?? workspace.launchConfigurations.first?.name ?? "" },
                        set: { workspace.selectedLaunchName = $0 })) {
                        ForEach(workspace.launchConfigurations) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Menu {
                        Button("Edit launch.json") { workspace.createLaunchFile() }
                        Button("Attach to Process…") { Task { await workspace.attachToProcess() } }
                        Divider()
                        Button("Look Again for Programs") {
                            Task {
                                isLoading = true
                                await workspace.loadLaunchConfigurations()
                                isLoading = false
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Edit launch.json or attach to a running process")
                }
                if let session = workspace.debugSession, let code = session.exitCode {
                    Label("Last run exited with code \(code)", systemImage: code == 0 ? "checkmark.circle" : "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(code == 0 ? Color.secondary : Color.red)
                }
            }
        }
    }

    private func status(_ session: DebugSession) -> String {
        switch session.state {
        case .building: "Building…"
        case .starting: "Starting…"
        case .running: "Running"
        case .stopped: "Paused on \(session.stopReason ?? "a stop")"
        case .terminated: "Ended"
        }
    }

    // MARK: Watch

    @ViewBuilder
    private var watchRows: some View {
        ForEach(Array(workspace.breakpoints.watches.enumerated()), id: \.offset) { index, expression in
            WatchRow(workspace: workspace, index: index, expression: expression)
        }
        HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(width: 12)
            TextField("Add expression", text: $newWatch, prompt: Text("Add expression").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($isAddingWatch)
                .onSubmit {
                    workspace.breakpoints.addWatch(newWatch)
                    newWatch = ""
                }
                .onExitCommand {
                    newWatch = ""
                    isAddingWatch = false
                }
        }
    }

    // MARK: Breakpoints

    @ViewBuilder
    private var breakpointRows: some View {
        let all = workspace.breakpoints.all
        if all.isEmpty {
            DebugEmptyRow(text: "Click beside a line number, or press F9, to stop there.")
        }
        ForEach(all.map { ("\($0.path):\($0.breakpoint.line)", $0) }, id: \.0) { _, entry in
            BreakpointRow(workspace: workspace, path: entry.path, breakpoint: entry.breakpoint)
        }
        ExceptionBreakpointsRow(breakpoints: workspace.breakpoints)
    }
}

/// The exception breakpoints, as one row: which are on, and a menu to turn them on or off.
private struct ExceptionBreakpointsRow: View {
    let breakpoints: BreakpointStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(breakpoints.enabledExceptionFilters.isEmpty ? Color.secondary : Color.orange)
                .frame(width: 14)
            Text("Stop on exceptions").lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                ForEach(breakpoints.exceptionFilters) { filter in
                    Toggle(filter.label, isOn: Binding(get: { breakpoints.enabledExceptionFilters.contains(filter.filter) },
                                                       set: { breakpoints.setException(filter.filter, enabled: $0) }))
                }
                if !breakpoints.enabledExceptionFilters.isEmpty {
                    Divider()
                    Button("Turn All Off") {
                        breakpoints.enabledExceptionFilters.forEach { breakpoints.setException($0, enabled: false) }
                    }
                }
            } label: {
                Text(summary).font(.caption).lineLimit(1).truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help("Which thrown or caught exceptions stop the program")
        }
    }

    private var summary: String {
        let on = breakpoints.exceptionFilters.filter { breakpoints.enabledExceptionFilters.contains($0.filter) }.map(\.label)
        switch on.count {
        case 0: return "Off"
        case 1, 2: return on.joined(separator: ", ")
        default: return "\(on.count) kinds"
        }
    }
}

/// A section's name, how many it holds, and its actions.
private struct DebugSectionHeader<Actions: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let count, count > 0 {
                Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 8) { actions }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }
}

/// A quiet line saying a section is empty, and what would fill it.
private struct DebugEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Green while running, yellow when paused, blue while building or starting.
private struct DebugStateDot: View {
    let state: DebugSession.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .stopped: .yellow
        case .building, .starting: .blue
        case .terminated: .secondary
        }
    }
}

/// Continue/pause, step over/into/out, restart, stop.
struct DebugToolbar: View {
    let workspace: Workspace
    let session: DebugSession

    var body: some View {
        let stopped = session.state == .stopped
        HStack(spacing: 2) {
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
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func button(_ help: String, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        DebugToolbarButton(help: help, symbol: symbol, color: color, action: action)
    }
}

private struct DebugToolbarButton: View {
    let help: String
    let symbol: String
    let color: Color
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
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
        .font(.system(size: 12, design: .monospaced))
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
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Toggle("Enabled", isOn: Binding(get: { breakpoint.isEnabled },
                                            set: { workspace.breakpoints.setEnabled(path, line: breakpoint.line, $0) }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .labelsHidden()
            BreakpointGlyph(mark: workspace.breakpoints.marks(for: path)[breakpoint.line - 1] ?? BreakpointMark())
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text((path as NSString).lastPathComponent).lineLimit(1)
                    Text(folderText).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
                if let condition = breakpoint.condition {
                    Text("when \(condition)").font(.caption.monospaced()).foregroundStyle(.orange).lineLimit(1)
                }
                if let message = breakpoint.logMessage {
                    Text("logs \(message)").font(.caption.monospaced()).foregroundStyle(.blue).lineLimit(1)
                }
            }
            .opacity(breakpoint.isEnabled ? 1 : 0.55)
            Spacer(minLength: 4)
            if isHovering {
                Button("Remove", systemImage: "xmark") { workspace.breakpoints.remove(path, line: breakpoint.line) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Remove this breakpoint")
            }
            Text("\(breakpoint.line)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            workspace.open(fileAt: URL(filePath: path))
            workspace.document(matching: URL(filePath: path))?.revealLine(breakpoint.line)
        }
        .contextMenu {
            Button("Edit Condition…") { editCondition() }
            Button("Edit Log Message…") { editLogMessage() }
            Divider()
            Button("Remove", role: .destructive) { workspace.breakpoints.remove(path, line: breakpoint.line) }
        }
        .help("\(path):\(breakpoint.line)")
    }

    /// The file's folder, from the workspace folder it's in.
    private var folderText: String {
        let directory = (path as NSString).deletingLastPathComponent
        guard let root = workspace.folder(containing: URL(filePath: path)) else { return (directory as NSString).abbreviatingWithTildeInPath }
        let rootPath = FileWatcher.canonicalPath(root)
        guard directory.hasPrefix(rootPath) else { return directory }
        let relative = String(directory.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative
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
                Button { workspace.hidePanel() } label: { Image(systemName: "chevron.down") }
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

/// An expression shown whenever the program stops, with its value.
private struct WatchRow: View {
    let workspace: Workspace
    let index: Int
    let expression: String
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(expression).foregroundStyle(Color.purple).lineLimit(1).layoutPriority(1)
            Text("=").foregroundStyle(.secondary)
            value
            Spacer(minLength: 4)
            if isHovering {
                HStack(spacing: 6) {
                    Button("Edit", systemImage: "pencil") { edit() }.help("Edit the expression")
                    Button("Remove", systemImage: "xmark") { workspace.breakpoints.removeWatch(at: index) }.help("Stop watching it")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { edit() }
        .contextMenu {
            Button("Edit…") { edit() }
            Button("Copy Value") {
                if case .value(let value) = workspace.debugSession?.watchResults[expression] {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
            }
            Divider()
            Button("Remove", role: .destructive) { workspace.breakpoints.removeWatch(at: index) }
        }
    }

    @ViewBuilder private var value: some View {
        switch workspace.debugSession?.isActive == true ? workspace.debugSession?.watchResults[expression] : nil {
        case .value(let value):
            Text(value).lineLimit(1).truncationMode(.tail).textSelection(.enabled).help(value)
        case .error(let message):
            Text(message).foregroundStyle(.secondary).lineLimit(1).help(message)
        case nil:
            Text("—").foregroundStyle(.tertiary).help("Shown when the program pauses")
        }
    }

    private func edit() {
        Task {
            if let text = await workspace.showInputBox(prompt: "Watch expression", value: expression, placeholder: nil) {
                workspace.breakpoints.replaceWatch(at: index, with: text)
            }
        }
    }
}

/// A breakpoint as the gutter draws it: red when on, grey when off, a diamond for a logpoint,
/// hollow when the debugger couldn't place it, a white bar when it has a condition.
private struct BreakpointGlyph: View {
    let mark: BreakpointMark

    var body: some View {
        let color = mark.isEnabled ? Color.red : Color.gray
        ZStack {
            if mark.isVerified == false {
                shape.stroke(color, lineWidth: 1.5)
            } else {
                shape.fill(color)
            }
            if mark.hasCondition {
                Capsule().fill(.white).frame(width: 5, height: 1.5)
            }
        }
        .frame(width: 9, height: 9)
        .help(mark.isVerified == false ? "The debugger couldn't place this breakpoint" : "")
    }

    private var shape: AnyShape {
        mark.isLogpoint ? AnyShape(Diamond()) : AnyShape(Circle())
    }

    private struct Diamond: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                path.closeSubpath()
            }
        }
    }
}
