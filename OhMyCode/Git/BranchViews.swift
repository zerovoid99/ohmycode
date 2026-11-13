import SwiftUI

/// Top of the Source Control panel: the current branch (click to pick another), how far it is
/// from its upstream, and fetch, pull and push.
struct BranchBar: View {
    let workspace: Workspace
    let status: GitStatus
    @State private var isPicking = false

    var body: some View {
        HStack(spacing: 6) {
            Button { isPicking = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: status.branch == nil ? "exclamationmark.triangle" : "arrow.triangle.branch")
                    Text(status.branch ?? "Detached HEAD").lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .help("Switch, create, merge or delete branches")
            .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                BranchPicker(workspace: workspace) { isPicking = false }
            }
            Spacer(minLength: 4)
            if status.ahead > 0 || status.behind > 0 {
                Text("\(status.behind)↓ \(status.ahead)↑")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("\(status.behind) to pull, \(status.ahead) to push (as of the last fetch)")
            }
            Group {
                Button("Fetch", systemImage: "arrow.triangle.2.circlepath") { workspace.fetch() }
                    .help("Fetch from all remotes")
                Button("Pull", systemImage: "arrow.down") { workspace.pull() }
                    .help(status.upstream.map { "Pull from \($0)" } ?? "Pull (no upstream yet)")
                    .disabled(status.upstream == nil)
                Button("Push", systemImage: "arrow.up") { workspace.push() }
                    .help(status.upstream.map { "Push to \($0)" } ?? "Push and set the upstream")
                    .disabled(status.branch == nil)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(workspace.isRunningGitCommand || status.operation != nil)
            if workspace.isRunningGitCommand { ProgressView().controlSize(.mini) }
        }
        .font(.callout)
    }
}

/// Shown while a merge or rebase waits: resolve the conflicts (stage the files), then continue.
struct OperationBanner: View {
    let workspace: Workspace
    let operation: GitOperation
    let conflicts: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(operation == .merge ? "Merging" : "Rebasing", systemImage: "arrow.triangle.merge")
                .font(.callout.weight(.semibold))
            Text(conflicts > 0
                 ? "\(conflicts) file\(conflicts == 1 ? " has" : "s have") conflicts. Fix them, stage the files, then "
                   + (operation == .merge ? "commit." : "continue.")
                 : operation == .merge ? "Conflicts are resolved: commit to finish the merge." : "Ready to continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if operation == .rebase {
                    Button("Continue") { workspace.resolveOperation(.continue) }.disabled(conflicts > 0)
                    Button("Skip") { workspace.resolveOperation(.skip) }
                        .help("Drop the commit being replayed")
                }
                Spacer()
                Button("Abort", role: .destructive) { workspace.resolveOperation(.abort) }
            }
            .controlSize(.small)
            .disabled(workspace.isRunningGitCommand)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The branch list: search, switch with a click, more in the context menu.
struct BranchPicker: View {
    let workspace: Workspace
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search branches", text: $query).textFieldStyle(.roundedBorder)
                Button("New Branch…", systemImage: "plus") {
                    dismiss()
                    workspace.createBranchFromCurrent()
                }
                .labelStyle(.iconOnly)
                .help("Create a branch from the current commit")
            }
            if let branches = workspace.branches {
                let shown = branches.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                List {
                    section("Branches", shown.filter { !$0.isRemote })
                    section("Remote Branches", shown.filter(\.isRemote))
                }
                .listStyle(.plain)
                .frame(height: min(360, CGFloat(shown.count) * 34 + 60))
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(10)
        .frame(width: 340)
        .task { await workspace.loadBranches() }
    }

    @ViewBuilder
    private func section(_ title: String, _ branches: [GitBranch]) -> some View {
        if !branches.isEmpty {
            Section(title) {
                ForEach(branches) { branch in
                    BranchRow(branch: branch)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !branch.isCurrent else { return }
                            dismiss()
                            workspace.switchBranch(branch)
                        }
                        .contextMenu { menu(for: branch) }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for branch: GitBranch) -> some View {
        let current = workspace.gitStatus?.branch ?? "HEAD"
        Button(branch.isRemote ? "Check Out as \(branch.localName)" : "Switch to \(branch.name)") {
            dismiss(); workspace.switchBranch(branch)
        }
        .disabled(branch.isCurrent)
        Divider()
        Button("Merge into \(current)") { dismiss(); workspace.mergeIntoCurrent(branch) }
            .disabled(branch.isCurrent)
        Button("Rebase \(current) onto \(branch.name)") { dismiss(); workspace.rebaseCurrent(onto: branch) }
            .disabled(branch.isCurrent)
        if !branch.isRemote {
            Divider()
            Button("Rename…") { dismiss(); workspace.renameBranch(branch) }
            Button("Delete", role: .destructive) { workspace.deleteBranch(branch) }
                .disabled(branch.isCurrent)
        }
    }
}

private struct BranchRow: View {
    let branch: GitBranch

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: branch.isCurrent ? "checkmark" : (branch.isRemote ? "cloud" : "arrow.triangle.branch"))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(branch.name).fontWeight(branch.isCurrent ? .semibold : .regular).lineLimit(1)
                Text(branch.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                if !branch.tracking.isEmpty {
                    Text(branch.tracking).font(.caption2).foregroundStyle(branch.tracking == "gone" ? .red : .orange)
                }
                Text(branch.date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .help(branch.upstream.map { "\(branch.name) → \($0)" } ?? branch.name)
    }
}
