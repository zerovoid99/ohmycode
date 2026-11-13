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
    var ahead = 0
    var behind = 0
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
        func add(_ path: String, _ fileStatus: GitFileStatus, xy: String, original: String? = nil) {
            guard path.hasPrefix(prefix) else { return }
            let relative = String(path.dropFirst(prefix.count))
            guard !relative.isEmpty else { return }
            let codes = Array(xy)
            if codes.count == 2 {
                status.changes.append(GitChange(path: relative, index: codes[0], worktree: codes[1],
                                                originalPath: original.map { String($0.dropFirst(prefix.count)) }))
            }
            if relative.hasSuffix("/") {
                status.untrackedDirectories.append(relative)
            } else {
                status.files[relative] = max(status.files[relative] ?? fileStatus, fileStatus)
            }
            // Mark every ancestor folder (the directory itself, for an untracked folder).
            var components = relative.split(separator: "/").map(String.init)
            if !relative.hasSuffix("/") { components.removeLast() }
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
                if header.hasPrefix("branch.head ") {
                    let name = String(header.dropFirst("branch.head ".count))
                    status.branch = name == "(detached)" ? nil : name
                } else if header.hasPrefix("branch.ab ") {
                    let parts = header.dropFirst("branch.ab ".count).split(separator: " ")
                    status.ahead = parts.first.flatMap { Int($0.dropFirst()) } ?? 0
                    status.behind = parts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
                }
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if fields.count == 9, let fileStatus = GitFileStatus(xy: String(fields[1])) {
                    add(String(fields[8]), fileStatus, xy: String(fields[1]))
                }
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = i < records.count ? records[i] : nil
                if fields.count == 10 {
                    add(String(fields[9]), GitFileStatus(xy: String(fields[1])) ?? .renamed, xy: String(fields[1]),
                        original: original)
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
        let root: URL
        /// Workspace folder's path inside the repository ("" at the top level, else "sub/dir/").
        let prefix: String
    }

    static func repository(at folder: URL) -> Repository? {
        guard let output = run(["rev-parse", "--show-prefix"], in: folder) else { return nil }
        let prefix = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Repository(root: folder, prefix: prefix)
    }

    static func status(of repository: Repository) -> GitStatus? {
        guard let output = run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"],
                               in: repository.root) else { return nil }
        return GitStatus.parse(output, prefix: repository.prefix)
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

    static func commit(message: String, in repository: Repository) throws {
        try check(["commit", "--quiet", "-m", message], in: repository.root)
    }

    /// Runs git and throws its stderr on failure.
    @discardableResult
    private static func check(_ arguments: [String], in directory: URL, input: Data? = nil) throws -> Data {
        let result = execute(arguments, in: directory, input: input)
        guard result.status == 0 else {
            let message = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func run(_ arguments: [String], in directory: URL, input: Data? = nil) -> Data? {
        let result = execute(arguments, in: directory, input: input)
        return result.status == 0 ? result.output : nil
    }

    private static func execute(_ arguments: [String], in directory: URL, input: Data? = nil)
        -> (status: Int32, output: Data, error: Data) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-c", "core.quotepath=off", "-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe(), errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data(), Data("could not run git".utf8)) }
        if let inputPipe, let input {
            // Written concurrently: git may fill the output pipe before it has read all input.
            DispatchQueue.global().async {
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        // Drain stderr concurrently so a chatty command can't block on a full pipe.
        nonisolated(unsafe) var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()
        return (process.terminationStatus, data, errorData)
    }
}


/// One line's last change, from `git blame --porcelain`.
struct BlameLine: Sendable, Equatable {
    let commit: String
    let author: String
    let date: Date
    let summary: String

    /// Lines changed in the buffer (or in the working tree) and not committed yet.
    var isUncommitted: Bool { commit.allSatisfy { $0 == "0" } }

    /// One entry per line of the blamed text (nil where git said nothing).
    static func parse(_ data: Data) -> [BlameLine?] {
        struct Info { var author = "", time: TimeInterval = 0, summary = "" }
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
                                             date: Date(timeIntervalSince1970: info.time), summary: info.summary)
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
                    if infos[String(key)] == nil { infos[String(key)] = Info() }
                }
            } else if let commit = current?.commit {
                switch key {
                case "author": infos[commit]?.author = value
                case "author-time": infos[commit]?.time = TimeInterval(value) ?? 0
                case "summary": infos[commit]?.summary = value
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
