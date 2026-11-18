import AppKit

/// Language features from both sources: the file's language server and the extensions'
/// providers, asked at the same time and merged (the server's answers first).
extension EditorDocument {
    /// The language server, once it's ready.
    var readyLanguageClient: LanguageClient? { languageClient.flatMap { $0.state == .ready ? $0 : nil } }

    /// Whether the server or an extension can answer `feature` here.
    func canUse(_ feature: LanguageClient.Feature, _ kind: ExtensionHost.ProviderKind) -> Bool {
        readyLanguageClient?.supports(feature) == true || extensionHost?.hasProviders(kind, for: self) == true
    }

    /// Asks again for everything the server and extensions show in the file (it connected to a
    /// server, its language changed, the server registered more).
    func refreshLanguageFeatures() {
        refreshSymbols()
        refreshInlayHints()
        refreshLinks()
        refreshSemanticTokens()
        refreshFoldRegions()
        refreshCodeLenses()
        refreshColorDecorators()
    }
}

extension Workspace {
    /// Where the symbol at `offset` is defined.
    func definitions(in document: EditorDocument, at offset: Int) async -> [LSPLocation] {
        await locations("textDocument/definition", .definition, in: document, at: offset)
    }

    /// Definitions, implementations or type definitions (`method`) from the server (when it
    /// has the feature; definitions it always has) and the extensions.
    func locations(_ method: String, _ kind: ExtensionHost.ProviderKind, in document: EditorDocument, at offset: Int) async -> [LSPLocation] {
        let client = document.readyLanguageClient
        let feature: LanguageClient.Feature? = switch kind {
        case .implementation: .implementation
        case .typeDefinition: .typeDefinition
        default: nil
        }
        let position = document.lspPosition(at: offset)
        let asked = client.flatMap { client in feature.map { client.supports($0) } ?? true ? client : nil }
        async let server = Self.serverLocations(asked, method, document.url, position)
        let fromExtensions = await extensions.locations(kind, for: document, at: offset)
        return Self.unique(await server + fromExtensions)
    }

    func references(in document: EditorDocument, at offset: Int) async throws -> [LSPLocation] {
        let client = document.readyLanguageClient.flatMap { $0.supports(.references) ? $0 : nil }
        let position = document.lspPosition(at: offset)
        async let server = Self.serverReferences(client, document.url, position)
        let fromExtensions = await extensions.references(for: document, at: offset)
        return Self.unique(try await server + fromExtensions)
    }

    private static func serverLocations(_ client: LanguageClient?, _ method: String, _ url: URL, _ position: LSPPosition) async -> [LSPLocation] {
        guard let client else { return [] }
        return (try? await client.locations(method, url: url, position: position)) ?? []
    }

    private static func serverReferences(_ client: LanguageClient?, _ url: URL, _ position: LSPPosition) async throws -> [LSPLocation] {
        guard let client else { return [] }
        return try await client.references(url: url, position: position)
    }

    /// Each place once (a server and an extension may both name it).
    static func unique(_ locations: [LSPLocation]) -> [LSPLocation] {
        var seen = Set<String>()
        return locations.filter { seen.insert("\($0.url.standardizedFileURL.path)#\($0.range.start.line):\($0.range.start.character)").inserted }
    }

    /// Languages for `omc.languages.getLanguages()`: ids, built-in and contributed.
    var languageIds: [String] { LanguageRegistry.shared.languages.map(\.language.languageId) }

    /// Symbols matching `query` in the whole workspace, from the extensions.
    func extensionWorkspaceSymbols(_ query: String) async -> [WorkspaceSymbol] {
        await extensions.workspaceSymbols(query: query)
    }
}

extension EditorController {
    /// After typing one of an extension's on-type formatting characters: its edits, as one undo
    /// step (dropped when more was typed meanwhile).
    func formatOnType(_ typed: String?) {
        guard let typed, typed.count == 1, let host = document.extensionHost,
              host.onTypeFormattingTriggers(for: document).contains(typed) else { return }
        let document = document
        let cursor = textView.selectedRange().location
        let version = document.editVersion
        Task {
            guard let edits = await host.onTypeFormattingEdits(for: document, at: cursor, character: typed), !edits.isEmpty,
                  document.editVersion == version else { return }
            _ = try? document.apply(edits, actionName: "Format")
        }
    }
}
