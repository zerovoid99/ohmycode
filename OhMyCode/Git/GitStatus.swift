import AppKit

enum GitFileStatus: Int, Sendable, Comparable {
    // Raw values order importance: a folder shows its most important child's status.
    case untracked, renamed, added, modified, deleted, conflicted

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var letter: String {
        switch self {
        case .untracked: "U"
        case .renamed: "R"
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .conflicted: "C"
        }
    }

    var label: String {
        switch self {
        case .untracked: "Untracked"
        case .renamed: "Renamed"
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .conflicted: "Conflict"
        }
    }

    var color: NSColor {
        switch self {
        case .untracked, .added: .systemGreen
        case .modified, .renamed: .systemOrange
        case .deleted: .systemRed
        case .conflicted: .systemPurple
        }
    }

    /// From the two-letter XY code of `git status --porcelain=v2` (index, worktree).
    init?(xy: String) {
        let codes = Array(xy)
        guard codes.count == 2 else { return nil }
        let (index, worktree) = (codes[0], codes[1])
        if index == "D" || worktree == "D" { self = .deleted }
        else if index == "A" { self = .added }
        else if index == "R" || index == "C" { self = .renamed }
        else if index == "M" || worktree == "M" || index == "T" || worktree == "T" { self = .modified }
        else { return nil }
    }
}

/// One path in `git status`, split into its staged (index) and unstaged (worktree) parts.
struct GitChange: Sendable, Equatable, Identifiable, Hashable {
    let path: String
    /// Porcelain codes: index (staged) and worktree (unstaged); "." means unchanged.
    let index: Character
    let worktree: Character
    var originalPath: String?
    /// A submodule: its recorded commit changed, or it has changes inside.
    var isSubmodule = false

    var id: String { path }
    var isUntracked: Bool { index == "?" }
    var isConflicted: Bool { index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") }
    var isStaged: Bool { !isUntracked && !isConflicted && index != "." }
    var hasUnstagedChanges: Bool { isUntracked || isConflicted || worktree != "." }

    var stagedStatus: GitFileStatus? { isStaged ? Self.status(index) : nil }
    var unstagedStatus: GitFileStatus? {
        if isConflicted { return .conflicted }
        if isUntracked { return .untracked }
        return worktree == "." ? nil : Self.status(worktree)
    }

    private static func status(_ code: Character) -> GitFileStatus {
        switch code {
        case "A": .added
        case "D": .deleted
        case "R", "C": .renamed
        default: .modified
        }
    }
}

/// A snapshot of `git status`, with paths relative to the workspace folder.
struct GitStatus: Sendable, Equatable {
    var branch: String?
    /// The branch's upstream ("origin/main"), if it has one.
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// A merge or rebase stopped midway (conflicts, or waiting to continue).
    var operation: GitOperation?
    /// HEAD points at a commit (false in a repository with no commits yet).
    var hasCommits = false
    private(set) var files: [String: GitFileStatus] = [:]
    /// Untracked folders git reports as a whole ("dir/"), without listing their contents.
    private(set) var untrackedDirectories: [String] = []
    /// Most important status of anything inside each folder.
    private(set) var directories: [String: GitFileStatus] = [:]
    /// Every changed path, in git's order, for the Source Control panel.
    private(set) var changes: [GitChange] = []

    var stagedChanges: [GitChange] { changes.filter(\.isStaged) }
    var unstagedChanges: [GitChange] { changes.filter(\.hasUnstagedChanges) }

    var changedFileCount: Int { files.count + untrackedDirectories.count }

    func status(forRelativePath path: String, isDirectory: Bool) -> GitFileStatus? {
        if let status = isDirectory ? directories[path] : files[path] { return status }
        let probe = isDirectory ? path + "/" : path
        return untrackedDirectories.contains { probe.hasPrefix($0) } ? .untracked : nil
    }

    /// Parses `git status --porcelain=v2 -z --branch` output. Porcelain paths are relative to the
    /// repository root; `prefix` (from `git rev-parse --show-prefix`) is the workspace folder's
    /// path inside the repository, so entries outside it are dropped.
    static func parse(_ output: Data, prefix: String) -> GitStatus {
        var status = GitStatus()
        let records = output.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        func add(_ path: String, _ fileStatus: GitFileStatus, xy: String, original: String? = nil, submodule: Bool = false) {
            guard path.hasPrefix(prefix) else { return }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.isEmpty else { return }
            let codes = Array(xy)
            if codes.count == 2 {
                status.changes.append(GitChange(path: relative, index: codes[0], worktree: codes[1],
                                                originalPath: original.map { String($0.dropFirst(prefix.count)) },
                                                isSubmodule: submodule))
            }
            if relative.hasSuffix("/") {
                status.untrackedDirectories.append(relative)
            } else {
                status.files[relative] = max(status.files[relative] ?? fileStatus, fileStatus)
            }
            // Mark every ancestor folder (the directory itself, for an untracked folder).
            var components = relative.split(separator: "/").map(String.init)
            if !relative.hasSuffix("/") && !submodule { components.removeLast() } // a submodule is a folder too
            var current = ""
            for component in components {
                current = current.isEmpty ? component : current + "/" + component
                status.directories[current] = max(status.directories[current] ?? fileStatus, fileStatus)
            }
        }

        while i < records.count {
            let record = records[i]
            i += 1
            guard let kind = record.first else { continue }
            switch kind {
            case "#":
                let header = record.dropFirst(2)
                if header.hasPrefix("branch.oid ") {
                    status.hasCommits = header != "branch.oid (initial)"
                } else if header.hasPrefix("branch.head ") {
                    let name = String(header.dropFirst("branch.head ".count))
                    status.branch = name == "(detached)" ? nil : name
                } else if header.hasPrefix("branch.upstream ") {
                    status.upstream = String(header.dropFirst("branch.upstream ".count))
                } else if header.hasPrefix("branch.ab ") {
                    let parts = header.dropFirst("branch.ab ".count).split(separator: " ")
                    status.ahead = parts.first.flatMap { Int($0.dropFirst()) } ?? 0
                    status.behind = parts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
                }
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if fields.count == 9, let fileStatus = GitFileStatus(xy: String(fields[1])) {
                    add(String(fields[8]), fileStatus, xy: String(fields[1]), submodule: fields[2].hasPrefix("S"))
                }
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = i < records.count ? records[i] : nil
                if fields.count == 10 {
                    add(String(fields[9]), GitFileStatus(xy: String(fields[1])) ?? .renamed, xy: String(fields[1]),
                        original: original, submodule: fields[2].hasPrefix("S"))
                }
                i += 1 // with -z the original path follows as its own record
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if fields.count == 11 { add(String(fields[10]), .conflicted, xy: String(fields[1])) }
            case "?":
                add(String(record.dropFirst(2)), .untracked, xy: "??")
            default:
                break
            }
        }
        return status
    }
}

/// Runs git off the main thread. `--no-optional-locks` keeps `status` from rewriting
/// .git/index, which would otherwise trigger the file watcher and refresh in a loop.
enum Git {
    struct Repository: Sendable {
        /// The workspace folder (git runs here).
        let root: URL
        /// Workspace folder's path inside the repository ("" at the top level, else "sub/dir/").
        let prefix: String
        /// The .git directory (elsewhere for worktrees and submodules).
        var gitDirectory: URL?
    }

    static func repository(at folder: URL) -> Repository? {
        // `--show-prefix` prints an empty line at the top level, so keep empty lines.
        guard let output = run(["rev-parse", "--show-prefix", "--absolute-git-dir"], in: folder) else { return nil }
        let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let prefix = lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let gitDirectory = lines.count > 1 && !lines[1].isEmpty ? URL(filePath: String(lines[1])) : nil
        return Repository(root: folder, prefix: prefix, gitDirectory: gitDirectory)
    }

    static func status(of repository: Repository) -> GitStatus? {
        guard let output = run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"],
                               in: repository.root) else { return nil }
        var status = GitStatus.parse(output, prefix: repository.prefix)
        status.operation = operation(in: repository)
        return status
    }

    /// A merge or rebase in progress, from the files git keeps while it waits.
    static func operation(in repository: Repository) -> GitOperation? {
        guard let directory = repository.gitDirectory else { return nil }
        let exists = { (name: String) in FileManager.default.fileExists(atPath: directory.appending(path: name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    // MARK: Branches

    /// Local and remote branches (not remotes' HEAD aliases), local first, most recent first.
    static func branches(in repository: Repository) -> [GitBranch]? {
        guard let output = run(["for-each-ref", "--sort=-committerdate",
                                "--format=%(refname)%1f%(refname:short)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)%1f%(committerdate:unix)%1f%(subject)",
                                "refs/heads", "refs/remotes"], in: repository.root) else { return nil }
        return GitBranch.parse(output)
    }

    static func switchBranch(_ name: String, in repository: Repository) throws {
        try check(["switch", name], in: repository.root)
    }

    /// Switches to a local branch tracking `remote` ("origin/feature" → "feature").
    static func switchToRemote(_ remote: String, as local: String, in repository: Repository) throws {
        try check(["switch", "-c", local, "--track", remote], in: repository.root)
    }

    static func deleteBranch(_ name: String, force: Bool, in repository: Repository) throws {
        try check(["branch", force ? "-D" : "-d", name], in: repository.root)
    }

    static func renameBranch(_ name: String, to newName: String, in repository: Repository) throws {
        try check(["branch", "-m", name, newName], in: repository.root)
    }

    static func merge(_ branch: String, in repository: Repository) throws {
        try check(["merge", "--no-edit", branch], in: repository.root)
    }

    static func rebase(onto branch: String, in repository: Repository) throws {
        try check(["rebase", branch], in: repository.root)
    }

    /// `--continue`, `--skip` or `--abort` for the merge or rebase in progress.
    static func resolve(_ operation: GitOperation, _ action: GitOperation.Action, in repository: Repository) throws {
        try check([operation.rawValue, "--\(action.rawValue)"], in: repository.root)
    }

    static func fetch(in repository: Repository) throws {
        try check(["fetch", "--all", "--prune"], in: repository.root)
    }

    static func pull(in repository: Repository) throws {
        try check(["pull"], in: repository.root)
    }

    /// Pushes the current branch; one without an upstream gets `remote`/`branch` as its upstream.
    static func push(branch: String, settingUpstreamTo remote: String?, in repository: Repository) throws {
        if let remote {
            try check(["push", "--set-upstream", remote, branch], in: repository.root)
        } else {
            try check(["push"], in: repository.root)
        }
    }

    // MARK: Tags

    /// A tag at `commit`: annotated when there's a message, lightweight otherwise.
    static func createTag(_ name: String, message: String?, at commit: String, in repository: Repository) throws {
        if let message, !message.isEmpty {
            try check(["tag", "--annotate", "--message", message, name, commit], in: repository.root)
        } else {
            try check(["tag", name, commit], in: repository.root)
        }
    }

    static func deleteTag(_ name: String, in repository: Repository) throws {
        try check(["tag", "--delete", name], in: repository.root)
    }

    /// Pushes one tag, or (`name` nil) every tag.
    static func pushTag(_ name: String?, to remote: String, in repository: Repository) throws {
        try check(["push", remote] + (name.map { ["refs/tags/\($0)"] } ?? ["--tags"]), in: repository.root)
    }

    static func deleteRemoteTag(_ name: String, from remote: String, in repository: Repository) throws {
        try check(["push", remote, "--delete", "refs/tags/\(name)"], in: repository.root)
    }

    /// "origin", or the only remote; nil if there are none.
    static func defaultRemote(in repository: Repository) -> String? {
        let remotes = remotes(in: repository)
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    // MARK: Cherry-pick and revert

    /// Applies a commit's changes on top of HEAD as a new commit (a merge commit's changes
    /// relative to its first parent).
    static func cherryPick(_ commit: RepoCommit, in repository: Repository) throws {
        try check(["cherry-pick"] + (commit.parents.count > 1 ? ["-m", "1"] : []) + [commit.sha], in: repository.root)
    }

    /// A new commit undoing a commit's changes (for a merge commit, relative to its first parent).
    static func revert(_ commit: RepoCommit, in repository: Repository) throws {
        try check(["revert", "--no-edit"] + (commit.parents.count > 1 ? ["-m", "1"] : []) + [commit.sha], in: repository.root)
    }

    // MARK: Interactive rebase

    /// The commits an interactive rebase from `commit` (included) to HEAD would replay, oldest
    /// first. Nil if `commit` isn't an ancestor of HEAD.
    static func rebaseCommits(from commit: RepoCommit, in repository: Repository) -> [RebaseStep]? {
        guard execute(["merge-base", "--is-ancestor", commit.sha, "HEAD"], in: repository.root).status == 0 else { return nil }
        let range = commit.parents.first.map { "\($0)..HEAD" } ?? "HEAD"
        guard let output = run(["log", "--reverse", "--format=%x1e%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s", range],
                               in: repository.root),
              let bodies = run(["log", "--format=%x1e%H%x1f%B", range], in: repository.root) else { return nil }
        // Full messages (with bodies), so rewording starts from the whole message.
        var messages: [String: String] = [:]
        for record in String(decoding: bodies, as: UTF8.self).split(separator: "\u{1e}") {
            let parts = record.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { messages[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return RepoCommit.parseLog(output).map { RebaseStep(commit: $0, message: messages[$0.sha] ?? $0.summary) }
    }

    /// Whether any of `commits` is on a remote branch already.
    static func isPushed(_ commit: String, in repository: Repository) -> Bool {
        guard let output = run(["branch", "--remotes", "--contains", commit], in: repository.root) else { return false }
        return !String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Runs `git rebase -i` with `steps` as its todo list instead of an editor. Rewording
    /// amends the picked commit's message right after it (`exec git commit --amend -F file`).
    /// Uncommitted changes are stashed for the rebase and restored after (`--autostash`).
    static func interactiveRebase(_ steps: [RebaseStep], onto base: String?, in repository: Repository) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "omc-rebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var todo = ""
        for (index, step) in steps.enumerated() {
            switch step.action {
            case .pick, .squash, .fixup, .drop:
                todo += "\(step.action.rawValue) \(step.commit.sha)\n"
            case .reword:
                let messageFile = directory.appending(path: "message-\(index)")
                try step.message.write(to: messageFile, atomically: true, encoding: .utf8)
                todo += "pick \(step.commit.sha)\n"
                todo += "exec git commit --quiet --amend --only --allow-empty -F \(shellQuoted(messageFile.path))\n"
            }
        }
        let todoFile = directory.appending(path: "todo")
        try todo.write(to: todoFile, atomically: true, encoding: .utf8)
        try check(["rebase", "--interactive", "--autostash", base ?? "--root"], in: repository.root,
                  environment: ["GIT_SEQUENCE_EDITOR": "cp \(shellQuoted(todoFile.path))"])
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Stash

    static func stashes(in repository: Repository) -> [GitStash]? {
        guard let output = run(["stash", "list", "--format=%gd%x1f%H%x1f%P%x1f%at%x1f%gs"], in: repository.root) else { return nil }
        return GitStash.parse(output)
    }

    /// Stashes changes: everything tracked, also untracked files, or only what is staged.
    static func stash(_ scope: GitStash.Scope, message: String?, in repository: Repository) throws {
        var arguments = ["stash", "push"]
        switch scope {
        case .all: break
        case .includingUntracked: arguments.append("--include-untracked")
        case .staged: arguments.append("--staged")
        }
        if let message, !message.isEmpty { arguments += ["--message", message] }
        try check(arguments, in: repository.root)
    }

    /// Applies a stash; `pop` also drops it (git keeps it if applying conflicts).
    static func applyStash(_ stash: GitStash, pop: Bool, in repository: Repository) throws {
        try check(["stash", pop ? "pop" : "apply", stash.ref], in: repository.root)
    }

    static func dropStash(_ stash: GitStash, in repository: Repository) throws {
        try check(["stash", "drop", stash.ref], in: repository.root)
    }

    /// A new branch at the stash's base commit, with the stash applied (and dropped).
    static func branch(_ name: String, fromStash stash: GitStash, in repository: Repository) throws {
        try check(["stash", "branch", name, stash.ref], in: repository.root)
    }

    /// The files a stash holds: its tracked changes, then the untracked files it took along.
    static func files(in stash: GitStash, repository: Repository) -> [StashFile]? {
        guard let tracked = changedFiles(in: stash.trackedChanges, repository: repository) else { return nil }
        var files = tracked.map { StashFile(file: $0, isUntracked: false) }
        if let untracked = stash.untrackedCommit,
           let output = run(["ls-tree", "-r", "-z", "--name-only", untracked], in: repository.root) {
            files += output.split(separator: 0).map {
                StashFile(file: CommitFile(change: .added, path: String(decoding: $0, as: UTF8.self), originalPath: nil),
                          isUntracked: true)
            }
        }
        return files
    }

    /// The remotes with their URLs, by name.
    static func remoteList(in repository: Repository) -> [GitRemote]? {
        guard let output = run(["remote", "--verbose"], in: repository.root) else { return nil }
        return GitRemote.parse(output)
    }

    static func addRemote(_ name: String, url: String, in repository: Repository) throws {
        try check(["remote", "add", "--", name, url], in: repository.root)
    }

    /// Removes the remote, its remote-tracking branches and the upstreams set to it.
    static func removeRemote(_ name: String, in repository: Repository) throws {
        try check(["remote", "remove", name], in: repository.root)
    }

    static func renameRemote(_ name: String, to newName: String, in repository: Repository) throws {
        try check(["remote", "rename", "--", name, newName], in: repository.root)
    }

    /// Sets the URL fetched from and, unless it has a push URL of its own, pushed to.
    static func setRemoteURL(_ name: String, url: String, in repository: Repository) throws {
        try check(["remote", "set-url", "--", name, url], in: repository.root)
    }

    static func fetch(remote: String, in repository: Repository) throws {
        try check(["fetch", "--prune", "--", remote], in: repository.root)
    }

    static func remotes(in repository: Repository) -> [String] {
        guard let output = run(["remote"], in: repository.root) else { return [] }
        return String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // MARK: Changing the repository

    struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func stage(_ paths: [String], in repository: Repository) throws {
        try check(["add", "--"] + paths, in: repository.root)
    }

    static func unstage(_ paths: [String], in repository: Repository) throws {
        // `restore --staged` needs a commit to restore from; in a fresh repo, drop from the index.
        if (try? check(["rev-parse", "--verify", "HEAD"], in: repository.root)) != nil {
            try check(["restore", "--staged", "--"] + paths, in: repository.root)
        } else {
            try check(["rm", "--cached", "--quiet", "--"] + paths, in: repository.root)
        }
    }

    /// Discards unstaged changes to tracked files (back to the staged version).
    static func discard(_ paths: [String], in repository: Repository) throws {
        try check(["restore", "--worktree", "--"] + paths, in: repository.root)
    }

    /// Replaces the last commit with one that also has what is staged; an empty message keeps
    /// the old one.
    static func amend(message: String, in repository: Repository) throws {
        try check(["commit", "--quiet", "--amend"] + (message.isEmpty ? ["--no-edit"] : ["-m", message]),
                  in: repository.root)
    }

    /// The last commit's full message and whether it has a parent.
    static func lastCommit(in repository: Repository) -> (message: String, hasParent: Bool)? {
        guard let output = run(["log", "-1", "--format=%P%x1f%B"], in: repository.root) else { return nil }
        let parts = String(decoding: output, as: UTF8.self).split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (parts[1].trimmingCharacters(in: .whitespacesAndNewlines), !parts[0].trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Whether HEAD is on a remote branch already (rewriting it would need a force push).
    static func isHeadPushed(in repository: Repository) -> Bool {
        guard let output = run(["branch", "--remotes", "--contains", "HEAD"], in: repository.root) else { return false }
        return !String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Takes back the last commit: its changes stay staged. The first commit of a repository
    /// has no parent to go back to, so the branch is unborn again (everything stays staged).
    static func undoLastCommit(hasParent: Bool, in repository: Repository) throws {
        if hasParent {
            try check(["reset", "--soft", "HEAD~1"], in: repository.root)
        } else {
            try check(["update-ref", "-d", "HEAD"], in: repository.root)
        }
    }

    static func commit(message: String, in repository: Repository) throws {
        try check(["commit", "--quiet", "-m", message], in: repository.root)
    }

    /// Runs git and throws its stderr on failure.
    @discardableResult
    private static func check(_ arguments: [String], in directory: URL, input: Data? = nil,
                              environment overrides: [String: String] = [:]) throws -> Data {
        let result = execute(arguments, in: directory, input: input, environment: overrides)
        guard result.status == 0 else {
            // Most commands explain failures on stderr; merge reports conflicts on stdout.
            let text = { (data: Data) in String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            let message = [text(result.output), text(result.error)].filter { !$0.isEmpty }.joined(separator: "\n")
            throw CommandError(message: message.isEmpty ? "git \(arguments.first ?? "") failed" : message)
        }
        return result.output
    }

    /// The file's content as staged in the index, or nil if it isn't tracked.
    static func indexContent(ofRelativePath path: String, in repository: Repository) -> String? {
        guard let output = run(["show", ":./" + path], in: repository.root) else { return nil }
        return String(data: output, encoding: .utf8)
    }

    /// The file's content in the last commit, or nil if HEAD doesn't have it (or there's no commit).
    static func headContent(ofRelativePath path: String, in repository: Repository) -> String? {
        guard let output = run(["show", "HEAD:./" + path], in: repository.root) else { return nil }
        return String(data: output, encoding: .utf8)
    }

    /// Replaces what is staged for one file with `content` (staging or unstaging part of a
    /// change). Fails, changing nothing, unless the index still holds `expected`: the change was
    /// computed against that text.
    static func setIndexContent(_ content: String, expected: String, relativePath path: String,
                                in repository: Repository) throws {
        let entry = String(decoding: try check(["ls-files", "-s", "--", path], in: repository.root), as: UTF8.self)
        let fields = entry.split(separator: " ", maxSplits: 2)
        // "<mode> <sha> <stage>\t<path>": one entry at stage 0 (not a conflict).
        guard entry.split(separator: "\n").count == 1, fields.count == 3, fields[2].hasPrefix("0\t") else {
            throw CommandError(message: "\(path) can't be staged in parts (it isn't in the index, or has a conflict).")
        }
        guard indexContent(ofRelativePath: path, in: repository) == expected else {
            throw CommandError(message: "The staged version of \(path) changed. Try again.")
        }
        let object = String(decoding: try check(["hash-object", "-w", "--stdin", "--no-filters"], in: repository.root,
                                                input: Data(content.utf8)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // --cacheinfo paths are relative to the repository root, not the working directory.
        try check(["update-index", "--cacheinfo", "\(fields[0]),\(object),\(repository.prefix + path)"], in: repository.root)
    }

    /// The commits that changed a file, newest first, following renames. Nil if git failed
    /// (not a repository); empty if the file has no history.
    static func history(ofRelativePath path: String, in repository: Repository, limit: Int = 300) -> [GitCommit]? {
        guard let output = run(["log", "--follow", "-M", "-n", String(limit), "--name-status",
                                "--format=%x1e%H%x1f%P%x1f%an%x1f%at%x1f%s", "--", path], in: repository.root) else { return nil }
        return GitCommit.parseLog(output, currentPath: repository.prefix + path)
    }

    /// The repository's commits, newest first, from `skip` on: every branch's, tag's and remote
    /// branch's (and a detached HEAD's), not just this folder's. `--date-order` keeps children
    /// before their parents when dates tie across branches. Nil if git failed.
    static func log(in repository: Repository, limit: Int = 200, skip: Int = 0, filter: LogFilter? = nil) -> [RepoCommit]? {
        guard let output = run(["log", "--branches", "--tags", "--remotes", "HEAD", "--date-order", "-n", String(limit), "--skip", String(skip),
                                "--format=%x1e%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s"] + (filter?.arguments ?? []),
                               in: repository.root) else { return nil }
        return RepoCommit.parseLog(output)
    }

    /// The commit a name (hash prefix, branch, tag) resolves to, if any.
    static func commit(named name: String, in repository: Repository) -> RepoCommit? {
        guard let output = run(["log", "-1", "--format=%x1e%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s", name + "^{commit}", "--"],
                               in: repository.root) else { return nil }
        return RepoCommit.parseLog(output).first
    }

    // MARK: Submodules

    /// The repository's submodules (none without a .gitmodules file); nil if git failed.
    static func submodules(in repository: Repository) -> [GitSubmodule]? {
        let top = repository.top
        guard FileManager.default.fileExists(atPath: top.appending(path: ".gitmodules").path) else { return [] }
        guard let status = run(["submodule", "status"], in: top) else { return nil }
        let config = run(["config", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.(path|url)$"], in: top) ?? Data()
        return GitSubmodule.parse(status: status, config: config)
    }

    /// Checks out the commits the repository records for the submodules (all when `paths` is
    /// empty), cloning ones not initialized yet, and theirs in turn.
    static func updateSubmodules(_ paths: [String], in repository: Repository) throws {
        try check(["submodule", "update", "--init", "--recursive", "--"] + paths, in: repository.top)
    }

    // MARK: Worktrees

    static func worktrees(in repository: Repository) -> [GitWorktree]? {
        guard let output = run(["worktree", "list", "--porcelain"], in: repository.root) else { return nil }
        return GitWorktree.parse(output)
    }

    /// A worktree at `path` on `branch` (a local branch); with `newBranch`, a new branch made
    /// from `branch` (any commit-ish, or HEAD when nil), tracking it if it's a remote branch.
    static func addWorktree(at path: String, branch: String?, newBranch: String?, track: Bool, in repository: Repository) throws {
        var arguments = ["worktree", "add"]
        if let newBranch { arguments += (track ? ["--track"] : []) + ["-b", newBranch] }
        arguments.append(path)
        if let branch { arguments.append(branch) }
        try check(arguments, in: repository.root)
    }

    /// Removes a worktree and its folder; `force` also throws away its uncommitted changes.
    static func removeWorktree(at path: String, force: Bool, in repository: Repository) throws {
        try check(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: repository.root)
    }

    // MARK: Comparing

    /// The commit a name (branch, tag, hash) resolves to.
    static func resolveCommit(_ name: String, in repository: Repository) -> String? {
        guard let output = run(["rev-parse", "--verify", "--quiet", "--end-of-options", name + "^{commit}"], in: repository.root)
        else { return nil }
        let sha = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.count == 40 ? sha : nil
    }

    /// The best common ancestor of two commits (nil: unrelated histories).
    static func mergeBase(_ a: String, _ b: String, in repository: Repository) -> String? {
        guard let output = run(["merge-base", a, b], in: repository.root) else { return nil }
        let sha = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.count == 40 ? sha : nil
    }

    /// The files that differ between two commits (renames detected).
    static func changedFiles(from base: String, to target: String, in repository: Repository) -> [CommitFile]? {
        guard let output = run(["diff", "-M", "--name-status", "-z", base, target, "--"], in: repository.root) else { return nil }
        return CommitFile.parse(output)
    }

    /// Commits only `base` has (behind) and only `target` has (ahead).
    static func aheadBehind(base: String, target: String, in repository: Repository) -> (ahead: Int, behind: Int)? {
        guard let output = run(["rev-list", "--left-right", "--count", "\(base)...\(target)"], in: repository.root) else { return nil }
        let numbers = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return numbers.count == 2 ? (numbers[1], numbers[0]) : nil
    }

    /// The files a commit changed against its first parent (everything, for a root commit).
    static func changedFiles(in commit: RepoCommit, repository: Repository) -> [CommitFile]? {
        let arguments = ["diff-tree", "-r", "-M", "--no-commit-id", "--name-status", "-z"]
            + (commit.parents.first.map { [$0, commit.sha] } ?? ["--root", commit.sha])
        guard let output = run(arguments, in: repository.root) else { return nil }
        return CommitFile.parse(output)
    }

    /// Switches to a new branch starting at `commit`.
    static func createBranch(_ name: String, at commit: String, in repository: Repository) throws {
        try check(["switch", "-c", name, commit], in: repository.root)
    }

    /// Checks out `commit` without a branch (detached HEAD).
    static func checkoutDetached(_ commit: String, in repository: Repository) throws {
        try check(["switch", "--detach", commit], in: repository.root)
    }

    /// A file's content at a commit, by its path from the repository root; nil if it isn't there.
    static func content(atCommit commit: String, repositoryPath path: String, in repository: Repository) -> String? {
        guard let output = run(["show", "\(commit):\(path)"], in: repository.root) else { return nil }
        return String(data: output, encoding: .utf8)
    }

    /// Who last changed each line of `contents` (the buffer as it is, so unsaved lines show as
    /// not committed and line numbers match the editor). Nil if the file isn't tracked.
    static func blame(relativePath path: String, contents: String, in repository: Repository) -> [BlameLine?]? {
        guard let output = run(["blame", "--porcelain", "--contents", "-", "--", path], in: repository.root,
                               input: Data(contents.utf8)) else { return nil }
        return BlameLine.parse(output)
    }

    /// A commit's author, email, date and whole message (for the blame popover).
    static func commitDetails(_ sha: String, in repository: Repository) -> CommitDetails? {
        guard let output = run(["show", "-s", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%B", sha + "^{commit}", "--"],
                               in: repository.root) else { return nil }
        return CommitDetails.parse(output)
    }

    static func run(_ arguments: [String], in directory: URL, input: Data? = nil) -> Data? {
        let result = execute(arguments, in: directory, input: input)
        return result.status == 0 ? result.output : nil
    }

    private static func execute(_ arguments: [String], in directory: URL, input: Data? = nil,
                                environment overrides: [String: String] = [:])
        -> (status: Int32, output: Data, error: Data) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.quotepath=off", "-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        // Nothing can answer a prompt here: fail instead of waiting forever for a password,
        // a host key or an editor (merge and rebase messages keep git's defaults).
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_SEQUENCE_EDITOR"] = "true"
        if environment["GIT_SSH_COMMAND"] == nil { environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        environment.merge(overrides) { _, override in override }
        process.environment = environment
        let output = Pipe(), errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        // Input is written concurrently: git may fill the output pipe before it has read it all.
        // On a thread of its own, not a dispatch queue: with as many commands waiting as there
        // are cores (a blame per open file) no dispatch thread is left to write, git waits for
        // its input forever, and every thread waiting for a git with it.
        if let inputPipe, let input {
            Thread.detachNewThread {
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        // Both pipes read here, on this thread (no dispatch thread to run out of).
        guard let result = try? ProcessIO.run(process, output: output, error: errorOutput) else {
            return (-1, Data(), Data("could not run git".utf8))
        }
        return (result.status, result.output, result.error)
    }
}


extension Git.Repository {
    /// The repository's top folder (the workspace folder may be inside it).
    var top: URL {
        (0..<prefix.split(separator: "/").count).reduce(root) { url, _ in url.deletingLastPathComponent() }
    }
}

/// A repository inside the repository, at a commit the outer one records.
struct GitSubmodule: Sendable, Hashable, Identifiable {
    enum State: Sendable, Hashable {
        case upToDate
        /// Not cloned yet (`git submodule update --init` does).
        case notInitialized
        /// Checked out at another commit than the one recorded.
        case otherCommit
        case conflicted
    }

    /// Its path from the repository's top folder.
    let path: String
    let url: String?
    /// The commit checked out (or recorded, when not initialized).
    let sha: String
    let state: State
    /// `git describe` of the commit, when there is one ("v1.2-3-gabc").
    let describe: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var shortSHA: String { String(sha.prefix(7)) }

    var stateDescription: String {
        switch state {
        case .upToDate: "At the recorded commit"
        case .notInitialized: "Not initialized"
        case .otherCommit: "At another commit than recorded"
        case .conflicted: "Merge conflict"
        }
    }

    /// Parses `git submodule status` (" <sha> path (describe)", "-" not initialized, "+" at
    /// another commit, "U" conflicted) with the URLs from
    /// `git config --file .gitmodules --get-regexp '^submodule\..*\.(path|url)$'`.
    static func parse(status: Data, config: Data) -> [GitSubmodule] {
        var paths: [String: String] = [:], urls: [String: String] = [:] // by submodule name
        for line in String(decoding: config, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].hasPrefix("submodule.") else { continue }
            let key = parts[0].dropFirst("submodule.".count)
            if key.hasSuffix(".path") { paths[String(key.dropLast(5))] = String(parts[1]) }
            if key.hasSuffix(".url") { urls[String(key.dropLast(4))] = String(parts[1]) }
        }
        let urlByPath = Dictionary(paths.compactMap { name, path in urls[name].map { (path, $0) } }) { first, _ in first }
        return String(decoding: status, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let flag = line.first else { return nil }
            let fields = line.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            let sha = String(fields[0])
            guard sha.count >= 40, sha.allSatisfy(\.isHexDigit) else { return nil }
            var path = String(fields[1])
            var describe: String?
            if path.hasSuffix(")"), let open = path.range(of: " (", options: .backwards) {
                describe = String(path[open.upperBound..<path.index(before: path.endIndex)])
                path = String(path[..<open.lowerBound])
            }
            let state: State = switch flag {
            case "-": .notInitialized
            case "+": .otherCommit
            case "U": .conflicted
            default: .upToDate
            }
            return GitSubmodule(path: path, url: urlByPath[path], sha: sha, state: state, describe: describe)
        }
    }
}

/// A working tree of the repository (`git worktree list`): the main one and any added.
struct GitWorktree: Sendable, Hashable, Identifiable {
    let path: String
    let head: String?
    /// The branch checked out ("main"); nil when detached or bare.
    let branch: String?
    let isBare: Bool
    let isLocked: Bool
    /// Its folder is gone: `git worktree prune` would forget it.
    let isPrunable: Bool

    var id: String { path }
    var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
    var name: String { (path as NSString).lastPathComponent }

    /// Whether this is the worktree at `url` (symlinks resolved: /var is /private/var).
    func isAt(_ url: URL) -> Bool {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
            == url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Parses `git worktree list --porcelain`: blocks of "worktree <path>", "HEAD <sha>",
    /// "branch refs/heads/<name>" or "detached", "bare", "locked", "prunable".
    static func parse(_ data: Data) -> [GitWorktree] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n").compactMap { block in
            var path: String?, head: String?, branch: String?
            var bare = false, locked = false, prunable = false
            for line in block.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1)
                let value = parts.count > 1 ? String(parts[1]) : ""
                switch parts.first {
                case "worktree": path = value
                case "HEAD": head = value
                case "branch": branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst(11)) : value
                case "bare": bare = true
                case "locked": locked = true
                case "prunable": prunable = true
                default: break
                }
            }
            return path.map { GitWorktree(path: $0, head: head, branch: branch, isBare: bare, isLocked: locked, isPrunable: prunable) }
        }
    }
}

/// Two commits (or branches, tags) compared: the files that differ and how far apart they are.
struct RefComparison: Sendable, Equatable {
    /// What the user picked (branch, tag or hash), as shown.
    let base: String
    let target: String
    /// Compared from the common ancestor (what `target` changed since it left `base`, as a pull
    /// request shows) rather than from `base` itself.
    let sinceCommonAncestor: Bool
    /// The commits diffed: the common ancestor (or `base`) and `target`.
    let baseSHA: String
    let targetSHA: String
    let files: [CommitFile]
    let ahead: Int
    let behind: Int

    /// A commit that turns `baseSHA` into `targetSHA`, to open one file's diff like a commit's.
    var asCommit: RepoCommit {
        RepoCommit(sha: targetSHA, parents: [baseSHA], author: "", date: Date(timeIntervalSince1970: 0),
                   summary: "\(base) \(sinceCommonAncestor ? "..." : "..") \(target)", refs: [])
    }
}

/// A remote and where it fetches from and pushes to.
struct GitRemote: Sendable, Hashable, Identifiable {
    let name: String
    let fetchURL: String
    let pushURL: String

    var id: String { name }

    /// The URL without a password (`https://user:token@host` shows as `https://user:•••@host`).
    static func display(_ url: String) -> String {
        guard var components = URLComponents(string: url), components.password != nil, components.host != nil else { return url }
        components.password = "•••"
        return components.string?.replacingOccurrences(of: "%E2%80%A2%E2%80%A2%E2%80%A2", with: "•••") ?? url
    }

    var displayURL: String { Self.display(fetchURL) }

    /// Parses `git remote --verbose`: "origin\turl (fetch)" and "origin\turl (push)" lines.
    static func parse(_ data: Data) -> [GitRemote] {
        var fetch: [String: String] = [:], push: [String: String] = [:], order: [String] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            var rest = String(parts[1])
            let isPush = rest.hasSuffix(" (push)")
            if isPush || rest.hasSuffix(" (fetch)") { rest = String(rest.dropLast(isPush ? 7 : 8)) }
            if !order.contains(name) { order.append(name) }
            if isPush { push[name] = rest } else { fetch[name] = rest }
        }
        return order.map { GitRemote(name: $0, fetchURL: fetch[$0] ?? push[$0] ?? "", pushURL: push[$0] ?? fetch[$0] ?? "") }
    }
}

/// A commit as the blame popover shows it.
struct CommitDetails: Sendable, Equatable {
    let sha: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    /// The whole message: subject, blank line, body.
    let message: String

    var shortSHA: String { String(sha.prefix(7)) }

    /// Parses `git show -s --format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%B`.
    static func parse(_ data: Data) -> CommitDetails? {
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\u{1f}", maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count == 6, fields[0].count == 40 else { return nil }
        return CommitDetails(sha: String(fields[0]), parents: fields[1].split(separator: " ").map(String.init),
                             author: String(fields[2]), email: String(fields[3]),
                             date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                             message: fields[5].trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// One line's last change, from `git blame --porcelain`.
struct BlameLine: Sendable, Equatable {
    let commit: String
    let author: String
    let date: Date
    let summary: String
    /// The file's path (from the repository root) in that commit: it may have been renamed since.
    var path: String? = nil

    /// Lines changed in the buffer (or in the working tree) and not committed yet.
    var isUncommitted: Bool { commit.allSatisfy { $0 == "0" } }

    /// A line edited since the file was blamed.
    static func uncommitted(at date: Date = Date()) -> BlameLine {
        BlameLine(commit: String(repeating: "0", count: 40), author: "Not Committed Yet", date: date, summary: "")
    }

    /// Blame kept in step with an edit: `old` lines became `count` uncommitted ones.
    static func shifted(_ blame: [BlameLine?], replacing old: Range<Int>, with count: Int) -> [BlameLine?] {
        guard old.lowerBound <= blame.count else { return blame }
        let edited = [BlameLine?](repeating: uncommitted(), count: count)
        return Array(blame[..<old.lowerBound]) + edited + Array(blame[min(blame.count, old.upperBound)...])
    }

    /// One entry per line of the blamed text (nil where git said nothing).
    static func parse(_ data: Data) -> [BlameLine?] {
        struct Info { var author = "", time: TimeInterval = 0, summary = "", path: String? }
        var infos: [String: Info] = [:]
        var result: [BlameLine?] = []
        var current: (commit: String, line: Int)?
        for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.hasPrefix("\t") {
                // The line's content ends its entry.
                guard let (commit, line) = current else { continue }
                let info = infos[commit] ?? Info()
                while result.count < line { result.append(nil) }
                result[line - 1] = BlameLine(commit: commit, author: info.author,
                                             date: Date(timeIntervalSince1970: info.time), summary: info.summary,
                                             path: info.path)
                current = nil
                continue
            }
            let parts = rawLine.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            if key.count == 40, key.allSatisfy(\.isHexDigit) {
                // "<commit> <original line> <final line> [<lines in group>]"
                let numbers = value.split(separator: " ")
                if numbers.count >= 2, let final = Int(numbers[1]) {
                    current = (String(key), final)
                    if infos[String(key)] == nil { infos[String(key)] = Info(path: nil) }
                }
            } else if let commit = current?.commit {
                switch key {
                case "author": infos[commit]?.author = value
                case "author-time": infos[commit]?.time = TimeInterval(value) ?? 0
                case "summary": infos[commit]?.summary = value
                case "filename": infos[commit]?.path = value
                default: break
                }
            }
        }
        return result
    }
}

/// One commit in a file's history, with the file's path in it and in its parent (paths from
/// the repository root, as they were then: renames change them).
struct GitCommit: Sendable, Hashable, Identifiable {
    enum Change: Sendable, Hashable { case added, modified, deleted, renamed }

    let sha: String
    let parents: [String]
    let author: String
    let date: Date
    let summary: String
    let change: Change
    /// The file in this commit (nil: deleted here).
    let path: String?
    /// The file in the first parent (nil: added here, or a root commit).
    let parentPath: String?

    var id: String { sha }
    var shortSHA: String { String(sha.prefix(7)) }
    var fileName: String { ((path ?? parentPath ?? "") as NSString).lastPathComponent }

    /// Parses `git log --name-status --format=%x1e%H%x1f%P%x1f%an%x1f%at%x1f%s`, newest
    /// first. `currentPath` is the file's path now, for commits git lists without a status
    /// line (merges): they keep the path the newer commit came from.
    static func parseLog(_ data: Data, currentPath: String) -> [GitCommit] {
        var commits: [GitCommit] = []
        var path = currentPath
        for record in String(decoding: data, as: UTF8.self).split(separator: "\u{1e}") {
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let header = lines.first else { continue }
            let fields = header.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5, fields[0].count == 40 else { continue }
            var change = Change.modified
            var newPath: String? = path, oldPath: String? = path
            if let status = lines.dropFirst().last(where: { $0.contains("\t") }) {
                let parts = status.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                switch parts[0].first {
                case "A": change = .added; newPath = parts.last; oldPath = nil
                case "D": change = .deleted; newPath = nil; oldPath = parts.last
                case "R", "C" where parts.count >= 3: change = .renamed; oldPath = parts[1]; newPath = parts[2]
                default: newPath = parts.last; oldPath = parts.last
                }
            }
            let parents = fields[1].split(separator: " ").map(String.init)
            commits.append(GitCommit(sha: String(fields[0]), parents: parents, author: String(fields[2]),
                                     date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0),
                                     summary: String(fields[4]), change: change,
                                     path: newPath, parentPath: parents.isEmpty ? nil : oldPath))
            // Older commits know the file by the name it had before this one.
            if let oldPath { path = oldPath }
        }
        return commits
    }
}

/// The Timeline panel's content: a file and the commits that changed it.
struct FileHistory: Equatable {
    let url: URL
    /// Nil when the file isn't in a repository (or while the first read runs).
    let commits: [GitCommit]?
    let isLoading: Bool
}

/// A commit in the repository log, with the branches and tags pointing at it.
struct RepoCommit: Sendable, Hashable, Identifiable {
    let sha: String
    let parents: [String]
    let author: String
    let date: Date
    let summary: String
    /// "HEAD -> main", "origin/main", "tag: v1", … as `git log --format=%D` names them.
    let refs: [String]

    var id: String { sha }
    var shortSHA: String { String(sha.prefix(7)) }
    /// Tags pointing at this commit ("tag: v1" refs).
    var tags: [String] { refs.filter { $0.hasPrefix("tag: ") }.map { String($0.dropFirst(5)) } }

    /// Parses `git log --format=%x1e%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s`.
    static func parseLog(_ data: Data) -> [RepoCommit] {
        String(decoding: data, as: UTF8.self).split(separator: "\u{1e}").compactMap { record in
            let line = record.split(separator: "\n", maxSplits: 1).first ?? ""
            let fields = line.split(separator: "\u{1f}", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6, fields[0].count == 40 else { return nil }
            return RepoCommit(sha: String(fields[0]), parents: fields[1].split(separator: " ").map(String.init),
                              author: String(fields[2]), date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0),
                              summary: String(fields[5]),
                              refs: fields[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                                  .filter { !$0.isEmpty })
        }
    }

    /// This commit's change to one file, as the file history shows it (to open its diff).
    func change(to file: CommitFile) -> GitCommit {
        GitCommit(sha: sha, parents: parents, author: author, date: date, summary: summary, change: file.change,
                  path: file.change == .deleted ? nil : file.path,
                  parentPath: parents.isEmpty || file.change == .added ? nil : file.originalPath ?? file.path)
    }
}

/// One file a commit changed (paths from the repository root).
struct CommitFile: Sendable, Hashable, Identifiable {
    let change: GitCommit.Change
    let path: String
    /// The path before a rename or copy.
    let originalPath: String?

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    /// Parses `git diff-tree --name-status -z`: "M\0path\0", "R100\0old\0new\0".
    static func parse(_ data: Data) -> [CommitFile] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var files: [CommitFile] = []
        var i = 0
        while i < fields.count, let code = fields[i].first {
            if code == "R" || code == "C" {
                guard i + 2 < fields.count else { break }
                files.append(CommitFile(change: code == "R" ? .renamed : .added, path: fields[i + 2],
                                        originalPath: code == "R" ? fields[i + 1] : nil))
                i += 3
            } else {
                guard i + 1 < fields.count else { break }
                let change: GitCommit.Change = switch code {
                case "A": .added
                case "D": .deleted
                default: .modified
                }
                files.append(CommitFile(change: change, path: fields[i + 1], originalPath: nil))
                i += 2
            }
        }
        return files
    }
}

/// The repository log in the Timeline panel.
struct RepoHistory: Equatable {
    let commits: [RepoCommit]
    let isLoading: Bool
    /// The last page was full: there may be older commits.
    let hasMore: Bool
    /// The commit graph, one row per commit.
    var graph: [CommitGraphRow] = []
    /// A commit found by its hash, listed first, that isn't part of the log's pages.
    var pinned: RepoCommit? = nil
    /// The most lanes any row uses (the graph column's width).
    var graphWidth: Int { graph.map(\.width).max() ?? 1 }
}

/// A merge or rebase that stopped and waits (for conflicts to be resolved).
enum GitOperation: String, Sendable, Equatable {
    /// Raw values are the git commands.
    case merge, rebase
    case cherryPick = "cherry-pick"
    case revert

    var title: String {
        switch self {
        case .merge: "Merging"
        case .rebase: "Rebasing"
        case .cherryPick: "Cherry-Picking"
        case .revert: "Reverting"
        }
    }

    /// Merges finish with a commit; the others continue (committing what's staged).
    var finishesWithCommit: Bool { self == .merge }

    enum Action: String, Sendable { case `continue`, skip, abort }
}

/// A local or remote branch.
struct GitBranch: Sendable, Hashable, Identifiable {
    /// "refs/heads/main", "refs/remotes/origin/main".
    let ref: String
    /// "main", "origin/main".
    let name: String
    let upstream: String?
    /// "ahead 1, behind 2", "gone", or "" when in sync.
    let tracking: String
    let isCurrent: Bool
    let date: Date
    let subject: String

    var id: String { ref }
    var isRemote: Bool { ref.hasPrefix("refs/remotes/") }
    /// For a remote branch, the local name it would get ("origin/feature/x" → "feature/x").
    var localName: String {
        guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }

    /// Parses `git for-each-ref --format=%(refname)%1f%(refname:short)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)%1f%(committerdate:unix)%1f%(subject)`.
    static func parse(_ data: Data) -> [GitBranch] {
        let branches = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> GitBranch? in
            let fields = line.split(separator: "\u{1f}", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, !fields[0].hasSuffix("/HEAD") else { return nil } // origin/HEAD is an alias
            return GitBranch(ref: fields[0], name: fields[1], upstream: fields[2].isEmpty ? nil : fields[2],
                             tracking: fields[3], isCurrent: fields[4] == "*",
                             date: Date(timeIntervalSince1970: TimeInterval(fields[5]) ?? 0), subject: fields[6])
        }
        return branches.filter { !$0.isRemote } + branches.filter(\.isRemote)
    }
}

/// A stash entry: `stash@{n}`, a commit whose parents are the base commit, the stashed index
/// and (with untracked files) a commit holding those.
struct GitStash: Sendable, Hashable, Identifiable {
    enum Scope: Sendable { case all, includingUntracked, staged }

    let ref: String
    let sha: String
    let parents: [String]
    let date: Date
    /// "On main: message" or "WIP on main: abc1234 last commit".
    let subject: String

    var id: String { sha }
    /// The branch it was made on.
    var branch: String? {
        let head = subject.hasPrefix("WIP on ") ? subject.dropFirst(7) : subject.hasPrefix("On ") ? subject.dropFirst(3) : nil
        return head.flatMap { $0.split(separator: ":", maxSplits: 1).first.map(String.init) }
    }
    /// The message, or for an unnamed stash the commit it was made on.
    var message: String {
        guard let colon = subject.firstIndex(of: ":") else { return subject }
        return subject[subject.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    var hasUntrackedFiles: Bool { parents.count > 2 }
    var untrackedCommit: String? { hasUntrackedFiles ? parents[2] : nil }

    /// The tracked changes as a commit on its base (diffing against the first parent).
    var trackedChanges: RepoCommit {
        RepoCommit(sha: sha, parents: Array(parents.prefix(1)), author: "", date: date, summary: message, refs: [ref])
    }

    /// Parses `git stash list --format=%gd%x1f%H%x1f%P%x1f%at%x1f%gs`.
    static func parse(_ data: Data) -> [GitStash] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, fields[1].count == 40 else { return nil }
            return GitStash(ref: fields[0], sha: fields[1], parents: fields[2].split(separator: " ").map(String.init),
                            date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0), subject: fields[4])
        }
    }

    /// A file of the stash as a commit change, to open its diff: tracked files against the base,
    /// untracked ones as new files.
    func change(to file: StashFile) -> GitCommit {
        if file.isUntracked, let untrackedCommit {
            return RepoCommit(sha: untrackedCommit, parents: [], author: "", date: date, summary: message, refs: [])
                .change(to: file.file)
        }
        return trackedChanges.change(to: file.file)
    }
}

struct StashFile: Sendable, Hashable, Identifiable {
    let file: CommitFile
    let isUntracked: Bool
    var id: String { (isUntracked ? "u:" : "t:") + file.path }
}

/// One line of an interactive rebase's todo list.
struct RebaseStep: Sendable, Hashable, Identifiable {
    enum Action: String, Sendable, CaseIterable {
        case pick, reword, squash, fixup, drop

        var help: String {
            switch self {
            case .pick: "Keep the commit"
            case .reword: "Keep the commit, with a new message"
            case .squash: "Meld into the commit above, keeping both messages"
            case .fixup: "Meld into the commit above, dropping this message"
            case .drop: "Remove the commit"
            }
        }
    }

    var action: Action
    let commit: RepoCommit
    /// The new message, for `reword`.
    var message: String

    var id: String { commit.sha }

    init(commit: RepoCommit, action: Action = .pick, message: String? = nil) {
        self.commit = commit
        self.action = action
        self.message = message ?? commit.summary
    }

    /// Why `steps` can't run as they are, or nil if they can.
    static func problem(with steps: [RebaseStep]) -> String? {
        let kept = steps.filter { $0.action != .drop }
        if kept.isEmpty { return "Every commit would be dropped." }
        if kept.first.map({ $0.action == .squash || $0.action == .fixup }) == true {
            return "The first commit can't be squashed or fixed up: there's nothing above it to meld into."
        }
        if steps.contains(where: { $0.action == .reword && $0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "A reworded commit needs a message."
        }
        if steps.contains(where: { $0.commit.parents.count > 1 }) {
            return "The range has merge commits; rebasing would flatten them."
        }
        return nil
    }
}

/// An interactive rebase being edited: the commits from `base` to HEAD, as steps.
struct RebasePlan: Identifiable {
    let id = UUID()
    let base: RepoCommit
    /// As git would list them (oldest first, all picked).
    let original: [RebaseStep]
    var steps: [RebaseStep]

    init(base: RepoCommit, steps: [RebaseStep]) {
        self.base = base
        original = steps
        self.steps = steps
    }

    /// Whether running it would change anything.
    var changesSomething: Bool {
        if steps.map(\.commit.sha) != original.map(\.commit.sha) { return true }
        let originalMessages = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.message) })
        return steps.contains { step in
            switch step.action {
            case .pick: false
            case .reword: step.message != originalMessages[step.id]   // the same message changes nothing
            case .squash, .fixup, .drop: true
            }
        }
    }
}

/// What the repository log is narrowed to.
struct LogFilter: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case message = "Message", author = "Author", code = "Code"

        var help: String {
            switch self {
            case .message: "Commits whose message contains the text"
            case .author: "Commits by an author whose name or email contains the text"
            case .code: "Commits that added or removed the text"
            }
        }
    }

    var kind: Kind
    var text: String

    /// `git log` options; the text is matched as is (not a pattern), ignoring case where git can.
    var arguments: [String] {
        switch kind {
        case .message: ["--fixed-strings", "--regexp-ignore-case", "--grep=\(text)"]
        case .author: ["--fixed-strings", "--regexp-ignore-case", "--author=\(text)"]
        case .code: ["-S\(text)"]
        }
    }

    /// The text, if it could be (the start of) a commit hash.
    var hashPrefix: String? {
        (4...40).contains(text.count) && text.allSatisfy(\.isHexDigit) ? text.lowercased() : nil
    }
}
