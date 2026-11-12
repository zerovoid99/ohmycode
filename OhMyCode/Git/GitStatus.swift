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
    private static func check(_ arguments: [String], in directory: URL) throws -> Data {
        let result = execute(arguments, in: directory)
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

    private static func run(_ arguments: [String], in directory: URL) -> Data? {
        let result = execute(arguments, in: directory)
        return result.status == 0 ? result.output : nil
    }

    private static func execute(_ arguments: [String], in directory: URL) -> (status: Int32, output: Data, error: Data) {
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
        do { try process.run() } catch { return (-1, Data(), Data("could not run git".utf8)) }
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
