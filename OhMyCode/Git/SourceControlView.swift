import AppKit
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
                HStack(spacing: 4) {
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
                    Menu {
                        Button("Commit (Amend)") {
                            Task { if await workspace.amend(message: message) { message = "" } }
                        }
                        .help("Add what is staged to the last commit; an empty message keeps its message")
                        Button("Edit Last Commit Message") {
                            Task { if let last = await workspace.lastCommitMessage() { message = last } }
                        }
                        Divider()
                        Button("Undo Last Commit") {
                            Task {
                                // Its message comes back to the box, unless something is typed there.
                                if let undone = await workspace.undoLastCommit(),
                                   message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    message = undone
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Amend or undo the last commit")
                    .disabled(!status.hasCommits || workspace.isRunningGitCommand || status.operation != nil)
                }

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
                                workspace.discard(status.unstagedChanges.filter { !$0.isConflicted && !$0.isSubmodule })
                            }
                            Button("Stage All", systemImage: "plus") {
                                workspace.stage(status.unstagedChanges.map(\.path))
                            }
                        }
                    }
                    if !workspace.submodules.isEmpty {
                        Section {
                            ForEach(workspace.submodules) { submodule in
                                SubmoduleRow(workspace: workspace, submodule: submodule)
                            }
                        } header: {
                            sectionHeader("Submodules", count: workspace.submodules.count) {
                                Button("Update All", systemImage: "arrow.down.circle") { workspace.updateSubmodules() }
                                    .help("Check out the recorded commits, cloning submodules not initialized yet")
                                    .disabled(workspace.isRunningGitCommand)
                            }
                        }
                    }
                    if let worktrees = workspace.worktrees, worktrees.count > 1 {
                        Section {
                            ForEach(worktrees) { worktree in
                                WorktreeRow(workspace: workspace, worktree: worktree)
                            }
                        } header: {
                            sectionHeader("Worktrees", count: worktrees.count) {
                                Button("New Worktree…", systemImage: "plus") { Task { await workspace.createWorktree(for: nil) } }
                                    .help("A new branch from the current commit, in its own folder")
                                    .disabled(workspace.isRunningGitCommand)
                            }
                        }
                    }
                    if !workspace.stashes.isEmpty || !status.changes.isEmpty {
                        Section {
                            ForEach(workspace.stashes) { stash in
                                StashRow(workspace: workspace, stash: stash)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Text("Stashes")
                                Text("\(workspace.stashes.count)").foregroundStyle(.secondary)
                                Spacer()
                                Menu {
                                    Button("Stash Changes…") { workspace.stash(.all) }
                                    Button("Stash Including Untracked…") { workspace.stash(.includingUntracked) }
                                    Button("Stash Staged Changes…") { workspace.stash(.staged) }
                                        .disabled(status.stagedChanges.isEmpty)
                                } label: {
                                    Label("Stash", systemImage: "archivebox")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .labelStyle(.iconOnly)
                                .help("Stash changes")
                                .disabled(status.changes.isEmpty || workspace.isRunningGitCommand)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .task(id: workspace.rootURL) { await workspace.loadWorktrees() }
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
            Image(systemName: change.isSubmodule ? "shippingbox" : "doc.text").foregroundStyle(.secondary)
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
                        if !change.isConflicted && !change.isSubmodule {
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
            // A submodule has no text diff: its menu opens or updates it.
            guard status != .deleted, !change.isSubmodule, let root = workspace.rootURL else { return }
            if change.isUntracked {
                workspace.open(fileAt: root.appending(path: change.path))
            } else {
                workspace.openChanges(for: root.appending(path: change.path), staged: staged)
            }
        }
        .contextMenu {
            if let submodule = workspace.submodule(for: change) {
                Button("Open Submodule in New Window") { workspace.openSubmodule(submodule) }
                    .disabled(submodule.state == .notInitialized)
                Button("Update Submodule") { workspace.updateSubmodules([submodule]) }
                    .help("Check out the commit the repository records for it")
            } else if status != .deleted, let root = workspace.rootURL {
                if !change.isUntracked {
                    Button("Open Changes") { workspace.openChanges(for: root.appending(path: change.path), staged: staged) }
                }
                Button("Open File") { workspace.open(fileAt: root.appending(path: change.path)) }
            }
        }
        .help(change.isSubmodule ? "\(change.path) — submodule: its commit changed or it has changes inside"
                                 : "\(change.path) — \(status?.label ?? "")")
    }
}

/// A submodule: its commit and state; update it or open it in its own window.
private struct SubmoduleRow: View {
    let workspace: Workspace
    let submodule: GitSubmodule
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "shippingbox").foregroundStyle(submodule.state == .notInitialized ? .tertiary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(submodule.name).lineLimit(1)
                HStack(spacing: 4) {
                    Text(submodule.shortSHA).monospaced()
                    if let describe = submodule.describe { Text("·"); Text(describe) }
                    if submodule.path != submodule.name { Text("·"); Text(submodule.path).truncationMode(.head) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isHovering {
                Group {
                    Button("Update", systemImage: "arrow.down.circle") { workspace.updateSubmodules([submodule]) }
                        .help(submodule.state == .notInitialized ? "Clone and check out the recorded commit"
                                                                 : "Check out the recorded commit")
                    Button("Open", systemImage: "macwindow") { workspace.openSubmodule(submodule) }
                        .help("Open in a new window")
                        .disabled(submodule.state == .notInitialized)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(workspace.isRunningGitCommand)
            }
            if let badge {
                Text(badge.letter)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(badge.color)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Update Submodule") { workspace.updateSubmodules([submodule]) }
            Button("Open in New Window") { workspace.openSubmodule(submodule) }
                .disabled(submodule.state == .notInitialized)
            if let url = submodule.url {
                Button("Copy URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        }
        .help("\(submodule.path) — \(submodule.stateDescription)" + (submodule.url.map { "\n\(GitRemote.display($0))" } ?? ""))
    }

    private var badge: (letter: String, color: Color)? {
        switch submodule.state {
        case .upToDate: nil
        case .notInitialized: ("–", .secondary)
        case .otherCommit: ("+", .orange)
        case .conflicted: ("!", .red)
        }
    }
}

/// A worktree: its branch and folder; open it in its own window or remove it.
private struct WorktreeRow: View {
    let workspace: Workspace
    let worktree: GitWorktree
    @State private var isHovering = false

    var body: some View {
        let isCurrent = workspace.isCurrent(worktree)
        HStack(spacing: 6) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "folder")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(worktree.branch ?? (worktree.isBare ? "(bare)" : "Detached \(worktree.head.map { String($0.prefix(7)) } ?? "")"))
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Text((worktree.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if worktree.isPrunable {
                Text("missing").font(.caption2).foregroundStyle(.red)
            } else if worktree.isLocked {
                Image(systemName: "lock").font(.caption).foregroundStyle(.secondary)
            }
            if isHovering && !isCurrent && !worktree.isBare {
                Button("Open", systemImage: "macwindow") { workspace.openWorktree(worktree) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open in a new window")
                    .disabled(worktree.isPrunable)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open in New Window") { workspace.openWorktree(worktree) }
                .disabled(isCurrent || worktree.isBare || worktree.isPrunable)
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree.url]) }
                .disabled(worktree.isPrunable)
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path, forType: .string)
            }
            Divider()
            Button("Remove Worktree…", role: .destructive) { Task { await workspace.removeWorktree(worktree) } }
                .disabled(isCurrent || worktree.isBare)
        }
        .help(isCurrent ? "\(worktree.path) — this window" : worktree.path)
    }
}

/// A stash entry: expand it for its files; apply, pop or drop it.
private struct StashRow: View {
    let workspace: Workspace
    let stash: GitStash
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let files = workspace.stashFiles[stash.sha] {
                ForEach(files) { file in
                    HStack(spacing: 6) {
                        Text(file.isUntracked ? "U" : letter(file.file.change))
                            .font(.caption.weight(.semibold).monospaced())
                            .foregroundStyle(file.isUntracked || file.file.change == .added ? .green
                                             : file.file.change == .deleted ? .red : .orange)
                            .frame(width: 12)
                        Text(file.file.fileName).lineLimit(1)
                        Text(file.file.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { workspace.openStashFile(stash, file) }
                    .help(file.file.path)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "archivebox").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(stash.message).lineLimit(1)
                    HStack(spacing: 4) {
                        if let branch = stash.branch { Text(branch) ; Text("·") }
                        Text(stash.date, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isHovering {
                    Group {
                        Button("Apply", systemImage: "arrow.down.doc") { workspace.applyStash(stash, pop: false) }
                            .help("Apply (keep the stash)")
                        Button("Pop", systemImage: "arrow.up.bin") { workspace.applyStash(stash, pop: true) }
                            .help("Pop (apply, then drop the stash)")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(workspace.isRunningGitCommand)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .contextMenu {
                Button("Apply Stash") { workspace.applyStash(stash, pop: false) }
                Button("Pop Stash") { workspace.applyStash(stash, pop: true) }
                Button("Create Branch from Stash…") { workspace.branchFromStash(stash) }
                Divider()
                Button("Drop Stash…", role: .destructive) { workspace.dropStash(stash) }
            }
            .help("\(stash.ref): \(stash.subject)")
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { Task { await workspace.loadFiles(of: stash) } }
        }
    }

    private func letter(_ change: GitCommit.Change) -> String {
        switch change {
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .modified: "M"
        }
    }
}
