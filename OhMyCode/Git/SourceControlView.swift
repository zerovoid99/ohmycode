import SwiftUI

/// Source Control sidebar: commit message, staged and unstaged changes with per-file actions.
struct SourceControlView: View {
    let workspace: Workspace
    @State private var message = ""

    var body: some View {
        if let status = workspace.gitStatus {
            VStack(spacing: 8) {
                BranchBar(workspace: workspace, status: status)
                if let operation = status.operation {
                    OperationBanner(workspace: workspace, operation: operation,
                                    conflicts: status.changes.filter(\.isConflicted).count)
                }
                TextField("Message (⌘↩ to commit on \(status.branch ?? "HEAD"))", text: $message, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { if await workspace.commit(message: message) { message = "" } }
                } label: {
                    Label("Commit", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || status.stagedChanges.isEmpty || workspace.isRunningGitCommand)
                .help(status.stagedChanges.isEmpty ? "Stage changes to commit them" : "Commit staged changes")

                List {
                    if !status.stagedChanges.isEmpty {
                        Section {
                            ForEach(status.stagedChanges) { change in
                                ChangeRow(workspace: workspace, change: change, staged: true)
                            }
                        } header: {
                            sectionHeader("Staged Changes", count: status.stagedChanges.count) {
                                Button("Unstage All", systemImage: "minus") {
                                    workspace.unstage(status.stagedChanges.map(\.path))
                                }
                            }
                        }
                    }
                    Section {
                        ForEach(status.unstagedChanges) { change in
                            ChangeRow(workspace: workspace, change: change, staged: false)
                        }
                    } header: {
                        sectionHeader("Changes", count: status.unstagedChanges.count) {
                            Button("Discard All", systemImage: "arrow.uturn.backward") {
                                workspace.discard(status.unstagedChanges.filter { !$0.isConflicted })
                            }
                            Button("Stage All", systemImage: "plus") {
                                workspace.stage(status.unstagedChanges.map(\.path))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
        } else {
            ContentUnavailableView("No Repository", systemImage: "arrow.triangle.branch",
                                   description: Text("This folder isn't in a git repository."))
        }
    }

    private func sectionHeader<Actions: View>(_ title: String, count: Int,
                                              @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(.secondary)
            Spacer()
            actions()
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(count == 0)
        }
    }
}

private struct ChangeRow: View {
    let workspace: Workspace
    let change: GitChange
    let staged: Bool
    @State private var isHovering = false

    private var status: GitFileStatus? { staged ? change.stagedStatus : change.unstagedStatus }
    private var name: String { (change.path as NSString).lastPathComponent }
    private var directory: String { (change.path as NSString).deletingLastPathComponent }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(name)
                .strikethrough(status == .deleted)
                .lineLimit(1)
            Text(directory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if isHovering {
                Group {
                    if staged {
                        Button("Unstage", systemImage: "minus") { workspace.unstage([change.path]) }
                    } else {
                        if !change.isConflicted {
                            Button("Discard", systemImage: "arrow.uturn.backward") { workspace.discard([change]) }
                        }
                        Button("Stage", systemImage: "plus") { workspace.stage([change.path]) }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            if let status {
                Text(status.letter)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(Color(nsColor: status.color))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Like VS Code: a click shows the changes; the context menu opens the file.
        .onTapGesture {
            guard status != .deleted, let root = workspace.rootURL else { return }
            if change.isUntracked {
                workspace.open(fileAt: root.appending(path: change.path))
            } else {
                workspace.openChanges(for: root.appending(path: change.path), staged: staged)
            }
        }
        .contextMenu {
            if status != .deleted, let root = workspace.rootURL {
                if !change.isUntracked {
                    Button("Open Changes") { workspace.openChanges(for: root.appending(path: change.path), staged: staged) }
                }
                Button("Open File") { workspace.open(fileAt: root.appending(path: change.path)) }
            }
        }
        .help("\(change.path) — \(status?.label ?? "")")
    }
}
