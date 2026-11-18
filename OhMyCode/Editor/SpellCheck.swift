import AppKit

/// A word to check, where it is (UTF-16, in the text it was read from) and what it is.
struct SpellToken: Equatable, Sendable {
    var range: NSRange
    var word: String
    /// Part of a name in code (not a comment's or string's prose).
    var isIdentifier = false
}

/// A word the spell checker doesn't know.
struct SpellIssue: Equatable, Sendable {
    var range: NSRange
    var word: String
    var isIdentifier: Bool
}

// MARK: Words

/// How text is cut into words to check: names split at their case changes, underscores,
/// hyphens and digits; prose at spaces and punctuation, with what isn't words (links, paths,
/// numbers) left out.
enum SpellWords {
    private enum Kind { case upper, lower, digit, other }

    private static func kind(_ unit: unichar) -> Kind {
        switch unit {
        case 0x41...0x5A: return .upper
        case 0x61...0x7A: return .lower
        case 0x30...0x39: return .digit
        case 0..<0x80: return .other
        default:
            // Surrogates (letters outside the BMP) aren't split; they end a word.
            guard let scalar = Unicode.Scalar(unit), scalar.properties.isAlphabetic else { return .other }
            return scalar.properties.isUppercase ? .upper : .lower
        }
    }

    /// The words of a name: `parseHTTPResponse` → parse, HTTP, Response; `URLSession` → URL,
    /// Session; `snake_case`, `SCREAMING_CASE`, `kebab-case` at their separators; digits
    /// separate words (`sha256Hash` → sha, Hash). Plural acronyms stay whole (`URLs`).
    static func split(_ identifier: String) -> [SpellToken] {
        split(identifier as NSString, range: NSRange(location: 0, length: (identifier as NSString).length))
    }

    /// `split` of part of a string; ranges are in `text`.
    static func split(_ text: NSString, range: NSRange) -> [SpellToken] {
        var result: [SpellToken] = []
        let end = NSMaxRange(range)
        var kinds = [Kind](repeating: .other, count: range.length)
        for index in 0..<range.length { kinds[index] = kind(text.character(at: range.location + index)) }
        func isUpper(_ i: Int) -> Bool { i < range.length && kinds[i] == .upper }
        func isLower(_ i: Int) -> Bool { i < range.length && kinds[i] == .lower }
        func emit(_ start: Int, _ stop: Int) {
            guard stop > start else { return }
            let found = NSRange(location: range.location + start, length: stop - start)
            result.append(SpellToken(range: found, word: text.substring(with: found)))
        }
        var i = 0
        while i < end - range.location {
            if isUpper(i) {
                var j = i + 1
                while isUpper(j) { j += 1 }
                if isLower(j) {
                    if j - i > 1 {
                        // "URLs": a plural acronym, not "UR" + "Ls".
                        if text.character(at: range.location + j) == 0x73, !isLower(j + 1) {
                            emit(i, j + 1)
                            i = j + 1
                            continue
                        }
                        emit(i, j - 1) // "HTTPResponse": the last capital starts the next word
                        i = j - 1
                        continue
                    }
                    var k = j
                    while isLower(k) { k += 1 }
                    emit(i, k)
                    i = k
                } else {
                    emit(i, j)
                    i = j
                }
            } else if isLower(i) {
                var k = i + 1
                while isLower(k) { k += 1 }
                emit(i, k)
                i = k
            } else {
                i += 1
            }
        }
        return result
    }

    /// The names in code: runs of letters, digits, `_` and `$` (and `-` between letters, in
    /// languages whose names have them), split into words. Numbers are skipped.
    static func identifierWords(in text: NSString, range: NSRange, allowsHyphen: Bool = false) -> [SpellToken] {
        var result: [SpellToken] = []
        let end = NSMaxRange(range)
        var i = range.location
        func isNameUnit(_ unit: unichar) -> Bool {
            kind(unit) != .other || unit == 0x5F || unit == 0x24
        }
        while i < end {
            let unit = text.character(at: i)
            guard isNameUnit(unit) else { i += 1; continue }
            var j = i + 1
            while j < end {
                let next = text.character(at: j)
                if isNameUnit(next) { j += 1; continue }
                if allowsHyphen, next == 0x2D, j + 1 < end, kind(text.character(at: j + 1)) == .lower || kind(text.character(at: j + 1)) == .upper {
                    j += 1
                    continue
                }
                break
            }
            if kind(unit) != .digit {
                result += split(text, range: NSRange(location: i, length: j - i)).map {
                    SpellToken(range: $0.range, word: $0.word, isIdentifier: true)
                }
            }
            i = j
        }
        return result
    }

    private static let chunkTrim = CharacterSet(charactersIn: "()[]{}<>\"'`,.;:!?*“”‘’")

    /// The words of prose (a comment, a string, Markdown): each whitespace-separated piece
    /// that isn't a link, path, email, number or encoded data, cut at punctuation; names in
    /// it are split like code's. Pieces with digits, and escapes (`\n`), are left out.
    static func proseWords(in text: NSString, range: NSRange) -> [SpellToken] {
        var result: [SpellToken] = []
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            while i < end, isSpace(text.character(at: i)) { i += 1 }
            var j = i
            while j < end, !isSpace(text.character(at: j)) { j += 1 }
            if j > i {
                let chunk = NSRange(location: i, length: j - i)
                if !SpellRules.skipsChunk(text.substring(with: chunk).trimmingCharacters(in: chunkTrim)) {
                    result += words(inChunk: chunk, of: text)
                }
            }
            i = j
        }
        return result
    }

    private static func isSpace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0xA0
    }

    private static func isApostrophe(_ unit: unichar) -> Bool { unit == 0x27 || unit == 0x2019 }

    private static func words(inChunk chunk: NSRange, of text: NSString) -> [SpellToken] {
        var result: [SpellToken] = []
        let end = NSMaxRange(chunk)
        var i = chunk.location
        while i < end {
            let unit = text.character(at: i)
            guard kind(unit) != .other || unit == 0x5F else { i += 1; continue }
            var start = i
            var j = i + 1
            var hasDigit = kind(unit) == .digit
            var apostrophe: Int?
            while j < end {
                let next = text.character(at: j)
                if kind(next) != .other || next == 0x5F {
                    if kind(next) == .digit { hasDigit = true }
                    j += 1
                } else if isApostrophe(next), apostrophe == nil, j + 1 < end, kind(text.character(at: j + 1)) == .lower {
                    apostrophe = j
                    j += 1
                } else {
                    break
                }
            }
            // An escape (`\n`, `\t`) glued to the word after it.
            if start > chunk.location, text.character(at: start - 1) == 0x5C, j - start > 1,
               "ntrbfvae0".utf16.contains(text.character(at: start)) {
                start += 1
            }
            defer { i = j }
            guard !hasDigit else { continue }
            if let apostrophe {
                let suffix = text.substring(with: NSRange(location: apostrophe + 1, length: j - apostrophe - 1))
                if suffix == "s" {
                    // A possessive: the word before it.
                    result += split(text, range: NSRange(location: start, length: apostrophe - start))
                } else {
                    // "doesn't": checked whole.
                    let range = NSRange(location: start, length: j - start)
                    result.append(SpellToken(range: range, word: text.substring(with: range)))
                }
            } else {
                result += split(text, range: NSRange(location: start, length: j - start))
            }
        }
        return result
    }
}

// MARK: Rules

/// What isn't checked.
enum SpellRules {
    /// Shorter words are left alone (abbreviations: `buf`, `ctx`, `idx`).
    static let minimumLength = 4

    private static let uuid = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    /// A whitespace-separated piece of prose that isn't words: a URL, an email address, a
    /// path, a hex number or color, a UUID, or base64-like data.
    static func skipsChunk(_ chunk: String) -> Bool {
        guard chunk.count >= 2 else { return false }
        if chunk.contains("://") || chunk.hasPrefix("www.") || chunk.hasPrefix("mailto:") { return true }
        if let at = chunk.firstIndex(of: "@"), at != chunk.startIndex, chunk[at...].contains(".") { return true }
        if chunk.contains("/") || chunk.hasPrefix("~") || chunk.hasPrefix("./") { return true }
        if chunk.contains("\\"), chunk.contains(":\\") || chunk.filter({ $0 == "\\" }).count > 1 { return true }
        let lower = chunk.lowercased()
        if lower.hasPrefix("0x") || (lower.hasPrefix("#") && lower.dropFirst().allSatisfy(\.isHexDigit) && lower.count > 3) { return true }
        if uuid.firstMatch(in: chunk, range: NSRange(location: 0, length: (chunk as NSString).length)) != nil { return true }
        return looksEncoded(chunk)
    }

    /// Base64-like or hex data: long, with no spaces, of letters and digits (and `+/=_-`), with
    /// digits or several case changes in it.
    static func looksEncoded(_ chunk: String) -> Bool {
        guard chunk.count >= 16 else { return false }
        let allowed = chunk.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "+/=_-".unicodeScalars.contains($0)
        }
        guard allowed else { return false }
        if chunk.allSatisfy(\.isHexDigit) { return true }
        let digits = chunk.filter(\.isNumber).count
        var changes = 0
        var previousUpper: Bool?
        for character in chunk where character.isLetter {
            if let previous = previousUpper, previous != character.isUppercase { changes += 1 }
            previousUpper = character.isUppercase
        }
        return digits >= 2 || chunk.hasSuffix("=") || changes > chunk.count / 3
    }

    /// A word that isn't checked: too short, with digits, all capitals and short (an acronym),
    /// or hex (`deadbeef`).
    static func skipsWord(_ word: String) -> Bool {
        let length = (word as NSString).length
        if length < minimumLength { return true }
        if word.contains(where: \.isNumber) { return true }
        if length <= 4, word == word.uppercased() { return true }
        if length >= 8, word.allSatisfy(\.isHexDigit) { return true }
        return false
    }
}

// MARK: Case

enum SpellCase {
    /// A suggestion written the way the word it replaces is: `RECIEVE` → `RECEIVE`, `Recieve` →
    /// `Receive`, `recieve` → `receive`.
    static func match(_ suggestion: String, to original: String) -> String {
        let letters = original.filter(\.isLetter)
        guard let first = letters.first else { return suggestion }
        if letters.count > 1, letters == letters.uppercased() { return suggestion.uppercased() }
        if first.isUppercase {
            return suggestion.prefix(1).uppercased() + suggestion.dropFirst()
        }
        if letters == letters.lowercased() { return suggestion.lowercased() }
        return suggestion
    }

    /// Up to `limit` of the checker's guesses for a word, written like it. In a name, only
    /// guesses that are one word (letters only) fit.
    static func suggestions(_ guesses: [String], for word: String, isIdentifier: Bool, limit: Int = 5) -> [String] {
        var result: [String] = []
        for guess in guesses {
            if isIdentifier, !guess.allSatisfy(\.isLetter) { continue }
            let matched = match(guess, to: word)
            if matched != word, !result.contains(matched) { result.append(matched) }
            if result.count == limit { break }
        }
        return result
    }
}

// MARK: Directives

/// `spell-checker: disable` / `enable` / `ignore word…` comments (also `cspell:`).
struct SpellDirectives: Equatable {
    /// Where checking is off (between a `disable` and the next `enable`, or the end).
    var disabled: [NSRange] = []
    /// Words accepted (lowercased).
    var ignored: Set<String> = []

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:spell-?checker|cspell)\s*:\s*(disable|enable|ignore|words)\b([^\n]*)"#, options: [.caseInsensitive])

    /// The directives in `text` (positions in it).
    static func parse(_ text: NSString) -> SpellDirectives {
        var result = SpellDirectives()
        guard text.range(of: "spell", options: [.caseInsensitive, .literal]).location != NSNotFound else { return result }
        var disabledFrom: Int?
        for match in pattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let verb = text.substring(with: match.range(at: 1)).lowercased()
            switch verb {
            case "disable":
                if disabledFrom == nil { disabledFrom = NSMaxRange(match.range) }
            case "enable":
                if let start = disabledFrom {
                    result.disabled.append(NSRange(location: start, length: match.range.location - start))
                    disabledFrom = nil
                }
            default:
                var rest = text.substring(with: match.range(at: 2))
                for end in ["*/", "-->", "#}"] { rest = rest.components(separatedBy: end)[0] }
                for word in rest.components(separatedBy: CharacterSet(charactersIn: " \t,")) where !word.isEmpty {
                    result.ignored.insert(word.lowercased())
                }
            }
        }
        if let start = disabledFrom { result.disabled.append(NSRange(location: start, length: text.length - start)) }
        return result
    }

    func isDisabled(_ location: Int) -> Bool { disabled.contains { NSLocationInRange(location, $0) } }
}

// MARK: Dictionaries

/// Word lists: the built-in programming terms, the user's (Application Support) and each
/// folder's (`.omc/dictionary.txt`), one word per line. Files are read again when they change.
@MainActor
final class SpellDictionaries {
    static let shared = SpellDictionaries(userFile: AppSettings.isRunningTests
        ? FileManager.default.temporaryDirectory.appending(path: "omc-test-dictionary-\(ProcessInfo.processInfo.processIdentifier).txt")
        : URL.omcApplicationSupport.appending(path: "OhMyCode/dictionary.txt"))
    static let didChange = Notification.Name("omcSpellingDictionariesDidChange")
    /// A folder's dictionary, relative to it.
    static let folderFile = ".omc/dictionary.txt"

    let userFile: URL
    private var cache: [URL: (date: Date?, words: Set<String>)] = [:]

    init(userFile: URL) {
        self.userFile = userFile
    }

    /// The built-in terms (lowercased), from the app's SpellingTerms.txt.
    nonisolated static let terms: Set<String> = {
        guard let url = Bundle.main.url(forResource: "SpellingTerms", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return words(in: text)
    }()

    nonisolated static func words(in text: String) -> Set<String> {
        var result = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let word = line.trimmingCharacters(in: .whitespaces)
            if !word.isEmpty, !word.hasPrefix("#") { result.insert(word.lowercased()) }
        }
        return result
    }

    static func folderDictionary(in folder: URL) -> URL { folder.appending(path: folderFile) }

    /// A dictionary file's words (lowercased), read again when its modification date changed.
    func words(at url: URL) -> Set<String> {
        // Not the URL's resource values: those are cached in the URL.
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached = cache[url], cached.date == date { return cached.words }
        let words = date == nil ? [] : (try? String(contentsOf: url, encoding: .utf8)).map(Self.words(in:)) ?? []
        cache[url] = (date, words)
        return words
    }

    /// Adds a word to a dictionary file (made with its folder when it isn't there yet).
    func add(_ word: String, to url: URL) throws {
        guard !words(at: url).contains(word.lowercased()) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += word + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        cache[url] = nil
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Words ignored in a file until the app quits ("Ignore in This File"), by path.
    private(set) var ignoredInFile: [String: Set<String>] = [:]

    func ignore(_ word: String, inFile url: URL) {
        ignoredInFile[url.standardizedFileURL.path, default: []].insert(word.lowercased())
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func ignored(inFile url: URL) -> Set<String> { ignoredInFile[url.standardizedFileURL.path] ?? [] }
}

// MARK: Checking

/// The system spell checker (offline), behind a lock, with what it said about each word kept.
/// It checks in a spell document of its own: nothing is learned into the user's dictionary.
final class SpellEngine: @unchecked Sendable {
    static let shared = SpellEngine()

    private let lock = NSLock()
    private var cache: [String: Bool] = [:]
    private let tag: Int

    init() {
        tag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    /// The languages the system can check, in the user's order (`en`, `en_GB`, `fr`, …).
    static var availableLanguages: [String] { NSSpellChecker.shared.availableLanguages }

    /// Whether the checker knows the word (in `language`; nil: the system's choice).
    func isCorrect(_ word: String, language: String?) -> Bool {
        // An acronym or SCREAMING_CASE word is checked as the word.
        let word = word == word.uppercased() ? word.lowercased() : word
        let key = (language ?? "") + "\u{0}" + word
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[key] { return known }
        if cache.count > 50_000 { cache.removeAll() }
        let checker = NSSpellChecker.shared
        let language = language.flatMap { checker.availableLanguages.contains($0) ? $0 : nil }
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                         inSpellDocumentWithTag: tag, wordCount: nil)
        let correct = miss.location == NSNotFound
        cache[key] = correct
        return correct
    }

    /// The checker's guesses for a word.
    func guesses(for word: String, language: String?) -> [String] {
        let lookup = word == word.uppercased() ? word.lowercased() : word
        lock.lock()
        defer { lock.unlock() }
        let checker = NSSpellChecker.shared
        let language = language.flatMap { checker.availableLanguages.contains($0) ? $0 : nil }
        return checker.guesses(forWordRange: NSRange(location: 0, length: (lookup as NSString).length), in: lookup,
                               language: language, inSpellDocumentWithTag: tag) ?? []
    }
}

/// One check of part of a document, made on the main thread and run in the background.
/// `@unchecked Sendable`: the text is an immutable copy.
struct SpellCheckRequest: @unchecked Sendable {
    enum Mode: Sendable {
        /// Code: comments and strings as prose (`proseRanges`), names between them.
        case code
        /// Everything is prose (plain text).
        case prose
        /// Prose, without code blocks and `code spans`.
        case markdown
    }

    /// The text copied (it may start before `checkRange`, for directives above it).
    var text: NSString
    /// Where `text` starts in the document.
    var offset = 0
    /// What to check, in the document.
    var checkRange: NSRange
    var mode: Mode
    /// Comments and strings (document positions, sorted).
    var proseRanges: [NSRange] = []
    /// Keywords, numbers, library names: not checked as names.
    var excludedRanges: [NSRange] = []
    var checksIdentifiers = true
    /// Names with `-` in them (CSS, HTML).
    var allowsHyphen = false
    var language: String?
    /// Accepted words (lowercased): the terms, the dictionaries, the file's ignored ones.
    var known: [Set<String>] = []

    /// The words to check (document positions), before dictionaries and the checker.
    func tokens() -> [SpellToken] {
        let local = NSIntersectionRange(NSRange(location: checkRange.location - offset, length: checkRange.length),
                                        NSRange(location: 0, length: text.length))
        guard local.length > 0 else { return [] }
        var tokens: [SpellToken] = []
        switch mode {
        case .prose:
            tokens = SpellWords.proseWords(in: text, range: local)
        case .markdown:
            for piece in Self.subtract(Self.markdownCode(in: text), from: local) {
                tokens += SpellWords.proseWords(in: text, range: piece)
            }
        case .code:
            let prose = proseRanges.map { NSRange(location: $0.location - offset, length: $0.length) }
                .map { NSIntersectionRange($0, local) }.filter { $0.length > 0 }
            for range in prose { tokens += SpellWords.proseWords(in: text, range: range) }
            if checksIdentifiers {
                let excluded = Self.merged(excludedRanges.map { NSRange(location: $0.location - offset, length: $0.length) })
                for piece in Self.subtract(prose, from: local) {
                    let names = SpellWords.identifierWords(in: text, range: piece, allowsHyphen: allowsHyphen)
                    tokens += names.filter { !Self.intersects(excluded, $0.range) }
                }
            }
            tokens.sort { $0.range.location < $1.range.location }
        }
        let directives = SpellDirectives.parse(text)
        return tokens.compactMap { token in
            guard !directives.isDisabled(token.range.location), !directives.ignored.contains(token.word.lowercased()) else { return nil }
            return SpellToken(range: NSRange(location: token.range.location + offset, length: token.range.length),
                              word: token.word, isIdentifier: token.isIdentifier)
        }
    }

    /// The misspelled words (document positions).
    func run(engine: SpellEngine = .shared) -> [SpellIssue] {
        tokens().compactMap { token in
            guard !SpellRules.skipsWord(token.word) else { return nil }
            let lower = token.word.lowercased()
            guard !known.contains(where: { $0.contains(lower) }), !engine.isCorrect(token.word, language: language) else { return nil }
            return SpellIssue(range: token.range, word: token.word, isIdentifier: token.isIdentifier)
        }
    }

    /// Fenced code blocks and code spans in Markdown text.
    static func markdownCode(in text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var fenceStart: Int?
        var lineStart = 0
        let length = text.length
        while lineStart < length {
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let start = fenceStart {
                    result.append(NSRange(location: start, length: NSMaxRange(lineRange) - start))
                    fenceStart = nil
                } else {
                    fenceStart = lineRange.location
                }
            } else if fenceStart == nil {
                // `spans` on the line.
                var open: Int?
                for index in lineRange.location..<NSMaxRange(lineRange) where text.character(at: index) == 0x60 {
                    if let start = open {
                        result.append(NSRange(location: start, length: index + 1 - start))
                        open = nil
                    } else {
                        open = index
                    }
                }
            }
            lineStart = NSMaxRange(lineRange)
        }
        if let start = fenceStart { result.append(NSRange(location: start, length: length - start)) }
        return result
    }

    /// Sorted, with overlapping ranges joined.
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Whether `range` overlaps any of `merged` (sorted, disjoint).
    static func intersects(_ merged: [NSRange], _ range: NSRange) -> Bool {
        // The last one starting before the range ends.
        var low = 0, high = merged.count - 1, found = -1
        while low <= high {
            let middle = (low + high) / 2
            if merged[middle].location < NSMaxRange(range) { found = middle; low = middle + 1 } else { high = middle - 1 }
        }
        return found >= 0 && NSMaxRange(merged[found]) > range.location
    }

    /// The parts of `range` outside `ranges`.
    static func subtract(_ ranges: [NSRange], from range: NSRange) -> [NSRange] {
        var pieces: [NSRange] = []
        var cursor = range.location
        for cut in ranges.sorted(by: { $0.location < $1.location }) where NSMaxRange(cut) > cursor {
            if cut.location >= NSMaxRange(range) { break }
            if cut.location > cursor { pieces.append(NSRange(location: cursor, length: cut.location - cursor)) }
            cursor = max(cursor, NSMaxRange(cut))
        }
        if cursor < NSMaxRange(range) { pieces.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor)) }
        return pieces
    }
}
