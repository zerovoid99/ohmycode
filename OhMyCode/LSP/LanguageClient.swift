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

/// LSP client for one server process. All protocol state lives on the main thread; messages
/// arrive parsed (see `IncomingMessage`), and big answers are decoded off it.
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
    /// The server's `TextDocumentSyncKind`: 0 no changes, 1 whole texts, 2 incremental. Until it
    /// says (while starting), changes go as whole texts, which any server takes.
    @ObservationIgnored private var syncKind = 1
    var incrementalSync: Bool { syncKind == 2 }
    @ObservationIgnored private(set) var triggerCharacters: Set<String> = []
    /// The server's `capabilities` from `initialize`.
    @ObservationIgnored private var capabilities: [String: Any] = [:]
    @ObservationIgnored var onDiagnostics: ((URL, [Diagnostic]) -> Void)?
    /// The server failed to start or exited (not after `shutdown`).
    @ObservationIgnored var onFailure: (() -> Void)?

    /// The folders the server works on (sent in `initialize`; changes are sent if it takes
    /// them): the folder it starts in, or, for a server shared by a window's folders, all of them.
    @ObservationIgnored private(set) var workspaceFolders: [URL]
    /// Folder changes made while it was starting, sent once it says it takes them.
    @ObservationIgnored private var pendingFolderChange: (added: [URL], removed: [URL])?

    /// The folder the server was started in (its `rootUri`).
    var rootFolder: URL { rootURL }

    init(name: String, command: [String], rootURL: URL, workspaceFolders: [URL] = [], environment: [String: String]) throws {
        self.name = name
        self.rootURL = rootURL
        self.workspaceFolders = workspaceFolders.isEmpty ? [rootURL] : workspaceFolders
        connection = try LanguageServerConnection(command: command, directory: rootURL, environment: environment, parsesMessages: true)
        connection.onParsedMessage = { [weak self] message in self?.handle(message) }
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
            "workspaceFolders": workspaceFolders.map(Self.folderJSON),
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "window": ["workDoneProgress": true],
                "workspace": [
                    "workspaceFolders": true, "configuration": true, "applyEdit": true,
                    "symbol": [String: Any](),
                    "inlayHint": ["refreshSupport": true],
                    "semanticTokens": ["refreshSupport": true],
                    "codeLens": ["refreshSupport": true],
                    "workspaceEdit": ["documentChanges": true],
                    "fileOperations": ["dynamicRegistration": false, "willRename": true, "didRename": true],
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
                    "rangeFormatting": [String: Any](),
                    // Whole lines; a block's end line is the one before its closing bracket.
                    "foldingRange": ["lineFoldingOnly": true, "foldingRange": ["collapsedText": false]] as [String: Any],
                    "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                    "implementation": ["linkSupport": true],
                    "typeDefinition": ["linkSupport": true],
                    "callHierarchy": [String: Any](),
                    "inlayHint": [String: Any](),
                    "documentHighlight": [String: Any](),
                    "codeLens": [String: Any](),
                    "documentLink": ["tooltipSupport": true],
                    "semanticTokens": [
                        "requests": ["full": true], "formats": ["relative"],
                        "tokenTypes": SemanticTokens.knownTypes, "tokenModifiers": [String](),
                        "multilineTokenSupport": false, "overlappingTokenSupport": false,
                    ] as [String: Any],
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
            syncKind = (0...2).contains(kind) ? kind : 2
            let completion = capabilities["completionProvider"] as? [String: Any]
            triggerCharacters = Set(completion?["triggerCharacters"] as? [String] ?? ["."])

            write(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()], force: true)
            state = .ready
            queued.forEach(connection.send)
            queued.removeAll()
            if let change = pendingFolderChange {
                pendingFolderChange = nil
                sendFolderChange(added: change.added, removed: change.removed)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Gives up: requests waiting for answers (or for `initialize`) end with the error, nothing
    /// more is queued, and the server is stopped.
    private func fail(_ message: String) {
        guard state != .stopped else { return }
        let wasFailed = if case .failed = state { true } else { false }
        state = .failed(message)
        failPending(message)
        connection.terminate()
        if !wasFailed { onFailure?() }
    }

    private func failPending(_ message: String) {
        let waiting = pending.values
        pending.removeAll()
        queued.removeAll()
        fullTextFlush?.cancel()
        fullTextFlush = nil
        pendingFullText.removeAll()
        for continuation in waiting { continuation.resume(throwing: LanguageServerError(message: message)) }
    }

    func shutdown() {
        guard state == .ready else {
            // Still starting (or failed): nothing to say goodbye to; what waits ends now.
            state = .stopped
            failPending("\(name) was stopped")
            connection.terminate()
            return
        }
        Task {
            _ = try? await request("shutdown", params: nil)
            notify("exit", params: nil)
            connection.terminate()
            state = .stopped
            failPending("\(name) was stopped")
        }
    }

    private func serverDidExit(_ status: Int32) {
        guard state != .stopped else { return failPending("\(name) exited") }
        fail("\(name) exited (\(status))")
    }

    // MARK: Documents

    func didOpen(url: URL, languageId: String, text: String) {
        versions[url] = 1
        notify("textDocument/didOpen", params: [
            "textDocument": ["uri": url.absoluteString, "languageId": languageId, "version": 1, "text": text],
        ])
    }

    /// Full sync: how often the whole text goes out while typing, at most.
    @ObservationIgnored var fullSyncInterval: Duration = .milliseconds(100)
    /// Full sync: the documents edited since their text was last sent, with their latest version
    /// and how to read the text. Sent every `fullSyncInterval`, and before any other message
    /// (a completion, a save), so the server never answers about an older text.
    @ObservationIgnored private var pendingFullText: [URL: (version: Int, text: () -> NSString)] = [:]
    @ObservationIgnored private var fullTextFlush: Task<Void, Never>?

    /// `range` is in pre-edit coordinates; `fullText` is used when the server wants full sync.
    func didChange(url: URL, range: LSPRange, text: String, fullText: @escaping () -> NSString) {
        guard let version = versions[url], syncKind != 0 else { return } // 0: the server doesn't want changes
        versions[url] = version + 1
        guard incrementalSync, state == .ready else {
            // The whole text per keystroke, encoded on the main thread, took 15 ms for 5 MB.
            pendingFullText[url] = (version + 1, fullText)
            if fullTextFlush == nil {
                fullTextFlush = Task { [weak self, fullSyncInterval] in
                    try? await Task.sleep(for: fullSyncInterval)
                    guard !Task.isCancelled else { return }
                    self?.sendPendingFullText()
                }
            }
            return
        }
        notify("textDocument/didChange", params: [
            "textDocument": ["uri": url.absoluteString, "version": version + 1],
            "contentChanges": [["range": range.json, "text": text]],
        ])
    }

    /// Sends the edited documents' whole texts now: copied here (one memcpy), encoded on the
    /// connection's write queue, ahead of anything sent after.
    func sendPendingFullText() {
        fullTextFlush?.cancel()
        fullTextFlush = nil
        guard !pendingFullText.isEmpty else { return }
        let changes = pendingFullText
        pendingFullText.removeAll()
        for (url, change) in changes {
            let uri = url.absoluteString, version = change.version
            let text = TextSnapshot(string: change.text().snapshot())
            let encode: @Sendable () -> Data? = {
                try? JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0", "method": "textDocument/didChange",
                    "params": [
                        "textDocument": ["uri": uri, "version": version] as [String: Any],
                        "contentChanges": [["text": text.string]],
                    ] as [String: Any],
                ] as [String: Any])
            }
            if state == .ready {
                connection.send(encode)
            } else if state == .starting, let data = encode() {
                queued.append(data)
            }
        }
    }

    func didSave(url: URL) {
        guard versions[url] != nil else { return }
        notify("textDocument/didSave", params: ["textDocument": ["uri": url.absoluteString]])
    }

    func didClose(url: URL) {
        guard versions.removeValue(forKey: url) != nil else { return }
        pendingFullText[url] = nil
        notify("textDocument/didClose", params: ["textDocument": ["uri": url.absoluteString]])
    }

    func isOpen(_ url: URL) -> Bool { versions[url] != nil }

    // MARK: File operations

    /// Whether the server wants to hear about renaming this file (`willRename`/`didRename`
    /// registration filters: a glob on the path, files or folders).
    func wantsRename(of url: URL, isFolder: Bool, notification: Bool) -> Bool {
        let operations = (capabilities["workspace"] as? [String: Any])?["fileOperations"] as? [String: Any]
        guard let registration = operations?[notification ? "didRename" : "willRename"] as? [String: Any],
              let filters = registration["filters"] as? [[String: Any]] else { return false }
        let path = String(url.standardizedFileURL.path.dropFirst())
        return filters.contains { filter in
            if let scheme = filter["scheme"] as? String, scheme != "file" { return false }
            guard let pattern = filter["pattern"] as? [String: Any], let glob = pattern["glob"] as? String else { return false }
            if let matches = pattern["matches"] as? String, matches != (isFolder ? "folder" : "file") { return false }
            let ignoreCase = (pattern["options"] as? [String: Any])?["ignoreCase"] as? Bool ?? false
            let anchored = glob.hasPrefix("/") ? String(glob.dropFirst()) : glob
            return EditorConfig.matches(ignoreCase ? anchored.lowercased() : anchored,
                                        relative: ignoreCase ? path.lowercased() : path)
        }
    }

    /// The edits the server wants made before files move (imports that name them).
    func willRenameFiles(_ renames: [(old: URL, new: URL)]) async throws -> WorkspaceEdit? {
        let result = try await request("workspace/willRenameFiles", params: [
            "files": renames.map { ["oldUri": $0.old.absoluteString, "newUri": $0.new.absoluteString] },
        ])
        return try current(WorkspaceEdit(json: result))
    }

    /// `edit`, unless it's for an older version of an open file.
    private func current(_ edit: WorkspaceEdit?) throws -> WorkspaceEdit? {
        if let edit, let stale = staleFile(in: edit) {
            throw LanguageServerError(message: "\(stale.lastPathComponent) changed since \(name) made the edit. Try again.")
        }
        return edit
    }

    func didRenameFiles(_ renames: [(old: URL, new: URL)]) {
        notify("workspace/didRenameFiles", params: [
            "files": renames.map { ["oldUri": $0.old.absoluteString, "newUri": $0.new.absoluteString] },
        ])
    }

    // MARK: Features

    func completion(url: URL, position: LSPPosition, triggerCharacter: String?) async throws -> (items: [CompletionItem], isIncomplete: Bool) {
        var context: [String: Any] = ["triggerKind": triggerCharacter == nil ? 1 : 2]
        if let triggerCharacter { context["triggerCharacter"] = triggerCharacter }
        let resolves = resolvesCompletionItems
        let result = try await request("textDocument/completion", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json, "context": context,
        ])
        return await decoding(result) { result in
            let list = result as? [String: Any]
            let rawItems = (list?["items"] as? [Any]) ?? (result as? [Any]) ?? []
            let items = rawItems.enumerated().compactMap { CompletionItem(json: $1, id: $0, keepingJSON: resolves) }
            return (items, list?["isIncomplete"] as? Bool ?? false)
        }
    }

    /// Whether the server fills in items' details (their additional edits) only when asked.
    var resolvesCompletionItems: Bool {
        (capabilities["completionProvider"] as? [String: Any])?["resolveProvider"] as? Bool ?? false
    }

    /// The item with what the server left out of the list (`completionItem/resolve`).
    func resolve(_ item: CompletionItem) async throws -> CompletionItem {
        guard let raw = item.raw?.value else { return item }
        let result = try await request("completionItem/resolve", params: raw)
        guard var resolved = CompletionItem(json: result, id: item.id) else { return item }
        resolved.raw = item.raw
        return resolved
    }

    /// The first open file `edit` was computed for at another version than the one open here
    /// (the server answered about an older text): applying it would edit the wrong places.
    func staleFile(in edit: WorkspaceEdit) -> URL? {
        edit.versions.first { url, version in versions[url].map { $0 != version } ?? false }?.key
    }

    /// Decodes a big answer off the main thread.
    private func decoding<T: Sendable>(_ result: Any?, _ decode: @escaping @Sendable (Any?) -> T) async -> T {
        let box = JSONBox(result)
        return await Task.detached(priority: .userInitiated) { decode(box.value) }.value
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
        case documentHighlight = "documentHighlightProvider"
        case documentLink = "documentLinkProvider"
        case semanticTokens = "semanticTokensProvider"
        case rangeFormatting = "documentRangeFormattingProvider"
        case foldingRange = "foldingRangeProvider"
        case codeLens = "codeLensProvider"
    }

    /// The server works on several folders at once (`workspace.workspaceFolders.supported`):
    /// one is shared by all a window's folders. Known once it's ready.
    var supportsWorkspaceFolders: Bool {
        let folders = (capabilities["workspace"] as? [String: Any])?["workspaceFolders"] as? [String: Any]
        return folders?["supported"] as? Bool == true
    }

    /// The window's folders changed: the server hears it (`workspace/didChangeWorkspaceFolders`)
    /// if it takes several; asked for its folders, it lists the new ones either way.
    func changeWorkspaceFolders(added: [URL], removed: [URL]) {
        let added = added.filter { !workspaceFolders.contains($0) }
        let removed = removed.filter { workspaceFolders.contains($0) }
        guard !added.isEmpty || !removed.isEmpty else { return }
        workspaceFolders = workspaceFolders.filter { !removed.contains($0) } + added
        switch state {
        case .starting:
            let earlier = pendingFolderChange ?? ([], [])
            pendingFolderChange = (earlier.added.filter { !removed.contains($0) } + added,
                                   earlier.removed.filter { !added.contains($0) } + removed)
        case .ready:
            sendFolderChange(added: added, removed: removed)
        case .failed, .stopped:
            break
        }
    }

    private func sendFolderChange(added: [URL], removed: [URL]) {
        let folders = (capabilities["workspace"] as? [String: Any])?["workspaceFolders"] as? [String: Any]
        // `changeNotifications`: true, or an id to register them under; either means it wants them.
        let notifications = folders?["changeNotifications"]
        guard supportsWorkspaceFolders, (notifications as? Bool) == true || notifications is String else { return }
        notify("workspace/didChangeWorkspaceFolders", params: ["event": [
            "added": added.map(Self.folderJSON), "removed": removed.map(Self.folderJSON),
        ]])
    }

    private static func folderJSON(_ url: URL) -> [String: Any] {
        ["uri": url.absoluteString, "name": url.lastPathComponent]
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

    /// The file's fold regions, as the server sees them.
    func foldingRanges(url: URL) async throws -> [FoldRegion] {
        let result = try await request("textDocument/foldingRange", params: ["textDocument": ["uri": url.absoluteString]])
        return (result as? [[String: Any]] ?? []).compactMap { range in
            guard let start = range["startLine"] as? Int, let end = range["endLine"] as? Int, end > start else { return nil }
            let kind: FoldRegion.Kind = switch range["kind"] as? String {
            case "comment": .comment
            case "imports": .imports
            case "region": .region
            default: .code
            }
            return FoldRegion(start: start, end: end, kind: kind)
        }
    }

    func codeLenses(url: URL) async throws -> [CodeLens] {
        let result = try await request("textDocument/codeLens", params: ["textDocument": ["uri": url.absoluteString]])
        return (result as? [Any] ?? []).compactMap(CodeLens.init(json:))
    }

    var resolvesCodeLenses: Bool {
        (capabilities["codeLensProvider"] as? [String: Any])?["resolveProvider"] as? Bool ?? false
    }

    func resolveCodeLens(_ lens: CodeLens) async throws -> CodeLens? {
        CodeLens(json: try await request("codeLens/resolve", params: lens.json))
    }

    /// The token types the server's numbers stand for (its legend).
    var semanticTokenTypes: [String] {
        ((capabilities["semanticTokensProvider"] as? [String: Any])?["legend"] as? [String: Any])?["tokenTypes"] as? [String] ?? []
    }

    /// Every token in the file, as the server encodes them (5 numbers each, relative).
    func semanticTokens(url: URL) async throws -> [Int] {
        let result = try await request("textDocument/semanticTokens/full", params: ["textDocument": ["uri": url.absoluteString]])
        return await decoding(result) { result in SemanticTokens.numbers((result as? [String: Any])?["data"]) }
    }

    /// The file's links (targets may come later, from `resolveDocumentLink`).
    func documentLinks(url: URL) async throws -> [LSPDocumentLink] {
        let result = try await request("textDocument/documentLink", params: ["textDocument": ["uri": url.absoluteString]])
        return (result as? [Any] ?? []).compactMap(LSPDocumentLink.init(json:))
    }

    var resolvesDocumentLinks: Bool {
        (capabilities["documentLinkProvider"] as? [String: Any])?["resolveProvider"] as? Bool ?? false
    }

    func resolveDocumentLink(_ link: LSPDocumentLink) async throws -> LSPDocumentLink? {
        LSPDocumentLink(json: try await request("documentLink/resolve", params: link.json))
    }

    /// Where the symbol at `position` appears in the file, and whether it's read or written there.
    func documentHighlights(url: URL, position: LSPPosition) async throws -> [DocumentHighlight] {
        let result = try await request("textDocument/documentHighlight", params: [
            "textDocument": ["uri": url.absoluteString], "position": position.json,
        ])
        return (result as? [Any] ?? []).compactMap(DocumentHighlight.init(json:))
    }

    func inlayHints(url: URL, range: LSPRange) async throws -> [InlayHint] {
        let result = try await request("textDocument/inlayHint", params: [
            "textDocument": ["uri": url.absoluteString], "range": range.json,
        ])
        return (result as? [Any] ?? []).compactMap(InlayHint.init(json:))
    }

    /// The server's hints changed (asked for again).
    var onInlayHintRefresh: (() -> Void)?
    /// The server asked for code lenses again (`workspace/codeLens/refresh`).
    var onCodeLensRefresh: (() -> Void)?
    /// The server asked for semantic tokens again (`workspace/semanticTokens/refresh`).
    var onSemanticTokensRefresh: (() -> Void)?

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
        return try current(WorkspaceEdit(json: result))
    }

    func formatting(url: URL, tabSize: Int, insertSpaces: Bool, trimTrailingWhitespace: Bool = true,
                    insertFinalNewline: Bool = true) async throws -> [LSPTextEdit] {
        let result = try await request("textDocument/formatting", params: [
            "textDocument": ["uri": url.absoluteString],
            "options": ["tabSize": tabSize, "insertSpaces": insertSpaces, "trimTrailingWhitespace": trimTrailingWhitespace,
                        "insertFinalNewline": insertFinalNewline],
        ])
        return (result as? [Any] ?? []).compactMap(LSPTextEdit.init(json:))
    }

    /// Formatting edits for part of the file.
    func rangeFormatting(url: URL, range: LSPRange, tabSize: Int, insertSpaces: Bool) async throws -> [LSPTextEdit] {
        let result = try await request("textDocument/rangeFormatting", params: [
            "textDocument": ["uri": url.absoluteString], "range": range.json,
            "options": ["tabSize": tabSize, "insertSpaces": insertSpaces],
        ])
        return (result as? [Any] ?? []).compactMap(LSPTextEdit.init(json:))
    }

    // MARK: JSON-RPC

    /// While starting, requests wait for `initialize` (and end with its error if it fails).
    func request(_ method: String, params: Any?, beforeReady: Bool = false) async throws -> Any? {
        switch state {
        case .failed(let message): throw LanguageServerError(message: message)
        case .stopped: throw LanguageServerError(message: "\(name) was stopped")
        case .starting, .ready: break
        }
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        // Cancelling the task that waits gives up on the answer and tells the server to stop
        // working on it (a completion or a file's tokens asked for before the latest keystroke).
        let data = try JSONSerialization.data(withJSONObject: message)
        let box = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONBox, Error>) in
                guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
                pending[id] = continuation
                sendPendingFullText() // answered about the current text
                send(data, force: beforeReady)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        return box.value
    }

    private func cancel(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return } // answered already
        notify("$/cancelRequest", params: ["id": id])
        continuation.resume(throwing: CancellationError())
    }

    private func notify(_ method: String, params: Any?) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        write(message, force: false)
    }

    private func write(_ message: [String: Any], force: Bool) {
        sendPendingFullText()
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        send(data, force: force)
    }

    /// Queued while starting (sent once ready); dropped once failed or stopped, where nothing
    /// would ever send them.
    private func send(_ data: Data, force: Bool) {
        if force || state == .ready {
            connection.send(data)
        } else if state == .starting {
            queued.append(data)
        }
    }

    private func handle(_ incoming: IncomingMessage) {
        let message = incoming.object
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
        } else if let diagnostics = incoming.diagnostics {
            onDiagnostics?(diagnostics.url, diagnostics.list)
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
        case "workspace/codeLens/refresh":
            response["result"] = NSNull()
            onCodeLensRefresh?()
        case "workspace/semanticTokens/refresh":
            response["result"] = NSNull()
            onSemanticTokensRefresh?()
        case "workspace/applyEdit":
            let object = params as? [String: Any]
            let edit = WorkspaceEdit(json: object?["edit"])
            if let edit, let stale = staleFile(in: edit) {
                response["result"] = ["applied": false, "failureReason": "\(stale.lastPathComponent) has changed"] as [String: Any]
            } else {
                let applied = edit.map { onApplyEdit?($0, object?["label"] as? String) ?? false } ?? false
                response["result"] = ["applied": applied]
            }
        case "workspace/workspaceFolders":
            response["result"] = workspaceFolders.map(Self.folderJSON)
        case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability",
             "window/showMessageRequest", "window/showDocument":
            response["result"] = NSNull()
        default:
            response["error"] = ["code": -32601, "message": "Method not found: \(method)"]
        }
        write(response, force: true)
    }
}
