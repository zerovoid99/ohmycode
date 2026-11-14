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
    /// The server's `capabilities` from `initialize`.
    @ObservationIgnored private var capabilities: [String: Any] = [:]
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
                "workspace": [
                    "workspaceFolders": true, "configuration": true, "applyEdit": true,
                    "symbol": [String: Any](),
                    "inlayHint": ["refreshSupport": true],
                    "workspaceEdit": ["documentChanges": true],
                ],
                "textDocument": [
                    "synchronization": ["didSave": true, "dynamicRegistration": false],
                    "completion": [
                        "completionItem": ["snippetSupport": true, "documentationFormat": ["plaintext"]],
                        "contextSupport": true,
                    ],
                    "definition": ["linkSupport": true],
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "references": [String: Any](),
                    "rename": ["prepareSupport": true],
                    "formatting": [String: Any](),
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "implementation": ["linkSupport": true],
                    "typeDefinition": ["linkSupport": true],
                    "callHierarchy": [String: Any](),
                    "inlayHint": [String: Any](),
                    "codeAction": [
                        "codeActionLiteralSupport": ["codeActionKind": ["valueSet": [
                            "", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite",
                            "source", "source.organizeImports", "source.fixAll",
                        ]]],
                        "isPreferredSupport": true, "disabledSupport": true, "dataSupport": true,
                        "resolveSupport": ["properties": ["edit"]],
                    ],
                    "signatureHelp": [
                        "signatureInformation": [
                            "documentationFormat": ["markdown", "plaintext"],
                            "parameterInformation": ["labelOffsetSupport": true], "activeParameterSupport": true,
                        ],
                        "contextSupport": true,
                    ],
                    "publishDiagnostics": ["relatedInformation": false],
                ],
            ],
        ]
        do {
            let result = try await request("initialize", params: params, beforeReady: true) as? [String: Any]
            let capabilities = result?["capabilities"] as? [String: Any] ?? [:]
            self.capabilities = capabilities
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
        try await locations("textDocument/definition", url: url, position: position)
    }

    /// Definition, implementation or type definition: Location, Location[] or LocationLink[].
    func locations(_ method: String, url: URL, position: LSPPosition) async throws -> [LSPLocation] {
        let result = try await request(method, params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json,
        ])
        if let list = result as? [Any] { return list.compactMap(LSPLocation.init(json:)) }
        return LSPLocation(json: result).map { [$0] } ?? []
    }

    enum Feature: String {
        case hover = "hoverProvider"
        case references = "referencesProvider"
        case rename = "renameProvider"
        case formatting = "documentFormattingProvider"
        case documentSymbol = "documentSymbolProvider"
        case implementation = "implementationProvider"
        case typeDefinition = "typeDefinitionProvider"
        case callHierarchy = "callHierarchyProvider"
        case workspaceSymbol = "workspaceSymbolProvider"
        case codeAction = "codeActionProvider"
        case signatureHelp = "signatureHelpProvider"
        case inlayHint = "inlayHintProvider"
    }

    /// Whether the server advertised `feature` (a provider is `true` or an options object).
    func supports(_ feature: Feature) -> Bool {
        switch capabilities[feature.rawValue] {
        case let flag as Bool: flag
        case is [String: Any]: true
        default: false
        }
    }

    /// Symbols in the whole workspace matching `query` (SymbolInformation[] or WorkspaceSymbol[]).
    func workspaceSymbols(query: String) async throws -> [WorkspaceSymbol] {
        let result = try await request("workspace/symbol", params: ["query": query])
        return (result as? [[String: Any]] ?? []).compactMap(WorkspaceSymbol.init(json:))
    }

    // MARK: Code actions

    /// Fixes and refactorings for `range`, given the diagnostics there; `only` limits the kinds.
    func codeActions(url: URL, range: LSPRange, diagnostics: [Diagnostic], only: [String]? = nil) async throws -> [CodeAction] {
        var context: [String: Any] = ["diagnostics": diagnostics.map(\.json), "triggerKind": 1]
        if let only { context["only"] = only }
        let result = try await request("textDocument/codeAction", params: [
            "textDocument": ["uri": url.absoluteString], "range": range.json, "context": context,
        ])
        return (result as? [Any] ?? []).compactMap(CodeAction.init(json:))
    }

    /// Whether the server fills in actions' edits only when asked (`codeAction/resolve`).
    var resolvesCodeActions: Bool {
        (capabilities["codeActionProvider"] as? [String: Any])?["resolveProvider"] as? Bool ?? false
    }

    func resolve(_ action: CodeAction) async throws -> CodeAction {
        CodeAction(json: try await request("codeAction/resolve", params: action.json)) ?? action
    }

    func executeCommand(_ command: [String: Any]) async throws {
        var params: [String: Any] = ["command": command["command"] as? String ?? ""]
        if let arguments = command["arguments"] { params["arguments"] = arguments }
        _ = try await request("workspace/executeCommand", params: params)
    }

    /// The server asks to change files (after a command): answered with whether it was done.
    var onApplyEdit: ((WorkspaceEdit, String?) -> Bool)?

    // MARK: Inlay hints

    func inlayHints(url: URL, range: LSPRange) async throws -> [InlayHint] {
        let result = try await request("textDocument/inlayHint", params: [
            "textDocument": ["uri": url.absoluteString], "range": range.json,
        ])
        return (result as? [Any] ?? []).compactMap(InlayHint.init(json:))
    }

    /// The server's hints changed (asked for again).
    var onInlayHintRefresh: (() -> Void)?

    // MARK: Signature help

    func signatureHelp(url: URL, position: LSPPosition, trigger: String?, isRetrigger: Bool) async throws -> SignatureHelp? {
        var context: [String: Any] = ["triggerKind": trigger == nil ? (isRetrigger ? 3 : 1) : 2, "isRetrigger": isRetrigger]
        if let trigger { context["triggerCharacter"] = trigger }
        let result = try await request("textDocument/signatureHelp", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json, "context": context,
        ])
        return SignatureHelp(json: result)
    }

    /// Characters that open signature help ("(", ","), and those that update it once open.
    var signatureHelpTriggers: (open: Set<String>, update: Set<String>) {
        let options = capabilities["signatureHelpProvider"] as? [String: Any]
        let open = Set(options?["triggerCharacters"] as? [String] ?? [])
        return (open, open.union(options?["retriggerCharacters"] as? [String] ?? []))
    }

    // MARK: Call hierarchy

    func prepareCallHierarchy(url: URL, position: LSPPosition) async throws -> [CallHierarchyItem] {
        let result = try await request("textDocument/prepareCallHierarchy", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json,
        ])
        return (result as? [[String: Any]] ?? []).compactMap(CallHierarchyItem.init(json:))
    }

    /// Who calls `item` (incoming) or what it calls (outgoing), with the call sites' ranges
    /// (in the caller's file for incoming calls, in `item`'s for outgoing ones).
    func calls(_ item: CallHierarchyItem, incoming: Bool) async throws -> [(item: CallHierarchyItem, ranges: [LSPRange])] {
        let result = try await request(incoming ? "callHierarchy/incomingCalls" : "callHierarchy/outgoingCalls",
                                       params: ["item": item.json])
        return (result as? [[String: Any]] ?? []).compactMap { call in
            guard let other = CallHierarchyItem(json: call[incoming ? "from" : "to"]) else { return nil }
            return (other, (call["fromRanges"] as? [Any] ?? []).compactMap(LSPRange.init(json:)))
        }
    }

    /// The file's symbols, as the server sends them (DocumentSymbol[] or SymbolInformation[]).
    func documentSymbols(url: URL) async throws -> Any? {
        try await request("textDocument/documentSymbol", params: ["textDocument": ["uri": url.absoluteString]])
    }

    /// Hover documentation as Markdown, or nil when there is none.
    func hover(url: URL, position: LSPPosition) async throws -> String? {
        let result = try await request("textDocument/hover", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json,
        ])
        return HoverContent.markdown(from: result)
    }

    func references(url: URL, position: LSPPosition, includeDeclaration: Bool = true) async throws -> [LSPLocation] {
        let result = try await request("textDocument/references", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json,
            "context": ["includeDeclaration": includeDeclaration],
        ])
        return (result as? [Any] ?? []).compactMap(LSPLocation.init(json:))
    }

    enum PrepareRename: Equatable {
        /// The symbol can't be renamed here.
        case invalid
        /// The server didn't say what's renamed; the client uses the word at the cursor.
        case defaultBehavior
        case range(LSPRange, placeholder: String?)
    }

    func prepareRename(url: URL, position: LSPPosition) async throws -> PrepareRename {
        let options = capabilities[Feature.rename.rawValue] as? [String: Any]
        guard options?["prepareProvider"] as? Bool == true else { return .defaultBehavior }
        let result = try await request("textDocument/prepareRename", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json,
        ])
        guard let object = result as? [String: Any] else { return .invalid }
        if let range = LSPRange(json: object) { return .range(range, placeholder: nil) }
        if let range = LSPRange(json: object["range"]) {
            return .range(range, placeholder: object["placeholder"] as? String)
        }
        return object["defaultBehavior"] as? Bool == true ? .defaultBehavior : .invalid
    }

    func rename(url: URL, position: LSPPosition, newName: String) async throws -> WorkspaceEdit? {
        let result = try await request("textDocument/rename", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json, "newName": newName,
        ])
        return WorkspaceEdit(json: result)
    }

    func formatting(url: URL, tabSize: Int, insertSpaces: Bool) async throws -> [LSPTextEdit] {
        let result = try await request("textDocument/formatting", params: [
            "textDocument": ["uri": url.absoluteString],
            "options": ["tabSize": tabSize, "insertSpaces": insertSpaces, "trimTrailingWhitespace": true,
                        "insertFinalNewline": true],
        ])
        return (result as? [Any] ?? []).compactMap(LSPTextEdit.init(json:))
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
        case "workspace/inlayHint/refresh":
            response["result"] = NSNull()
            onInlayHintRefresh?()
        case "workspace/applyEdit":
            let object = params as? [String: Any]
            let applied = WorkspaceEdit(json: object?["edit"]).map { onApplyEdit?($0, object?["label"] as? String) ?? false } ?? false
            response["result"] = ["applied": applied]
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
