import Foundation

/// An extension's `extension.json`.
///
///     {
///       "id": "acme.word-count",
///       "name": "Word Count",
///       "version": "1.0.0",
///       "main": "dist/extension.js",
///       "activationEvents": ["onStartup"],
///       "contributes": {
///         "commands": [{ "command": "wordCount.show", "title": "Show Word Count", "category": "Word Count" }],
///         "configuration": { "wordCount.includeSelection": { "type": "boolean", "default": true } }
///       },
///       "permissions": ["process"]
///     }
struct ExtensionManifest: Codable, Sendable, Equatable {
    struct Command: Codable, Sendable, Equatable {
        let command: String
        let title: String
        var category: String?
        var icon: String?

        /// "Category: Title", as the palette lists it.
        var paletteTitle: String { category.map { "\($0): \(title)" } ?? title }
    }

    struct Setting: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case boolean, string, number }
        let type: Kind
        var `default`: JSONValue?
        var description: String?
    }

    /// A shortcut for a command: "cmd+shift+k"; `when` narrows it ("editorTextFocus",
    /// "editorLangId == swift", joined with "&&", "!" negates).
    struct Keybinding: Codable, Sendable, Equatable {
        let command: String
        let key: String
        var when: String?
    }

    /// A language it adds, or more for a language the editor knows (VS Code's shape).
    struct Language: Codable, Sendable, Equatable {
        let id: String
        var aliases: [String]?
        var extensions: [String]?
        var filenames: [String]?
        var filenamePatterns: [String]?
        var firstLine: String?
        /// A `language-configuration.json`, relative to the extension's folder.
        var configuration: String?
    }

    /// Snippets for a language, in VS Code's snippet JSON.
    struct Snippets: Codable, Sendable, Equatable {
        /// A language id; omitted or "*" for every language.
        var language: String?
        let path: String
    }

    /// A TextMate grammar (VS Code's `contributes.grammars`): `.tmLanguage.json` or a
    /// `.tmLanguage` property list.
    struct TextMateGrammar: Codable, Sendable, Equatable {
        /// The language it colors; omitted for a grammar others include or that's injected.
        var language: String?
        let scopeName: String
        let path: String
        var embeddedLanguages: [String: String]?
        var tokenTypes: [String: String]?
        var injectTo: [String]?
        /// Used instead of the app's built-in highlighting for the language.
        var override: Bool?
    }

    /// A tree-sitter parser built as a dynamic library, with its queries.
    struct TreeSitterGrammar: Codable, Sendable, Equatable {
        let language: String
        /// "./parser/libtree-sitter-foo.dylib"
        let library: String
        /// "tree_sitter_foo"
        let symbol: String
        /// "highlights", "folds", "injections", "locals", "indents" → a `.scm` file.
        var queries: [String: String]?
        var override: Bool?
    }

    struct Contributions: Codable, Sendable, Equatable {
        var commands: [Command]?
        var configuration: [String: Setting]?
        var keybindings: [Keybinding]?
        var languages: [Language]?
        /// Language servers to start for languages (see `LanguageServerDefinition`).
        var languageServers: [JSONValue]?
        var snippets: [Snippets]?
        var grammars: [TextMateGrammar]?
        var treeSitterGrammars: [TreeSitterGrammar]?
    }

    /// What an extension may do beyond the editor and the workspace folder, granted when it's
    /// installed.
    enum Permission: String, Codable, Sendable, CaseIterable {
        /// Run programs (`omc.process.run`).
        case process
        /// Make network requests (`omc.net.fetch`).
        case network
        /// Read and write files outside the workspace folder.
        case fileSystem
        /// Load native code into the app (a tree-sitter parser library).
        case nativeCode

        var title: String {
            switch self {
            case .process: "Run programs on this Mac"
            case .network: "Make network requests"
            case .fileSystem: "Read and write files outside the open folder"
            case .nativeCode: "Load native code into Oh My Code (a tree-sitter parser)"
            }
        }
    }

    let id: String
    let name: String
    let version: String
    var description: String?
    var publisher: String?
    let main: String
    var activationEvents: [String]?
    var contributes: Contributions?
    var permissions: [Permission]?

    var commands: [Command] { contributes?.commands ?? [] }
    var settings: [String: Setting] { contributes?.configuration ?? [:] }
    var keybindings: [Keybinding] { contributes?.keybindings ?? [] }
    var grantedPermissions: Set<Permission> { Set(permissions ?? []) }

    enum ValidationError: LocalizedError, Equatable {
        case unreadable(String)
        case invalidID(String)
        case emptyField(String)
        case mainOutside(String)
        case mainMissing(String)
        case outside(String)
        case needsPermission(String, Permission)
        case invalidContribution(String)

        var errorDescription: String? {
            switch self {
            case .outside(let path): "“\(path)” must be inside the extension's folder."
            case .needsPermission(let what, let permission): "\(what) needs \"\(permission.rawValue)\" in “permissions”."
            case .invalidContribution(let detail): "extension.json: \(detail)"
            case .unreadable(let detail): "extension.json can't be read: \(detail)"
            case .invalidID(let id): "“\(id)” isn't a valid id: use publisher.name (letters, digits, - and _)."
            case .emptyField(let field): "extension.json needs a non-empty “\(field)”."
            case .mainOutside(let main): "“main” (\(main)) must be inside the extension's folder."
            case .mainMissing(let main): "The main file \(main) doesn't exist (build the extension first?)."
            }
        }
    }

    /// Reads and checks `extension.json` in `folder`.
    static func load(from folder: URL) throws -> ExtensionManifest {
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: folder.appending(path: "extension.json")))
        } catch let error as DecodingError {
            throw ValidationError.unreadable(Self.describe(error))
        } catch {
            throw ValidationError.unreadable(error.localizedDescription)
        }
        try manifest.validate(in: folder)
        return manifest
    }

    func validate(in folder: URL) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw ValidationError.invalidID(id)
        }
        for (field, value) in [("name", name), ("version", version), ("main", main)]
        where value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError.emptyField(field)
        }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let file = folder.appending(path: main).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root + "/") else { throw ValidationError.mainOutside(main) }
        guard FileManager.default.fileExists(atPath: file.path) else { throw ValidationError.mainMissing(main) }
        for language in languages {
            guard !language.id.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ValidationError.invalidContribution("a language needs an “id”.")
            }
            if let path = language.configuration, Self.inside(folder, path) == nil { throw ValidationError.outside(path) }
        }
        for snippets in snippetFiles where Self.inside(folder, snippets.path) == nil { throw ValidationError.outside(snippets.path) }
        let servers = contributes?.languageServers ?? []
        for server in servers where LanguageServerDefinition(json: server, extensionID: id, folder: folder) == nil {
            throw ValidationError.invalidContribution("a language server needs an “id”, “languages” and a “command” (and the stdio transport).")
        }
        // Starting a server runs a program: asked for (and shown) before it's installed.
        if !servers.isEmpty, !grantedPermissions.contains(.process) {
            throw ValidationError.needsPermission("A language server", .process)
        }
        for grammar in textMateGrammars {
            guard !grammar.scopeName.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ValidationError.invalidContribution("a grammar needs a “scopeName”.")
            }
            if Self.inside(folder, grammar.path) == nil { throw ValidationError.outside(grammar.path) }
        }
        for grammar in treeSitterGrammars {
            guard !grammar.language.isEmpty, !grammar.symbol.isEmpty else {
                throw ValidationError.invalidContribution("a tree-sitter grammar needs a “language”, a “library” and a “symbol”.")
            }
            for path in [grammar.library] + (grammar.queries ?? [:]).values.sorted() where Self.inside(folder, path) == nil {
                throw ValidationError.outside(path)
            }
        }
        // A parser library is native code running in the app: asked for before it's installed.
        if !treeSitterGrammars.isEmpty, !grantedPermissions.contains(.nativeCode) {
            throw ValidationError.needsPermission("A tree-sitter grammar", .nativeCode)
        }
    }

    var textMateGrammars: [TextMateGrammar] { contributes?.grammars ?? [] }
    var treeSitterGrammars: [TreeSitterGrammar] { contributes?.treeSitterGrammars ?? [] }

    /// Its grammars for `ContributedGrammars` (paths resolved in `folder`; ones outside it left out).
    func grammarContributions(in folder: URL) -> (textMate: [TextMateGrammarContribution], treeSitter: [TreeSitterGrammarContribution]) {
        func modified(_ urls: [URL]) -> Date? {
            urls.compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
        }
        let textMate = textMateGrammars.compactMap { grammar -> TextMateGrammarContribution? in
            guard let url = Self.inside(folder, grammar.path) else { return nil }
            return TextMateGrammarContribution(language: grammar.language, scopeName: grammar.scopeName, url: url,
                                               embeddedLanguages: grammar.embeddedLanguages ?? [:], tokenTypes: grammar.tokenTypes ?? [:],
                                               injectTo: grammar.injectTo ?? [], override: grammar.override ?? false, extensionID: id,
                                               modified: modified([url]))
        }
        let treeSitter = treeSitterGrammars.map { grammar in
            let queries = (grammar.queries ?? [:]).compactMapValues { Self.inside(folder, $0) }
            return TreeSitterGrammarContribution(language: grammar.language, library: grammar.library, symbol: grammar.symbol,
                                                 queries: queries, override: grammar.override ?? false, extensionID: id, folder: folder,
                                                 permitted: grantedPermissions.contains(.nativeCode), modified: modified(Array(queries.values)))
        }
        return (textMate, treeSitter)
    }

    /// `path` inside `folder` (links followed), or nil when it's outside.
    static func inside(_ folder: URL, _ path: String) -> URL? {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let file = folder.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
        return file.path.hasPrefix(root + "/") ? file : nil
    }

    var languages: [Language] { contributes?.languages ?? [] }
    var snippetFiles: [Snippets] { contributes?.snippets ?? [] }

    /// Its languages for the registry, with their configuration files read (a file that's
    /// missing or isn't valid JSON leaves the configuration out, with why in `problems`).
    func languageContributions(in folder: URL, problems: inout [String]) -> [LanguageContribution] {
        languages.map { language in
            var contribution = LanguageContribution(id: language.id, aliases: language.aliases ?? [],
                                                    extensions: language.extensions ?? [], filenames: language.filenames ?? [],
                                                    filenamePatterns: language.filenamePatterns ?? [], firstLine: language.firstLine)
            if let path = language.configuration {
                do {
                    guard let url = Self.inside(folder, path) else { throw ValidationError.outside(path) }
                    contribution.configuration = try LanguageConfiguration(json: Data(contentsOf: url))
                } catch {
                    problems.append("\(path) couldn't be read: \(error.localizedDescription)")
                }
            }
            return contribution
        }
    }

    /// The language servers it declares.
    func languageServerDefinitions(in folder: URL) -> [LanguageServerDefinition] {
        (contributes?.languageServers ?? []).compactMap { LanguageServerDefinition(json: $0, extensionID: id, folder: folder) }
    }

    /// Activated when the window opens (rather than when a command or language needs it).
    var activatesOnStartup: Bool {
        (activationEvents ?? []).contains { $0 == "*" || $0 == "onStartup" }
    }

    func activates(onCommand command: String) -> Bool {
        commands.contains { $0.command == command } || (activationEvents ?? []).contains("onCommand:\(command)")
    }

    func activates(onLanguage language: String) -> Bool {
        (activationEvents ?? []).contains("onLanguage:\(language)")
    }

    /// Activated by a file in `language`: `onLanguage:<id>` (either of a built-in language's
    /// ids), or a language it adds itself.
    func activates(onLanguage language: SourceLanguage) -> Bool {
        activates(onLanguage: language.languageId) || activates(onLanguage: language.rawValue)
            || (!language.isBuiltIn && languages.contains { SourceLanguage(languageId: $0.id) == language })
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): "missing “\(key.stringValue)”"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "wrong type at “\(context.codingPath.map(\.stringValue).joined(separator: "."))”"
        case .dataCorrupted(let context): context.debugDescription
        @unknown default: error.localizedDescription
        }
    }
}

/// A JSON value (settings defaults and values, storage).
enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// From JSON text; nil if it isn't valid JSON.
    init?(json: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return nil }
        self = value
    }

    var json: String {
        (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "null"
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    /// The number as a whole number, nil when it has none: `Int(_:)` traps on NaN, infinity
    /// and anything past Int's range, all of which an extension can send.
    var integer: Int? { number.flatMap { Int(exactly: $0.rounded(.towardZero)) } }
    /// The number as a line or column, pulled into ±Int32.max so huge values clamp instead of
    /// trapping (and offsets built from them can't overflow); nil for NaN.
    var position: Int? {
        guard let value = number, !value.isNaN else { return nil }
        let limit = Double(Int32.max)
        return Int(min(max(value, -limit), limit).rounded(.towardZero))
    }
    /// As JSONSerialization makes and takes it (`NSNull` for null).
    var foundation: Any? {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): Int(exactly: value).map { $0 as Any } ?? value
        case .string(let value): value
        case .array(let items): items.map { $0.foundation ?? NSNull() }
        case .object(let fields): fields.mapValues { $0.foundation ?? NSNull() }
        }
    }

    /// From what JSONSerialization made (nil and `NSNull` are null).
    init(foundation value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(foundation: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { JSONValue(foundation: $0) })
        default: self = .null
        }
    }

    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    subscript(key: String) -> JSONValue? { object?[key] }
}
