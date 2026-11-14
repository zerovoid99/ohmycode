import Foundation
import Observation

/// Every diagnostic in the workspace, open files or not, for the Problems panel: the language
/// servers', extensions' and tasks' (each a "source" that replaces its own list per file).
@MainActor
@Observable
final class ProblemStore {
    struct File: Identifiable, Equatable {
        var url: URL
        var diagnostics: [Diagnostic]
        var id: String { url.path }
        var errors: Int { diagnostics.count { $0.severity == .error } }
    }

    /// Canonical file path → source → diagnostics.
    private(set) var entries: [String: [String: [Diagnostic]]] = [:]
    /// What each path is shown as (the workspace's URL for it).
    @ObservationIgnored private var urls: [String: URL] = [:]

    /// Replaces `source`'s diagnostics for the file (empty removes them).
    func set(_ diagnostics: [Diagnostic], for url: URL, source: String) {
        let path = FileWatcher.canonicalPath(url)
        guard entries[path]?[source] ?? [] != diagnostics else { return }
        urls[path] = url
        entries[path, default: [:]][source] = diagnostics.isEmpty ? nil : diagnostics
        if entries[path]?.isEmpty == true { entries[path] = nil }
    }

    /// Removes every diagnostic from sources matching `predicate`.
    func clear(where predicate: (String) -> Bool) {
        for path in Array(entries.keys) {
            guard let sources = entries[path], sources.keys.contains(where: predicate) else { continue }
            let kept = sources.filter { !predicate($0.key) }
            entries[path] = kept.isEmpty ? nil : kept
        }
    }

    func clear(source: String) { clear { $0 == source } }

    func removeAll() {
        entries = [:]
        urls = [:]
    }

    /// One source's diagnostics for a file.
    func diagnostics(for url: URL, source: String) -> [Diagnostic] {
        entries[FileWatcher.canonicalPath(url)]?[source] ?? []
    }

    /// Sources with diagnostics for a file.
    func sources(for url: URL) -> [String: [Diagnostic]] {
        entries[FileWatcher.canonicalPath(url)] ?? [:]
    }

    var errorCount: Int { entries.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count { $0.severity == .error } } } }
    var warningCount: Int { entries.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count { $0.severity == .warning } } } }
    var totalCount: Int { entries.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }

    /// Files with problems, those with errors first, then by path; each file's diagnostics by
    /// position. `filter` matches the message, source or file name (case-insensitively);
    /// `minimum` drops less severe ones (`.warning` hides information and hints).
    func files(filter: String = "", minimum: Diagnostic.Severity = .hint) -> [File] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [File] = []
        for (path, sources) in entries {
            let url = urls[path] ?? URL(filePath: path)
            let nameMatches = !needle.isEmpty && url.lastPathComponent.lowercased().contains(needle)
            let list = sources.values.flatMap { $0 }
                .filter { $0.severity.rawValue <= minimum.rawValue }
                .filter { needle.isEmpty || nameMatches || $0.message.lowercased().contains(needle)
                    || ($0.source?.lowercased().contains(needle) ?? false) }
                .sorted { ($0.range.start.line, $0.range.start.character, $0.severity.rawValue)
                    < ($1.range.start.line, $1.range.start.character, $1.severity.rawValue) }
            if !list.isEmpty { result.append(File(url: url, diagnostics: list)) }
        }
        return result.sorted {
            ($0.errors > 0 ? 0 : 1, $0.url.path) < ($1.errors > 0 ? 0 : 1, $1.url.path)
        }
    }
}
