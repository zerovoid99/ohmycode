import Foundation
import Observation

/// What an agent may do in the editor: read the open files' text (unsaved changes included),
/// write files, show where it's working.
@MainActor
protocol AgentHost: AnyObject {
    /// The folder the agent works in; it may read and write only inside it.
    var agentRootURL: URL? { get }
    /// The file's text as the editor has it (an open file's unsaved changes included).
    func agentReadText(_ url: URL) throws -> String
    /// Replaces the file's text (an open file's, as one undo step, then saved).
    func agentWriteText(_ url: URL, _ text: String) throws
}

struct AgentError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { message }

    static let authRequired = -32000
}

/// A conversation with a coding agent over the Agent Client Protocol: the agent runs as a
/// process speaking JSON-RPC on stdin/stdout, one message per line. The editor starts it,
/// opens a session in the workspace folder, sends prompts, and answers what the agent asks:
/// permission for an action, a file's text, writing a file, running a command.
@MainActor
@Observable
final class AgentClient {
    enum State: Equatable {
        case starting
        /// The agent needs the user to sign in first (`authMethods`).
        case needsAuthentication
        case ready
        /// A prompt is being answered.
        case working
        case failed(String)
        case stopped
    }

    let definition: AgentDefinition
    private(set) var state = State.starting
    private(set) var entries: [AgentEntry] = []
    private(set) var plan: [AgentPlanEntry] = []
    /// Questions the agent is waiting on, oldest first.
    private(set) var permissions: [AgentPermissionRequest] = []
    private(set) var modes: [AgentMode] = []
    private(set) var currentModeID: String?
    private(set) var commands: [AgentCommand] = []
    private(set) var authMethods: [AgentAuthMethod] = []
    /// The agent's name and version, as it gives them.
    private(set) var agentTitle: String?
    /// The session's title, when the agent names it.
    private(set) var sessionTitle: String?
    /// The agent's own output on stderr (its log), the last part of it.
    private(set) var log = ""
    /// Commands the agent ran, by id.
    private(set) var terminals: [String: AgentTerminal] = [:]
    /// The agent accepts files' text in prompts (else only links to them).
    private(set) var acceptsEmbeddedContext = false

    @ObservationIgnored private var connection: LanguageServerConnection?
    @ObservationIgnored private weak var host: AgentHost?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSONValueBox, Error>] = [:]
    @ObservationIgnored private var sessionID: String?
    /// Updates for a session not known yet: an agent may send some (its commands) right after
    /// answering `session/new`, before the answer is read here.
    @ObservationIgnored private var earlyUpdates: [(session: String, update: [String: Any])] = []
    @ObservationIgnored private var toolIndex: [String: Int] = [:]
    @ObservationIgnored private var nextEntryID = 0
    @ObservationIgnored private var nextTerminalID = 1
    @ObservationIgnored private var lastMessageID: String?
    @ObservationIgnored private let rootURL: URL

    static let protocolVersion = 1
    private static let logLimit = 20_000

    init(definition: AgentDefinition, rootURL: URL, host: AgentHost) {
        self.definition = definition
        self.rootURL = rootURL
        self.host = host
    }

    isolated deinit {
        connection?.terminate()
        terminals.values.forEach { $0.kill() }
    }

    // MARK: Lifecycle

    /// Starts the agent and opens a session (`environment`: the login shell's, to find it).
    func start(environment: [String: String]) async {
        state = .starting
        let words = AgentDefinition.words(definition.command)
        guard let name = words.first else { return fail("No command is set for \(definition.name) (Settings ▸ Agents).") }
        var environment = environment
        environment.merge(definition.environmentVariables) { $1 }
        let executable = name.contains("/") ? name : LanguageServers.find(name, in: environment["PATH"] ?? "")
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
            return fail("\(name) wasn't found on the PATH. Install it, or change the command in Settings ▸ Agents.")
        }
        do {
            let connection = try LanguageServerConnection(command: [executable] + words.dropFirst(), directory: rootURL,
                                                          environment: environment, parsesMessages: true,
                                                          framing: .newlineDelimited, capturesStandardError: true)
            connection.onParsedMessage = { [weak self] message in self?.handle(message.object) }
            connection.onExit = { [weak self] status in self?.agentDidExit(status) }
            connection.onStandardError = { [weak self] text in self?.appendLog(text) }
            self.connection = connection
        } catch {
            return fail("Couldn't start \(definition.name): \(error.localizedDescription)")
        }
        do {
            let result = try await request("initialize", params: [
                "protocolVersion": Self.protocolVersion,
                "clientCapabilities": [
                    "fs": ["readTextFile": true, "writeTextFile": true],
                    "terminal": true,
                ],
                "clientInfo": ["name": "oh-my-code", "title": "Oh My Code",
                               "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
            ]) as? [String: Any] ?? [:]
            if let version = result["protocolVersion"] as? Int, version != Self.protocolVersion {
                return fail("\(definition.name) speaks version \(version) of the Agent Client Protocol; this editor speaks \(Self.protocolVersion).")
            }
            let capabilities = result["agentCapabilities"] as? [String: Any] ?? [:]
            acceptsEmbeddedContext = (capabilities["promptCapabilities"] as? [String: Any])?["embeddedContext"] as? Bool ?? false
            if let info = result["agentInfo"] as? [String: Any], let name = info["title"] as? String ?? info["name"] as? String {
                agentTitle = [name, info["version"] as? String].compactMap { $0 }.joined(separator: " ")
            }
            authMethods = (result["authMethods"] as? [[String: Any]] ?? []).compactMap { method in
                guard let id = method["id"] as? String else { return nil }
                return AgentAuthMethod(id: id, name: method["name"] as? String ?? id, description: method["description"] as? String)
            }
            await newSession()
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Opens a new session (a fresh conversation) with the running agent.
    func newSession() async {
        guard connection != nil else { return }
        if state == .working { cancel() }
        do {
            let result = try await request("session/new", params: ["cwd": rootURL.path, "mcpServers": [Any]()]) as? [String: Any] ?? [:]
            guard let id = result["sessionId"] as? String else { return fail("\(definition.name) didn't open a session.") }
            sessionID = id
            entries = []
            plan = []
            toolIndex = [:]
            sessionTitle = nil
            setModes(result["modes"])
            state = .ready
            let early = earlyUpdates
            earlyUpdates = []
            for item in early where item.session == id { sessionUpdate(item.update) }
        } catch let error as AgentError where error.code == AgentError.authRequired {
            state = .needsAuthentication
        } catch {
            fail(error.localizedDescription)
        }
    }

    func authenticate(_ method: AgentAuthMethod) async {
        do {
            _ = try await request("authenticate", params: ["methodId": method.id])
            await newSession()
        } catch {
            addNotice("Signing in failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard state != .stopped else { return }
        cancelPermissions()
        connection?.terminate()
        connection = nil
        terminals.values.forEach { $0.kill() }
        state = .stopped
    }

    private func fail(_ message: String) {
        state = .failed(message)
        connection?.terminate()
        connection = nil
    }

    private func agentDidExit(_ status: Int32) {
        for continuation in pending.values {
            continuation.resume(throwing: AgentError(code: -1, message: "\(definition.name) exited"))
        }
        pending.removeAll()
        cancelPermissions()
        guard state != .stopped, !isFailed else { return }
        let lastLine = log.split(separator: "\n").last.map(String.init)
        state = .failed("\(definition.name) exited (\(status))" + (lastLine.map { ": \($0)" } ?? ""))
        connection = nil
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    private func appendLog(_ text: String) {
        log += text
        if log.count > Self.logLimit { log = String(log.suffix(Self.logLimit)) }
    }

    // MARK: Prompts

    /// Sends a prompt; the reply streams into `entries`. Returns when the turn ends.
    func send(_ text: String, attachments: [AgentAttachment] = []) async {
        guard let sessionID, state == .ready else { return }
        var blocks: [[String: Any]] = []
        if !text.isEmpty { blocks.append(AgentContent.textBlock(text)) }
        blocks += attachments.map { AgentContent.block(for: $0, embedded: acceptsEmbeddedContext) }
        guard !blocks.isEmpty else { return }
        append(.user(text, attachments: attachments.map(\.label)))
        lastMessageID = nil
        state = .working
        do {
            let result = try await request("session/prompt", params: ["sessionId": sessionID, "prompt": blocks]) as? [String: Any]
            switch result?["stopReason"] as? String {
            case "max_tokens": addNotice("The agent stopped: it reached its output limit.")
            case "max_turn_requests": addNotice("The agent stopped: it reached its limit of requests for one turn.")
            case "refusal": addNotice("The agent refused to continue.")
            case "cancelled": addNotice("Stopped.")
            default: break
            }
        } catch {
            if connection != nil { addNotice("The prompt failed: \(error.localizedDescription)") }
        }
        if state == .working { state = .ready }
    }

    /// Stops the turn: the agent is told, and every question it's waiting on is cancelled.
    func cancel() {
        guard let sessionID, state == .working else { return }
        notify("session/cancel", params: ["sessionId": sessionID])
        cancelPermissions()
        for (id, index) in toolIndex {
            guard case .tool(var call) = entries[index].kind, !call.isFinished else { continue }
            call.status = .cancelled
            entries[index].kind = .tool(call)
            _ = id
        }
    }

    func setMode(_ id: String) {
        guard let sessionID, id != currentModeID else { return }
        let previous = currentModeID
        currentModeID = id
        Task {
            do { _ = try await request("session/set_mode", params: ["sessionId": sessionID, "modeId": id]) } catch { currentModeID = previous }
        }
    }

    /// Answers a permission request with one of its options.
    func respond(to permission: AgentPermissionRequest, with option: AgentPermissionRequest.Option) {
        guard permissions.contains(where: { $0.id == permission.id }) else { return }
        permissions.removeAll { $0.id == permission.id }
        respond(permission.requestID, result: ["outcome": ["outcome": "selected", "optionId": option.id]])
    }

    private func cancelPermissions() {
        for permission in permissions { respond(permission.requestID, result: ["outcome": ["outcome": "cancelled"]]) }
        permissions = []
    }

    // MARK: Updates

    private func append(_ kind: AgentEntry.Kind) {
        entries.append(AgentEntry(id: nextEntryID, kind: kind))
        nextEntryID += 1
    }

    private func addNotice(_ text: String) { append(.notice(text)) }

    private func setModes(_ json: Any?) {
        guard let object = json as? [String: Any] else { modes = []; currentModeID = nil; return }
        modes = (object["availableModes"] as? [[String: Any]] ?? []).compactMap { mode in
            guard let id = mode["id"] as? String else { return nil }
            return AgentMode(id: id, name: mode["name"] as? String ?? id, description: mode["description"] as? String)
        }
        currentModeID = object["currentModeId"] as? String
    }

    private func sessionUpdate(_ update: [String: Any]) {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            appendChunk(update, thought: false)
        case "agent_thought_chunk":
            appendChunk(update, thought: true)
        case "user_message_chunk":
            if let text = AgentContent.text(of: update["content"]) { append(.user(text, attachments: [])) }
        case "tool_call":
            guard let id = update["toolCallId"] as? String else { return }
            var call = AgentToolCall(id: id, title: update["title"] as? String ?? "Tool", kind: update["kind"] as? String ?? "other",
                                     status: .pending, content: [], locations: [])
            apply(update, to: &call)
            if let index = toolIndex[id] {
                entries[index].kind = .tool(call)
            } else {
                toolIndex[id] = entries.count
                append(.tool(call))
            }
            lastMessageID = nil
        case "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            if let index = toolIndex[id], case .tool(var call) = entries[index].kind {
                apply(update, to: &call)
                entries[index].kind = .tool(call)
            } else {
                // An update for a call it didn't announce: shown anyway.
                var call = AgentToolCall(id: id, title: update["title"] as? String ?? "Tool", kind: update["kind"] as? String ?? "other",
                                         status: .pending, content: [], locations: [])
                apply(update, to: &call)
                toolIndex[id] = entries.count
                append(.tool(call))
            }
        case "plan":
            plan = (update["entries"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let content = entry["content"] as? String else { return nil }
                return AgentPlanEntry(content: content, priority: entry["priority"] as? String ?? "medium",
                                      status: entry["status"] as? String ?? "pending")
            }
        case "available_commands_update":
            commands = (update["availableCommands"] as? [[String: Any]] ?? []).compactMap { command in
                guard let name = command["name"] as? String else { return nil }
                return AgentCommand(name: name, description: command["description"] as? String ?? "",
                                    hint: (command["input"] as? [String: Any])?["hint"] as? String)
            }
        case "current_mode_update":
            currentModeID = update["currentModeId"] as? String ?? currentModeID
        case "session_info_update":
            if update.keys.contains("title") { sessionTitle = update["title"] as? String }
        default:
            break // usage, config options, …: not shown
        }
    }

    /// A chunk of the reply (or reasoning): added to the entry it continues.
    private func appendChunk(_ update: [String: Any], thought: Bool) {
        guard let text = AgentContent.text(of: update["content"]) else { return }
        let messageID = update["messageId"] as? String
        let continues = messageID == nil || messageID == lastMessageID
        lastMessageID = messageID ?? lastMessageID
        if continues, let last = entries.indices.last {
            switch entries[last].kind {
            case .message(let existing) where !thought:
                entries[last].kind = .message(existing + text)
                return
            case .thought(let existing) where thought:
                entries[last].kind = .thought(existing + text)
                return
            default:
                break
            }
        }
        append(thought ? .thought(text) : .message(text))
    }

    private func apply(_ update: [String: Any], to call: inout AgentToolCall) {
        if let title = update["title"] as? String { call.title = title }
        if let kind = update["kind"] as? String { call.kind = kind }
        if let status = (update["status"] as? String).flatMap(AgentToolCall.Status.init(rawValue:)) { call.status = status }
        if let content = update["content"] as? [Any] { call.content = content.compactMap(AgentToolContent.init(json:)) }
        if let locations = update["locations"] as? [[String: Any]] {
            call.locations = locations.compactMap { location in
                (location["path"] as? String).map { AgentLocation(path: $0, line: location["line"] as? Int) }
            }
        }
    }

    // MARK: JSON-RPC

    private func request(_ method: String, params: Any) async throws -> Any? {
        guard let connection else { throw AgentError(code: -1, message: "\(definition.name) isn't running") }
        let id = nextID
        nextID += 1
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValueBox, Error>) in
            pending[id] = continuation
            connection.send(data)
        }
        return box.value
    }

    private func notify(_ method: String, params: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": method, "params": params]) else { return }
        connection?.send(data)
    }

    private func respond(_ id: AnyHashableID, result: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id.json, "result": result]) else { return }
        connection?.send(data)
    }

    private func respond(_ id: AnyHashableID, error: AgentError) {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id.json, "error": ["code": error.code, "message": error.message]]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        connection?.send(data)
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        if method == nil, let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: AgentError(code: error["code"] as? Int ?? -1, message: error["message"] as? String ?? "Error"))
            } else {
                continuation.resume(returning: JSONValueBox(message["result"]))
            }
            return
        }
        guard let method else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id = AnyHashableID(message["id"]) else {
            if method == "session/update", let session = params["sessionId"] as? String,
               let update = params["update"] as? [String: Any] {
                if session == sessionID {
                    sessionUpdate(update)
                } else if earlyUpdates.count < 100 {
                    earlyUpdates.append((session, update))
                }
            }
            return
        }
        Task {
            do {
                if let result = try await answer(method, params: params, id: id) { respond(id, result: result) }
            } catch let error as AgentError {
                respond(id, error: error)
            } catch {
                respond(id, error: AgentError(code: -32603, message: error.localizedDescription))
            }
        }
    }

    /// What the agent asks the editor. Nil: answered later (a permission, by the user).
    private func answer(_ method: String, params: [String: Any], id: AnyHashableID) async throws -> Any? {
        switch method {
        case "session/request_permission":
            let toolCall = params["toolCall"] as? [String: Any] ?? [:]
            let toolCallID = toolCall["toolCallId"] as? String
            var title = toolCall["title"] as? String
            var content = (toolCall["content"] as? [Any])?.compactMap(AgentToolContent.init(json:)) ?? []
            // What the announced call has, where the request leaves it out.
            if let toolCallID, let index = toolIndex[toolCallID], case .tool(let call) = entries[index].kind {
                title = title ?? call.title
                if content.isEmpty { content = call.content }
            }
            let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentPermissionRequest.Option? in
                guard let id = option["optionId"] as? String else { return nil }
                return .init(id: id, name: option["name"] as? String ?? id, kind: option["kind"] as? String ?? "allow_once")
            }
            guard !options.isEmpty else { return ["outcome": ["outcome": "cancelled"]] }
            permissions.append(AgentPermissionRequest(requestID: id, toolCallID: toolCallID, title: title ?? "Allow this action?",
                                                      options: options, content: content))
            return nil
        case "fs/read_text_file":
            let url = try fileURL(params["path"])
            guard let host else { throw AgentError(code: -32603, message: "The workspace is closed") }
            let text = try host.agentReadText(url)
            let line = params["line"] as? Int, limit = params["limit"] as? Int
            guard line != nil || limit != nil else { return ["content": text] }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = min(max((line ?? 1) - 1, 0), lines.count)
            let end = limit.map { min(lines.count, start + max(0, $0)) } ?? lines.count
            return ["content": lines[start..<end].joined(separator: "\n")]
        case "fs/write_text_file":
            let url = try fileURL(params["path"])
            guard let content = params["content"] as? String else { throw AgentError(code: -32602, message: "No content") }
            guard let host else { throw AgentError(code: -32603, message: "The workspace is closed") }
            try host.agentWriteText(url, content)
            return [String: Any]()
        case "terminal/create":
            guard let command = params["command"] as? String else { throw AgentError(code: -32602, message: "No command") }
            var environment = await ShellEnvironment.shared.environment()
            for variable in params["env"] as? [[String: Any]] ?? [] {
                if let name = variable["name"] as? String, let value = variable["value"] as? String { environment[name] = value }
            }
            let directory = (params["cwd"] as? String).map { URL(filePath: $0) } ?? rootURL
            let id = "terminal-\(nextTerminalID)"
            nextTerminalID += 1
            let terminal = try AgentTerminal(id: id, command: command, arguments: params["args"] as? [String] ?? [],
                                             environment: environment, directory: directory,
                                             byteLimit: params["outputByteLimit"] as? Int)
            terminals[id] = terminal
            return ["terminalId": id]
        case "terminal/output":
            let terminal = try self.terminal(params)
            var result: [String: Any] = ["output": terminal.output, "truncated": terminal.truncated]
            if let status = terminal.exitStatus { result["exitStatus"] = Self.json(status) }
            return result
        case "terminal/wait_for_exit":
            return Self.json(await (try terminal(params)).waitForExit())
        case "terminal/kill":
            try terminal(params).kill()
            return [String: Any]()
        case "terminal/release":
            let terminal = try self.terminal(params)
            terminal.kill()
            // The output stays in the conversation; the id can't be used again.
            terminals[terminal.id] = nil
            releasedTerminals[terminal.id] = terminal
            return [String: Any]()
        default:
            throw AgentError(code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Released commands, still shown where the conversation has them.
    @ObservationIgnored private(set) var releasedTerminals: [String: AgentTerminal] = [:]

    func terminal(id: String) -> AgentTerminal? { terminals[id] ?? releasedTerminals[id] }

    private func terminal(_ params: [String: Any]) throws -> AgentTerminal {
        guard let id = params["terminalId"] as? String, let terminal = terminals[id] else {
            throw AgentError(code: -32602, message: "Unknown terminal")
        }
        return terminal
    }

    private static func json(_ status: AgentTerminal.ExitStatus) -> [String: Any] {
        ["exitCode": status.exitCode.map { Int($0) as Any } ?? NSNull(), "signal": status.signal ?? NSNull()]
    }

    /// An absolute path inside the workspace folder.
    private func fileURL(_ value: Any?) throws -> URL {
        guard let path = value as? String, path.hasPrefix("/") else { throw AgentError(code: -32602, message: "The path must be absolute") }
        let url = URL(filePath: path).standardizedFileURL
        let root = rootURL.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().path, resolvedRoot = rootURL.resolvingSymlinksInPath().path
        func inside(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
        // Both as given and with links followed: a link inside pointing outside doesn't count.
        guard inside(url.path, root), inside(resolved, resolvedRoot) else {
            throw AgentError(code: -32602, message: "\(path) is outside the workspace")
        }
        return url
    }
}

/// Boxes a JSON value (`Any`) for a continuation.
final class JSONValueBox: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}
