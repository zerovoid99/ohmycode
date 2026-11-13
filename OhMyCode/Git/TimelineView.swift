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
            case .compare: CompareView(workspace: workspace)
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
    @State private var query: String
    @State private var kind: LogFilter.Kind

    /// Starts from the search the log is filtered by: the panel is rebuilt when switching
    /// sidebar tabs, and an empty box would clear the search.
    init(workspace: Workspace) {
        self.workspace = workspace
        _query = State(initialValue: workspace.repoHistoryFilter?.text ?? "")
        _kind = State(initialValue: workspace.repoHistoryFilter?.kind ?? .message)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            content
        }
        // Debounced: searching code (-S) reads every commit's changes.
        .task(id: "\(kind.rawValue)\u{1f}\(query)") {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let filter = text.isEmpty ? nil : LogFilter(kind: kind, text: text)
            guard filter != workspace.repoHistoryFilter else { return }
            if filter != nil { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            workspace.repoHistoryFilter = filter
        }
        // A search started elsewhere (blame's Show in Timeline) shows in the box.
        .onChange(of: workspace.repoHistoryFilter) { _, filter in
            let current = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let filter, filter.text != current || filter.kind != kind else { return }
            query = filter.text
            kind = filter.kind
        }
        // The commit searched for by its whole hash opens, showing its files.
        .onChange(of: workspace.repoHistory?.pinned?.sha, initial: true) { _, sha in
            if let sha, sha == workspace.repoHistoryFilter?.text.lowercased() {
                expanded.insert(sha)
                if let commit = workspace.repoHistory?.pinned { Task { await workspace.loadFiles(of: commit) } }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search commits", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear the search")
            }
            Picker("Search in", selection: $kind) {
                ForEach(LogFilter.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0).help($0.help) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help(kind.help)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var content: some View {
        Group {
            if let history = workspace.repoHistory {
                if history.commits.isEmpty && !history.isLoading {
                    if workspace.repoHistoryFilter != nil {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ContentUnavailableView("No Commits", systemImage: "clock", description: Text("Nothing has been committed yet."))
                    }
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
        Button("Create Tag…") { workspace.createTag(at: commit) }
        ForEach(commit.tags, id: \.self) { tag in
            Menu("Tag “\(tag)”") {
                Button("Push to Remote") { workspace.pushTag(tag) }
                Divider()
                Button("Delete…", role: .destructive) { workspace.deleteTag(tag) }
                Button("Delete from Remote…", role: .destructive) { workspace.deleteRemoteTag(tag) }
            }
        }
        Divider()
        Button("Cherry-Pick into \(workspace.gitStatus?.branch ?? "HEAD")") { workspace.cherryPick(commit) }
            .help("Apply this commit's changes on the current branch as a new commit")
        Button("Revert Commit…") { workspace.revertCommit(commit) }
            .help("Add a commit that undoes this one")
        Button("Interactive Rebase from Here…") { Task { await workspace.planInteractiveRebase(from: commit) } }
            .help("Reorder, reword, squash or drop this commit and the ones after it")
        Divider()
        Button("Compare with HEAD") {
            Task { await workspace.compare(commit.shortSHA, with: "HEAD", sinceCommonAncestor: false) }
        }
        .help("Every difference between this commit and the current one")
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

/// Compares two branches, tags or commits: how far apart they are and the files that differ.
private struct CompareView: View {
    let workspace: Workspace
    @State private var base: String
    @State private var target: String
    @State private var sinceCommonAncestor: Bool

    init(workspace: Workspace) {
        self.workspace = workspace
        let comparison = workspace.comparison
        _base = State(initialValue: comparison?.base ?? workspace.gitStatus?.branch ?? "HEAD")
        _target = State(initialValue: comparison?.target ?? "")
        _sinceCommonAncestor = State(initialValue: comparison?.sinceCommonAncestor ?? true)
    }

    private var canCompare: Bool {
        !base.trimmingCharacters(in: .whitespaces).isEmpty && !target.trimmingCharacters(in: .whitespaces).isEmpty
            && !workspace.isComparing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            form
            Divider()
            result
        }
        .task { if workspace.branches == nil { await workspace.loadBranches() } }
        // A comparison started elsewhere (a branch's or commit's menu) shows its refs here.
        .onChange(of: workspace.comparison) { _, comparison in
            guard let comparison else { return }
            base = comparison.base
            target = comparison.target
            sinceCommonAncestor = comparison.sinceCommonAncestor
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            refField("Base", text: $base)
            refField("Compare", text: $target)
            HStack {
                Toggle("Since common ancestor", isOn: $sinceCommonAncestor)
                    .toggleStyle(.checkbox)
                    .help("Only what “Compare” changed since it diverged from “Base”, as a pull request shows. "
                          + "Off: every difference between the two.")
                Spacer()
                Button("Swap", systemImage: "arrow.up.arrow.down") { swap(&base, &target) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Swap base and compare")
                Button("Compare") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCompare)
            }
            .font(.callout)
        }
        .padding(8)
    }

    private func refField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            TextField("branch, tag or commit", text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canCompare { run() } }
            Menu {
                Button("HEAD") { text.wrappedValue = "HEAD" }
                let branches = workspace.branches ?? []
                Section("Branches") {
                    ForEach(branches.filter { !$0.isRemote }) { branch in Button(branch.name) { text.wrappedValue = branch.name } }
                }
                Section("Remote Branches") {
                    ForEach(branches.filter(\.isRemote)) { branch in Button(branch.name) { text.wrappedValue = branch.name } }
                }
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick a branch")
        }
    }

    private func run() {
        let base = base.trimmingCharacters(in: .whitespaces), target = target.trimmingCharacters(in: .whitespaces)
        Task { await workspace.compare(base, with: target, sinceCommonAncestor: sinceCommonAncestor) }
    }

    @ViewBuilder
    private var result: some View {
        if workspace.isComparing {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let comparison = workspace.comparison {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(comparison.target) \(comparison.sinceCommonAncestor ? "since" : "vs") \(comparison.base)")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(summary(comparison)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close", systemImage: "xmark") { workspace.clearComparison() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Close the comparison")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
                if comparison.files.isEmpty {
                    ContentUnavailableView("No Differences", systemImage: "equal.circle",
                                           description: Text("The files are the same in both."))
                } else {
                    List(comparison.files) { file in
                        HStack(spacing: 6) {
                            Text(letter(file.change))
                                .font(.caption.weight(.semibold).monospaced())
                                .foregroundStyle(color(file.change))
                                .frame(width: 12)
                            Text(file.fileName).strikethrough(file.change == .deleted).lineLimit(1)
                            Text(file.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.openComparison(file) }
                        .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
        } else {
            ContentUnavailableView("Compare", systemImage: "arrow.left.arrow.right",
                                   description: Text("Pick two branches, tags or commits to see the files that differ."))
        }
    }

    private func summary(_ comparison: RefComparison) -> String {
        let files = "\(comparison.files.count) file\(comparison.files.count == 1 ? "" : "s") changed"
        func commits(_ count: Int) -> String { "\(count) commit\(count == 1 ? "" : "s")" }
        return "\(files) · \(commits(comparison.ahead)) ahead, \(commits(comparison.behind)) behind"
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
