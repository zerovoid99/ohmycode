import AppKit
import Network
import Testing
@testable import Oh_My_Code

/// Claude Code's IDE integration, from the other side: a WebSocket client as `claude` is, with
/// the lock file's port and token.
@MainActor
@Suite(.serialized)
struct ClaudeCodeServerTests {
    private func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// A Claude Code stand-in: JSON-RPC over a WebSocket.
    @MainActor
    private final class FakeClaude {
        let task: URLSessionWebSocketTask
        private var nextID = 1
        /// Messages without an id (notifications), in order.
        var notifications: [[String: Any]] = []
        private var responses: [Int: [String: Any]] = [:]
        private(set) var closed = false

        init(port: UInt16, token: String?) {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
            if let token { request.setValue(token, forHTTPHeaderField: "x-claude-code-ide-authorization") }
            // As Claude Code does: it gives up on a server that doesn't pick this.
            request.setValue("mcp", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            task = URLSession.shared.webSocketTask(with: request)
            task.resume()
            receive()
        }

        private func receive() {
            task.receive { [weak self] result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success(.string(let text)):
                        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                        if let id = object["id"] as? Int { self.responses[id] = object } else { self.notifications.append(object) }
                        self.receive()
                    case .success:
                        self.receive()
                    case .failure:
                        self.closed = true
                    }
                    }
                }
            }
        }

        func send(_ method: String, _ params: [String: Any] = [:], notification: Bool = false) -> Int {
            var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            let id = nextID
            if !notification { message["id"] = id; nextID += 1 }
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            task.send(.string(text)) { _ in }
            return id
        }

        func response(_ id: Int) -> [String: Any]? { responses[id] }

        func close() { task.cancel(with: .goingAway, reason: nil) }
    }

    private func call(_ claude: FakeClaude, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = claude.send(method, params)
        _ = try await eventually { claude.response(id) != nil }
        return try #require(claude.response(id))
    }

    /// A tool's result: its first text, and that text parsed as JSON (when it is).
    private func tool(_ claude: FakeClaude, _ name: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, json: Any?) {
        let response = try await call(claude, "tools/call", ["name": name, "arguments": arguments])
        let content = (response["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        let text = content.first?["text"] as? String ?? ""
        return (text, try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    private struct Fixture {
        let workspace: Workspace
        let root: URL
        let lockDirectory: URL
        let document: EditorDocument
        let controller: EditorController
        let window: NSWindow
    }

    private func makeFixture() throws -> Fixture {
        let lockDirectory = FileManager.default.temporaryDirectory.appending(path: "omc-claude-ide-\(UUID().uuidString)")
        ClaudeCodeServer.lockDirectoryOverride = lockDirectory
        AgentStore.shared.claudeCodeIntegration = true
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "let a = 1\nlet b = 2\nlet c = 3\n", files: ["other.swift": "old\n"])
        return Fixture(workspace: workspace, root: try #require(workspace.rootURL), lockDirectory: lockDirectory,
                       document: document, controller: controller, window: window)
    }

    private func tearDown(_ fixture: Fixture) {
        fixture.workspace.claudeCode.stop()
        AgentStore.shared.claudeCodeIntegration = false
        ClaudeCodeServer.lockDirectoryOverride = nil
        try? FileManager.default.removeItem(at: fixture.lockDirectory)
    }

    /// The lock file the server wrote: its port and contents.
    private func lockFile(_ fixture: Fixture) async throws -> (port: UInt16, lock: [String: Any]) {
        #expect(try await eventually { fixture.workspace.claudeCode.port != nil })
        let port = try #require(fixture.workspace.claudeCode.port)
        let url = fixture.lockDirectory.appending(path: "\(port).lock")
        #expect(try await eventually { FileManager.default.fileExists(atPath: url.path) })
        let lock = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        return (port, lock)
    }

    private func connect(_ fixture: Fixture) async throws -> FakeClaude {
        let (port, lock) = try await lockFile(fixture)
        let claude = FakeClaude(port: port, token: lock["authToken"] as? String)
        let initialized = try await call(claude, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                                 "clientInfo": ["name": "claude-code", "version": "2"]])
        let result = try #require(initialized["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        _ = claude.send("notifications/initialized", notification: true)
        #expect(try await eventually { fixture.workspace.claudeCode.connectedCount == 1 })
        return claude
    }

    @Test func writesALockFileAndTakesOnlyItsToken() async throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }
        let (port, lock) = try await lockFile(fixture)
        #expect(lock["workspaceFolders"] as? [String] == [fixture.root.path])
        #expect(lock["ideName"] as? String == "Oh My Code" && lock["transport"] as? String == "ws")
        #expect(lock["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
        let token = try #require(lock["authToken"] as? String)
        #expect(token.count == 32 && token.allSatisfy(\.isHexDigit))
        #expect(fixture.workspace.claudeCode.terminalEnvironment == ["CLAUDE_CODE_SSE_PORT": String(port), "ENABLE_IDE_INTEGRATION": "true"])

        // Without the token, or with another, the connection is refused.
        for wrong in [nil, String(repeating: "0", count: 32)] {
            let intruder = FakeClaude(port: port, token: wrong)
            #expect(try await eventually { intruder.closed })
        }
        #expect(fixture.workspace.claudeCode.connectedCount == 0)

        // Turned off: the lock file goes.
        AgentStore.shared.claudeCodeIntegration = false
        #expect(!FileManager.default.fileExists(atPath: fixture.lockDirectory.appending(path: "\(port).lock").path))
        #expect(fixture.workspace.claudeCode.port == nil)
    }

    /// The HTTP response to a hand-written upgrade request.
    private func handshake(port: UInt16, headers: [String: String]) async throws -> String {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: .global())
        var request = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        connection.send(content: Data((request + "\r\n").utf8), completion: .contentProcessed { _ in })
        let data: Data? = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 12, maximumLength: 4096) { data, _, _, _ in continuation.resume(returning: data) }
        }
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    @Test func theHandshakePicksTheMCPSubprotocol() async throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }
        let (port, lock) = try await lockFile(fixture)
        let token = try #require(lock["authToken"] as? String)
        // Claude Code offers "mcp" and gives up on a server that doesn't pick it.
        let accepted = try await handshake(port: port, headers: ["x-claude-code-ide-authorization": token,
                                                                 "Sec-WebSocket-Protocol": "mcp"])
        #expect(accepted.hasPrefix("HTTP/1.1 101"))
        #expect(accepted.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n")) // RFC 6455's example
        #expect(accepted.contains("Sec-WebSocket-Protocol: mcp\r\n"))
        let refused = try await handshake(port: port, headers: ["Sec-WebSocket-Protocol": "mcp"])
        #expect(refused.hasPrefix("HTTP/1.1 401"))
    }

    /// A connection that passed the handshake, for writing frames by hand.
    private func upgraded(port: UInt16, token: String) async throws -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        let request = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\(ClaudeCodeServer.headerName): \(token)\r\n\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        let head: Data? = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 12, maximumLength: 4096) { data, _, _, _ in continuation.resume(returning: data) }
        }
        #expect(String(decoding: head ?? Data(), as: UTF8.self).hasPrefix("HTTP/1.1 101"))
        return connection
    }

    /// A client's (masked) frame.
    private func frame(_ opcode: UInt8, final: Bool = true, _ payload: [UInt8] = []) -> Data {
        var bytes: [UInt8] = [(final ? 0x80 : 0) | opcode]
        if payload.count < 126 { bytes.append(0x80 | UInt8(payload.count)) } else { bytes += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] }
        let mask: [UInt8] = [1, 2, 3, 4]
        return Data(bytes + mask + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
    }

    /// Everything the server sends from now until it closes the connection (nil: it didn't).
    private func untilClosed(_ connection: NWConnection, timeout: Duration = .seconds(5)) async -> Data? {
        final class Box: @unchecked Sendable { var data = Data(); var closed = false }
        let box = Box()
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                DispatchQueue.main.async {
                    if let data { box.data.append(data) }
                    if isComplete || error != nil { box.closed = true } else { receive() }
                }
            }
        }
        receive()
        let deadline = ContinuousClock.now + timeout
        while !box.closed, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return box.closed ? box.data : nil
    }

    private static let protocolError = Data([0x88, 0x02, 0x03, 0xEA]) // close, 1002

    @Test func breachesOfTheProtocolCloseTheConnection() async throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }
        let (port, lock) = try await lockFile(fixture)
        let token = try #require(lock["authToken"] as? String)
        let longPing = frame(0x9, Array(repeating: 0x61, count: 126))
        let cases: [(String, Data)] = [
            ("a fragmented ping", frame(0x9, final: false, [0x61])),
            ("a ping over 125 bytes", longPing),
            ("a new message during a fragmented one", frame(0x1, final: false, [0x61]) + frame(0x1, [0x62])),
        ]
        for (name, bytes) in cases {
            let connection = try await upgraded(port: port, token: token)
            defer { connection.cancel() }
            connection.send(content: bytes, completion: .contentProcessed { _ in })
            let received = await untilClosed(connection)
            #expect(received == Self.protocolError, "\(name)")
        }

        // After a close frame, what comes is dropped: never read as another HTTP request.
        let connection = try await upgraded(port: port, token: token)
        defer { connection.cancel() }
        let again = "GET / HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\(ClaudeCodeServer.headerName): \(token)\r\n\r\n"
        connection.send(content: frame(0x8, [0x03, 0xE8]) + Data(again.utf8), completion: .contentProcessed { _ in })
        let received = try #require(await untilClosed(connection))
        #expect(received == Data([0x88, 0x02, 0x03, 0xE8]))
    }

    @Test func aConnectionThatNeverUpgradesIsClosed() async throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }
        WebSocketPeer.handshakeTimeout = 0.3
        defer { WebSocketPeer.handshakeTimeout = 10 }
        let (port, lock) = try await lockFile(fixture)
        let idle = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { idle.cancel() }
        idle.start(queue: .global())
        idle.send(content: Data("GET / HTTP/1.1\r\n".utf8), completion: .contentProcessed { _ in })
        #expect(await untilClosed(idle) == Data())

        // Stopping the server cuts the connections it has.
        let open = try await upgraded(port: port, token: try #require(lock["authToken"] as? String))
        defer { open.cancel() }
        fixture.workspace.claudeCode.stop()
        #expect(await untilClosed(open) != nil)
    }

    @Test func answersTheIDETools() async throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }
        let claude = try await connect(fixture)
        defer { claude.close() }

        let list = try await call(claude, "tools/list")
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(Set(names).isSuperset(of: ["openFile", "openDiff", "getCurrentSelection", "getOpenEditors",
                                           "getWorkspaceFolders", "getDiagnostics", "checkDocumentDirty", "saveDocument",
                                           "close_tab", "closeAllDiffTabs"]))

        let folders = try #require(try await tool(claude, "getWorkspaceFolders").json as? [String: Any])
        #expect(folders["rootPath"] as? String == fixture.root.path)

        // The selection: 0-based lines, the end exclusive.
        fixture.controller.textView.setSelectedRange(NSRange(location: 14, length: 9)) // "b = 2\nlet"
        let selection = try #require(try await tool(claude, "getCurrentSelection").json as? [String: Any])
        #expect(selection["text"] as? String == "b = 2\nlet")
        let range = try #require(selection["selection"] as? [String: Any])
        #expect((range["start"] as? [String: Int]) == ["line": 1, "character": 4])
        #expect((range["end"] as? [String: Int]) == ["line": 2, "character": 3])

        // Unsaved changes, then saved.
        let main = fixture.document.url.path
        fixture.document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// x\n")
        #expect((try await tool(claude, "checkDocumentDirty", ["filePath": main]).json as? [String: Any])?["isDirty"] as? Bool == true)
        let tabs = (try await tool(claude, "getOpenEditors").json as? [String: Any])?["tabs"] as? [[String: Any]]
        #expect(tabs?.first?["isDirty"] as? Bool == true && tabs?.first?["isActive"] as? Bool == true)
        #expect((try await tool(claude, "saveDocument", ["filePath": main]).json as? [String: Any])?["saved"] as? Bool == true)
        #expect(try String(contentsOfFile: main, encoding: .utf8).hasPrefix("// x\n"))
        let notOpen = try await tool(claude, "checkDocumentDirty", ["filePath": fixture.root.appending(path: "nope.swift").path])
        #expect((notOpen.json as? [String: Any])?["success"] as? Bool == false)

        // Problems, all or one file's.
        fixture.workspace.problems.set([Diagnostic(range: LSPRange(start: LSPPosition(line: 2, character: 4), end: LSPPosition(line: 2, character: 5)),
                                                   severity: .warning, message: "unused", source: "test")],
                                       for: fixture.document.url, source: "test")
        let all = try #require(try await tool(claude, "getDiagnostics").json as? [[String: Any]])
        let first = (all.first?["diagnostics"] as? [[String: Any]])?.first
        #expect(first?["message"] as? String == "unused" && first?["severity"] as? String == "Warning")
        let none = try await tool(claude, "getDiagnostics", ["uri": fixture.root.appending(path: "other.swift").absoluteString])
        #expect((none.json as? [Any])?.isEmpty == true)

        // Opening a file at some text.
        let other = fixture.root.appending(path: "other.swift").path
        #expect(try await tool(claude, "openFile", ["filePath": other, "startText": "old"]).text == "Opened file: \(other)")
        #expect(fixture.workspace.activeDocument?.url.path == other)

        // Unknown methods are errors, not silence.
        let unknown = try await call(claude, "nope/nope")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)

        // Pings are answered.
        let pongError: Error? = await withCheckedContinuation { continuation in
            claude.task.sendPing { continuation.resume(returning: $0) }
        }
        #expect(pongError == nil)
    }

    @Test func proposedEditsWaitForAcceptOrReject() async throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }
        let claude = try await connect(fixture)
        defer { claude.close() }
        let path = fixture.root.appending(path: "other.swift").path
        let workspace = fixture.workspace

        func openDiff(_ contents: String, tab: String) -> Int {
            claude.send("tools/call", ["name": "openDiff", "arguments": [
                "old_file_path": path, "new_file_path": path, "new_file_contents": contents, "tab_name": tab]])
        }
        func proposal(_ tab: String) -> DiffSession? {
            workspace.diffSessions.first { if case .proposed(let change) = $0.mode { change.title == tab } else { false } }
        }
        func texts(_ id: Int) -> [String] {
            ((claude.response(id)?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        }

        // Accepted: FILE_SAVED and the text; the file is Claude Code's to write.
        let accepted = openDiff("new\n", tab: "✻ [Claude Code] other.swift")
        #expect(try await eventually { proposal("✻ [Claude Code] other.swift")?.awaitsDecision == true })
        let session = try #require(proposal("✻ [Claude Code] other.swift"))
        #expect(session.baseLines == ["old", ""] && session.currentLines == ["new", ""])
        #expect(claude.response(accepted) == nil) // waiting
        session.decide(true)
        #expect(try await eventually { claude.response(accepted) != nil })
        #expect(texts(accepted) == ["FILE_SAVED", "new\n"])
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "old\n")
        #expect(try await tool(claude, "close_tab", ["tab_name": "✻ [Claude Code] other.swift"]).text == "TAB_CLOSED")
        #expect(proposal("✻ [Claude Code] other.swift") == nil)

        // A big change (frames longer than 64 KB, both ways).
        let big = String(repeating: "x", count: 200_000) + "\n"
        let bigID = openDiff(big, tab: "big")
        #expect(try await eventually { proposal("big")?.awaitsDecision == true })
        proposal("big")?.decide(true)
        #expect(try await eventually { claude.response(bigID) != nil })
        #expect(texts(bigID).last == big)
        _ = try await tool(claude, "close_tab", ["tab_name": "big"])

        // Closing the tab turns it down.
        let rejected = openDiff("nope\n", tab: "second")
        #expect(try await eventually { proposal("second") != nil })
        workspace.closeDiffSessions { $0 === proposal("second") }
        #expect(try await eventually { claude.response(rejected) != nil })
        #expect(texts(rejected) == ["DIFF_REJECTED", "second"])

        // The same tab again replaces the first (which is turned down); closing all closes it.
        let replaced = openDiff("one\n", tab: "third")
        #expect(try await eventually { proposal("third") != nil })
        let replacement = openDiff("two\n", tab: "third")
        #expect(try await eventually { claude.response(replaced) != nil })
        #expect(texts(replaced).first == "DIFF_REJECTED")
        #expect(try await eventually { proposal("third")?.currentLines == ["two", ""] })
        #expect(try await tool(claude, "closeAllDiffTabs").text == "CLOSED_1_DIFF_TABS")
        #expect(try await eventually { claude.response(replacement) != nil })
        #expect(texts(replacement).first == "DIFF_REJECTED")

        // A diff of a connection that goes is turned down with it.
        _ = openDiff("gone\n", tab: "fourth")
        #expect(try await eventually { proposal("fourth") != nil })
        claude.close()
        #expect(try await eventually { proposal("fourth") == nil && workspace.claudeCode.connectedCount == 0 })
    }

    /// A diff asked for by a connection that goes at once: no tab is left waiting for it.
    @Test func noDiffForAConnectionThatWent() async throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }
        let claude = try await connect(fixture)
        let path = fixture.root.appending(path: "other.swift").path
        _ = claude.send("tools/call", ["name": "openDiff", "arguments": [
            "old_file_path": path, "new_file_path": path, "new_file_contents": "late\n", "tab_name": "late"]])
        claude.close()
        #expect(try await eventually { fixture.workspace.claudeCode.connectedCount == 0 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.workspace.diffSessions.isEmpty)
    }

    @Test func toldOfSelectionsAndMentions() async throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }
        let claude = try await connect(fixture)
        defer { claude.close() }

        fixture.controller.textView.setSelectedRange(NSRange(location: 10, length: 5))
        #expect(try await eventually { claude.notifications.contains { $0["method"] as? String == "selection_changed" } })
        let params = try #require(claude.notifications.last { $0["method"] as? String == "selection_changed" }?["params"] as? [String: Any])
        #expect(params["text"] as? String == "let b" && params["filePath"] as? String == fixture.document.url.path)
        #expect(((params["selection"] as? [String: Any])?["isEmpty"]) as? Bool == false)
        #expect(params["success"] == nil)
        let latest = try #require(try await tool(claude, "getLatestSelection").json as? [String: Any])
        #expect(latest["text"] as? String == "let b")

        // ⌥⌘K: the selected lines (0-based, the last one in).
        fixture.controller.textView.setSelectedRange(NSRange(location: 0, length: 20)) // lines 1-2, ending at line 3's start
        fixture.workspace.sendSelectionToClaudeCode()
        #expect(try await eventually { claude.notifications.contains { $0["method"] as? String == "at_mentioned" } })
        let mention = try #require(claude.notifications.last { $0["method"] as? String == "at_mentioned" }?["params"] as? [String: Any])
        #expect(mention["lineStart"] as? Int == 0 && mention["lineEnd"] as? Int == 1)
        #expect(fixture.workspace.errorMessage == nil)
    }
}
