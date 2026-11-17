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

    struct Contributions: Codable, Sendable, Equatable {
        var commands: [Command]?
        var configuration: [String: Setting]?
        var keybindings: [Keybinding]?
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

        var title: String {
            switch self {
            case .process: "Run programs on this Mac"
            case .network: "Make network requests"
            case .fileSystem: "Read and write files outside the open folder"
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

        var errorDescription: String? {
            switch self {
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
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    subscript(key: String) -> JSONValue? { object?[key] }
}
