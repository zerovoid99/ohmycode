import SwiftUI

/// The interactive rebase sheet: the commits from the chosen one to HEAD, oldest first. Each
/// gets an action; drag to reorder. Nothing runs until Start Rebase.
struct InteractiveRebaseView: View {
    let workspace: Workspace
    @State var plan: RebasePlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let problem = RebaseStep.problem(with: plan.steps)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Interactive Rebase").font(.headline)
                Text("\(plan.steps.count) commit\(plan.steps.count == 1 ? "" : "s") on \(workspace.gitStatus?.branch ?? "HEAD"), oldest first. "
                     + "Drag to reorder; squash and fixup meld a commit into the one above it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List {
                ForEach($plan.steps) { $step in
                    RebaseStepRow(step: $step)
                }
                .onMove { plan.steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 220)
            HStack {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Reset") { plan.steps = plan.original }
                    .disabled(!plan.changesSomething)
                Button("Cancel", role: .cancel) { workspace.pendingRebase = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Rebase") { workspace.startRebase(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || !plan.changesSomething)
            }
        }
        .padding(16)
        .frame(width: 620, height: 460)
    }
}

private struct RebaseStepRow: View {
    @Binding var step: RebaseStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
                Picker("Action", selection: $step.action) {
                    ForEach(RebaseStep.Action.allCases, id: \.self) { action in
                        Text(action.rawValue).tag(action).help(action.help)
                    }
                }
                .labelsHidden()
                .frame(width: 92)
                .help(step.action.help)
                if step.action == .squash || step.action == .fixup {
                    Image(systemName: "arrow.turn.left.up").foregroundStyle(.secondary).help("Melds into the commit above")
                }
                Text(step.commit.summary)
                    .lineLimit(1)
                    .strikethrough(step.action == .drop)
                    .foregroundStyle(step.action == .drop ? .secondary : .primary)
                Spacer(minLength: 6)
                Text(step.commit.shortSHA).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if step.action == .reword {
                TextField("New message", text: $step.message, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 2)
    }
}
