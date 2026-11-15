import AppKit
import CryptoKit

/// When files save themselves.
enum AutoSave: String, CaseIterable, Identifiable {
    case off
    /// A moment after you stop typing.
    case afterDelay
    /// When you switch tabs, windows or apps.
    case onFocusChange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .afterDelay: "After a delay"
        case .onFocusChange: "When focus changes"
        }
    }
}

/// What a window had open, and the text of its unsaved files: kept while it runs (so a crash
/// loses nothing), on quit (to come back as it was) and when it's closed with unsaved changes
/// (they come back when the folder is opened again).
struct WindowSession: Codable, Equatable {
    struct Buffer: Codable, Equatable {
        var path: String
        /// The backup's file name in the session's folder.
        var file: String
        /// The file's modification date when the backup was made (to tell if it changed since).
        var diskDate: Date?
    }

    var root: String?
    /// Open files, in tab order; the active one.
    var files: [String]
    var activeFile: String?
    var unsaved: [Buffer]
    /// Open when the app quit (or crashed): reopened at launch.
    var wasOpen: Bool
}

/// The sessions, one folder each (~/Library/Application Support/OhMyCode/Sessions).
@MainActor
final class SessionStore {
    static let shared = SessionStore(directory: AppSettings.isRunningTests
        ? FileManager.default.temporaryDirectory.appending(path: "omc-test-sessions-\(ProcessInfo.processInfo.processIdentifier)")
        : URL.applicationSupportDirectory.appending(path: "OhMyCode/Sessions"))

    let directory: URL
    /// Set while quitting: windows closing then are still "open" for next launch.
    var isTerminating = false

    init(directory: URL) {
        self.directory = directory
    }

    /// A folder's key (a hash of its path), or a folder-less window's own.
    static func key(root: URL?, windowID: UUID) -> String {
        guard let root else { return "window-" + windowID.uuidString }
        let digest = SHA256.hash(data: Data(FileWatcher.canonicalPath(root).utf8))
        return "folder-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func folder(_ key: String) -> URL { directory.appending(path: key) }

    func write(_ session: WindowSession, texts: [String: String], key: String) {
        let folder = folder(key)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, text) in texts { try text.write(to: folder.appending(path: file), atomically: true, encoding: .utf8) }
            // Backups no longer listed go.
            let keep = Set(session.unsaved.map(\.file) + ["session.json"])
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
            let encoder = JSONEncoder()
            // Full precision: a backup's date is compared with the file's to the millisecond.
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: folder.appending(path: "session.json"), options: .atomic)
        } catch {
            NSLog("Oh My Code: couldn't keep the session: \(error.localizedDescription)")
        }
    }

    func read(_ key: String) -> WindowSession? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: folder(key).appending(path: "session.json")) else { return nil }
        return try? decoder.decode(WindowSession.self, from: data)
    }

    func backup(_ buffer: WindowSession.Buffer, key: String) -> String? {
        try? String(contentsOf: folder(key).appending(path: buffer.file), encoding: .utf8)
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: folder(key))
    }

    /// Every kept session, by key.
    func all() -> [(key: String, session: WindowSession)] {
        let keys = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return keys.sorted().compactMap { key in read(key).map { (key, $0) } }
    }
}

extension Workspace {
    var sessionKey: String { SessionStore.key(root: rootURL, windowID: id) }

    /// What the window has open now, and the texts of unsaved files changed since their last
    /// backup (`all`: every unsaved file's).
    func currentSession(wasOpen: Bool, all: Bool = false) -> (WindowSession, [String: String]) {
        var buffers: [WindowSession.Buffer] = []
        var texts: [String: String] = [:]
        for document in documents where document.isDirty {
            // Named by the document, so a backup stays valid while tabs move around.
            let file = "\(document.id.uuidString)-\(document.url.lastPathComponent).txt"
            buffers.append(.init(path: document.url.path, file: file, diskDate: document.diskModificationDate))
            if all || backedUpVersions[document.id] != document.editVersion {
                texts[file] = document.textStorage.string
            }
        }
        let files = groups.flatMap(\.documentIDs).compactMap { id in document(id: id)?.url.path }
        var seen = Set<String>()
        let session = WindowSession(root: rootURL?.path, files: files.filter { seen.insert($0).inserted },
                                    activeFile: activeDocument?.url.path, unsaved: buffers, wasOpen: wasOpen)
        return (session, texts)
    }

    /// How often, at most, the session is written while typing (a big unsaved file is copied
    /// each time). Quitting and closing write at once.
    static let sessionWriteInterval: TimeInterval = 2

    /// Writes the session if anything changed since the last write (or `force`).
    func keepSession(wasOpen: Bool = true, force: Bool = false, now: Date = Date()) {
        guard rootURL != nil || !documents.isEmpty else { return }
        let signature = documents.map { "\($0.id):\($0.editVersion):\($0.isDirty)" }.joined(separator: ",")
            + "|\(groups.flatMap(\.documentIDs))|\(activeDocumentID?.uuidString ?? "")|\(wasOpen)"
        guard force || signature != sessionSignature else { return }
        if !force, let last = sessionWrittenAt, now.timeIntervalSince(last) < Self.sessionWriteInterval { return }
        sessionSignature = signature
        sessionWrittenAt = now
        let (session, texts) = currentSession(wasOpen: wasOpen, all: force)
        backedUpVersions = Dictionary(uniqueKeysWithValues: documents.filter(\.isDirty).map { ($0.id, $0.editVersion) })
        // Nothing worth keeping for a window that's going away.
        if !wasOpen, session.unsaved.isEmpty {
            SessionStore.shared.remove(sessionKey)
            return
        }
        SessionStore.shared.write(session, texts: texts, key: sessionKey)
    }

    /// The window closed: its unsaved changes stay (for when the folder is opened again).
    func windowClosed() {
        guard !SessionStore.shared.isTerminating else { return }
        keepSession(wasOpen: false, force: true)
        sessionLoop?.cancel()
    }

    /// Keeps the session and auto-saves, twice a second, while the window is open.
    func startKeepingSession() {
        sessionLoop?.cancel()
        sessionLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.autoSaveTick(now: Date())
                self.keepSession()
            }
        }
    }

    /// The folder's kept session: its tabs come back, and unsaved text over what's on disk.
    func restoreSession() {
        let store = SessionStore.shared
        guard let session = store.read(sessionKey) else { return }
        let key = sessionKey
        for path in session.files where FileManager.default.fileExists(atPath: path) && document(matching: URL(fileURLWithPath: path)) == nil {
            open(fileAt: URL(fileURLWithPath: path))
        }
        var restored = 0, changedOnDisk = 0
        for buffer in session.unsaved {
            let url = URL(fileURLWithPath: buffer.path)
            guard let text = store.backup(buffer, key: key) else { continue }
            if document(matching: url) == nil {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                open(fileAt: url)
            }
            guard let document = document(matching: url), document.textStorage.string != text else { continue }
            try? document.apply([TextReplacement(range: NSRange(location: 0, length: document.textStorage.length), text: text)],
                                actionName: "Restore Unsaved Changes")
            restored += 1
            if let date = buffer.diskDate, let now = document.diskModificationDate, abs(date.timeIntervalSince(now)) > 0.01 { changedOnDisk += 1 }
        }
        if let active = session.activeFile { open(fileAt: URL(fileURLWithPath: active)) }
        if restored > 0 {
            let message = restored == 1 ? "Restored unsaved changes in 1 file." : "Restored unsaved changes in \(restored) files."
            let warning = changedOnDisk > 0 ? " \(changedOnDisk) of them changed on disk since: compare before saving." : ""
            Task { _ = await notify(changedOnDisk > 0 ? .warning : .info, message + warning, source: nil) }
        }
        sessionSignature = nil
    }

    // MARK: Auto save

    /// Saves files as the setting says: after `autoSaveDelay` without edits (not formatted),
    /// or (on focus change) when told by `focusChanged`.
    func autoSaveTick(now: Date) {
        let delay = effectiveAutoSaveDelay
        guard effectiveAutoSave == .afterDelay else { autoSaveSeen.removeAll(); return }
        for document in documents where document.isDirty && !document.hasExternalChanges {
            let seen = autoSaveSeen[document.id]
            if seen?.version != document.editVersion {
                autoSaveSeen[document.id] = (document.editVersion, now)
            } else if let since = seen?.since, now.timeIntervalSince(since) >= delay {
                save(document)
                autoSaveSeen[document.id] = nil
            }
        }
    }

    /// Switching tabs, windows or apps: saves (formatting first if format on save is on).
    func focusChanged() {
        guard effectiveAutoSave == .onFocusChange else { return }
        for document in documents where document.isDirty && !document.hasExternalChanges {
            formatAndSave(document)
        }
    }

    // MARK: Launch and quit

    /// At launch: the windows open when the app last quit (or crashed) come back.
    static func reopenLastSessions(open: (OpenRequest) -> Void) {
        for (key, session) in SessionStore.shared.all() where session.wasOpen {
            if let root = session.root {
                guard FileManager.default.fileExists(atPath: root) else { SessionStore.shared.remove(key); continue }
                open(OpenRequest(url: URL(fileURLWithPath: root, isDirectory: true)))
            } else {
                // Files without a folder: their window comes back with them; the old record goes
                // (the new window keeps its own).
                let files = (session.files + session.unsaved.map(\.path)).filter { FileManager.default.fileExists(atPath: $0) }
                for (index, path) in files.enumerated() {
                    var request = OpenRequest(url: URL(fileURLWithPath: path))
                    request.reuseWindow = index > 0
                    open(request)
                }
                pendingFolderlessRestores[files.first ?? ""] = key
            }
        }
    }

    /// Folder-less sessions waiting for their window (by first file), to restore unsaved text.
    @MainActor static var pendingFolderlessRestores: [String: String] = [:]

    /// A folder-less window got its first file: if it's a reopened session, its unsaved text.
    func restoreFolderlessSession(firstFile: URL) {
        guard rootURL == nil, let key = Self.pendingFolderlessRestores.removeValue(forKey: firstFile.path),
              let session = SessionStore.shared.read(key) else { return }
        for buffer in session.unsaved {
            let url = URL(fileURLWithPath: buffer.path)
            guard let text = SessionStore.shared.backup(buffer, key: key) else { continue }
            if document(matching: url) == nil { open(fileAt: url) }
            if let document = document(matching: url), document.textStorage.string != text {
                try? document.apply([TextReplacement(range: NSRange(location: 0, length: document.textStorage.length), text: text)],
                                    actionName: "Restore Unsaved Changes")
            }
        }
        SessionStore.shared.remove(key)
    }

    /// Quitting: every window's session is kept (hot exit), or, with hot exit off, unsaved
    /// changes are asked about. Returns false to cancel.
    static func prepareToQuit(_ workspaces: [Workspace]) -> Bool {
        if AppSettings.shared.hotExit {
            SessionStore.shared.isTerminating = true
            for workspace in workspaces { workspace.keepSession(wasOpen: true, force: true) }
            return true
        }
        for workspace in workspaces {
            for document in workspace.documents where document.isDirty {
                guard workspace.confirmSaving(document) else { return false }
            }
        }
        SessionStore.shared.isTerminating = true
        for workspace in workspaces { SessionStore.shared.remove(workspace.sessionKey) }
        return true
    }
}
