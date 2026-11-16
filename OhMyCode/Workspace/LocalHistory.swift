import AppKit
import CryptoKit
import Foundation
import Observation

/// A file's past content, kept by the editor (whether or not the file is in git).
struct LocalHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// What was saved.
        case saved
        /// What was on disk before a save replaced it (the first version, or another program's).
        case beforeSave
        /// What the editor had before another program's version replaced it.
        case beforeReload
        /// What the editor had before an entry was restored.
        case beforeRestore

        var title: String {
            switch self {
            case .saved: "Saved"
            case .beforeSave: "Before saving"
            case .beforeReload: "Before changed on disk"
            case .beforeRestore: "Before restoring"
            }
        }

        var icon: String {
            switch self {
            case .saved: "square.and.arrow.down"
            case .beforeSave: "doc"
            case .beforeReload: "arrow.triangle.2.circlepath.doc.on.clipboard"
            case .beforeRestore: "arrow.uturn.backward"
            }
        }
    }

    /// Its file's name in the history folder.
    let id: String
    let date: Date
    let reason: Reason
    let size: Int
}

/// Versions of every file saved in the editor (~/Library/Application Support/OhMyCode/History,
/// a folder per file): to compare with or go back to, like VS Code's Local History.
@MainActor
@Observable
final class LocalHistory {
    static let shared = LocalHistory(directory: AppSettings.isRunningTests
        ? FileManager.default.temporaryDirectory.appending(path: "omc-test-history-\(ProcessInfo.processInfo.processIdentifier)")
        : URL.omcApplicationSupport.appending(path: "OhMyCode/History"))

    static let maxEntriesPerFile = 50
    static let maxFileSize = 2_000_000
    static let maxAge: TimeInterval = 30 * 24 * 3600

    let directory: URL
    /// Bumped when any file's entries change (views re-read).
    private(set) var version = 0

    init(directory: URL) {
        self.directory = directory
    }

    private struct Index: Codable {
        var path: String
        var entries: [LocalHistoryEntry]
    }

    /// The folder for a file: named by a hash of its symlink-resolved path.
    func folder(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(FileWatcher.canonicalPath(url).utf8))
        return directory.appending(path: digest.prefix(12).map { String(format: "%02x", $0) }.joined())
    }

    private func index(for url: URL) -> Index {
        let file = folder(for: url).appending(path: "index.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file), let index = try? decoder.decode(Index.self, from: data) { return index }
        return Index(path: FileWatcher.canonicalPath(url), entries: [])
    }

    private func write(_ index: Index, for url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: folder(for: url).appending(path: "index.json"), options: .atomic)
    }

    /// A file of the history itself (however its path is spelled).
    private func isInside(_ url: URL) -> Bool {
        let paths = [url.standardizedFileURL.path, FileWatcher.canonicalPath(url)]
        let roots = [directory.standardizedFileURL.path, FileWatcher.canonicalPath(directory)]
        return paths.contains { path in roots.contains { path.hasPrefix($0 + "/") } }
    }

    /// Newest first.
    func entries(for url: URL) -> [LocalHistoryEntry] {
        index(for: url).entries.sorted { $0.date > $1.date }
    }

    func text(of entry: LocalHistoryEntry, for url: URL) -> String? {
        try? String(contentsOf: folder(for: url).appending(path: entry.id), encoding: .utf8)
    }

    /// Keeps `text` as the file's newest version (unless it's the same as the newest kept, too
    /// big, or the file is the history's own). Old entries beyond the limits go.
    @discardableResult
    func record(_ text: String, for url: URL, reason: LocalHistoryEntry.Reason, date: Date = Date()) -> LocalHistoryEntry? {
        let size = text.utf8.count
        guard size <= Self.maxFileSize, !isInside(url), !url.pathComponents.contains(".git") else { return nil }
        var index = index(for: url)
        if let newest = index.entries.max(by: { $0.date < $1.date }), self.text(of: newest, for: url) == text { return nil }
        let folder = folder(for: url)
        let stamp = Int(date.timeIntervalSince1970 * 1000)
        var id = "\(stamp).txt"
        var attempt = 1
        while index.entries.contains(where: { $0.id == id }) { id = "\(stamp)-\(attempt).txt"; attempt += 1 }
        let entry = LocalHistoryEntry(id: id, date: date, reason: reason, size: size)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appending(path: id), atomically: true, encoding: .utf8)
            index.path = FileWatcher.canonicalPath(url)
            index.entries.append(entry)
            prune(&index, folder: folder, now: date)
            try write(index, for: url)
        } catch {
            return nil
        }
        version += 1
        return entry
    }

    private func prune(_ index: inout Index, folder: URL, now: Date) {
        var kept = index.entries.sorted { $0.date > $1.date }
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        let dropped = kept.enumerated().filter { $0.offset >= Self.maxEntriesPerFile || $0.element.date < cutoff }.map(\.element)
        kept.removeAll { entry in dropped.contains(entry) }
        for entry in dropped { try? FileManager.default.removeItem(at: folder.appending(path: entry.id)) }
        index.entries = kept
    }

    func remove(_ entry: LocalHistoryEntry, for url: URL) {
        var index = index(for: url)
        index.entries.removeAll { $0.id == entry.id }
        try? FileManager.default.removeItem(at: folder(for: url).appending(path: entry.id))
        try? write(index, for: url)
        version += 1
    }

    /// Forgets a file's history.
    func clear(for url: URL) {
        try? FileManager.default.removeItem(at: folder(for: url))
        version += 1
    }
}

extension Workspace {
    /// A saved version against the editor's text now (live), in a diff tab.
    @discardableResult
    func compare(_ entry: LocalHistoryEntry, with url: URL) -> DiffSession? {
        let canonical = FileWatcher.canonicalPath(url)
        if let existing = diffSessions.first(where: { $0.mode == .history(entry) && FileWatcher.canonicalPath($0.url) == canonical }) {
            activeGroup.show(existing.id)
            return existing
        }
        guard let text = LocalHistory.shared.text(of: entry, for: url) else {
            errorMessage = "That version of \(url.lastPathComponent) is gone from the local history."
            return nil
        }
        let wasOpen = document(matching: url) != nil
        guard let document = document(matching: url) ?? openWithoutTab(url) else { return nil }
        let session = DiffSession(document: document, ownsDocument: !wasOpen, comparingWithHistory: entry)
        session.setLoaded(base: text, current: nil, isNewFile: false)
        addDiffSession(session)
        return session
    }

    /// Puts a saved version back in the editor, as one undoable change (saved when you save).
    func restore(_ entry: LocalHistoryEntry, of url: URL) {
        guard let text = LocalHistory.shared.text(of: entry, for: url) else {
            errorMessage = "That version of \(url.lastPathComponent) is gone from the local history."
            return
        }
        open(fileAt: url)
        guard let document = document(matching: url) else { return }
        let current = document.textStorage.string
        guard current != text else { return }
        LocalHistory.shared.record(current, for: url, reason: .beforeRestore)
        _ = try? document.apply([TextReplacement(range: NSRange(location: 0, length: document.textStorage.length), text: text)],
                                actionName: "Restore \(entry.date.formatted(date: .abbreviated, time: .shortened))")
    }

    /// Local History: picks one of the active file's versions; it's compared, or restored.
    func pickLocalHistoryEntry(restoring: Bool) async {
        guard let url = activeDocument?.url else { NSSound.beep(); return }
        let entries = LocalHistory.shared.entries(for: url)
        guard !entries.isEmpty else {
            errorMessage = "\(url.lastPathComponent) has no local history yet: versions are kept each time it's saved."
            return
        }
        let items = entries.map {
            QuickPickItem(label: $0.date.formatted(date: .abbreviated, time: .standard),
                          description: "\($0.reason.title) · \(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file))")
        }
        guard let index = await showQuickPick(items, placeholder: restoring ? "Version to restore" : "Version to compare with"),
              entries.indices.contains(index) else { return }
        if restoring { restore(entries[index], of: url) } else { compare(entries[index], with: url) }
    }
}
