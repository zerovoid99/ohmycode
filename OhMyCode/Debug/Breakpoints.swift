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

/// The workspace's breakpoints by file, kept across launches (per folder).
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
    @ObservationIgnored private var key: String?

    init(defaults: UserDefaults = AppSettings.isRunningTests ? UserDefaults(suiteName: "dev.zerovoid99.ohmycode.tests.breakpoints")! : .standard) {
        self.defaults = defaults
    }

    /// Loads the breakpoints saved for a folder.
    func load(for root: URL?) {
        key = root.map { "breakpoints.\($0.standardizedFileURL.path)" }
        byPath = key.flatMap { defaults.data(forKey: $0) }.flatMap { try? JSONDecoder().decode([String: [Breakpoint]].self, from: $0) } ?? [:]
        enabledExceptionFilters = Set(key.flatMap { defaults.stringArray(forKey: $0 + ".exceptions") } ?? [])
        watches = key.flatMap { defaults.stringArray(forKey: $0 + ".watches") } ?? []
        verified = nil
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

    private func save() {
        guard let key else { return }
        defaults.set(try? JSONEncoder().encode(byPath), forKey: key)
    }
}
