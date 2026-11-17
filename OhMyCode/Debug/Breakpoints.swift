import Foundation
import Observation

/// How a breakpoint shows in the gutter.
struct BreakpointMark: Equatable {
    var isEnabled = true
    /// The debugger confirmed it (nil: not debugging; false: it couldn't place it).
    var isVerified: Bool?
    var hasCondition = false
    /// A logpoint: prints its message instead of stopping.
    var isLogpoint = false
}

/// The workspace's breakpoints by file (absolute, canonical paths), kept across launches per
/// folder: each folder's files' breakpoints are saved under that folder, so a folder keeps them
/// whether it's opened alone or in a workspace with others. Watches and exception breakpoints
/// are the window's, saved with its first folder.
@MainActor
@Observable
final class BreakpointStore {
    struct Breakpoint: Codable, Hashable, Identifiable {
        /// One-based, as the debug adapter counts.
        var line: Int
        var condition: String?
        var isEnabled = true
        /// Printed (with {expressions} filled in) instead of stopping.
        var logMessage: String?
        var id: Int { line }
    }

    /// An exception breakpoint the debugger offers ("swift_throw": "Swift Throw").
    struct ExceptionFilter: Codable, Hashable, Identifiable {
        let filter: String
        let label: String
        var id: String { filter }
    }

    /// LLDB's, until a debugger says what it offers.
    static let lldbExceptionFilters = [("swift_throw", "Swift Throw"), ("swift_catch", "Swift Catch"),
                                       ("cpp_throw", "C++ Throw"), ("cpp_catch", "C++ Catch"),
                                       ("objc_throw", "Objective-C Throw"), ("objc_catch", "Objective-C Catch")]
        .map { ExceptionFilter(filter: $0.0, label: $0.1) }

    /// The exception breakpoints offered, and the ones turned on.
    private(set) var exceptionFilters = lldbExceptionFilters
    private(set) var enabledExceptionFilters: Set<String> = []
    /// Expressions shown whenever the program stops (the Watch list).
    private(set) var watches: [String] = []
    @ObservationIgnored var onExceptionFiltersChange: (() -> Void)?
    @ObservationIgnored var onWatchesChange: (() -> Void)?

    private(set) var byPath: [String: [Breakpoint]] = [:]
    /// Lines (one-based) the debugger confirmed, per file; nil when not debugging.
    private(set) var verified: [String: Set<Int>]?
    /// Called with the file whose breakpoints changed (the session sends them again).
    @ObservationIgnored var onChange: ((String) -> Void)?
    @ObservationIgnored private var defaults: UserDefaults
    /// The first folder's key (watches, exception breakpoints, files outside every folder).
    @ObservationIgnored private var key: String?
    /// Each folder's key and canonical path, innermost first.
    @ObservationIgnored private var folderKeys: [(key: String, path: String)] = []
    /// Files outside every folder, and the key they were loaded from (kept there).
    @ObservationIgnored private var outsideHomes: [String: String] = [:]

    init(defaults: UserDefaults = AppSettings.isRunningTests ? ScratchDefaults.named("dev.zerovoid99.ohmycode.tests.breakpoints") : .omc) {
        self.defaults = defaults
    }

    /// Loads the breakpoints saved for a folder.
    func load(for root: URL?) {
        load(for: root.map { [$0] } ?? [])
    }

    /// Loads the breakpoints saved for a window's folders (the first one's watches and
    /// exception breakpoints). Breakpoints for another folder's files, saved under the first
    /// folder before each folder kept its own, move to their folder.
    func load(for folders: [URL]) {
        key = folders.first.map(Self.key)
        folderKeys = folders.map { (Self.key($0), FileWatcher.canonicalPath($0)) }
            .sorted { $0.path.count > $1.path.count }
        outsideHomes = [:]
        var loaded: [String: [Breakpoint]] = [:]
        var migrated = false
        for (index, folder) in folders.enumerated() {
            let folderKey = Self.key(folder)
            let saved = defaults.data(forKey: folderKey).flatMap { try? JSONDecoder().decode([String: [Breakpoint]].self, from: $0) } ?? [:]
            for (path, list) in saved {
                let home = homeKey(of: path)
                if home == nil { outsideHomes[path] = folderKey }
                if home != nil, home != folderKey { migrated = true }
                // A folder's own saved breakpoints win over a copy saved elsewhere.
                if loaded[path] == nil || home == folderKey || (home == nil && index == 0) { loaded[path] = list }
            }
        }
        byPath = loaded
        enabledExceptionFilters = Set(key.flatMap { defaults.stringArray(forKey: $0 + ".exceptions") } ?? [])
        watches = key.flatMap { defaults.stringArray(forKey: $0 + ".watches") } ?? []
        verified = nil
        if migrated { save() }
    }

    /// The window's folders changed (one added or removed): their breakpoints are loaded, and
    /// the files whose breakpoints that changed are announced (a running debugger gets them).
    func setFolders(_ folders: [URL]) {
        let before = byPath, confirmed = verified
        let oldWatches = watches, oldFilters = enabledExceptionFilters
        load(for: folders)
        verified = confirmed
        Set(before.keys).union(byPath.keys).filter { before[$0] != byPath[$0] }.sorted().forEach { onChange?($0) }
        if watches != oldWatches { onWatchesChange?() }
        if enabledExceptionFilters != oldFilters { onExceptionFiltersChange?() }
    }

    /// Where a folder's breakpoints are saved (a single folder's, as always).
    static func key(_ folder: URL) -> String { "breakpoints.\(folder.standardizedFileURL.path)" }

    /// The key of the innermost folder a file is in; nil outside every folder.
    private func homeKey(of path: String) -> String? {
        folderKeys.first { path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }?.key
    }

    var all: [(path: String, breakpoint: Breakpoint)] {
        byPath.keys.sorted().flatMap { path in byPath[path]!.map { (path, $0) } }
    }

    func breakpoints(in path: String) -> [Breakpoint] { byPath[path] ?? [] }

    /// Gutter marks for a file, by zero-based line.
    func marks(for path: String) -> [Int: BreakpointMark] {
        let confirmed = verified?[path]
        return Dictionary(breakpoints(in: path).map { breakpoint in
            (breakpoint.line - 1, BreakpointMark(isEnabled: breakpoint.isEnabled,
                                                 isVerified: confirmed.map { $0.contains(breakpoint.line) },
                                                 hasCondition: breakpoint.condition?.isEmpty == false,
                                                 isLogpoint: breakpoint.logMessage?.isEmpty == false))
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Adds a breakpoint on a line (one-based), or removes the one there.
    func toggle(_ path: String, line: Int) {
        var list = breakpoints(in: path)
        if let index = list.firstIndex(where: { $0.line == line }) { list.remove(at: index) } else { list.append(Breakpoint(line: line)) }
        set(list, for: path)
    }

    func setEnabled(_ path: String, line: Int, _ enabled: Bool) {
        update(path, line: line) { $0.isEnabled = enabled }
    }

    func setCondition(_ path: String, line: Int, _ condition: String?) {
        update(path, line: line) { $0.condition = condition?.isEmpty == true ? nil : condition }
    }

    func setLogMessage(_ path: String, line: Int, _ message: String?) {
        update(path, line: line) { $0.logMessage = message?.isEmpty == true ? nil : message }
    }

    // MARK: Exception breakpoints

    /// What the debugger offers (kept: what's turned on stays on).
    func setExceptionFilters(_ filters: [ExceptionFilter]) {
        if !filters.isEmpty { exceptionFilters = filters }
    }

    func setException(_ filter: String, enabled: Bool) {
        if enabled { enabledExceptionFilters.insert(filter) } else { enabledExceptionFilters.remove(filter) }
        if let key { defaults.set(enabledExceptionFilters.sorted(), forKey: key + ".exceptions") }
        onExceptionFiltersChange?()
    }

    // MARK: Watch

    func addWatch(_ expression: String) {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !watches.contains(text) else { return }
        setWatches(watches + [text])
    }

    func replaceWatch(at index: Int, with expression: String) {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard watches.indices.contains(index) else { return }
        var list = watches
        if text.isEmpty { list.remove(at: index) } else { list[index] = text }
        setWatches(list)
    }

    func removeWatch(at index: Int) {
        guard watches.indices.contains(index) else { return }
        var list = watches
        list.remove(at: index)
        setWatches(list)
    }

    private func setWatches(_ list: [String]) {
        watches = list
        if let key { defaults.set(list, forKey: key + ".watches") }
        onWatchesChange?()
    }

    func remove(_ path: String, line: Int) {
        set(breakpoints(in: path).filter { $0.line != line }, for: path)
    }

    func removeAll() {
        let paths = Array(byPath.keys)
        byPath = [:]
        save()
        paths.forEach { onChange?($0) }
    }

    /// Lines `old` (zero-based) of a file became `count` lines: later breakpoints move, ones on
    /// removed lines go.
    func linesReplaced(in path: String, _ old: Range<Int>, with count: Int) {
        let list = breakpoints(in: path)
        guard !list.isEmpty else { return }
        let delta = count - old.count
        var moved: [Breakpoint] = []
        for var breakpoint in list {
            let line = breakpoint.line - 1
            if line >= old.upperBound {
                breakpoint.line += delta
            } else if line >= old.lowerBound {
                // On a replaced line: it stays on the edit's first line, unless the lines went.
                guard count > 0 else { continue }
                breakpoint.line = old.lowerBound + 1
            }
            if !moved.contains(where: { $0.line == breakpoint.line }) { moved.append(breakpoint) }
        }
        if moved != list { set(moved, for: path) }
    }

    /// A file or folder moved (renamed): its breakpoints (those of files under it) go with it.
    func move(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        let moving = byPath.keys.filter { $0 == oldPath || $0.hasPrefix(oldPath + "/") }
        guard !moving.isEmpty else { return }
        var changed: [String] = []
        for path in moving {
            let destination = newPath + path.dropFirst(oldPath.count)
            byPath[destination] = byPath.removeValue(forKey: path)
            verified?[path] = nil
            changed += [path, destination]
        }
        save()
        changed.forEach { onChange?($0) }
    }

    /// What the debugger said about a file's breakpoints (one-based lines it placed).
    func setVerified(_ lines: Set<Int>, for path: String) {
        if verified == nil { verified = [:] }
        verified?[path] = lines
    }

    func clearVerified() { verified = nil }

    private func update(_ path: String, line: Int, _ change: (inout Breakpoint) -> Void) {
        var list = breakpoints(in: path)
        guard let index = list.firstIndex(where: { $0.line == line }) else { return }
        change(&list[index])
        set(list, for: path)
    }

    private func set(_ list: [Breakpoint], for path: String) {
        byPath[path] = list.isEmpty ? nil : list.sorted { $0.line < $1.line }
        save()
        onChange?(path)
    }

    /// Saves each folder's breakpoints under it (files outside every folder where they were
    /// loaded from, or with the first folder).
    private func save() {
        guard let key else { return }
        var byKey: [String: [String: [Breakpoint]]] = Dictionary(folderKeys.map { ($0.key, [:]) }, uniquingKeysWith: { a, _ in a })
        for (path, list) in byPath {
            byKey[homeKey(of: path) ?? outsideHomes[path] ?? key, default: [:]][path] = list
        }
        for (folderKey, list) in byKey {
            if list.isEmpty { defaults.removeObject(forKey: folderKey) } else { defaults.set(try? JSONEncoder().encode(list), forKey: folderKey) }
        }
    }
}
