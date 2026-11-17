import AppKit
import SwiftUI

/// Something to open, from Finder, the Dock, `open`, the `omc` command or a drop: a folder, or
/// a file (at a line).
struct OpenRequest: Equatable {
    var url: URL
    /// 1-based.
    var line: Int?
    var column: Int?
    /// `omc -n`: always a new window.
    var newWindow = false
    /// `omc -r`: the frontmost window, even for a file outside its folder.
    var reuseWindow = false
    /// An unsaved workspace coming back at launch (`url` is its first folder).
    var workspace: UntitledWorkspace?

    struct UntitledWorkspace: Equatable {
        var id: UUID
        var folders: [URL]
        var names: [URL: String]
    }

    static let scheme = "ohmycode"

    /// The same path (however the URL was made) and the same options.
    static func == (a: OpenRequest, b: OpenRequest) -> Bool {
        a.url.standardizedFileURL.path == b.url.standardizedFileURL.path && a.line == b.line && a.column == b.column
            && a.newWindow == b.newWindow && a.reuseWindow == b.reuseWindow && a.workspace == b.workspace
    }

    /// A workspace file (`.omc-workspace`, `.code-workspace`): opened as the window's folders.
    var isWorkspaceFile: Bool { workspace == nil && WorkspaceFile.isWorkspaceFile(url) && !isDirectory }

    var isDirectory: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    init(url: URL, line: Int? = nil, column: Int? = nil, newWindow: Bool = false, reuseWindow: Bool = false) {
        self.url = url
        self.line = line
        self.column = column
        self.newWindow = newWindow
        self.reuseWindow = reuseWindow
    }

    /// A file URL, or `ohmycode://open?path=/abs/path&line=12&column=3&new=1&reuse=1`.
    init?(external url: URL) {
        if url.isFileURL {
            self.init(url: url.standardizedFileURL, line: nil)
            return
        }
        guard url.scheme?.lowercased() == Self.scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        self.init(url: URL(filePath: path).standardizedFileURL,
                  line: value("line").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil },
                  column: value("column").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil },
                  newWindow: value("new") == "1", reuseWindow: value("reuse") == "1")
    }

    /// The URL the `omc` command sends for this request.
    var commandURL: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "open"
        var items = [URLQueryItem(name: "path", value: url.path)]
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        if let column { items.append(URLQueryItem(name: "column", value: String(column))) }
        if newWindow { items.append(URLQueryItem(name: "new", value: "1")) }
        if reuseWindow { items.append(URLQueryItem(name: "reuse", value: "1")) }
        components.queryItems = items
        return components.url!
    }
}

/// Decides which window opens a request, and opens it.
@MainActor
final class OpenRouter {
    static let shared = OpenRouter()

    /// Every window's workspace (weak).
    private let workspaces = NSHashTable<Workspace>.weakObjects()
    /// Opens a new window for a URL (set by the first window shown).
    var openWindow: ((URL) -> Void)?
    /// Requests waiting for a window: a new window takes its own; any window takes the rest.
    private var pending: [OpenRequest] = []
    private var pendingForNewWindow: [String: OpenRequest] = [:]
    /// A first window was asked for (several requests at launch make one, not one each).
    private var awaitingFirstWindow = false

    func register(_ workspace: Workspace) {
        workspaces.add(workspace)
        awaitingFirstWindow = false
        if !pending.isEmpty {
            let requests = pending
            pending = []
            requests.forEach(open)
        }
    }

    var allWorkspaces: [Workspace] { workspaces.allObjects }

    enum Decision: Equatable {
        /// Already open there: bring it forward (and go to the line).
        case focus(ObjectIdentifier)
        /// Open it in this window.
        case openIn(ObjectIdentifier)
        case newWindow
    }

    /// Where a request goes, given the windows (the key window first).
    static func route(_ request: OpenRequest, isDirectory: Bool, workspaces: [Workspace]) -> Decision {
        let path = FileWatcher.canonicalPath(request.url)
        let isEmpty: (Workspace) -> Bool = { $0.rootURL == nil && $0.documents.isEmpty }
        // A workspace (file, or unsaved coming back): the window showing it, else like a folder.
        if request.workspace != nil || request.isWorkspaceFile {
            let shows: (Workspace) -> Bool = { workspace in
                if let id = request.workspace?.id { return workspace.untitledWorkspaceID == id }
                return workspace.workspaceFile.map(FileWatcher.canonicalPath) == path
            }
            if !request.newWindow, let existing = workspaces.first(where: shows) { return .focus(ObjectIdentifier(existing)) }
            if !request.newWindow, let empty = workspaces.first(where: isEmpty) { return .openIn(ObjectIdentifier(empty)) }
            if request.reuseWindow, let front = workspaces.first { return .openIn(ObjectIdentifier(front)) }
            return .newWindow
        }
        if isDirectory {
            // A plain folder window showing it (a workspace's folder opens a window of its own).
            if !request.newWindow, let existing = workspaces.first(where: {
                $0.workspaceFile == nil && $0.untitledWorkspaceID == nil && $0.rootURL.map(FileWatcher.canonicalPath) == path
            }) {
                return .focus(ObjectIdentifier(existing))
            }
            if !request.newWindow, let empty = workspaces.first(where: isEmpty) { return .openIn(ObjectIdentifier(empty)) }
            if request.reuseWindow, let front = workspaces.first { return .openIn(ObjectIdentifier(front)) }
            return .newWindow
        }
        if !request.newWindow {
            if let owner = workspaces.first(where: { workspace in
                workspace.folders.contains { path.hasPrefix(FileWatcher.canonicalPath($0) + "/") }
            }) {
                return .focus(ObjectIdentifier(owner))
            }
            if let open = workspaces.first(where: { $0.document(matching: request.url) != nil }) { return .focus(ObjectIdentifier(open)) }
            if request.reuseWindow, let front = workspaces.first { return .openIn(ObjectIdentifier(front)) }
            if let empty = workspaces.first(where: isEmpty) { return .openIn(ObjectIdentifier(empty)) }
        }
        return .newWindow
    }

    /// Windows, the key one first, then front to back.
    private var orderedWorkspaces: [Workspace] {
        let order = NSApp.orderedWindows
        return workspaces.allObjects.sorted { a, b in
            if a.window?.isKeyWindow == true { return true }
            if b.window?.isKeyWindow == true { return false }
            return (a.window.flatMap { order.firstIndex(of: $0) } ?? .max) < (b.window.flatMap { order.firstIndex(of: $0) } ?? .max)
        }
    }

    func open(_ request: OpenRequest) {
        let isDirectory = request.isDirectory
        guard isDirectory || FileManager.default.fileExists(atPath: request.url.path) else {
            NSSound.beep()
            return
        }
        let candidates = orderedWorkspaces
        if candidates.isEmpty, openWindow == nil {
            // Launched to open it: SwiftUI shows no window then. The first one takes it.
            pending.append(request)
            if !awaitingFirstWindow {
                awaitingFirstWindow = true
                Self.newWindowFromMenu()
            }
            return
        }
        switch Self.route(request, isDirectory: isDirectory, workspaces: candidates) {
        case .focus(let id), .openIn(let id):
            guard let workspace = candidates.first(where: { ObjectIdentifier($0) == id }) else { return }
            apply(request, isDirectory: isDirectory, in: workspace)
        case .newWindow:
            guard let openWindow else { pending.append(request); return }
            pendingForNewWindow[request.url.path] = request
            openWindow(request.url)
            // A window already showing that URL is brought forward instead of a new one made:
            // nothing takes the request then, so it goes to that window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.settleUntaken(request) }
            }
        }
    }

    /// A request for a new window that no window took (see above).
    private func settleUntaken(_ request: OpenRequest) {
        guard pendingForNewWindow[request.url.path] == request else { return }
        var reused = request
        reused.newWindow = false
        let candidates = orderedWorkspaces
        guard case .focus(let id) = Self.route(reused, isDirectory: request.isDirectory, workspaces: candidates),
              let workspace = candidates.first(where: { ObjectIdentifier($0) == id }) else { return }
        pendingForNewWindow[request.url.path] = nil
        apply(request, in: workspace)
    }

    /// File → New (⌘N), as if chosen: a window when there's none to call `openWindow` from.
    private static func newWindowFromMenu() {
        DispatchQueue.main.async {
            func find(_ menu: NSMenu?) -> (NSMenu, Int)? {
                guard let menu else { return nil }
                for (index, item) in menu.items.enumerated() {
                    if item.keyEquivalent == "n", item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command,
                       item.action != nil { return (menu, index) }
                    if let found = find(item.submenu) { return found }
                }
                return nil
            }
            if let (menu, index) = find(NSApp.mainMenu) { menu.performActionForItem(at: index) }
        }
    }

    /// A window opened for a URL: what it should do with it.
    func takeRequest(for url: URL) -> OpenRequest {
        pendingForNewWindow.removeValue(forKey: url.path) ?? OpenRequest(url: url)
    }

    /// Opens a request in a window.
    func apply(_ request: OpenRequest, isDirectory: Bool? = nil, in workspace: Workspace) {
        workspace.window?.makeKeyAndOrderFront(nil)
        if !LaunchTrace.isEnabled { NSApp.activate() } // a traced launch takes no focus
        if let untitled = request.workspace {
            if workspace.untitledWorkspaceID != untitled.id {
                workspace.openUntitledWorkspace(folders: untitled.folders, names: untitled.names, id: untitled.id)
            }
            return
        }
        if request.isWorkspaceFile {
            if workspace.workspaceFile.map(FileWatcher.canonicalPath) != FileWatcher.canonicalPath(request.url) {
                workspace.openWorkspace(file: request.url)
            }
            return
        }
        if isDirectory ?? request.isDirectory {
            if workspace.rootURL.map(FileWatcher.canonicalPath) != FileWatcher.canonicalPath(request.url) {
                workspace.openFolder(request.url)
            }
            return
        }
        let url = workspace.workspaceURL(for: request.url)
        workspace.open(fileAt: url)
        // Only the file just opened goes to the line (it may not have opened: not text, gone).
        guard let document = workspace.activeDocument, workspace.document(matching: url) === document else { return }
        if let line = request.line {
            let index = min(max(line, 1), document.lineIndex.lineCount) - 1
            let start = document.lineIndex.lineStarts[index]
            let end = index + 1 < document.lineIndex.lineCount ? document.lineIndex.lineStarts[index + 1] - 1 : document.textStorage.length
            let column = min(max((request.column ?? 1) - 1, 0), end - start)
            document.reveal(NSRange(location: start + column, length: 0))
        }
        document.editor?.focus()
    }
}

/// Folders opened lately (File → Open Recent, the welcome screen, the Dock menu).
@MainActor
@Observable
final class RecentFolders {
    static let shared = RecentFolders(defaults: AppSettings.isRunningTests ? ScratchDefaults.named("recent") : .standard)
    static let limit = 15
    private let defaults: UserDefaults
    private(set) var urls: [URL]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        urls = (defaults.stringArray(forKey: "recentFolders") ?? []).map { URL(filePath: $0) }
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        urls.removeAll { $0.path == path }
        urls.insert(URL(filePath: path), at: 0)
        if urls.count > Self.limit { urls.removeLast(urls.count - Self.limit) }
        save()
        if !AppSettings.isRunningTests { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }

    func remove(_ url: URL) {
        urls.removeAll { $0.path == url.path }
        save()
    }

    func clear() {
        urls = []
        save()
        if !AppSettings.isRunningTests { NSDocumentController.shared.clearRecentDocuments(nil) }
    }

    /// Those that still exist.
    var existing: [URL] { urls.filter { FileManager.default.fileExists(atPath: $0.path) } }

    /// A recent entry's icon: a folder, or a workspace file's.
    static func symbol(for url: URL) -> String {
        WorkspaceFile.isWorkspaceFile(url) ? "square.stack.3d.up" : "folder"
    }

    /// A recent entry's name: a workspace file's without its extension, marked as a workspace.
    static func title(for url: URL) -> String {
        WorkspaceFile.isWorkspaceFile(url) ? url.deletingPathExtension().lastPathComponent + " (Workspace)" : url.lastPathComponent
    }

    private func save() { defaults.set(urls.map(\.path), forKey: "recentFolders") }
}

/// Files and URLs from outside (Finder, the Dock, `open`, the `omc` command).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if let request = OpenRequest(external: url) { OpenRouter.shared.open(request) }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            LaunchTrace.mark("app.didFinishLaunching")
            guard !AppSettings.isRunningTests, AppSettings.shared.hotExit else { return }
            Workspace.reopenLastSessions { OpenRouter.shared.open($0) }
        }
    }

    /// Hot exit: the windows' sessions are kept, nothing asked; with it off, unsaved changes are.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            Workspace.prepareToQuit(OpenRouter.shared.allWorkspaces) ? .terminateNow : .terminateCancel
        }
    }

    /// Leaving the app: auto save on focus change.
    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { OpenRouter.shared.allWorkspaces.forEach { $0.focusChanged() } }
    }

    /// Clicking the Dock icon with no window open: a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }
}
