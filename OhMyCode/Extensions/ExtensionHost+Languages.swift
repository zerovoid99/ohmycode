import AppKit

/// What extensions add to languages: the languages themselves, snippets and language servers
/// (declared in extension.json), and every language feature the editor asks for (from their
/// code's providers, answered in the protocol's shapes and decoded like a server's answers).
extension ExtensionHost {
    /// Which extension and provider an item, action or lens came from (to resolve or run it).
    struct Origin: Sendable, Equatable {
        let extensionID: String
        let providerID: Int
        /// Its index in the provider's list.
        let item: Int
    }

    // MARK: Contributions

    /// Tells the registry and the snippet library what the extensions declare: an enabled
    /// extension's languages and snippets, nothing of a disabled or removed one's.
    func publishContributions(previous: [String]) {
        let current = Set(extensions.map(\.id))
        for id in previous where !current.contains(id) {
            LanguageRegistry.shared.setContributions([], from: id)
            SnippetLibrary.shared.setExtensionSnippets([], from: id)
            ContributedGrammars.shared.setContributions(textMate: [], treeSitter: [], from: id)
        }
        for instance in extensions {
            guard instance.isEnabled else {
                LanguageRegistry.shared.setContributions([], from: instance.id)
                SnippetLibrary.shared.setExtensionSnippets([], from: instance.id)
                ContributedGrammars.shared.setContributions(textMate: [], treeSitter: [], from: instance.id)
                continue
            }
            let folder = instance.installed.folder
            var problems: [String] = []
            LanguageRegistry.shared.setContributions(instance.manifest.languageContributions(in: folder, problems: &problems), from: instance.id)
            let grammars = instance.manifest.grammarContributions(in: folder)
            ContributedGrammars.shared.setContributions(textMate: grammars.textMate, treeSitter: grammars.treeSitter, from: instance.id)
            problems += ContributedGrammars.shared.problems.withLock { $0[instance.id] ?? [] }
            let snippets = instance.manifest.snippetFiles.compactMap { file -> (language: String?, url: URL)? in
                guard let url = ExtensionManifest.inside(folder, file.path) else { return nil }
                return (file.language.flatMap { $0 == "*" ? nil : $0 }, url)
            }
            SnippetLibrary.shared.setExtensionSnippets(snippets, from: instance.id)
            for problem in problems where !instance.log.contains(where: { $0.message == problem }) { instance.append("warning", problem) }
        }
    }

    // MARK: Language servers

    /// The servers the enabled extensions declare, then those their code registered.
    var languageServerDefinitions: [LanguageServerDefinition] {
        extensions.filter(\.isEnabled).flatMap { $0.manifest.languageServerDefinitions(in: $0.installed.folder) } + registeredServers
    }

    func hasLanguageServerDefinition(_ id: String) -> Bool {
        languageServerDefinitions.contains { $0.id == id }
    }

    /// How to start the extensions' servers whose programs are there, with their settings'
    /// `${config:…}` filled in from the extensions' configuration.
    func languageServerConfigs(path: String) -> [LanguageServerConfig] {
        languageServerDefinitions.compactMap { definition in
            guard let instance = extensions.first(where: { $0.id == definition.extensionID }) else { return nil }
            return definition.config(path: path) { [store] key in store.setting(key, of: instance.manifest) }
        }
    }

    /// A running client of server `id`: the active file's, else any (a ready one first).
    func languageClient(_ id: String) -> LanguageClient? {
        if let client = workspace.activeDocument?.languageClient, client.serverID == id { return client }
        let clients = workspace.languageClients.values.filter { $0.serverID == id }
        return clients.first { $0.state == .ready } ?? clients.first { $0.state == .starting }
    }

    static func listenerKey(_ server: String, _ method: String, request: Bool) -> String {
        (request ? "request:" : "") + server + "\n" + method
    }

    /// A server's notification nobody in the app handles: to the extensions listening for it.
    func languageServerNotification(from client: LanguageClient, method: String, params: Any?) {
        let key = Self.listenerKey(client.serverID, method, request: false)
        let payload = JSONValue.object(["server": .string(client.serverID), "method": .string(method), "params": JSONValue(foundation: params)])
        for instance in extensions where instance.state == .active && instance.serverListeners.contains(key) {
            instance.runtime?.emit("languageServerNotification", payloadJSON: payload.json)
        }
    }

    /// A server's request nobody in the app answers: the first listening extension's answer;
    /// nil when none listens.
    func languageServerRequest(from client: LanguageClient, method: String, params: Any?) async throws -> JSONBoxResult? {
        let key = Self.listenerKey(client.serverID, method, request: true)
        guard let instance = extensions.first(where: { $0.state == .active && $0.serverListeners.contains(key) }),
              let runtime = instance.runtime else { return nil }
        let payload = JSONValue.object(["server": .string(client.serverID), "method": .string(method), "params": JSONValue(foundation: params)])
        guard let answer = try await runtime.serverRequest(argumentsJSON: payload.json).flatMap(JSONValue.init(json:)),
              answer["__omcNoHandler"] == nil else { return nil }
        return JSONBoxResult(value: (answer["result"] ?? .null).foundation ?? NSNull())
    }

    // MARK: Documents

    /// A document's language changed: extensions hear it closed and opened again in the new
    /// one (as VS Code tells them), and those for the new language activate.
    func documentLanguageChanged(_ document: EditorDocument) {
        emitAll("didCloseTextDocument", Self.info(document))
        activateForLanguage(of: document)
        emitAll("didOpenTextDocument", Self.info(document))
        document.refreshLanguageFeatures()
    }

    /// Providers of `kind` came or went: what open files show from them is asked for again.
    func providersChanged(_ kind: ProviderKind) {
        for document in workspace.documents {
            switch kind {
            case .documentSymbol: document.refreshSymbols()
            case .foldingRange: document.refreshFoldRegions()
            case .codeLens: document.refreshCodeLenses()
            case .inlayHint: document.refreshInlayHints()
            case .semanticTokens: document.refreshSemanticTokens()
            case .documentLink: document.refreshLinks()
            default: break
            }
        }
    }

    // MARK: Features

    private static func position(_ document: EditorDocument, at offset: Int) -> JSONValue {
        let position = document.lspPosition(at: min(offset, document.textStorage.length))
        return .object(["line": .number(Double(position.line)), "character": .number(Double(position.character))])
    }

    private static func range(_ range: LSPRange) -> JSONValue {
        .object(["start": .object(["line": .number(Double(range.start.line)), "character": .number(Double(range.start.character))]),
                 "end": .object(["line": .number(Double(range.end.line)), "character": .number(Double(range.end.character))])])
    }

    private static func options(_ document: EditorDocument) -> JSONValue {
        let (tabSize, insertSpaces) = document.indentation
        return .object(["tabSize": .number(Double(tabSize)), "insertSpaces": .bool(insertSpaces)])
    }

    /// The extensions' answers as Foundation JSON (what the protocol types decode).
    private func answers(_ kind: ProviderKind, for document: EditorDocument?, method: String = "provide",
                         only: Origin? = nil, _ arguments: [String: JSONValue]) async -> [(Provider, Any)] {
        await ask(kind, for: document, method: method, only: only.map { ($0.extensionID, $0.providerID) }, arguments)
            .map { ($0.0, $0.1.foundation ?? NSNull()) }
    }

    /// Definitions, type definitions, implementations: every provider's.
    func locations(_ kind: ProviderKind, for document: EditorDocument, at offset: Int) async -> [LSPLocation] {
        await answers(kind, for: document, ["position": Self.position(document, at: offset)])
            .flatMap { ($0.1 as? [Any] ?? []).compactMap(LSPLocation.init(json:)) }
    }

    func references(for document: EditorDocument, at offset: Int, includeDeclaration: Bool = true) async -> [LSPLocation] {
        await answers(.references, for: document, ["position": Self.position(document, at: offset),
                                                   "includeDeclaration": .bool(includeDeclaration)])
            .flatMap { ($0.1 as? [Any] ?? []).compactMap(LSPLocation.init(json:)) }
    }

    /// The file's symbols, in the protocol's shape (`DocumentSymbol[]` or `SymbolInformation[]`):
    /// the first provider that lists any.
    func documentSymbols(for document: EditorDocument) async -> [Any]? {
        for (_, answer) in await answers(.documentSymbol, for: document, [:]) {
            if let list = answer as? [Any], !list.isEmpty { return list }
        }
        return nil
    }

    func workspaceSymbols(query: String) async -> [WorkspaceSymbol] {
        await answers(.workspaceSymbol, for: nil, ["query": .string(query)])
            .flatMap { ($0.1 as? [[String: Any]] ?? []).compactMap(WorkspaceSymbol.init(json:)) }
    }

    /// Code actions for a range, marked with where they came from (so their commands run in
    /// the extension).
    func codeActions(for document: EditorDocument, range: LSPRange, diagnostics: [Diagnostic], only: [String]?) async -> [CodeAction] {
        var arguments: [String: JSONValue] = ["range": Self.range(range),
                                              "diagnostics": .array(diagnostics.map { JSONValue(foundation: $0.json) })]
        if let only { arguments["only"] = .array(only.map(JSONValue.string)) }
        var actions: [CodeAction] = []
        for (provider, answer) in await answers(.codeAction, for: document, arguments) {
            for item in answer as? [[String: Any]] ?? [] {
                if let action = CodeAction(json: Self.marked(item, provider)) {
                    if let only, !only.contains(where: { action.kind.hasPrefix($0) }) { continue }
                    actions.append(action)
                }
            }
        }
        return actions
    }

    /// `object` with its extension noted (and its command's), as `__omcExtension`.
    private static func marked(_ object: [String: Any], _ provider: Provider) -> [String: Any] {
        var object = object
        object["__omcExtension"] = provider.extensionID
        if var command = object["command"] as? [String: Any] {
            command["__omcExtension"] = provider.extensionID
            object["command"] = command
        } else if object["command"] is String {
            object["__omcExtension"] = provider.extensionID
        }
        return object
    }

    /// The extension a code action, lens or completion command came from, if one did.
    static func extensionID(of json: [String: Any]?) -> String? { json?["__omcExtension"] as? String }

    /// Runs a command from an extension's action, lens or item: its own command (or a built-in one).
    func runCommand(_ command: [String: Any]) async throws {
        guard let id = command["command"] as? String, !id.isEmpty else { return }
        let arguments = (command["arguments"] as? [Any] ?? []).map { JSONValue(foundation: $0) }
        try await executeCommand(id, arguments: arguments)
    }

    func codeLenses(for document: EditorDocument) async -> [CodeLens] {
        var lenses: [CodeLens] = []
        for (provider, answer) in await answers(.codeLens, for: document, [:]) {
            lenses += (answer as? [[String: Any]] ?? []).compactMap { CodeLens(json: Self.marked($0, provider)) }
        }
        return lenses
    }

    /// A lens without a command, as its extension fills it in.
    func resolve(_ lens: CodeLens) async -> CodeLens? {
        guard let origin = Self.origin(of: lens.json) else { return nil }
        guard let (provider, answer) = await answers(.codeLens, for: nil, method: "resolve", only: origin, ["item": .number(Double(origin.item))]).first,
              let object = answer as? [String: Any] else { return nil }
        return CodeLens(json: Self.marked(object, provider))
    }

    private static func origin(of json: [String: Any]) -> Origin? {
        guard let extensionID = json["__omcExtension"] as? String, let data = json["data"] as? [String: Any],
              let provider = data["__omcProvider"] as? Int, let item = data["__omcItem"] as? Int else { return nil }
        return Origin(extensionID: extensionID, providerID: provider, item: item)
    }

    func signatureHelp(for document: EditorDocument, at offset: Int, trigger: String?, isRetrigger: Bool) async -> SignatureHelp? {
        var arguments: [String: JSONValue] = ["position": Self.position(document, at: offset), "isRetrigger": .bool(isRetrigger)]
        if let trigger { arguments["triggerCharacter"] = .string(trigger) }
        for (_, answer) in await answers(.signatureHelp, for: document, arguments) {
            if let help = SignatureHelp(json: answer), !help.signatures.isEmpty { return help }
        }
        return nil
    }

    /// The characters that open signature help, and those that update it once it's open.
    func signatureHelpTriggers(for document: EditorDocument) -> (open: Set<String>, update: Set<String>) {
        let providers = providers(.signatureHelp, for: document)
        let open = Set(providers.flatMap(\.triggerCharacters))
        return (open, open.union(providers.flatMap { $0.metadata["retriggerCharacters"]?.array?.compactMap(\.string) ?? [] }))
    }

    /// What renaming at `offset` changes, from the first rename provider (nil: there's none).
    func prepareRename(for document: EditorDocument, at offset: Int) async -> LanguageClient.PrepareRename? {
        guard let provider = providers(.rename, for: document).first else { return nil }
        guard provider.metadata["prepares"]?.bool == true else { return .defaultBehavior }
        let origin = Origin(extensionID: provider.extensionID, providerID: provider.id, item: 0)
        guard let answer = await answers(.rename, for: document, method: "prepare", only: origin,
                                         ["position": Self.position(document, at: offset)]).first?.1 as? [String: Any] else { return .invalid }
        if answer["defaultBehavior"] as? Bool == true { return .defaultBehavior }
        guard let range = LSPRange(json: answer["range"]) else { return .invalid }
        return .range(range, placeholder: answer["placeholder"] as? String)
    }

    func rename(in document: EditorDocument, at offset: Int, to newName: String) async -> WorkspaceEdit? {
        guard let provider = providers(.rename, for: document).first else { return nil }
        let origin = Origin(extensionID: provider.extensionID, providerID: provider.id, item: 0)
        return await answers(.rename, for: document, only: origin, ["position": Self.position(document, at: offset), "newName": .string(newName)])
            .first.flatMap { WorkspaceEdit(json: $0.1) }
    }

    func documentHighlights(for document: EditorDocument, at offset: Int) async -> [DocumentHighlight] {
        await answers(.documentHighlight, for: document, ["position": Self.position(document, at: offset)])
            .flatMap { ($0.1 as? [Any] ?? []).compactMap(DocumentHighlight.init(json:)) }
    }

    func documentLinks(for document: EditorDocument) async -> [LSPDocumentLink] {
        var links: [LSPDocumentLink] = []
        for (provider, answer) in await answers(.documentLink, for: document, [:]) {
            links += (answer as? [[String: Any]] ?? []).compactMap { LSPDocumentLink(json: Self.marked($0, provider)) }
        }
        return links
    }

    /// A link's target, as its extension fills it in.
    func resolve(_ link: LSPDocumentLink) async -> URL? {
        guard let origin = Self.origin(of: link.json) else { return nil }
        return await answers(.documentLink, for: nil, method: "resolve", only: origin, ["item": .number(Double(origin.item))])
            .first.flatMap { LSPDocumentLink(json: $0.1)?.target }
    }

    func foldingRanges(for document: EditorDocument) async -> [FoldRegion] {
        await answers(.foldingRange, for: document, [:]).flatMap { answer in
            (answer.1 as? [[String: Any]] ?? []).compactMap { range -> FoldRegion? in
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
    }

    func inlayHints(for document: EditorDocument, range: LSPRange) async -> [InlayHint] {
        await answers(.inlayHint, for: document, ["range": Self.range(range)])
            .flatMap { ($0.1 as? [Any] ?? []).compactMap(InlayHint.init(json:)) }
    }

    /// The first semantic tokens provider's tokens, decoded with its legend (nil: none answered).
    func semanticTokens(for document: EditorDocument) async -> [SemanticToken]? {
        for (provider, answer) in await answers(.semanticTokens, for: document, [:]) {
            let legend = provider.metadata["legend"]?["tokenTypes"]?.array?.compactMap(\.string) ?? []
            return SemanticTokens.decode(SemanticTokens.numbers((answer as? [String: Any])?["data"]), legend: legend, in: document)
        }
        return nil
    }

    /// Edits for part of the file from the first range formatter that answers.
    func rangeFormattingEdits(for document: EditorDocument, range: LSPRange) async -> [TextReplacement]? {
        let answers = await answers(.rangeFormatting, for: document, ["range": Self.range(range), "options": Self.options(document)])
        guard let edits = answers.first?.1 as? [Any] else { return nil }
        return edits.compactMap(LSPTextEdit.init(json:)).map { TextReplacement(range: document.range(for: $0.range), text: $0.newText) }
    }

    func onTypeFormattingTriggers(for document: EditorDocument) -> Set<String> {
        Set(providers(.onTypeFormatting, for: document).flatMap(\.triggerCharacters))
    }

    /// Edits after typing `character` at `offset` (just after it), from the providers that
    /// take that character.
    func onTypeFormattingEdits(for document: EditorDocument, at offset: Int, character: String) async -> [TextReplacement]? {
        guard providers(.onTypeFormatting, for: document).contains(where: { $0.triggerCharacters.contains(character) }) else { return nil }
        let answers = await answers(.onTypeFormatting, for: document, ["position": Self.position(document, at: offset),
                                                                       "ch": .string(character), "options": Self.options(document)])
        guard let edits = answers.first?.1 as? [Any] else { return nil }
        return edits.compactMap(LSPTextEdit.init(json:)).map { TextReplacement(range: document.range(for: $0.range), text: $0.newText) }
    }

    /// A completion item with what its extension fills in later (documentation, edits).
    func resolve(_ item: CompletionItem) async -> CompletionItem? {
        guard let origin = item.origin else { return nil }
        guard let (provider, answer) = await answers(.completion, for: nil, method: "resolve", only: origin,
                                                     ["item": .number(Double(origin.item))]).first,
              var resolved = CompletionItem(json: answer, id: item.id) else { return nil }
        resolved.origin = origin
        if resolved.command != nil { resolved.command = RawJSON(Self.marked(["command": resolved.command!.value], provider)["command"]!) }
        return resolved
    }
}
