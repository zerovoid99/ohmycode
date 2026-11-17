import Foundation
import Synchronization
import SwiftTreeSitter
import TreeSitterGo
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript

/// Immutable once compiled; tree-sitter lets threads share a query (each runs its own cursor).
struct Grammar: @unchecked Sendable {
    let language: SwiftTreeSitter.Language
    let highlightsQuery: Query
}

/// Loads tree-sitter grammars and compiles their highlight queries once per language, on
/// whichever thread asks first: `warmUp` does it in the background at launch, since Swift's
/// query takes ~100 ms to compile and would otherwise hold up opening the first Swift file.
enum GrammarRegistry {
    /// A language's grammar, compiled by whoever gets its lock first; the others wait for it.
    private final class Slot: @unchecked Sendable {
        let lock = NSLock()
        var grammar: Grammar?? // nil until loaded
    }

    private static let slots = Mutex<[SourceLanguage: Slot]>([:])

    static func grammar(for language: SourceLanguage) -> Grammar? {
        let slot = slots.withLock { slots in
            if let slot = slots[language] { return slot }
            let slot = Slot()
            slots[language] = slot
            return slot
        }
        return slot.lock.withLock {
            if let loaded = slot.grammar { return loaded }
            let grammar = load(language)
            slot.grammar = .some(grammar)
            return grammar
        }
    }

    /// Compiles the grammars in the background, the slowest first, before files ask for them.
    static func warmUp() {
        Thread.detachNewThread {
            for language in [SourceLanguage.swift, .tsx, .typescript, .rust, .javascript, .python, .go, .json] {
                _ = grammar(for: language)
            }
        }
    }

    private static let javaScript = QueryFile(bundle: "TreeSitterJavaScript_TreeSitterJavaScript", name: "highlights")
    private static let jsx = QueryFile(bundle: "TreeSitterJavaScript_TreeSitterJavaScript", name: "highlights-jsx")

    /// The tree-sitter language for parsing (no queries), from any thread.
    static func treeSitterLanguage(for language: SourceLanguage) -> SwiftTreeSitter.Language? {
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
        case .markdown, .c, .cpp, .objc, .html, .css, .yaml, .toml, .shell, .http, .plaintext:
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
