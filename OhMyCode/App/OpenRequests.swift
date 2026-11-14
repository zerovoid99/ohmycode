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

    static let scheme = "ohmycode"

    /// The same path (however the URL was made) and the same options.
    static func == (a: OpenRequest, b: OpenRequest) -> Bool {
        a.url.standardizedFileURL.path == b.url.standardizedFileURL.path && a.line == b.line && a.column == b.column
            && a.newWindow == b.newWindow && a.reuseWindow == b.reuseWindow
    }

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

    func register(_ workspace: Workspace) {
        workspaces.add(workspace)
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
        if isDirectory {
            if !request.newWindow,
               let existing = workspaces.first(where: { $0.rootURL.map(FileWatcher.canonicalPath) == path }) {
                return .focus(ObjectIdentifier(existing))
            }
            if !request.newWindow, let empty = workspaces.first(where: isEmpty) { return .openIn(ObjectIdentifier(empty)) }
            if request.reuseWindow, let front = workspaces.first { return .openIn(ObjectIdentifier(front)) }
            return .newWindow
        }
        if !request.newWindow {
            if let owner = workspaces.first(where: { workspace in
                workspace.rootURL.map { path.hasPrefix(FileWatcher.canonicalPath($0) + "/") } ?? false
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
            Self.newWindowFromMenu()
            return
        }
        switch Self.route(request, isDirectory: isDirectory, workspaces: candidates) {
        case .focus(let id), .openIn(let id):
            guard let workspace = candidates.first(where: { ObjectIdentifier($0) == id }) else { return }
            apply(request, isDirectory: isDirectory, in: workspace)
        case .newWindow:
            pendingForNewWindow[request.url.path] = request
            if let openWindow { openWindow(request.url) } else { pending.append(request) }
        }
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
        NSApp.activate()
        if isDirectory ?? request.isDirectory {
            if workspace.rootURL.map(FileWatcher.canonicalPath) != FileWatcher.canonicalPath(request.url) {
                workspace.openFolder(request.url)
            }
            return
        }
        workspace.open(fileAt: workspace.workspaceURL(for: request.url))
        guard let document = workspace.activeDocument else { return }
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
    static let shared = RecentFolders(defaults: AppSettings.isRunningTests ? UserDefaults(suiteName: "omc-tests-recent-\(ProcessInfo.processInfo.processIdentifier)")! : .standard)
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

    /// Clicking the Dock icon with no window open: a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }
}
