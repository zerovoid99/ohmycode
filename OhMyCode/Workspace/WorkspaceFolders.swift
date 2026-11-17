import AppKit
import CryptoKit

/// The window's folders, as paths are written from them: with one folder a file's path is its
/// path in it ("src/main.swift"), as always; with several it starts with the folder's label
/// ("api/src/main.go"), so files with the same path in two folders stay apart, and Find in
/// Files can be narrowed to a folder with "api/**".
struct WorkspaceRoots: Sendable, Equatable {
    struct Folder: Sendable, Equatable {
        let url: URL
        /// Unique among the window's folders, without "/".
        let label: String
    }

    let folders: [Folder]

    init(_ folders: [Folder]) { self.folders = folders }

    /// One folder: paths are relative to it.
    init(single url: URL) { folders = [Folder(url: url, label: url.lastPathComponent)] }

    var isMultiRoot: Bool { folders.count > 1 }

    /// Labels for folders: their given names (or folder names), made unique by the parent
    /// folder's name and then a number.
    static func labels(for urls: [URL], names: [URL: String] = [:]) -> [String] {
        let base = urls.map { url in
            (names[url] ?? url.lastPathComponent).replacingOccurrences(of: "/", with: "-")
        }
        var labels: [String] = []
        for (index, name) in base.enumerated() {
            var label = name
            if base.filter({ $0 == name }).count > 1 {
                label = "\(name) (\(urls[index].deletingLastPathComponent().lastPathComponent))"
            }
            var number = 2
            let first = label
            while labels.contains(label) {
                label = "\(first) \(number)"
                number += 1
            }
            labels.append(label)
        }
        return labels
    }

    init(urls: [URL], names: [URL: String] = [:]) {
        let labels = Self.labels(for: urls, names: names)
        folders = zip(urls, labels).map { Folder(url: $0, label: $1) }
    }

    /// The folder a file is in (the innermost, when one folder is inside another).
    func folder(containing url: URL) -> Folder? {
        let path = url.standardizedFileURL.path
        return folders
            .filter { let root = $0.url.standardizedFileURL.path; return path == root || path.hasPrefix(root + "/") }
            .max { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count }
    }

    /// A file's path as the window writes it (see above); nil outside every folder. A folder
    /// itself is "" (one folder) or its label.
    func path(of url: URL) -> String? {
        guard let folder = folder(containing: url) else { return nil }
        let root = folder.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
        guard isMultiRoot else { return relative.isEmpty ? (path == root ? "" : nil) : relative }
        return relative.isEmpty ? folder.label : folder.label + "/" + relative
    }

    /// The file a path written this way names.
    func url(for path: String) -> URL? {
        guard isMultiRoot else { return folders.first?.url.appending(path: path, directoryHint: .notDirectory) }
        let label = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        guard let folder = folders.first(where: { $0.label == label }) else { return nil }
        let rest = path.dropFirst(label.count).drop { $0 == "/" }
        return rest.isEmpty ? folder.url : folder.url.appending(path: String(rest), directoryHint: .notDirectory)
    }

    /// A folder's own paths written as the window writes them.
    func paths(_ relative: [String], in folder: Folder) -> [String] {
        isMultiRoot ? relative.map { folder.label + "/" + $0 } : relative
    }

    /// Whether `url` is in one of the folders, with links followed (a link inside pointing
    /// outside is outside).
    func contains(_ url: URL) -> Bool {
        folders.contains { url.isWithin($0.url) }
    }
}

/// A workspace file (`.omc-workspace`, modelled on VS Code's `.code-workspace`, which opens the
/// same way): the folders a window shows, and settings for all of them.
///
///     { "folders": [{ "path": "frontend" }, { "path": "../api", "name": "API" }],
///       "settings": { "formatOnSave": true } }
///
/// Relative paths are from the file's own folder. Keys it doesn't know are left alone.
struct WorkspaceFile: Equatable {
    static let fileExtension = "omc-workspace"
    /// Opened as workspaces (VS Code's too).
    static let extensions: Set<String> = [fileExtension, "code-workspace"]

    struct Entry: Equatable {
        var path: String
        var name: String?
    }

    var folders: [Entry]
    /// The `settings` object as written (kept to write it back), and what it means here.
    var settingsJSON: Data?
    var settings: ProjectSettings

    static func isWorkspaceFile(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    init(folders: [Entry], settingsJSON: Data? = nil) {
        self.folders = folders
        self.settingsJSON = settingsJSON
        settings = settingsJSON.flatMap { try? ProjectSettings(json: $0) } ?? ProjectSettings()
    }

    /// Reads a workspace file (comments and trailing commas allowed, as VS Code writes them).
    init(data: Data) throws {
        let cleaned = ProjectSettings.stripComments(String(decoding: data, as: UTF8.self))
        guard let object = try JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let entries = (object["folders"] as? [[String: Any]] ?? []).compactMap { entry -> Entry? in
            // VS Code also allows a `uri`; only file URIs mean something here.
            if let path = entry["path"] as? String, !path.isEmpty { return Entry(path: path, name: entry["name"] as? String) }
            if let uri = entry["uri"] as? String, let url = URL(string: uri), url.isFileURL {
                return Entry(path: url.path, name: entry["name"] as? String)
            }
            return nil
        }
        let settings = (object["settings"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        self.init(folders: entries, settingsJSON: settings)
    }

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// The folders, relative paths resolved against the file's folder (`~` expanded).
    func resolvedFolders(relativeTo file: URL) -> [(url: URL, name: String?)] {
        let base = file.deletingLastPathComponent()
        var seen = Set<String>()
        return folders.compactMap { entry in
            let expanded = (entry.path as NSString).expandingTildeInPath
            let url = (expanded.hasPrefix("/") ? URL(filePath: expanded, directoryHint: .isDirectory)
                       : base.appending(path: expanded, directoryHint: .isDirectory)).standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            return (url, entry.name)
        }
    }

    /// A workspace file for `folders`, saved at `file`: paths relative to it where they can be
    /// (so the file and its folders can move together), the settings kept.
    static func make(folders: [(url: URL, name: String?)], savingAt file: URL, settingsJSON: Data?) -> WorkspaceFile {
        let base = file.deletingLastPathComponent().standardizedFileURL
        return WorkspaceFile(folders: folders.map { Entry(path: relativePath(from: base, to: $0.url), name: $0.name) },
                             settingsJSON: settingsJSON)
    }

    /// `to` from `base`: "app", "../api", or the absolute path when they share nothing but "/".
    static func relativePath(from base: URL, to url: URL) -> String {
        let from = base.standardizedFileURL.pathComponents
        let to = url.standardizedFileURL.pathComponents
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        guard common > 1 else { return url.standardizedFileURL.path }
        let up = Array(repeating: "..", count: from.count - common)
        let parts = up + to[common...]
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// The file's JSON (folders, then settings), pretty-printed.
    func data() throws -> Data {
        var object: [String: Any] = [
            "folders": folders.map { entry -> [String: Any] in
                var folder: [String: Any] = ["path": entry.path]
                if let name = entry.name { folder["name"] = name }
                return folder
            },
        ]
        if let settingsJSON, let settings = try? JSONSerialization.jsonObject(with: settingsJSON) { object["settings"] = settings }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

/// A repository the window's folders are in, with its status (a Source Control section).
struct RepositoryState: Sendable, Equatable, Identifiable {
    var repository: Git.Repository
    var status: GitStatus
    /// The window's folders in it.
    var folders: [URL]

    var id: String { repository.root.standardizedFileURL.path }
    /// The repository's folder name.
    var name: String { repository.top.lastPathComponent }
}

extension Git.Repository: Equatable {
    static func == (a: Git.Repository, b: Git.Repository) -> Bool {
        a.root == b.root && a.prefix == b.prefix && a.gitDirectory == b.gitDirectory
    }
}

extension ProjectSettings {
    /// These settings, with what they leave unset taken from `fallback` (a folder's over the
    /// workspace file's).
    func over(_ fallback: ProjectSettings) -> ProjectSettings {
        var merged = self
        merged.formatOnSave = formatOnSave ?? fallback.formatOnSave
        merged.formatOnSaveScope = formatOnSaveScope ?? fallback.formatOnSaveScope
        merged.autoSave = autoSave ?? fallback.autoSave
        merged.autoSaveDelay = autoSaveDelay ?? fallback.autoSaveDelay
        merged.wordWrap = wordWrap ?? fallback.wordWrap
        merged.renderWhitespace = renderWhitespace ?? fallback.renderWhitespace
        merged.showsInlayHints = showsInlayHints ?? fallback.showsInlayHints
        merged.semanticHighlighting = semanticHighlighting ?? fallback.semanticHighlighting
        merged.showsCodeLens = showsCodeLens ?? fallback.showsCodeLens
        merged.unknownKeys = []
        return merged
    }
}

extension Workspace {
    /// More than one folder, or a workspace file (which names the window).
    var isMultiRoot: Bool { folders.count > 1 }

    /// The window's folders with their labels (see `WorkspaceRoots`).
    var roots: WorkspaceRoots { WorkspaceRoots(urls: folders, names: folderNames) }

    /// What a folder is called in the Explorer and in labels.
    func label(of folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        return roots.folders.first { $0.url.standardizedFileURL.path == path }?.label ?? folder.lastPathComponent
    }

    /// A folder's URL as the window keeps it (one spelling per folder, to compare and key by).
    static func folderURL(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.path, directoryHint: .isDirectory)
    }

    /// The folder (of the window's) a file is in.
    func folder(containing url: URL) -> URL? { roots.folder(containing: url)?.url }

    /// The workspace's name: the workspace file's (without its extension), "Untitled
    /// (Workspace)" for several folders not saved as one, else the folder's.
    var workspaceName: String? {
        if let workspaceFile { return workspaceFile.deletingPathExtension().lastPathComponent }
        if isMultiRoot { return "Untitled (Workspace)" }
        return rootURL?.lastPathComponent
    }

    /// Whether `url` is inside one of the window's folders (links followed).
    func isInsideWorkspace(_ url: URL) -> Bool { roots.contains(url) }

    // MARK: Opening

    /// Open Folder…: a folder, or a workspace file.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder or a workspace file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if WorkspaceFile.isWorkspaceFile(url) {
            openWorkspace(file: url)
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            openFolder(url)
        } else {
            open(fileAt: url)
        }
    }

    /// Open Workspace…: asks for a workspace file.
    func presentOpenWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = WorkspaceFile.extensions.compactMap { .init(filenameExtension: $0) }
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWorkspace(file: url)
    }

    /// Opens a workspace file: its folders (those that exist) and settings.
    @discardableResult
    func openWorkspace(file: URL) -> Bool {
        let workspaceFile: WorkspaceFile
        do {
            workspaceFile = try WorkspaceFile(contentsOf: file)
        } catch {
            errorMessage = "\(file.lastPathComponent) couldn't be read: \(error.localizedDescription)"
            return false
        }
        let resolved = workspaceFile.resolvedFolders(relativeTo: file)
        let existing = resolved.filter { FileManager.default.fileExists(atPath: $0.url.path) }.map { (url: Self.folderURL($0.url), name: $0.name) }
        guard !existing.isEmpty else {
            errorMessage = "None of the folders \(file.lastPathComponent) lists exists."
            return false
        }
        let names = Dictionary(existing.compactMap { entry in entry.name.map { (entry.url, $0) } }, uniquingKeysWith: { a, _ in a })
        open(folders: existing.map(\.url), names: names, workspaceFile: file.standardizedFileURL, untitledID: nil,
             settings: workspaceFile.settings, settingsJSON: workspaceFile.settingsJSON)
        return true
    }

    /// Opens several folders as an unsaved workspace (a window restored at launch).
    func openUntitledWorkspace(folders: [URL], names: [URL: String] = [:], id: UUID) {
        open(folders: folders.map(Self.folderURL),
             names: Dictionary(names.map { (Self.folderURL($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }),
             workspaceFile: nil, untitledID: id, settings: ProjectSettings(), settingsJSON: nil)
    }

    // MARK: Adding and removing folders

    /// Add Folder to Workspace…
    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFolder(url) }
    }

    /// Adds a folder to the window (a single-folder window becomes an untitled workspace).
    func addFolder(_ url: URL, name: String? = nil) {
        let url = Self.folderURL(url)
        guard !folders.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) else { return }
        guard rootURL != nil else {
            openFolder(url)
            return
        }
        // The window's session moves to the workspace's key: the old one is let go.
        let oldKey = sessionKey
        if workspaceFile == nil, untitledWorkspaceID == nil { untitledWorkspaceID = UUID() }
        setFolders(folders + [url], names: name.map { folderNames.merging([url: $0]) { $1 } } ?? folderNames)
        if oldKey != sessionKey { SessionStore.shared.release(oldKey, windowID: id) }
        saveWorkspaceFileIfOpen()
    }

    /// Remove Folder from Workspace: the folder's open files close (asking to save).
    func removeFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard folders.count > 1, let index = folders.firstIndex(where: { $0.standardizedFileURL.path == path }) else { NSSound.beep(); return }
        let remaining = folders.enumerated().filter { $0.offset != index }.map(\.element)
        let leaving = documents.filter { document in
            WorkspaceRoots(urls: folders, names: folderNames).folder(containing: document.url)?.url == folders[index]
        }
        for document in leaving {
            for group in groups where group.contains(document.id) { close(document, in: group) }
            if documents.contains(where: { $0 === document }) { return } // cancelled
        }
        var names = folderNames
        names[folders[index]] = nil
        setFolders(remaining, names: names)
        saveWorkspaceFileIfOpen()
    }

    /// Remove Folder from Workspace… (the palette): picks one.
    func pickFolderToRemove() async {
        let roots = self.roots.folders
        let items = roots.map { QuickPickItem(label: $0.label, description: ($0.url.path as NSString).abbreviatingWithTildeInPath) }
        guard let index = await showQuickPick(items, placeholder: "Folder to remove from the workspace"),
              roots.indices.contains(index) else { return }
        removeFolder(roots[index].url)
    }

    /// Save Workspace As…: writes the folders (and settings) to a workspace file, which then
    /// names the window.
    func presentSaveWorkspacePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: WorkspaceFile.fileExtension)].compactMap { $0 }
        panel.nameFieldStringValue = (workspaceFile?.deletingPathExtension().lastPathComponent
                                      ?? rootURL?.lastPathComponent ?? "Workspace") + "." + WorkspaceFile.fileExtension
        panel.directoryURL = workspaceFile?.deletingLastPathComponent() ?? rootURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveWorkspace(as: url)
    }

    @discardableResult
    func saveWorkspace(as url: URL) -> Bool {
        let file = WorkspaceFile.make(folders: folders.map { ($0, folderNames[$0]) }, savingAt: url, settingsJSON: workspaceSettingsJSON)
        do {
            try file.data().write(to: url, options: .atomic)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let oldKey = sessionKey
        workspaceFile = url.standardizedFileURL
        untitledWorkspaceID = nil
        RecentFolders.shared.add(url)
        if oldKey != sessionKey {
            SessionStore.shared.release(oldKey, windowID: id)
            sessionSignature = nil
            keepSession(force: true)
        }
        return true
    }

    /// An opened workspace file follows the folders added and removed.
    private func saveWorkspaceFileIfOpen() {
        guard let workspaceFile else { return }
        let file = WorkspaceFile.make(folders: folders.map { ($0, folderNames[$0]) }, savingAt: workspaceFile,
                                      settingsJSON: workspaceSettingsJSON)
        do { try file.data().write(to: workspaceFile, options: .atomic) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Settings

    /// The settings for a file: its folder's `.omc/settings.json` over the workspace file's.
    func settings(for url: URL?) -> ProjectSettings {
        guard let url, let folder = folder(containing: url) else { return projectSettings }
        return (folderSettings[folder] ?? ProjectSettings()).over(workspaceSettings)
    }
}

extension SessionStore {
    /// A workspace file's key (a hash of its path), or an unsaved workspace's own.
    static func key(workspaceFile: URL) -> String {
        let digest = SHA256.hash(data: Data(FileWatcher.canonicalPath(workspaceFile).utf8))
        return "workspace-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func key(untitledWorkspace id: UUID) -> String { "untitled-" + id.uuidString }
}
