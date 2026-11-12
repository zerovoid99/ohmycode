import Foundation

enum SourceLanguage: String {
    case swift, javascript, typescript, tsx, json, markdown, python, rust, go, c, cpp, objc
    case html, css, yaml, toml, shell, plaintext

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
        default: self = .plaintext
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
        case .plaintext: "Plain Text"
        }
    }
}
