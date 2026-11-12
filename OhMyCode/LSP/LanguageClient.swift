import Foundation
import Observation

/// Boxes JSON values (which are `Any`) for continuations.
private final class JSONBox: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}

struct LanguageServerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// LSP client for one server process. All protocol state lives on the main thread; message
/// bodies are small and parsing them here keeps ordering simple.
@MainActor
@Observable
final class LanguageClient {
    enum State: Equatable {
        case starting, ready, failed(String), stopped
    }

    let name: String
    private(set) var state = State.starting

    @ObservationIgnored private let connection: LanguageServerConnection
    @ObservationIgnored private let rootURL: URL
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSONBox, Error>] = [:]
    /// Notifications sent before `initialized` are queued, preserving order.
    @ObservationIgnored private var queued: [Data] = []
    @ObservationIgnored private var versions: [URL: Int] = [:]
    @ObservationIgnored private(set) var incrementalSync = true
    @ObservationIgnored private(set) var triggerCharacters: Set<String> = []
    @ObservationIgnored var onDiagnostics: ((URL, [Diagnostic]) -> Void)?

    init(name: String, command: [String], rootURL: URL, environment: [String: String]) throws {
        self.name = name
        self.rootURL = rootURL
        connection = try LanguageServerConnection(command: command, directory: rootURL, environment: environment)
        connection.onMessage = { [weak self] data in self?.handle(data) }
        connection.onExit = { [weak self] status in self?.serverDidExit(status) }
        Task { await initialize() }
    }

    isolated deinit {
        connection.terminate()
    }

    // MARK: Lifecycle

    private func initialize() async {
        let params: [String: Any] = [
            "processId": Int(ProcessInfo.processInfo.processIdentifier),
            "clientInfo": ["name": "Oh My Code"],
            "rootUri": rootURL.absoluteString,
            "workspaceFolders": [["uri": rootURL.absoluteString, "name": rootURL.lastPathComponent]],
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "window": ["workDoneProgress": true],
                "workspace": ["workspaceFolders": true, "configuration": true],
                "textDocument": [
                    "synchronization": ["didSave": true, "dynamicRegistration": false],
                    "completion": [
                        "completionItem": ["snippetSupport": true, "documentationFormat": ["plaintext"]],
                        "contextSupport": true,
                    ],
                    "definition": ["linkSupport": true],
                    "publishDiagnostics": ["relatedInformation": false],
                ],
            ],
        ]
        do {
            let result = try await request("initialize", params: params, beforeReady: true) as? [String: Any]
            let capabilities = result?["capabilities"] as? [String: Any] ?? [:]
            let sync = capabilities["textDocumentSync"]
            let kind = (sync as? Int) ?? ((sync as? [String: Any])?["change"] as? Int) ?? 2
            incrementalSync = kind != 1
            let completion = capabilities["completionProvider"] as? [String: Any]
            triggerCharacters = Set(completion?["triggerCharacters"] as? [String] ?? ["."])

            write(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()], force: true)
            state = .ready
            queued.forEach(connection.send)
            queued.removeAll()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func shutdown() {
        guard state == .ready else { connection.terminate(); return }
        Task {
            _ = try? await request("shutdown", params: nil)
            notify("exit", params: nil)
            connection.terminate()
            state = .stopped
        }
    }

    private func serverDidExit(_ status: Int32) {
        if state != .stopped { state = .failed("\(name) exited (\(status))") }
        for continuation in pending.values {
            continuation.resume(throwing: LanguageServerError(message: "\(name) exited"))
        }
        pending.removeAll()
    }

    // MARK: Documents

    func didOpen(url: URL, languageId: String, text: String) {
        versions[url] = 1
        notify("textDocument/didOpen", params: [
            "textDocument": ["uri": url.absoluteString, "languageId": languageId, "version": 1, "text": text],
        ])
    }

    /// `range` is in pre-edit coordinates; `fullText` is used when the server wants full sync.
    func didChange(url: URL, range: LSPRange, text: String, fullText: () -> String) {
        guard let version = versions[url] else { return }
        versions[url] = version + 1
        let change: [String: Any] = incrementalSync ? ["range": range.json, "text": text] : ["text": fullText()]
        notify("textDocument/didChange", params: [
            "textDocument": ["uri": url.absoluteString, "version": version + 1],
            "contentChanges": [change],
        ])
    }

    func didSave(url: URL) {
        guard versions[url] != nil else { return }
        notify("textDocument/didSave", params: ["textDocument": ["uri": url.absoluteString]])
    }

    func didClose(url: URL) {
        guard versions.removeValue(forKey: url) != nil else { return }
        notify("textDocument/didClose", params: ["textDocument": ["uri": url.absoluteString]])
    }

    func isOpen(_ url: URL) -> Bool { versions[url] != nil }

    // MARK: Features

    func completion(url: URL, position: LSPPosition, triggerCharacter: String?) async throws -> (items: [CompletionItem], isIncomplete: Bool) {
        var context: [String: Any] = ["triggerKind": triggerCharacter == nil ? 1 : 2]
        if let triggerCharacter { context["triggerCharacter"] = triggerCharacter }
        let result = try await request("textDocument/completion", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json, "context": context,
        ])
        let list = result as? [String: Any]
        let rawItems = (list?["items"] as? [Any]) ?? (result as? [Any]) ?? []
        let items = rawItems.enumerated().compactMap { CompletionItem(json: $1, id: $0) }
        return (items, list?["isIncomplete"] as? Bool ?? false)
    }

    func definition(url: URL, position: LSPPosition) async throws -> [LSPLocation] {
        let result = try await request("textDocument/definition", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json,
        ])
        if let list = result as? [Any] { return list.compactMap(LSPLocation.init(json:)) }
        return LSPLocation(json: result).map { [$0] } ?? []
    }

    // MARK: JSON-RPC

    func request(_ method: String, params: Any?, beforeReady: Bool = false) async throws -> Any? {
        if case .failed(let message) = state { throw LanguageServerError(message: message) }
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        let box = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(message, force: beforeReady)
        }
        return box.value
    }

    private func notify(_ method: String, params: Any?) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        write(message, force: false)
    }

    private func write(_ message: [String: Any], force: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        if force || state == .ready { connection.send(data) } else { queued.append(data) }
    }

    private func handle(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let method = message["method"] as? String
        let id = message["id"]

        if method == nil, let id = id as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: LanguageServerError(message: error["message"] as? String ?? "LSP error"))
            } else {
                continuation.resume(returning: JSONBox(message["result"]))
            }
            return
        }
        guard let method else { return }
        if let id {
            respond(to: id, method: method, params: message["params"])
        } else if method == "textDocument/publishDiagnostics",
                  let params = message["params"] as? [String: Any],
                  let uri = params["uri"] as? String, let url = URL(string: uri) {
            let diagnostics = (params["diagnostics"] as? [Any] ?? []).compactMap(Diagnostic.init(json:))
            onDiagnostics?(url, diagnostics)
        }
    }

    /// Requests the server sends us. We answer the common ones so servers don't stall.
    private func respond(to id: Any, method: String, params: Any?) {
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "workspace/configuration":
            let items = (params as? [String: Any])?["items"] as? [Any] ?? []
            response["result"] = Array(repeating: NSNull(), count: items.count)
        case "workspace/workspaceFolders":
            response["result"] = [["uri": rootURL.absoluteString, "name": rootURL.lastPathComponent]]
        case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability",
             "window/showMessageRequest", "window/showDocument":
            response["result"] = NSNull()
        default:
            response["error"] = ["code": -32601, "message": "Method not found: \(method)"]
        }
        write(response, force: true)
    }
}
