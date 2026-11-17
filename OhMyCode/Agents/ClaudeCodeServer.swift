import AppKit
import Observation
import Security

/// Lets Claude Code (the `claude` command line tool) work with this window, as it does with VS
/// Code: started in this window's terminal, or with `/ide` from a terminal in its folder, it
/// sees the open files and the selection and the workspace's problems, and shows the edits it
/// proposes as diff tabs here, to accept or reject.
///
/// How: a WebSocket server on 127.0.0.1 speaking MCP (JSON-RPC) with Claude Code's IDE tools,
/// and a lock file, `~/.claude/ide/<port>.lock` (`$CLAUDE_CONFIG_DIR/ide` when set), naming
/// the port, this window's folder and a token Claude Code must send. Terminals opened here get
/// `CLAUDE_CODE_SSE_PORT` and `ENABLE_IDE_INTEGRATION`, which make `claude` connect at once.
@MainActor
@Observable
final class ClaudeCodeServer {
    /// Claude Code sessions connected now.
    private(set) var connectedCount = 0
    private(set) var port: UInt16?

    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var server: LocalWebSocketServer?
    @ObservationIgnored private var clients: [ObjectIdentifier: Client] = [:]
    @ObservationIgnored private let authToken: String
    @ObservationIgnored private var lockURL: URL?
    @ObservationIgnored private var latestSelection: [String: Any]?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Where lock files go (tests: a scratch folder).
    nonisolated(unsafe) static var lockDirectoryOverride: URL?
    static let ideName = "Oh My Code"
    nonisolated static let headerName = "x-claude-code-ide-authorization"

    private final class Client {
        let peer: WebSocketPeer
        /// Diff tabs this connection opened, by tab name.
        var diffs: [String: DiffSession] = [:]
        var isInitialized = false
        init(peer: WebSocketPeer) { self.peer = peer }
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        authToken = Self.randomToken()
    }

    isolated deinit {
        server?.stop()
        removeLockFile()
    }

    /// The environment that makes `claude` started in a terminal connect here.
    var terminalEnvironment: [String: String] {
        guard let port else { return [:] }
        return ["CLAUDE_CODE_SSE_PORT": String(port), "ENABLE_IDE_INTEGRATION": "true"]
    }

    // MARK: Lifecycle

    func start() {
        guard server == nil else { return writeLockFile() }
        let token = authToken
        do {
            let server = try LocalWebSocketServer(subprotocols: ["mcp"]) { headers in
                headers.contains { $0.name.lowercased() == Self.headerName && Self.constantTimeEqual($0.value, token) }
            }
            server.onReady = { [weak self, weak server] port in
                // Not a server stopped meanwhile.
                guard let self, let server, self.server === server else { return }
                self.port = port
                self.writeLockFile()
            }
            server.onFailure = { [weak self, weak server] _ in
                guard let self, let server, self.server === server else { return }
                self.stop()
            }
            server.onConnect = { [weak self] peer in self?.connected(peer) }
            self.server = server
            server.start()
        } catch {
            server = nil
        }
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
            observers.append(center.addObserver(forName: EditorController.selectionDidChangeNotification, object: nil, queue: .main) { [weak self] note in
                let editor = note.object as? EditorController
                MainActor.assumeIsolated { self?.selectionChanged(in: editor) }
            })
        }
    }

    func stop() {
        for client in clients.values {
            client.peer.close()
            for diff in client.diffs.values { workspace?.closeDiffSessions { $0 === diff } }
        }
        clients = [:]
        connectedCount = 0
        server?.stop()
        server = nil
        port = nil
        removeLockFile()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        selectionTask?.cancel()
    }

    // MARK: Lock file

    static var lockDirectory: URL {
        if let lockDirectoryOverride { return lockDirectoryOverride }
        // Tests never touch the real one (a running `claude` would see their windows).
        if AppSettings.isRunningTests { return FileManager.default.temporaryDirectory.appending(path: "omc-test-claude-ide") }
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            return URL(filePath: configured).appending(path: "ide")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/ide")
    }

    /// Writes (or rewrites, the folder changed) the lock file: readable only by the user.
    func writeLockFile() {
        guard let port, let root = workspace?.rootURL else { return removeLockFile() }
        let directory = Self.lockDirectory
        let url = directory.appending(path: "\(port).lock")
        let lock: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "workspaceFolders": [root.path],
            "ideName": Self.ideName,
            "transport": "ws",
            "authToken": authToken,
        ]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: lock, options: [.sortedKeys])
            let temporary = directory.appending(path: ".\(port).lock.\(UUID().uuidString)")
            // Made 0600 from the start (FileManager sets the permissions after writing): the
            // token is never readable by others, even for a moment.
            let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return }
            let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            close(descriptor)
            guard written == data.count else { try? FileManager.default.removeItem(at: temporary); return }
            if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
            lockURL = url
        } catch {
            lockURL = nil
        }
    }

    private func removeLockFile() {
        guard let lockURL else { return }
        try? FileManager.default.removeItem(at: lockURL)
        self.lockURL = nil
    }

    // MARK: Connections

    private func connected(_ peer: WebSocketPeer) {
        let client = Client(peer: peer)
        let key = ObjectIdentifier(peer)
        clients[key] = client
        connectedCount = clients.count
        peer.onMessage = { [weak self, weak client] data in
            guard let self, let client else { return }
            self.receive(data, from: client)
        }
        peer.onClose = { [weak self] in
            guard let self, let client = self.clients.removeValue(forKey: key) else { return }
            self.connectedCount = self.clients.count
            // Its diffs go with it (each answered "rejected", to nobody).
            for diff in client.diffs.values { self.workspace?.closeDiffSessions { $0 === diff } }
        }
    }

    private func receive(_ data: Data, from client: Client) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]], to: client)
        }
        guard let method = message["method"] as? String else { return } // a response: none expected
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = message["id"], !(id is NSNull) else {
            if method == "notifications/initialized" {
                client.isInitialized = true
                if let latestSelection { notify("selection_changed", params: latestSelection, to: client) }
            }
            return // other notifications (ide_connected, …): nothing to do
        }
        Task {
            do {
                let result = try await answer(method, params: params, client: client)
                send(["jsonrpc": "2.0", "id": id, "result": result], to: client)
            } catch let error as AgentError {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]], to: client)
            } catch {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]], to: client)
            }
        }
    }

    private func send(_ message: [String: Any], to client: Client) {
        guard client.peer.isOpen, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        client.peer.send(data)
    }

    private func notify(_ method: String, params: [String: Any], to client: Client) {
        send(["jsonrpc": "2.0", "method": method, "params": params], to: client)
    }

    private func answer(_ method: String, params: [String: Any], client: Client) async throws -> Any {
        switch method {
        case "initialize":
            return [
                // The version Claude Code asks for (it's the one it speaks).
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-03-26",
                "capabilities": ["tools": ["listChanged": true], "prompts": ["listChanged": true], "logging": [String: Any]()],
                "serverInfo": ["name": "oh-my-code",
                               "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
            ] as [String: Any]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            guard let name = params["name"] as? String else { throw AgentError(code: -32602, message: "Invalid params") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return try await callTool(name, arguments, client: client)
        case "prompts/list":
            return ["prompts": [Any]()]
        case "resources/list":
            return ["resources": [Any]()]
        case "ping":
            return [String: Any]()
        default:
            throw AgentError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: Tools

    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    private static let string: [String: Any] = ["type": "string"]
    private static let boolean: [String: Any] = ["type": "boolean"]

    static let tools: [[String: Any]] = [
        tool("openFile", "Open a file in the editor, optionally selecting text in it",
             ["filePath": string, "preview": boolean, "startText": string, "endText": string,
              "selectToEndOfLine": boolean, "makeFrontmost": boolean], required: ["filePath"]),
        tool("openDiff", "Show a proposed change to a file as a diff, and wait for the user to accept or reject it",
             ["old_file_path": string, "new_file_path": string, "new_file_contents": string, "tab_name": string],
             required: ["old_file_path", "new_file_path", "new_file_contents", "tab_name"]),
        tool("getCurrentSelection", "The selection in the active editor"),
        tool("getLatestSelection", "The most recent selection in any editor"),
        tool("getOpenEditors", "The files open in the editor"),
        tool("getWorkspaceFolders", "The folders open in the editor"),
        tool("getDiagnostics", "Errors and warnings in the workspace, or in one file", ["uri": string]),
        tool("checkDocumentDirty", "Whether a file has unsaved changes", ["filePath": string], required: ["filePath"]),
        tool("saveDocument", "Save a file's unsaved changes", ["filePath": string], required: ["filePath"]),
        tool("close_tab", "Close a diff tab", ["tab_name": string], required: ["tab_name"]),
        tool("closeAllDiffTabs", "Close every diff tab opened for Claude Code"),
    ]

    private static func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }

    private static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func result(_ object: Any) -> [String: Any] { ["content": [text(json(object))]] }

    private func callTool(_ name: String, _ arguments: [String: Any], client: Client) async throws -> [String: Any] {
        guard let workspace else { throw AgentError(code: -32603, message: "The window is closed") }
        switch name {
        case "openFile":
            guard let path = arguments["filePath"] as? String else { throw AgentError(code: -32602, message: "filePath is required") }
            let url = URL(filePath: path)
            workspace.open(fileAt: url)
            guard let document = workspace.document(matching: url) else {
                return ["content": [Self.text("Couldn't open \(path)")], "isError": true]
            }
            if let start = arguments["startText"] as? String, !start.isEmpty {
                select(start, until: arguments["endText"] as? String,
                       toEndOfLine: arguments["selectToEndOfLine"] as? Bool ?? false, in: document)
            }
            if arguments["makeFrontmost"] as? Bool ?? true {
                workspace.window?.makeKeyAndOrderFront(nil)
                return ["content": [Self.text("Opened file: \(path)")]]
            }
            return Self.result(["success": true, "filePath": url.path, "languageId": document.languageId,
                                "lineCount": document.lineIndex.lineCount])
        case "openDiff":
            guard let oldPath = arguments["old_file_path"] as? String, let newPath = arguments["new_file_path"] as? String,
                  let contents = arguments["new_file_contents"] as? String else {
                throw AgentError(code: -32602, message: "old_file_path, new_file_path and new_file_contents are required")
            }
            let tabName = arguments["tab_name"] as? String ?? URL(filePath: newPath).lastPathComponent
            return await openDiff(old: URL(filePath: oldPath), new: URL(filePath: newPath), contents: contents,
                                  tabName: tabName, client: client)
        case "getCurrentSelection":
            guard let editor = workspace.activeDocument?.editor else {
                return Self.result(["success": false, "message": "No active editor found"])
            }
            return Self.result(selection(in: editor))
        case "getLatestSelection":
            guard let latestSelection else { return Self.result(["success": false, "message": "No selection available"]) }
            return Self.result(latestSelection)
        case "getOpenEditors":
            let active = workspace.activeDocument
            let tabs: [[String: Any]] = workspace.documents.map { document in
                ["uri": document.url.absoluteString, "isActive": document === active, "label": document.fileName,
                 "languageId": document.languageId, "isDirty": document.isDirty]
            }
            return Self.result(["tabs": tabs])
        case "getWorkspaceFolders":
            guard let root = workspace.rootURL else { return Self.result(["success": true, "folders": [Any](), "rootPath": ""]) }
            return Self.result(["success": true, "rootPath": root.path,
                                "folders": [["name": root.lastPathComponent, "uri": root.absoluteString, "path": root.path]]])
        case "getDiagnostics":
            var files = workspace.problems.files()
            if let uri = arguments["uri"] as? String, let url = URL(string: uri) {
                let wanted = FileWatcher.canonicalPath(url.isFileURL ? url : URL(filePath: uri))
                files = files.filter { FileWatcher.canonicalPath($0.url) == wanted }
            }
            return Self.result(files.map { file in
                ["uri": file.url.absoluteString, "diagnostics": file.diagnostics.map { diagnostic in
                    var entry: [String: Any] = ["message": diagnostic.message, "severity": Self.severity(diagnostic.severity),
                                                "range": diagnostic.range.json]
                    if let source = diagnostic.source { entry["source"] = source }
                    return entry
                }] as [String: Any]
            })
        case "checkDocumentDirty":
            guard let path = arguments["filePath"] as? String else { throw AgentError(code: -32602, message: "filePath is required") }
            guard let document = workspace.document(matching: URL(filePath: path)) else {
                return Self.result(["success": false, "message": "Document not open: \(path)"])
            }
            return Self.result(["success": true, "filePath": path, "isDirty": document.isDirty, "isUntitled": false])
        case "saveDocument":
            guard let path = arguments["filePath"] as? String else { throw AgentError(code: -32602, message: "filePath is required") }
            guard let document = workspace.document(matching: URL(filePath: path)) else {
                return Self.result(["success": false, "message": "Document not open: \(path)"])
            }
            guard workspace.save(document) else { return Self.result(["success": false, "message": "Couldn't save \(path)"]) }
            return Self.result(["success": true, "filePath": path, "saved": true, "message": "Document saved successfully"])
        case "close_tab":
            if let tabName = arguments["tab_name"] as? String, let diff = client.diffs.removeValue(forKey: tabName) {
                workspace.closeDiffSessions { $0 === diff }
            }
            return ["content": [Self.text("TAB_CLOSED")]]
        case "closeAllDiffTabs":
            // The ones still open (the user may have closed some).
            let diffs = client.diffs.values.filter { diff in workspace.diffSessions.contains { $0 === diff } }
            client.diffs = [:]
            for diff in diffs { workspace.closeDiffSessions { $0 === diff } }
            return ["content": [Self.text("CLOSED_\(diffs.count)_DIFF_TABS")]]
        default:
            throw AgentError(code: -32602, message: "Unknown tool: \(name)")
        }
    }

    private static func severity(_ severity: Diagnostic.Severity) -> String {
        switch severity {
        case .error: "Error"
        case .warning: "Warning"
        case .information: "Information"
        case .hint: "Hint"
        }
    }

    /// Shows the change as a diff tab and waits: `FILE_SAVED` (and the text) when accepted —
    /// Claude Code writes the file itself — or `DIFF_REJECTED`.
    private func openDiff(old: URL, new: URL, contents: String, tabName: String, client: Client) async -> [String: Any] {
        // A connection that went before this ran: nobody would answer its tab.
        guard let workspace, clients[ObjectIdentifier(client.peer)] === client else {
            return ["content": [Self.text("DIFF_REJECTED"), Self.text(tabName)]]
        }
        // The same tab again replaces it (the earlier one is answered "rejected").
        for other in clients.values {
            if let previous = other.diffs.removeValue(forKey: tabName) { workspace.closeDiffSessions { $0 === previous } }
        }
        let current = (try? workspace.agentReadText(old)) ?? nil
        let accepted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let change = ProposedChange(title: tabName, source: "Claude Code", old: current, new: contents)
            let session = workspace.showProposedChange(change, for: new) { continuation.resume(returning: $0) }
            client.diffs[tabName] = session
            workspace.window?.makeKeyAndOrderFront(nil)
        }
        return accepted
            ? ["content": [Self.text("FILE_SAVED"), Self.text(contents)]]
            : ["content": [Self.text("DIFF_REJECTED"), Self.text(tabName)]]
    }

    private func select(_ start: String, until end: String?, toEndOfLine: Bool, in document: EditorDocument) {
        let text = document.textStorage.mutableString
        let found = text.range(of: start)
        guard found.location != NSNotFound else { return }
        var upper = NSMaxRange(found)
        if let end, !end.isEmpty {
            let after = text.range(of: end, options: [], range: NSRange(location: found.location, length: text.length - found.location))
            if after.location != NSNotFound { upper = NSMaxRange(after) }
        }
        if toEndOfLine {
            let line = text.lineRange(for: NSRange(location: upper, length: 0))
            upper = max(upper, NSMaxRange(line) - (NSMaxRange(line) > line.location && text.character(at: NSMaxRange(line) - 1) == 0x0A ? 1 : 0))
        }
        document.reveal(NSRange(location: found.location, length: upper - found.location))
    }

    // MARK: Selection

    /// The editor's selection, as Claude Code reads it: 0-based lines, UTF-16 characters, the
    /// end exclusive.
    func selection(in editor: EditorController) -> [String: Any] {
        let document = editor.document
        let text = document.textStorage.mutableString
        var range = editor.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        if range.location == NSNotFound || NSMaxRange(range) > text.length { range = NSRange(location: 0, length: 0) }
        let index = document.lineIndex
        func position(_ offset: Int) -> [String: Any] {
            let line = index.line(containing: offset)
            return ["line": line, "character": offset - index.lineStarts[line]]
        }
        return [
            "success": true,
            "text": text.substring(with: range),
            "filePath": document.url.path,
            "fileUrl": document.url.absoluteString,
            "selection": ["start": position(range.location), "end": position(NSMaxRange(range)), "isEmpty": range.length == 0] as [String: Any],
        ]
    }

    /// A selection moved in one of this window's editors: Claude Code hears of it shortly after
    /// it stops moving.
    private func selectionChanged(in editor: EditorController?) {
        guard let editor, let workspace, workspace.documents.contains(where: { $0 === editor.document }),
              editor.document === workspace.activeDocument else { return }
        selectionTask?.cancel()
        selectionTask = Task { [weak self, weak editor] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self, let editor else { return }
            var params = self.selection(in: editor)
            params["success"] = nil
            self.latestSelection = params.merging(["success": true]) { $1 }
            for client in self.clients.values where client.isInitialized {
                self.notify("selection_changed", params: params, to: client)
            }
        }
    }

    /// Sends the active editor's selected lines to Claude Code (it adds them to the prompt as
    /// `@file#L…`). Returns false with no Claude Code connected.
    @discardableResult
    func sendSelection() -> Bool {
        guard let editor = workspace?.activeDocument?.editor, !clients.isEmpty else { return false }
        let document = editor.document
        let text = document.textStorage.mutableString
        var range = editor.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        if range.location == NSNotFound || NSMaxRange(range) > text.length { range = NSRange(location: 0, length: 0) }
        let first = document.lineIndex.line(containing: range.location)
        var end = NSMaxRange(range)
        if range.length > 0, text.character(at: end - 1) == 0x0A { end -= 1 }
        let last = document.lineIndex.line(containing: end)
        for client in clients.values where client.isInitialized {
            notify("at_mentioned", params: ["filePath": document.url.path, "lineStart": first, "lineEnd": max(first, last)], to: client)
        }
        return true
    }

    // MARK: Helpers

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: 0...255) } // SystemRandomNumberGenerator: also a CSPRNG
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }
}
