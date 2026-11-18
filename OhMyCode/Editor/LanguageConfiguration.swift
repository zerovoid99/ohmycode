import Foundation
import Synchronization

/// How the editor treats a language's text, from an extension's `language-configuration.json`
/// (VS Code's format): comments, brackets, what closes itself, folding markers, what a word
/// is, and how Enter indents. Every part is optional: what's missing keeps the editor's
/// built-in behavior.
struct LanguageConfiguration: Sendable, Equatable {
    struct Comments: Sendable, Equatable {
        var lineComment: String?
        var blockComment: (start: String, end: String)?

        static func == (a: Comments, b: Comments) -> Bool {
            a.lineComment == b.lineComment && a.blockComment?.start == b.blockComment?.start && a.blockComment?.end == b.blockComment?.end
        }
    }

    /// A pair that closes itself; `notIn` ("string", "comment") is where it doesn't.
    struct Pair: Sendable, Equatable {
        var open: String
        var close: String
        var notIn: Set<String> = []
    }

    /// A regular expression as VS Code writes them (JavaScript syntax, which NSRegularExpression
    /// mostly shares), with its flags ("i").
    struct Pattern: Sendable, Equatable {
        var source: String
        var flags: String = ""

        var regex: NSRegularExpression? { Self.compiled(source, flags) }

        func matches(_ text: String) -> Bool {
            guard let regex else { return false }
            return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }

        private static let cache = Mutex<[String: NSRegularExpression?]>([:])

        private static func compiled(_ source: String, _ flags: String) -> NSRegularExpression? {
            let key = flags + "/" + source
            if let cached = cache.withLock({ $0[key] }) { return cached }
            var options: NSRegularExpression.Options = []
            if flags.contains("i") { options.insert(.caseInsensitive) }
            if flags.contains("m") { options.insert(.anchorsMatchLines) }
            if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
            let regex = try? NSRegularExpression(pattern: source, options: options)
            cache.withLock { $0[key] = .some(regex) }
            return regex
        }
    }

    struct IndentationRules: Sendable, Equatable {
        var increaseIndent: Pattern?
        var decreaseIndent: Pattern?
        var indentNextLine: Pattern?
        var unIndentedLine: Pattern?
    }

    struct OnEnterRule: Sendable, Equatable {
        enum Indent: String, Sendable { case none, indent, outdent, indentOutdent }
        var beforeText: Pattern
        var afterText: Pattern?
        var previousLineText: Pattern?
        var indent: Indent
        var appendText: String?
        var removeText: Int?
    }

    var comments: Comments?
    var brackets: [(open: String, close: String)]?
    var autoClosingPairs: [Pair]?
    var surroundingPairs: [(open: String, close: String)]?
    var autoCloseBefore: String?
    var foldingMarkers: (start: Pattern, end: Pattern)?
    var offSide: Bool?
    var wordPattern: Pattern?
    var indentationRules: IndentationRules?
    var onEnterRules: [OnEnterRule]?

    static func == (a: LanguageConfiguration, b: LanguageConfiguration) -> Bool {
        func same(_ x: [(open: String, close: String)]?, _ y: [(open: String, close: String)]?) -> Bool {
            x?.map { [$0.open, $0.close] } == y?.map { [$0.open, $0.close] }
        }
        return a.comments == b.comments && same(a.brackets, b.brackets) && a.autoClosingPairs == b.autoClosingPairs
            && same(a.surroundingPairs, b.surroundingPairs) && a.autoCloseBefore == b.autoCloseBefore
            && a.foldingMarkers?.start == b.foldingMarkers?.start && a.foldingMarkers?.end == b.foldingMarkers?.end
            && a.offSide == b.offSide && a.wordPattern == b.wordPattern && a.indentationRules == b.indentationRules
            && a.onEnterRules == b.onEnterRules
    }

    init() {}

    /// Reads a `language-configuration.json` (comments and trailing commas allowed, as VS Code
    /// allows them). Parts it doesn't understand are left out.
    init(json data: Data) throws {
        let cleaned = ProjectSettings.stripComments(String(decoding: data, as: UTF8.self))
        guard let object = try JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        self.init(object: object)
    }

    init(object: [String: Any]) {
        if let comments = object["comments"] as? [String: Any] {
            let block = comments["blockComment"] as? [String]
            self.comments = Comments(lineComment: comments["lineComment"] as? String,
                                     blockComment: block.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil })
        }
        brackets = (object["brackets"] as? [[String]])?.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        autoClosingPairs = (object["autoClosingPairs"] as? [Any])?.compactMap(Self.pair)
        surroundingPairs = (object["surroundingPairs"] as? [Any])?.compactMap(Self.pair).map { ($0.open, $0.close) }
        autoCloseBefore = object["autoCloseBefore"] as? String
        if let folding = object["folding"] as? [String: Any] {
            offSide = folding["offSide"] as? Bool
            if let markers = folding["markers"] as? [String: Any],
               let start = Self.pattern(markers["start"]), let end = Self.pattern(markers["end"]) {
                foldingMarkers = (start, end)
            }
        }
        wordPattern = Self.pattern(object["wordPattern"])
        if let rules = object["indentationRules"] as? [String: Any] {
            indentationRules = IndentationRules(increaseIndent: Self.pattern(rules["increaseIndentPattern"]),
                                                decreaseIndent: Self.pattern(rules["decreaseIndentPattern"]),
                                                indentNextLine: Self.pattern(rules["indentNextLinePattern"]),
                                                unIndentedLine: Self.pattern(rules["unIndentedLinePattern"]))
        }
        onEnterRules = (object["onEnterRules"] as? [[String: Any]])?.compactMap { rule in
            guard let before = Self.pattern(rule["beforeText"]), let action = rule["action"] as? [String: Any] else { return nil }
            let indent = (action["indent"] as? String).flatMap(OnEnterRule.Indent.init(rawValue:))
                ?? (action["indentAction"] as? Int).flatMap { [OnEnterRule.Indent.none, .indent, .indentOutdent, .outdent][safe: $0] }
                ?? .none
            return OnEnterRule(beforeText: before, afterText: Self.pattern(rule["afterText"]),
                               previousLineText: Self.pattern(rule["previousLineText"]), indent: indent,
                               appendText: action["appendText"] as? String, removeText: action["removeText"] as? Int)
        }
    }

    /// `["(", ")"]` or `{ "open": "(", "close": ")", "notIn": ["string"] }`.
    private static func pair(_ value: Any) -> Pair? {
        if let list = value as? [String], list.count == 2, !list[0].isEmpty { return Pair(open: list[0], close: list[1]) }
        guard let object = value as? [String: Any], let open = object["open"] as? String, !open.isEmpty,
              let close = object["close"] as? String else { return nil }
        return Pair(open: open, close: close, notIn: Set(object["notIn"] as? [String] ?? []))
    }

    /// `"^\\s*//"` or `{ "pattern": "…", "flags": "i" }`.
    private static func pattern(_ value: Any?) -> Pattern? {
        if let source = value as? String { return Pattern(source: source) }
        guard let object = value as? [String: Any], let source = object["pattern"] as? String else { return nil }
        return Pattern(source: source, flags: object["flags"] as? String ?? "")
    }

    /// `other`'s parts over these (an extension's configuration for a language that has one).
    func merged(with other: LanguageConfiguration) -> LanguageConfiguration {
        var result = self
        if let value = other.comments { result.comments = value }
        if let value = other.brackets { result.brackets = value }
        if let value = other.autoClosingPairs { result.autoClosingPairs = value }
        if let value = other.surroundingPairs { result.surroundingPairs = value }
        if let value = other.autoCloseBefore { result.autoCloseBefore = value }
        if let value = other.foldingMarkers { result.foldingMarkers = value }
        if let value = other.offSide { result.offSide = value }
        if let value = other.wordPattern { result.wordPattern = value }
        if let value = other.indentationRules { result.indentationRules = value }
        if let value = other.onEnterRules { result.onEnterRules = value }
        return result
    }

    // MARK: Using it

    /// Characters a pair closes itself before when `autoCloseBefore` isn't set (VS Code's).
    static let defaultAutoCloseBefore = ";:.,=}])> \n\t"

    /// Fold regions from `folding.markers` (`// #region` … `// #endregion`), nested.
    static func markerRegions(_ markers: (start: Pattern, end: Pattern), lines: [Substring]) -> [FoldRegion] {
        var open: [Int] = []
        var regions: [FoldRegion] = []
        for (number, line) in lines.enumerated() {
            let text = String(line)
            if markers.start.matches(text) {
                open.append(number)
            } else if markers.end.matches(text), let start = open.popLast(), number > start {
                regions.append(FoldRegion(start: start, end: number, kind: .region))
            }
        }
        return regions.sorted { $0.start < $1.start }
    }

    /// The range of the word (as `wordPattern` defines it) that contains or touches `index`
    /// in `line` (UTF-16 offsets within the line).
    func wordRange(in line: String, at index: Int) -> NSRange? {
        guard let regex = wordPattern?.regex else { return nil }
        let length = (line as NSString).length
        for match in regex.matches(in: line, range: NSRange(location: 0, length: length)) where match.range.length > 0 {
            if match.range.location <= index && index <= NSMaxRange(match.range) { return match.range }
            if match.range.location > index { break }
        }
        return nil
    }
}
