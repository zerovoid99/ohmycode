import Foundation

/// A TextMate rule as the grammar file writes it (`match`, `begin`/`end`, `include`…).
/// Immutable after loading; shared by every document using the grammar.
final class TextMateRawRule: @unchecked Sendable {
    let name: String?
    let contentName: String?
    let match: String?
    let begin: String?
    let end: String?
    let whilePattern: String?
    let captures: [Int: TextMateRawRule]?
    let beginCaptures: [Int: TextMateRawRule]?
    let endCaptures: [Int: TextMateRawRule]?
    let whileCaptures: [Int: TextMateRawRule]?
    let patterns: [TextMateRawRule]?
    let include: String?
    let repository: [String: TextMateRawRule]?
    let applyEndPatternLast: Bool

    init(_ object: [String: Any]) {
        name = object["name"] as? String
        contentName = object["contentName"] as? String
        match = Self.pattern(object["match"])
        begin = Self.pattern(object["begin"])
        end = Self.pattern(object["end"])
        whilePattern = Self.pattern(object["while"])
        captures = Self.captures(object["captures"])
        beginCaptures = Self.captures(object["beginCaptures"])
        endCaptures = Self.captures(object["endCaptures"])
        whileCaptures = Self.captures(object["whileCaptures"])
        patterns = (object["patterns"] as? [Any])?.compactMap { ($0 as? [String: Any]).map(TextMateRawRule.init) }
        include = object["include"] as? String
        repository = (object["repository"] as? [String: Any]).map { repository in
            repository.compactMapValues { ($0 as? [String: Any]).map(TextMateRawRule.init) }
        }
        switch object["applyEndPatternLast"] {
        case let flag as Bool: applyEndPatternLast = flag
        case let number as NSNumber: applyEndPatternLast = number.intValue != 0
        default: applyEndPatternLast = false
        }
    }

    /// Patterns are strings; a few grammars write a number (`"match": 0`).
    private static func pattern(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    /// `{ "1": { "name": … } }`, or an array indexed by group.
    private static func captures(_ value: Any?) -> [Int: TextMateRawRule]? {
        if let object = value as? [String: Any] {
            var result: [Int: TextMateRawRule] = [:]
            for (key, rule) in object {
                guard let index = Int(key), let rule = rule as? [String: Any] else { continue }
                result[index] = TextMateRawRule(rule)
            }
            return result
        }
        if let array = value as? [Any] {
            var result: [Int: TextMateRawRule] = [:]
            for (index, rule) in array.enumerated() {
                if let rule = rule as? [String: Any] { result[index] = TextMateRawRule(rule) }
            }
            return result
        }
        return nil
    }
}

/// A TextMate grammar file: `.tmLanguage.json`, or a `.tmLanguage` / `.plist` property list.
struct TextMateRawGrammar: Sendable {
    let scopeName: String
    /// The grammar's own patterns and repository (what `$self` and `$base` include).
    let root: TextMateRawRule
    /// `injections`: selector → rule, matched inside this grammar's documents.
    let injections: [(selector: String, rule: TextMateRawRule)]
    /// A grammar that's injected into others (`injectTo`) says where with this.
    let injectionSelector: String?
    let firstLineMatch: String?

    enum LoadError: LocalizedError {
        case unreadable(String)
        case noScopeName
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let detail): "The grammar can't be read: \(detail)"
            case .noScopeName: "The grammar has no “scopeName”."
            case .unsupportedFormat(let ext): "Grammars in .\(ext) files aren't supported: convert it to .tmLanguage.json."
            }
        }
    }

    static func load(_ url: URL) throws -> TextMateRawGrammar {
        let ext = url.pathExtension.lowercased()
        if ext == "yaml" || ext == "yml" { throw LoadError.unsupportedFormat(ext) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LoadError.unreadable(error.localizedDescription) }
        return try parse(data, isJSON: ext == "json" || url.lastPathComponent.lowercased().hasSuffix(".tmlanguage.json"))
    }

    static func parse(_ data: Data, isJSON: Bool? = nil) throws -> TextMateRawGrammar {
        let object: Any
        // A property list starts with "<?xml" or "<plist" (or "bplist"); anything else is JSON.
        let looksLikePlist = isJSON == false || (isJSON == nil && (data.starts(with: Data("<".utf8)) || data.starts(with: Data("bplist".utf8))))
        do {
            if looksLikePlist {
                object = try PropertyListSerialization.propertyList(from: data, format: nil)
            } else {
                object = try JSONSerialization.jsonObject(with: Data(VSCodeTheme.stripJSONC(String(decoding: data, as: UTF8.self)).utf8))
            }
        } catch {
            throw LoadError.unreadable((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else { throw LoadError.unreadable("not an object") }
        return try TextMateRawGrammar(dictionary)
    }

    init(_ object: [String: Any]) throws {
        guard let scopeName = object["scopeName"] as? String, !scopeName.isEmpty else { throw LoadError.noScopeName }
        self.scopeName = scopeName
        var rootObject: [String: Any] = ["patterns": object["patterns"] ?? []]
        rootObject["repository"] = object["repository"]
        rootObject["name"] = scopeName
        root = TextMateRawRule(rootObject)
        injections = (object["injections"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.compactMap { selector, rule in
            (rule as? [String: Any]).map { (selector, TextMateRawRule($0)) }
        }
        injectionSelector = object["injectionSelector"] as? String
        firstLineMatch = object["firstLineMatch"] as? String
    }
}

/// Where the tokenizer finds grammars by scope name: the one it starts with, those it
/// includes (`source.js#expression`) and those injected into it.
struct TextMateGrammarSource: Sendable {
    let grammar: @Sendable (String) -> TextMateRawGrammar?
    /// The grammars to inject into a document whose root scope is the argument (`injectTo`).
    let injections: @Sendable (String) -> [String]

    init(grammar: @escaping @Sendable (String) -> TextMateRawGrammar?, injections: @escaping @Sendable (String) -> [String] = { _ in [] }) {
        self.grammar = grammar
        self.injections = injections
    }

    /// A fixed set of grammars (tests, tools).
    static func fixed(_ grammars: [TextMateRawGrammar], injections: [String: [String]] = [:]) -> TextMateGrammarSource {
        let byScope = Dictionary(grammars.map { ($0.scopeName, $0) }, uniquingKeysWith: { $1 })
        return TextMateGrammarSource(grammar: { byScope[$0] }, injections: { injections[$0] ?? [] })
    }
}

/// A TextMate scope selector, as injections write them: `source.js -string`,
/// `L:text.html meta.tag`, `(string | comment)`, comma-separated alternatives.
struct ScopeSelector: Sendable {
    /// Which side wins a tie with the grammar's own patterns: `L:` (-1) before them, `R:` (1) after.
    struct Alternative: Sendable {
        let matcher: Matcher
        let priority: Int
    }

    indirect enum Matcher: Sendable {
        /// Scopes in this order (each a prefix match: `string` matches `string.quoted`).
        case path([String])
        case not(Matcher)
        case all([Matcher])
        case any([Matcher])

        func matches(_ scopes: [String]) -> Bool {
            switch self {
            case .path(let identifiers):
                var from = 0
                for identifier in identifiers {
                    guard let found = (from..<scopes.count).first(where: { ScopeSelector.scope(scopes[$0], matches: identifier) }) else {
                        return false
                    }
                    from = found + 1
                }
                return true
            case .not(let matcher): return !matcher.matches(scopes)
            case .all(let matchers): return matchers.allSatisfy { $0.matches(scopes) }
            case .any(let matchers): return matchers.contains { $0.matches(scopes) }
            }
        }
    }

    let alternatives: [Alternative]

    func matches(_ scopes: [String]) -> Bool { alternatives.contains { $0.matcher.matches(scopes) } }

    /// `string` matches `string` and `string.quoted.double`, not `strings`.
    static func scope(_ scope: String, matches identifier: String) -> Bool {
        scope == identifier || (scope.count > identifier.count && scope.hasPrefix(identifier) && scope[scope.index(scope.startIndex, offsetBy: identifier.count)] == ".")
    }

    init(_ source: String) {
        var parser = Parser(tokens: Self.tokens(source))
        alternatives = parser.parseSelector()
    }

    private static func tokens(_ source: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() { if !current.isEmpty { result.append(current); current = "" } }
        let chars = Array(source)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "L" || c == "R", index + 1 < chars.count, chars[index + 1] == ":", current.isEmpty {
                result.append(String(c) + ":")
                index += 2
                continue
            }
            if c == "," || c == "|" || c == "(" || c == ")" || (c == "-" && current.isEmpty) {
                flush()
                result.append(String(c))
            } else if c.isWhitespace {
                flush()
            } else {
                current.append(c)
            }
            index += 1
        }
        flush()
        return result
    }

    private struct Parser {
        let tokens: [String]
        var index = 0

        var token: String? { index < tokens.count ? tokens[index] : nil }

        static func isIdentifier(_ token: String?) -> Bool {
            guard let token else { return false }
            return !["," , "|", "(", ")", "-", "L:", "R:"].contains(token)
        }

        mutating func parseSelector() -> [Alternative] {
            var result: [Alternative] = []
            while token != nil {
                var priority = 0
                if token == "L:" { priority = -1; index += 1 } else if token == "R:" { priority = 1; index += 1 }
                if let matcher = parseConjunction() { result.append(Alternative(matcher: matcher, priority: priority)) }
                guard token == "," else {
                    if token != nil { index += 1; continue } // skip what can't be parsed
                    break
                }
                index += 1
            }
            return result
        }

        mutating func parseOperand() -> Matcher? {
            if token == "-" {
                index += 1
                return parseOperand().map { .not($0) }
            }
            if token == "(" {
                index += 1
                let inner = parseInner()
                if token == ")" { index += 1 }
                return inner
            }
            guard Self.isIdentifier(token) else { return nil }
            var identifiers: [String] = []
            while Self.isIdentifier(token), let current = token {
                identifiers.append(current)
                index += 1
            }
            return .path(identifiers)
        }

        mutating func parseConjunction() -> Matcher? {
            var matchers: [Matcher] = []
            while let matcher = parseOperand() { matchers.append(matcher) }
            return matchers.isEmpty ? nil : (matchers.count == 1 ? matchers[0] : .all(matchers))
        }

        mutating func parseInner() -> Matcher? {
            var matchers: [Matcher] = []
            while let matcher = parseConjunction() {
                matchers.append(matcher)
                guard token == "|" || token == "," else { break }
                while token == "|" || token == "," { index += 1 }
            }
            return matchers.isEmpty ? nil : .any(matchers)
        }
    }
}
