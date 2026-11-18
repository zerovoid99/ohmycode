import Foundation
import Synchronization
import SwiftTreeSitter

/// A TextMate grammar an extension contributes (`contributes.grammars`, VS Code's shape).
struct TextMateGrammarContribution: Sendable, Equatable {
    /// The language it highlights; nil for a grammar that's only included or injected.
    var language: String?
    var scopeName: String
    var url: URL
    /// Scopes of embedded code → the language it's in (`meta.embedded.block.javascript`).
    var embeddedLanguages: [String: String] = [:]
    var tokenTypes: [String: String] = [:]
    /// Root scopes of the grammars it's injected into (with its `injectionSelector`).
    var injectTo: [String] = []
    /// Used for a language that has built-in highlighting too.
    var override = false
    var extensionID: String
    /// When the file last changed: a grammar edited in place (an extension installed for
    /// development, then reloaded) is a new contribution, so open files pick it up.
    var modified: Date?
}

/// A tree-sitter parser an extension contributes (`contributes.treeSitterGrammars`).
struct TreeSitterGrammarContribution: Sendable, Equatable {
    var language: String
    /// As extension.json gives it, relative to the extension's folder.
    var library: String
    var symbol: String
    /// "highlights", "folds", "injections", "locals", "indents" → the query file.
    var queries: [String: URL] = [:]
    var override = false
    var extensionID: String
    /// The extension's folder: the library must be inside it.
    var folder: URL
    /// Whether the extension was granted `nativeCode`.
    var permitted: Bool
    /// When its query files last changed (see `TextMateGrammarContribution.modified`). A
    /// rebuilt library is only read again after a restart: one already loaded stays loaded.
    var modified: Date?
}

/// What colors a language's files.
enum HighlightingEngine: String, Sendable, CaseIterable {
    case builtIn = "builtin"
    case treeSitter = "tree-sitter"
    case textMate = "textmate"

    var title: String {
        switch self {
        case .builtIn: "Built-in"
        case .treeSitter: "Tree-sitter (extension)"
        case .textMate: "TextMate (extension)"
        }
    }
}

/// The grammars extensions contribute, loaded on first use, from any thread. Changes post
/// `LanguageRegistry.didChange` (open files pick their highlighting again).
final class ContributedGrammars: @unchecked Sendable {
    static let shared = ContributedGrammars()

    private struct State {
        var textMate: [(extensionID: String, grammars: [TextMateGrammarContribution])] = []
        var treeSitter: [(extensionID: String, grammars: [TreeSitterGrammarContribution])] = []
        var rawGrammars: [String: TextMateRawGrammar?] = [:]
        var treeSitterGrammars: [String: Result<Grammar, Error>] = [:]
        /// Bumped by every change: highlighters made before it are out of date.
        var generation = 0
    }

    private let state = Mutex(State())
    /// Problems loading a grammar, by extension id (shown in the extension's log).
    let problems = Mutex<[String: [String]]>([:])

    // MARK: Contributions

    func setContributions(textMate: [TextMateGrammarContribution], treeSitter: [TreeSitterGrammarContribution],
                          from extensionID: String) {
        let changed = state.withLock { state -> Bool in
            let oldTextMate = state.textMate.first { $0.extensionID == extensionID }?.grammars ?? []
            let oldTreeSitter = state.treeSitter.first { $0.extensionID == extensionID }?.grammars ?? []
            guard oldTextMate != textMate || oldTreeSitter != treeSitter else { return false }
            state.textMate.removeAll { $0.extensionID == extensionID }
            state.treeSitter.removeAll { $0.extensionID == extensionID }
            if !textMate.isEmpty { state.textMate.append((extensionID, textMate)) }
            if !treeSitter.isEmpty { state.treeSitter.append((extensionID, treeSitter)) }
            // Files may have changed with the contribution (a reinstall): read them again.
            state.rawGrammars.removeAll()
            state.treeSitterGrammars.removeAll()
            state.generation += 1
            return true
        }
        guard changed else { return }
        problems.withLock { $0[extensionID] = nil }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: LanguageRegistry.didChange, object: self)
        } else {
            DispatchQueue.main.async { NotificationCenter.default.post(name: LanguageRegistry.didChange, object: self) }
        }
    }

    var generation: Int { state.withLock { $0.generation } }

    private var allTextMate: [TextMateGrammarContribution] { state.withLock { $0.textMate.flatMap(\.grammars) } }
    private var allTreeSitter: [TreeSitterGrammarContribution] { state.withLock { $0.treeSitter.flatMap(\.grammars) } }

    /// The TextMate grammar for a language (the last extension's, when several give one).
    func textMateContribution(for language: SourceLanguage) -> TextMateGrammarContribution? {
        allTextMate.last { $0.language.map { SourceLanguage(languageId: $0) } == language }
    }

    func treeSitterContribution(for language: SourceLanguage) -> TreeSitterGrammarContribution? {
        allTreeSitter.last { SourceLanguage(languageId: $0.language) == language }
    }

    /// The language a scope of embedded code is in, by the grammars' `embeddedLanguages`.
    func embeddedLanguage(forScopes scopes: [String]) -> String? {
        let grammars = allTextMate
        for scope in scopes.reversed() {
            for grammar in grammars {
                if let language = grammar.embeddedLanguages.first(where: { ScopeSelector.scope(scope, matches: $0.key) })?.value {
                    return language
                }
            }
        }
        return nil
    }

    // MARK: Choosing

    /// The engines `language` can be highlighted with.
    func availableEngines(for language: SourceLanguage) -> [HighlightingEngine] {
        var engines: [HighlightingEngine] = []
        if GrammarRegistry.hasBuiltInHighlighting(language) { engines.append(.builtIn) }
        if treeSitterContribution(for: language) != nil { engines.append(.treeSitter) }
        if textMateContribution(for: language) != nil { engines.append(.textMate) }
        return engines
    }

    /// The engines to try for `language`, best first. The user's pick (Settings ▸ Languages)
    /// comes first. Otherwise a language without built-in highlighting takes a contributed
    /// tree-sitter grammar over a TextMate one; a language with it keeps it, unless a
    /// contribution says `"override": true`.
    func preference(for language: SourceLanguage, choice: String? = nil) -> [HighlightingEngine] {
        let available = availableEngines(for: language)
        var order: [HighlightingEngine] = []
        if let choice, let engine = HighlightingEngine(rawValue: choice), available.contains(engine) { order.append(engine) }
        if available.contains(.builtIn) {
            if treeSitterContribution(for: language)?.override == true { order.append(.treeSitter) }
            if textMateContribution(for: language)?.override == true { order.append(.textMate) }
            order.append(.builtIn)
        }
        order += [.treeSitter, .textMate].filter(available.contains)
        var seen = Set<HighlightingEngine>()
        return order.filter { seen.insert($0).inserted }
    }

    // MARK: TextMate

    /// The grammars, by scope name, for the tokenizer (loaded on first use).
    var source: TextMateGrammarSource {
        TextMateGrammarSource(grammar: { [self] in rawGrammar(scope: $0) }, injections: { [self] in injections(into: $0) })
    }

    func rawGrammar(scope: String) -> TextMateRawGrammar? {
        if let cached = state.withLock({ $0.rawGrammars[scope] }) { return cached }
        guard let contribution = allTextMate.last(where: { $0.scopeName == scope }) else { return nil }
        var grammar: TextMateRawGrammar?
        do {
            grammar = try TextMateRawGrammar.load(contribution.url)
            if grammar?.scopeName != scope {
                report("\(contribution.url.lastPathComponent): its scopeName is “\(grammar?.scopeName ?? "")”, not “\(scope)” as extension.json says.",
                       extensionID: contribution.extensionID)
            }
        } catch {
            report("\(contribution.url.lastPathComponent): \(error.localizedDescription)", extensionID: contribution.extensionID)
        }
        state.withLock { $0.rawGrammars[scope] = .some(grammar) }
        return grammar
    }

    func injections(into scope: String) -> [String] {
        allTextMate.filter { $0.injectTo.contains(scope) }.map(\.scopeName)
    }

    // MARK: Tree-sitter

    /// A contributed parser with its queries compiled (loaded once; nil if it can't be, with
    /// why in the extension's log).
    func treeSitterGrammar(for language: SourceLanguage) -> Grammar? {
        guard let contribution = treeSitterContribution(for: language) else { return nil }
        if let cached = state.withLock({ $0.treeSitterGrammars[contribution.language] }) { return try? cached.get() }
        let result = Result { try NativeGrammarLoader.loadGrammar(contribution) }
        if case .failure(let error) = result {
            report("Tree-sitter grammar for “\(contribution.language)”: \(error.localizedDescription)", extensionID: contribution.extensionID)
        }
        state.withLock { $0.treeSitterGrammars[contribution.language] = result }
        return try? result.get()
    }

    private func report(_ problem: String, extensionID: String) {
        NSLog("OMC: \(extensionID): \(problem)")
        problems.withLock { $0[extensionID, default: []].append(problem) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didReportProblem, object: extensionID) }
    }

    static let didReportProblem = Notification.Name("omcContributedGrammarProblem")
}

/// Loads a tree-sitter parser an extension ships as a dynamic library. This runs the
/// extension's native code inside the app, so it needs the `nativeCode` permission (asked
/// for when the extension is installed) and the library must be inside the extension's folder.
enum NativeGrammarLoader {
    /// The ABI versions the linked tree-sitter runtime reads: its
    /// TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION through TREE_SITTER_LANGUAGE_VERSION
    /// (13–15 with tree-sitter 0.25).
    static let supportedABIVersions = SwiftTreeSitter.Language.minimumCompatibleVersion...SwiftTreeSitter.Language.version

    enum LoadError: LocalizedError, Equatable {
        case permission
        case outside(String)
        case missing(String)
        case cannotOpen(String)
        case invalidSymbol(String)
        case missingSymbol(String)
        case incompatibleABI(Int)
        case query(String, String)

        var errorDescription: String? {
            switch self {
            case .permission:
                "Loading a tree-sitter parser runs native code: the extension needs \"nativeCode\" in “permissions”."
            case .outside(let path): "“\(path)” must be inside the extension's folder."
            case .missing(let path): "The parser library \(path) doesn't exist (build it with build-tree-sitter-grammar.sh)."
            case .cannotOpen(let detail): "The parser library can't be loaded: \(detail)"
            case .invalidSymbol(let symbol): "“\(symbol)” isn't a tree-sitter language function (tree_sitter_<name>)."
            case .missingSymbol(let symbol): "The parser library has no function “\(symbol)”."
            case .incompatibleABI(let version):
                "The parser was generated for tree-sitter ABI \(version); this app reads ABI \(supportedABIVersions.lowerBound)–\(supportedABIVersions.upperBound). Regenerate it with a matching tree-sitter CLI."
            case .query(let name, let detail): "\(name).scm doesn't compile: \(detail)"
            }
        }
    }

    /// Libraries opened so far, by path (never closed: their languages stay in use).
    private static let handles = Mutex<[String: UInt]>([:])

    /// The language a library's `symbol` returns, checked against the runtime's ABI range.
    /// `library` is the path extension.json gives, relative to the extension's `folder`.
    static func loadLanguage(library relative: String, symbol: String, folder: URL, permitted: Bool) throws -> SwiftTreeSitter.Language {
        guard permitted else { throw LoadError.permission }
        guard let url = ExtensionManifest.inside(folder, relative) else { throw LoadError.outside(relative) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.missing(relative) }
        guard symbol.hasPrefix("tree_sitter_"), symbol.count > 12,
              symbol.unicodeScalars.allSatisfy({ ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "_" })
        else { throw LoadError.invalidSymbol(symbol) }
        let handle: UnsafeMutableRawPointer
        if let open = handles.withLock({ $0[url.path] }).flatMap({ UnsafeMutableRawPointer(bitPattern: $0) }) {
            handle = open
        } else {
            guard let opened = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
                throw LoadError.cannotOpen(dlerror().map { String(cString: $0) } ?? "unknown error")
            }
            let bits = UInt(bitPattern: opened)
            handles.withLock { $0[url.path] = bits }
            handle = opened
        }
        guard let function = dlsym(handle, symbol) else { throw LoadError.missingSymbol(symbol) }
        typealias LanguageFunction = @convention(c) () -> OpaquePointer?
        guard let pointer = unsafeBitCast(function, to: LanguageFunction.self)() else { throw LoadError.missingSymbol(symbol) }
        let language = SwiftTreeSitter.Language(pointer)
        guard supportedABIVersions.contains(language.ABIVersion) else { throw LoadError.incompatibleABI(language.ABIVersion) }
        return language
    }

    static func loadGrammar(_ contribution: TreeSitterGrammarContribution) throws -> Grammar {
        let language = try loadLanguage(library: contribution.library, symbol: contribution.symbol, folder: contribution.folder,
                                        permitted: contribution.permitted)
        func query(_ name: String) throws -> Query? {
            guard let url = contribution.queries[name] else { return nil }
            do {
                return try Query(language: language, data: Data(contentsOf: url))
            } catch {
                throw LoadError.query(name, String(describing: error))
            }
        }
        // Without highlights.scm the parser still gives folding and sticky scroll.
        let highlights = try query("highlights") ?? Query(language: language, data: Data())
        return Grammar(language: language, highlightsQuery: highlights, foldsQuery: try query("folds"))
    }
}
