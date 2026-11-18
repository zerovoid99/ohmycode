import Foundation

enum SourceLanguage: String {
    case swift, javascript, typescript, tsx, json, markdown, python, rust, go, c, cpp, objc
    case html, css, yaml, toml, shell, http, sql, plaintext

    init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "swift": self = .swift
        case "js", "mjs", "cjs", "jsx": self = .javascript
        case "ts", "mts", "cts": self = .typescript
        case "tsx": self = .tsx
        case "json": self = .json
        case "md", "markdown": self = .markdown
        case "py": self = .python
        case "rs": self = .rust
        case "go": self = .go
        case "c", "h": self = .c
        case "cc", "cpp", "cxx", "hpp", "hh": self = .cpp
        case "m", "mm": self = .objc
        case "html", "htm": self = .html
        case "css", "scss": self = .css
        case "yml", "yaml": self = .yaml
        case "toml": self = .toml
        case "sh", "bash", "zsh": self = .shell
        case "http", "rest": self = .http
        case "sql": self = .sql
        default: self = .plaintext
        }
    }

    /// What starts a line comment (`//`, `#`), if the language has them.
    var lineComment: String? {
        switch self {
        case .swift, .javascript, .typescript, .tsx, .rust, .go, .c, .cpp, .objc: "//"
        case .python, .yaml, .toml, .shell, .http: "#"
        case .sql: "--"
        default: nil
        }
    }

    var blockComment: (start: String, end: String)? {
        switch self {
        case .swift, .javascript, .typescript, .tsx, .rust, .go, .c, .cpp, .objc, .css: ("/*", "*/")
        case .html, .markdown: ("<!--", "-->")
        case .sql: ("/*", "*/")
        default: nil
        }
    }

    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .tsx: "TypeScript JSX"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .python: "Python"
        case .rust: "Rust"
        case .go: "Go"
        case .c: "C"
        case .cpp: "C++"
        case .objc: "Objective-C"
        case .html: "HTML"
        case .css: "CSS"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .shell: "Shell Script"
        case .http: "HTTP"
        case .sql: "SQL"
        case .plaintext: "Plain Text"
        }
    }
}
