import Foundation

/// A language a file is written in, by id. The built-in ones are static members (`.swift`,
/// `.javascript`, …) so `case .swift` and `[SourceLanguage: …]` read as they did when this
/// was a closed enum; extensions add more through `LanguageRegistry` (their id is the
/// raw value). What a built-in language does lives in tables here, with a default for every
/// language they don't list.
struct SourceLanguage: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let swift = SourceLanguage(rawValue: "swift")
    static let javascript = SourceLanguage(rawValue: "javascript")
    static let typescript = SourceLanguage(rawValue: "typescript")
    static let tsx = SourceLanguage(rawValue: "tsx")
    static let json = SourceLanguage(rawValue: "json")
    static let markdown = SourceLanguage(rawValue: "markdown")
    static let python = SourceLanguage(rawValue: "python")
    static let rust = SourceLanguage(rawValue: "rust")
    static let go = SourceLanguage(rawValue: "go")
    static let c = SourceLanguage(rawValue: "c")
    static let cpp = SourceLanguage(rawValue: "cpp")
    static let objc = SourceLanguage(rawValue: "objc")
    static let html = SourceLanguage(rawValue: "html")
    static let css = SourceLanguage(rawValue: "css")
    static let yaml = SourceLanguage(rawValue: "yaml")
    static let toml = SourceLanguage(rawValue: "toml")
    static let shell = SourceLanguage(rawValue: "shell")
    static let http = SourceLanguage(rawValue: "http")
    static let sql = SourceLanguage(rawValue: "sql")
    static let plaintext = SourceLanguage(rawValue: "plaintext")

    /// The languages the app knows without extensions, in the language picker's order.
    static let builtIns: [SourceLanguage] = [
        .c, .cpp, .css, .go, .html, .http, .javascript, .json, .markdown, .objc, .plaintext, .python, .rust,
        .shell, .sql, .swift, .toml, .typescript, .tsx, .yaml,
    ]

    var isBuiltIn: Bool { Self.builtInNames[self] != nil }

    var description: String { rawValue }

    /// The language for a file extension: an extension's contribution, else the built-in table.
    init(fileExtension ext: String) {
        self = LanguageRegistry.shared.language(forExtension: ext)
    }

    /// The built-in table only (what the app knew before extensions could add languages).
    static func builtIn(fileExtension ext: String) -> SourceLanguage {
        builtInExtensions[ext.lowercased()] ?? .plaintext
    }

    static let builtInExtensions: [String: SourceLanguage] = [
        "swift": .swift,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "tsx": .tsx,
        "json": .json,
        "md": .markdown, "markdown": .markdown,
        "py": .python,
        "rs": .rust,
        "go": .go,
        "c": .c, "h": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp,
        "m": .objc, "mm": .objc,
        "html": .html, "htm": .html,
        "css": .css, "scss": .css,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml,
        "sh": .shell, "bash": .shell, "zsh": .shell,
        "http": .http, "rest": .http,
        "sql": .sql,
    ]

    /// What starts a line comment (`//`, `#`), if the language has them: its language
    /// configuration's, else the built-in table's.
    var lineComment: String? {
        if let comments = LanguageRegistry.shared.configuration(for: self)?.comments { return comments.lineComment }
        return Self.builtInLineComments[self]
    }

    var blockComment: (start: String, end: String)? {
        if let comments = LanguageRegistry.shared.configuration(for: self)?.comments {
            return comments.blockComment.map { ($0.start, $0.end) }
        }
        return Self.builtInBlockComments[self]
    }

    private static let builtInLineComments: [SourceLanguage: String] = {
        var table: [SourceLanguage: String] = [:]
        for language in [SourceLanguage.swift, .javascript, .typescript, .tsx, .rust, .go, .c, .cpp, .objc] { table[language] = "//" }
        for language in [SourceLanguage.python, .yaml, .toml, .shell, .http] { table[language] = "#" }
        table[.sql] = "--"
        return table
    }()

    private static let builtInBlockComments: [SourceLanguage: (start: String, end: String)] = {
        var table: [SourceLanguage: (start: String, end: String)] = [:]
        for language in [SourceLanguage.swift, .javascript, .typescript, .tsx, .rust, .go, .c, .cpp, .objc, .css, .sql] {
            table[language] = ("/*", "*/")
        }
        for language in [SourceLanguage.html, .markdown] { table[language] = ("<!--", "-->") }
        return table
    }()

    /// The name people know it by: a contribution's first alias, else the built-in name, else
    /// the id.
    var displayName: String {
        LanguageRegistry.shared.displayName(for: self) ?? Self.builtInNames[self] ?? rawValue
    }

    static let builtInNames: [SourceLanguage: String] = [
        .swift: "Swift", .javascript: "JavaScript", .typescript: "TypeScript", .tsx: "TypeScript JSX", .json: "JSON",
        .markdown: "Markdown", .python: "Python", .rust: "Rust", .go: "Go", .c: "C", .cpp: "C++", .objc: "Objective-C",
        .html: "HTML", .css: "CSS", .yaml: "YAML", .toml: "TOML", .shell: "Shell Script", .http: "HTTP", .sql: "SQL",
        .plaintext: "Plain Text",
    ]

    /// The id language servers and extensions know it by (VS Code's): mostly the raw value.
    var languageId: String { Self.builtInLanguageIds[self] ?? rawValue }

    private static let builtInLanguageIds: [SourceLanguage: String] = [
        .objc: "objective-c", .tsx: "typescriptreact", .shell: "shellscript",
    ]

    /// The language a VS Code language id names: a built-in one by either of its ids
    /// ("typescriptreact" is `.tsx`), else a language of that id.
    init(languageId id: String) {
        self = Self.builtInLanguageIds.first { $0.value == id }?.key ?? SourceLanguage(rawValue: id)
    }
}
