import Foundation
import Observation

/// Where a file of a folder comparison is, and whether its two copies match.
enum FolderCompareStatus: String, CaseIterable, Sendable {
    case onlyLeft, onlyRight, different, same

    var title: String {
        switch self {
        case .onlyLeft: "Only Left"
        case .onlyRight: "Only Right"
        case .different: "Different"
        case .same: "Same"
        }
    }
}

/// One file (or symbolic link) of a folder comparison, by its path inside the folders.
struct FolderCompareEntry: Identifiable, Hashable, Sendable {
    let path: String
    let status: FolderCompareStatus
    var id: String { path }
}

/// What a folder comparison leaves out: version control and build folders by name anywhere, and
/// what the folder's own `.gitignore` (at its top) lists. Only the plain forms of `.gitignore`
/// patterns are understood (names, globs, a leading or inner `/`, a trailing `/` for folders,
/// a leading `**/`); `!` exceptions are skipped, so a file they bring back stays out.
struct FolderCompareIgnore: Sendable {
    static let directories: Set<String> = FileIndexer.ignoredDirectories.union([
        ".hg", ".svn", "__pycache__", ".gradle", ".next", ".nuxt", ".parcel-cache", ".tox", ".venv",
    ])
    static let files: Set<String> = [".DS_Store"]

    private struct Pattern: Sendable {
        let glob: String
        /// Matched against the whole path from the folder, not only the name.
        let anchored: Bool
        let directoryOnly: Bool
    }

    private let patterns: [Pattern]

    init(gitignore: String = "") {
        patterns = gitignore.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { return nil }
            let directoryOnly = line.hasSuffix("/")
            if directoryOnly { line.removeLast() }
            if line.hasPrefix("**/") { line.removeFirst(3) }
            let anchored = line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            return line.isEmpty ? nil : Pattern(glob: line, anchored: anchored, directoryOnly: directoryOnly)
        }
    }

    /// The rules for a folder: its top `.gitignore`, if it has one.
    static func load(root: URL) -> FolderCompareIgnore {
        FolderCompareIgnore(gitignore: (try? String(contentsOf: root.appending(path: ".gitignore"), encoding: .utf8)) ?? "")
    }

    /// Whether `path` (from the folder, "/"-separated) is left out. A folder left out takes its
    /// contents with it (the walk doesn't go in).
    func ignores(_ path: String, isDirectory: Bool) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if isDirectory ? Self.directories.contains(name) : Self.files.contains(name) { return true }
        return patterns.contains { pattern in
            guard isDirectory || !pattern.directoryOnly else { return false }
            return fnmatch(pattern.glob, pattern.anchored ? path : name, pattern.anchored ? FNM_PATHNAME : 0) == 0
        }
    }
}

/// Compares two folders' files: by path, then size, then content (byte for byte). Symbolic
/// links aren't followed: two links match when they point to the same place.
enum FolderComparer {
    /// What the walk found at a path.
    struct Item: Equatable, Sendable {
        let size: Int64
        /// A symbolic link's target (nil: a regular file).
        let link: String?
    }

    /// The files under `root` by path from it, without what `ignore` leaves out. Throws when
    /// cancelled.
    static func files(in root: URL, ignore: FolderCompareIgnore, isCancelled: () -> Bool) throws -> [String: Item] {
        var result: [String: Item] = [:]
        var pending = [(path: root.standardizedFileURL.path, prefix: "")]
        while let (path, prefix) = pending.popLast() {
            if isCancelled() { throw CancellationError() }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }
            for name in names {
                let full = path + "/" + name, relative = prefix + name
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    if !ignore.ignores(relative, isDirectory: true) { pending.append((full, relative + "/")) }
                case S_IFREG:
                    if !ignore.ignores(relative, isDirectory: false) { result[relative] = Item(size: Int64(info.st_size), link: nil) }
                case S_IFLNK:
                    if !ignore.ignores(relative, isDirectory: false) {
                        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? ""
                        result[relative] = Item(size: Int64(info.st_size), link: target)
                    }
                default:
                    continue // sockets, pipes, devices
                }
            }
        }
        return result
    }

    /// Every file of either folder with its status, sorted by path. `progress` hears how many of
    /// the files in both folders were compared, out of how many. Throws when cancelled.
    static func compare(left: URL, right: URL,
                        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in },
                        isCancelled: () -> Bool) throws -> [FolderCompareEntry] {
        let leftFiles = try files(in: left, ignore: .load(root: left), isCancelled: isCancelled)
        let rightFiles = try files(in: right, ignore: .load(root: right), isCancelled: isCancelled)
        let paths = Set(leftFiles.keys).union(rightFiles.keys).sorted()
        let total = leftFiles.keys.reduce(0) { $0 + (rightFiles[$1] == nil ? 0 : 1) }
        var done = 0
        progress(0, total)
        var entries: [FolderCompareEntry] = []
        entries.reserveCapacity(paths.count)
        for path in paths {
            let status: FolderCompareStatus
            switch (leftFiles[path], rightFiles[path]) {
            case (nil, _): status = .onlyRight
            case (_, nil): status = .onlyLeft
            case (let a?, let b?):
                if isCancelled() { throw CancellationError() }
                if a.link != nil || b.link != nil {
                    status = a.link == b.link ? .same : .different
                } else if a.size != b.size {
                    status = .different
                } else {
                    status = try sameContent(left.appending(path: path), right.appending(path: path), isCancelled: isCancelled)
                        ? .same : .different
                }
                done += 1
                progress(done, total)
            }
            entries.append(FolderCompareEntry(path: path, status: status))
        }
        return entries
    }

    /// Whether two files (of the same size) hold the same bytes, read a block at a time.
    static func sameContent(_ a: URL, _ b: URL, isCancelled: () -> Bool) throws -> Bool {
        guard let first = try? FileHandle(forReadingFrom: a), let second = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? first.close(); try? second.close() }
        while true {
            if isCancelled() { throw CancellationError() }
            let x = (try? first.read(upToCount: 256 * 1024)) ?? Data()
            let y = (try? second.read(upToCount: 256 * 1024)) ?? Data()
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }
}

/// A folder comparison tab: runs the comparison off the main thread (again on Refresh), and
/// stops when the tab closes.
@MainActor
@Observable
final class FolderComparisonSession: Identifiable {
    let id = UUID()
    let left: URL
    let right: URL
    private(set) var entries: [FolderCompareEntry] = []
    private(set) var isRunning = false
    /// Files compared so far, out of those in both folders.
    private(set) var progress = (done: 0, total: 0)
    /// Unchanged files are listed too.
    var showsSame = false
    /// Only paths containing this (ignoring case) are listed.
    var filter = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    init(left: URL, right: URL) {
        self.left = left
        self.right = right
    }

    var title: String {
        let names = FileComparison.distinctNames(left, right)
        return "\(names.left) ↔ \(names.right)"
    }
    var help: String { "\(left.path) ↔ \(right.path)" }

    func count(_ status: FolderCompareStatus) -> Int { entries.reduce(0) { $0 + ($1.status == status ? 1 : 0) } }

    var visibleEntries: [FolderCompareEntry] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            (showsSame || entry.status != .same) && (text.isEmpty || entry.path.localizedCaseInsensitiveContains(text))
        }
    }

    /// Compares the folders (again), dropping a comparison still running.
    func refresh() {
        task?.cancel()
        isRunning = true
        progress = (0, 0)
        let left = left, right = right
        let reporter = ProgressRelay { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.isRunning, done >= self.progress.done else { return }
                self.progress = (done, total)
            }
        }
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> [FolderCompareEntry]? in
                try? FolderComparer.compare(left: left, right: right, progress: reporter.report, isCancelled: { Task.isCancelled })
            }.cancellableValue
            guard let self, !Task.isCancelled else { return }
            if let result { entries = result }
            isRunning = false
        }
    }

    /// Stops a comparison still running (the tab closed).
    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Waits for the comparison running (tests).
    func waitForCompletion() async { await task?.value }

    func url(_ entry: FolderCompareEntry, onLeft: Bool) -> URL {
        (onLeft ? left : right).appending(path: entry.path)
    }
}

/// Passes progress on at most every 50 ms (and at the end), not once per file.
private final class ProgressRelay: @unchecked Sendable {
    private let send: @Sendable (Int, Int) -> Void
    private var last = Date.distantPast
    private let lock = NSLock()

    init(send: @escaping @Sendable (Int, Int) -> Void) { self.send = send }

    func report(_ done: Int, _ total: Int) {
        let now = Date()
        let due = lock.withLock {
            guard done == total || now.timeIntervalSince(last) > 0.05 else { return false }
            last = now
            return true
        }
        if due { send(done, total) }
    }
}

private extension Task where Failure == Never {
    /// The detached task's value; cancelling the waiting task cancels it too.
    var cancellableValue: Success {
        get async { await withTaskCancellationHandler { await value } onCancel: { cancel() } }
    }
}
