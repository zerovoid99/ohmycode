import AppKit
import SwiftUI

/// The Timeline sidebar panel: the commits that changed the active file, newest first
/// (clicking one shows what it changed; the context menu compares it with the current text),
/// or the whole repository's log.
struct TimelineView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("History", selection: $workspace.historyScope) {
                ForEach(Workspace.HistoryScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            Divider()
            switch workspace.historyScope {
            case .file: fileTimeline
            case .repository: RepositoryLogView(workspace: workspace)
            }
        }
    }

    private var fileTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = workspace.activeFileURL ?? workspace.fileHistory?.url {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text(url.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if workspace.fileHistory?.isLoading == true { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
                content(for: url)
            } else {
                ContentUnavailableView("No File", systemImage: "clock.arrow.circlepath",
                                       description: Text("Open a file to see the commits that changed it."))
            }
        }
        // Follow the active file.
        .task(id: workspace.activeFileURL) {
            if let url = workspace.activeFileURL, url != workspace.fileHistory?.url { workspace.loadHistory(for: url) }
        }
    }

    @ViewBuilder
    private func content(for url: URL) -> some View {
        if let history = workspace.fileHistory, history.url == url, let commits = history.commits {
            if commits.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("This file hasn't been committed yet."))
            } else {
                List(commits) { commit in
                    CommitRow(commit: commit)
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.openCommit(commit, for: url) }
                        .contextMenu {
                            Button("Open Changes") { workspace.openCommit(commit, for: url) }
                            Button("Compare with Current") { workspace.compare(commit, with: url) }
                                .disabled(commit.path == nil)
                            Divider()
                            Button("Copy Commit Hash") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commit.sha, forType: .string)
                            }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        } else if workspace.fileHistory?.isLoading == true || workspace.fileHistory?.url != url {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Not in Git", systemImage: "questionmark.folder",
                                   description: Text("This file isn't in a git repository."))
        }
    }
}

private struct CommitRow: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(commit.summary).lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge.letter)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(badge.color)
                        .help(badge.help)
                }
            }
            HStack(spacing: 4) {
                Text(commit.author)
                Text("·")
                Text(commit.date, format: .relative(presentation: .named))
                Spacer(minLength: 4)
                Text(commit.shortSHA).monospaced()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
        .help("\(commit.summary)\n\(commit.author) — \(commit.date.formatted(date: .abbreviated, time: .shortened))\n\(commit.sha)")
    }

    private var badge: (letter: String, color: Color, help: String)? {
        switch commit.change {
        case .modified: nil
        case .added: ("A", .green, "Added in this commit")
        case .deleted: ("D", .red, "Deleted in this commit")
        case .renamed: ("R", .orange, "Renamed from \(commit.parentPath ?? "")")
        }
    }
}

/// Every commit in the repository, newest first; expanding one lists the files it changed.
private struct RepositoryLogView: View {
    let workspace: Workspace
    @State private var expanded: Set<String> = []

    var body: some View {
        Group {
            if let history = workspace.repoHistory {
                if history.commits.isEmpty && !history.isLoading {
                    ContentUnavailableView("No Commits", systemImage: "clock", description: Text("Nothing has been committed yet."))
                } else {
                    // Rows touch (no list insets), so each row's piece of the graph joins the next.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(history.commits.enumerated()), id: \.element.id) { index, commit in
                                commitRow(commit, graph: history.graph.indices.contains(index) ? history.graph[index] : nil,
                                          lanes: history.graphWidth)
                            }
                            if history.hasMore || history.isLoading {
                                HStack {
                                    Spacer()
                                    if history.isLoading {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Button("Load More") { workspace.loadRepoHistory(more: true) }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            } else if workspace.gitRepository == nil {
                ContentUnavailableView("Not in Git", systemImage: "questionmark.folder",
                                       description: Text("This folder isn't in a git repository."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if workspace.repoHistory == nil { workspace.loadRepoHistory() } }
    }

    /// The graph column's lane spacing: narrower when there are many lanes, so it never takes
    /// more than about half the panel.
    private func spacing(for lanes: Int) -> CGFloat { min(11, 120 / CGFloat(max(1, lanes))) }

    private func commitRow(_ commit: RepoCommit, graph: CommitGraphRow?, lanes: Int) -> some View {
        let isExpanded = expanded.contains(commit.sha)
        return HStack(alignment: .top, spacing: 4) {
            if let graph {
                CommitGraphCell(row: graph, lanes: lanes, spacing: spacing(for: lanes), nodeY: 13)
                    .frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    RepoCommitRow(commit: commit)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 5)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggle(commit) }
                .contextMenu { menu(for: commit) }
                if isExpanded {
                    files(of: commit).padding(.bottom, 4)
                }
            }
            .padding(.top, 4)
            .padding(.trailing, 8)
        }
        .padding(.leading, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toggle(_ commit: RepoCommit) {
        if expanded.remove(commit.sha) == nil {
            expanded.insert(commit.sha)
            Task { await workspace.loadFiles(of: commit) }
        }
    }

    private func files(of commit: RepoCommit) -> some View {
        VStack(alignment: .leading, spacing: 3) { fileRows(of: commit) }
    }

    @ViewBuilder
    private func fileRows(of commit: RepoCommit) -> some View {
        if let files = workspace.commitFiles[commit.sha] {
            if files.isEmpty {
                Text("No file changes").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(files) { file in
                HStack(spacing: 6) {
                    Text(letter(file.change))
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(color(file.change))
                        .frame(width: 12)
                    Text(file.fileName).strikethrough(file.change == .deleted).lineLimit(1)
                    Text(file.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                .contentShape(Rectangle())
                .onTapGesture { workspace.openCommit(commit, file: file) }
                .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func menu(for commit: RepoCommit) -> some View {
        Button("Create Branch Here…") { workspace.createBranch(at: commit) }
        Button("Check Out (Detached)…") { workspace.checkoutDetached(commit) }
        Divider()
        Button("Copy Commit Hash") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.sha, forType: .string)
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

    private func color(_ change: GitCommit.Change) -> Color {
        switch change {
        case .added: .green
        case .deleted: .red
        case .renamed, .modified: .orange
        }
    }
}

private struct RepoCommitRow: View {
    let commit: RepoCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                ForEach(commit.refs, id: \.self) { ref in RefBadge(ref: ref) }
                Text(commit.summary).lineLimit(1)
            }
            HStack(spacing: 4) {
                Text(commit.author)
                Text("·")
                Text(commit.date, format: .relative(presentation: .named))
                Spacer(minLength: 4)
                Text(commit.shortSHA).monospaced()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
        .help("\(commit.summary)\n\(commit.author) — \(commit.date.formatted(date: .abbreviated, time: .shortened))\n\(commit.sha)")
    }
}

/// A branch or tag name on a commit ("HEAD -> main" shows as main, marked current).
private struct RefBadge: View {
    let ref: String

    var body: some View {
        let isHead = ref.hasPrefix("HEAD")
        let isTag = ref.hasPrefix("tag: ")
        let name = isTag ? String(ref.dropFirst(5)) : ref.replacingOccurrences(of: "HEAD -> ", with: "")
        Label(name, systemImage: isTag ? "tag" : (isHead ? "checkmark.circle.fill" : "arrow.triangle.branch"))
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(isHead ? Color.accentColor : .secondary)
            .background(Capsule().fill((isHead ? Color.accentColor : Color.secondary).opacity(0.15)))
            .fixedSize()
    }
}
