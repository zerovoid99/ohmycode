import Foundation
import SwiftTreeSitter
import TreeSitterGo
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript

struct Grammar {
    let language: SwiftTreeSitter.Language
    let highlightsQuery: Query
}

/// Loads tree-sitter grammars and compiles their highlight queries once per language.
@MainActor
enum GrammarRegistry {
    private static var cache: [SourceLanguage: Grammar?] = [:]

    static func grammar(for language: SourceLanguage) -> Grammar? {
        if let cached = cache[language] { return cached }
        let grammar = load(language)
        cache[language] = grammar
        return grammar
    }

    private static let javaScript = QueryFile(bundle: "TreeSitterJavaScript_TreeSitterJavaScript", name: "highlights")
    private static let jsx = QueryFile(bundle: "TreeSitterJavaScript_TreeSitterJavaScript", name: "highlights-jsx")

    /// The tree-sitter language for parsing (no queries), from any thread.
    nonisolated static func treeSitterLanguage(for language: SourceLanguage) -> SwiftTreeSitter.Language? {
        switch language {
        case .swift: SwiftTreeSitter.Language(tree_sitter_swift())
        case .javascript: SwiftTreeSitter.Language(tree_sitter_javascript())
        case .typescript: SwiftTreeSitter.Language(tree_sitter_typescript())
        case .tsx: SwiftTreeSitter.Language(tree_sitter_tsx())
        case .python: SwiftTreeSitter.Language(tree_sitter_python())
        case .rust: SwiftTreeSitter.Language(tree_sitter_rust())
        case .go: SwiftTreeSitter.Language(tree_sitter_go())
        default: nil
        }
    }

    private static func load(_ language: SourceLanguage) -> Grammar? {
        switch language {
        case .swift:
            make(tree_sitter_swift(), [QueryFile(bundle: "TreeSitterSwift_TreeSitterSwift")])
        case .javascript:
            make(tree_sitter_javascript(), [javaScript, jsx])
        case .typescript:
            make(tree_sitter_typescript(),
                 [javaScript, QueryFile(bundle: "TreeSitterTypeScript_TreeSitterTypeScript")])
        case .tsx:
            make(tree_sitter_tsx(),
                 [javaScript, jsx, QueryFile(bundle: "TreeSitterTypeScript_TreeSitterTSX")])
        case .python:
            make(tree_sitter_python(), [QueryFile(bundle: "TreeSitterPython_TreeSitterPython")])
        case .json:
            make(tree_sitter_json(), [QueryFile(bundle: "TreeSitterJSON_TreeSitterJSON")])
        case .rust:
            make(tree_sitter_rust(), [QueryFile(bundle: "TreeSitterRust_TreeSitterRust")])
        case .go:
            make(tree_sitter_go(), [QueryFile(bundle: "TreeSitterGo_TreeSitterGo")])
        case .markdown, .c, .cpp, .objc, .html, .css, .yaml, .toml, .shell, .plaintext:
            nil
        }
    }

    /// Grammars that "inherit" another (TypeScript ← JavaScript) are built by concatenating query files.
    private static func make(_ tsLanguage: OpaquePointer, _ files: [QueryFile]) -> Grammar? {
        let language = SwiftTreeSitter.Language(tsLanguage)
        var source = Data()
        for file in files {
            guard let data = file.load() else {
                NSLog("OMC: missing highlight query \(file.bundle)/\(file.name).scm")
                return nil
            }
            source.append(data)
            source.append(0x0A)
        }
        do {
            return Grammar(language: language, highlightsQuery: try Query(language: language, data: source))
        } catch {
            NSLog("OMC: failed to compile highlight query: \(error)")
            return nil
        }
    }
}

private struct QueryFile {
    let bundle: String
    var name = "highlights"

    func load() -> Data? {
        let bundleURL = Bundle.main.resourceURL?.appending(path: "\(bundle).bundle")
        guard let bundleURL, let bundle = Bundle(url: bundleURL),
              let url = bundle.url(forResource: name, withExtension: "scm", subdirectory: "queries")
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
