import AppKit
import SwiftUI

/// The bottom panel's Tasks tab: each run's output; lines reporting an error open it.
struct TasksView: View {
    let workspace: Workspace
    /// Explain with AI on the selected run's output.
    @State private var explanation: AIExplainModel?

    var body: some View {
        let run = workspace.selectedTaskRun
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BottomPanelSwitcher(workspace: workspace)
                Divider().frame(height: 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(workspace.taskRuns) { item in
                            TaskRunTab(run: item, isSelected: item.id == run?.id,
                                       onSelect: { workspace.selectedTaskRunID = item.id },
                                       onClose: { workspace.closeTaskRun(item) })
                        }
                    }
                }
                Spacer(minLength: 8)
                Group {
                    Button { Task { await workspace.pickAndRunTask() } } label: { Image(systemName: "play") }
                        .help("Run Task…")
                    if let run {
                        if run.state.isRunning {
                            Button { run.terminate() } label: { Image(systemName: "stop.fill") }
                                .help("Terminate")
                        } else {
                            Button { workspace.runTask(run.task) } label: { Image(systemName: "arrow.clockwise") }
                                .help("Run again")
                        }
                        Button { run.clearOutput() } label: { Image(systemName: "trash") }
                            .help("Clear the output")
                        Button { explain(run) } label: { Image(systemName: "sparkles") }
                            .help(AISettings.shared.isConfigured ? "Explain the output with AI" : AIActions.notConfiguredHelp)
                            .disabled(!AISettings.shared.isConfigured || run.lines.isEmpty)
                            .popover(isPresented: Binding(get: { explanation != nil },
                                                          set: { if !$0 { explanation?.stop(); explanation = nil } })) {
                                if let explanation {
                                    AIExplainView(model: explanation) { self.explanation?.stop(); self.explanation = nil }
                                }
                            }
                    }
                    Button { workspace.hidePanel() } label: { Image(systemName: "chevron.down") }
                        .help("Hide the panel")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .themedBackground(.panel, fallback: .bar)
            Divider()
            if let run {
                TaskOutputView(run: run) { workspace.open($0) }
            } else {
                VStack(spacing: 8) {
                    Text("No task has run yet.").foregroundStyle(.secondary)
                    HStack {
                        Button("Run Task…") { Task { await workspace.pickAndRunTask() } }
                        Button("Configure Tasks…") { workspace.configureTasks() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The run's last 200 lines of output, explained with the task's command.
    private func explain(_ run: TaskRun) {
        explanation?.stop()
        let output = run.lines.suffix(200).map(\.text).joined(separator: "\n")
        explanation = workspace.outputExplanation(output, source: "Task “\(run.task.label)”", command: run.task.command)
    }
}

private struct TaskRunTab: View {
    let run: TaskRun
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            TaskStateIcon(state: run.state)
            Text(run.task.label)
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: 180)
                .foregroundStyle(isSelected ? .primary : .secondary)
            if !run.problems.isEmpty {
                Text("\(run.problems.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
                .opacity(isSelected || isHovering ? 1 : 0)
                .help(run.state.isRunning ? "Terminate and close" : "Close")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isSelected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

struct TaskStateIcon: View {
    let state: TaskRun.State

    var body: some View {
        switch state {
        case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed, .couldNotStart: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        case .terminated: Image(systemName: "stop.circle").foregroundStyle(.secondary).font(.caption)
        }
    }
}

private struct TaskOutputView: View {
    let run: TaskRun
    let open: (ProblemMatcher.Problem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(run.lines) { line in
                        row(line).id(line.id)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: run.lines.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear { if let id = run.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    @ViewBuilder
    private func row(_ line: TaskRun.Line) -> some View {
        if let index = line.problem, run.problems.indices.contains(index) {
            let problem = run.problems[index]
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(problem.severity == .error ? Color.red : problem.severity == .warning ? Color.orange : Color.primary)
                .underline(true, color: .secondary.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { open(problem) }
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                .help("Open \(problem.url.lastPathComponent):\(problem.line):\(problem.column)")
        } else {
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.text.hasPrefix("> ") || line.text.hasPrefix("✓") || line.text.hasPrefix("✗") || line.text.hasPrefix("■")
                                 ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
