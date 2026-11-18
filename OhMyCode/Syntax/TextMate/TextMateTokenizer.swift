import Foundation

/// A run of a line with one list of scopes (outermost first: `source.toy string.quoted.toy`).
/// Offsets are UTF-16, within the line.
struct TextMateToken: Equatable, Sendable {
    var start: Int
    var end: Int
    var scopes: [String]
}

/// Where tokenizing stands at the end of a line: the rules still open (a string, a comment
/// block, an embedded language…). The next line starts from it; when an edit leaves a line's
/// end state as it was, the lines after it don't need tokenizing again.
struct TextMateState: Equatable, Sendable {
    struct Frame: Equatable, Sendable {
        let ruleID: Int
        /// Where the rule began on the current line (-1: on an earlier line).
        var enterPosition: Int
        /// Where `\G` matches for it (-1: nowhere).
        var anchorPosition: Int
        /// Its `begin` match reached the end of the line.
        var beginRuleCapturedEOL: Bool
        /// Its `end` (or `while`) with back-references filled in from its `begin` match.
        var endPattern: String?
        var nameScopes: [String]
        var contentScopes: [String]
    }

    var frames: [Frame]
    var top: Frame { frames[frames.count - 1] }
    var scopes: [String] { top.contentScopes }
}

/// Tokenizes lines with a TextMate grammar, the way VS Code's vscode-textmate does: the
/// grammar's rules compiled on first use, matched with ICU regexes (see `OnigurumaRegex`).
/// Not thread-safe: each document's engine has its own (the regexes are shared).
final class TextMateTokenizer {
    static let endRuleID = -1
    static let whileRuleID = -2

    let scopeName: String
    private let source: TextMateGrammarSource
    private let base: TextMateRawGrammar
    private var rules: [Rule] = []
    private var ruleIDs: [ObjectIdentifier: Int] = [:]
    private var grammars: [String: TextMateRawGrammar?] = [:]
    private var rootID = 0
    private var injections: [Injection]?
    /// Each regex's last search on the current line (see `search`).
    private var searchCache: [ObjectIdentifier: (from: Int, result: NSTextCheckingResult?)] = [:]
    private var deadline: UInt64 = 0

    /// Lines longer than this (UTF-16 units) aren't tokenized: one token with the scopes
    /// they start in, and the next line starts where this one did.
    var lineLengthLimit = 20_000
    /// How long one line may take; a line that takes longer is left plain the same way.
    var timeLimit: Duration = .milliseconds(80)

    private final class Rule {
        enum Kind { case match, includeOnly, beginEnd, beginWhile, capture }
        var kind: Kind = .includeOnly
        var name: String?
        var contentName: String?
        /// `match`, or `begin`.
        var pattern: String?
        var end: String?
        var whilePattern: String?
        var captures: [Int: Int] = [:]
        var beginCaptures: [Int: Int] = [:]
        var endCaptures: [Int: Int] = [:]
        var whileCaptures: [Int: Int] = [:]
        var patterns: [Int] = []
        var applyEndPatternLast = false
        var endHasBackReferences = false
        var whileHasBackReferences = false
        /// A capture with `patterns`: the rule that tokenizes the captured text.
        var retokenizeID: Int?
        /// An `include` of it couldn't be found.
        var hasMissingPatterns = false
        var scanners: [String: Scanner] = [:]
    }

    private struct Scanner {
        struct Entry {
            let regex: NSRegularExpression?
            let ruleID: Int
            /// `\G` in it: its matches depend on where the search starts (not cached).
            let anchored: Bool
        }
        let entries: [Entry]
    }

    private struct Injection {
        let matcher: ScopeSelector.Matcher
        let priority: Int
        let ruleID: Int
    }

    private struct Match {
        let ruleID: Int
        let captures: [NSRange]
        var priority = 0
    }

    init?(scopeName: String, source: TextMateGrammarSource) {
        guard let base = source.grammar(scopeName) else { return nil }
        self.scopeName = scopeName
        self.source = source
        self.base = base
        grammars[scopeName] = base
        rootID = compile(base.root, grammar: base, repository: base.root.repository ?? [:])
    }

    var initialState: TextMateState {
        let scopes = [scopeName]
        return TextMateState(frames: [.init(ruleID: rootID, enterPosition: -1, anchorPosition: -1, beginRuleCapturedEOL: false,
                                            endPattern: nil, nameScopes: scopes, contentScopes: scopes)])
    }

    // MARK: Tokenizing

    /// Tokenizes one line (without its line break) from the state the previous line ended in
    /// (nil: the first line). The tokens cover the whole line.
    func tokenize(line text: NSString, state previous: TextMateState?) -> (tokens: [TextMateToken], state: TextMateState) {
        let start = previous ?? initialState
        if text.length > lineLengthLimit {
            return (text.length > 0 ? [TextMateToken(start: 0, end: text.length, scopes: start.scopes)] : [], start)
        }
        let line = text.appending("\n") as NSString
        var stack = start
        var producer = Producer(limit: text.length)
        searchCache.removeAll(keepingCapacity: true)
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeLimit.components.seconds) * 1_000_000_000
            + UInt64(timeLimit.components.attoseconds / 1_000_000_000)
        guard tokenizeString(line, isFirstLine: previous == nil, linePos: 0, stack: &stack, producer: &producer, checkWhile: true) else {
            // Too slow: plain, and the next line starts where this one did.
            return (text.length > 0 ? [TextMateToken(start: 0, end: text.length, scopes: start.scopes)] : [], start)
        }
        for index in stack.frames.indices {
            stack.frames[index].enterPosition = -1
            stack.frames[index].anchorPosition = -1
        }
        return (producer.tokens, stack)
    }

    private struct Producer {
        let limit: Int
        var tokens: [TextMateToken] = []
        var lastEnd = 0

        mutating func produce(_ scopes: [String], until position: Int) {
            let end = min(position, limit)
            guard end > lastEnd else { return }
            if let last = tokens.last, last.scopes == scopes, last.end == lastEnd {
                tokens[tokens.count - 1].end = end
            } else {
                tokens.append(TextMateToken(start: lastEnd, end: end, scopes: scopes))
            }
            lastEnd = end
        }
    }

    private var timedOut: Bool { DispatchTime.now().uptimeNanoseconds > deadline }

    /// The tokenizer's main loop (vscode-textmate's `_tokenizeString`): the earliest match of
    /// the open rule's patterns (or its `end`), or of an injection, from `linePos` on.
    private func tokenizeString(_ line: NSString, isFirstLine firstLine: Bool, linePos start: Int, stack: inout TextMateState,
                                producer: inout Producer, checkWhile: Bool) -> Bool {
        let lineLength = line.length
        var isFirstLine = firstLine
        var linePos = start
        var anchorPosition = -1
        if checkWhile {
            guard checkWhileConditions(line, isFirstLine: &isFirstLine, linePos: &linePos, anchorPosition: &anchorPosition,
                                       stack: &stack, producer: &producer) else { return false }
        }
        while true {
            if timedOut { return false }
            guard let match = matchRuleOrInjections(line, isFirstLine: isFirstLine, linePos: linePos, stack: stack,
                                                    anchorPosition: anchorPosition) else {
                if timedOut { return false } // a search gave up: nothing found isn't known
                producer.produce(stack.scopes, until: lineLength)
                return true
            }
            let whole = match.captures[0]
            let matchEnd = NSMaxRange(whole)
            let hasAdvanced = matchEnd > linePos

            if match.ruleID == Self.endRuleID {
                let popped = stack.top
                let rule = rules[popped.ruleID]
                producer.produce(popped.contentScopes, until: whole.location)
                stack.frames[stack.frames.count - 1].contentScopes = popped.nameScopes
                guard handleCaptures(line, isFirstLine: isFirstLine, stack: stack, producer: &producer,
                                     rules: rule.endCaptures, captures: match.captures) else { return false }
                producer.produce(stack.scopes, until: matchEnd)
                if stack.frames.count > 1 { stack.frames.removeLast() }
                anchorPosition = popped.anchorPosition
                if !hasAdvanced, popped.enterPosition == linePos {
                    // Pushed and popped without moving: stop here rather than loop forever.
                    stack.frames.append(popped)
                    producer.produce(stack.scopes, until: lineLength)
                    return true
                }
            } else {
                let rule = rules[match.ruleID]
                producer.produce(stack.scopes, until: whole.location)
                let before = stack
                let nameScopes = stack.scopes + Self.scopes(rule.name, line: line, captures: match.captures)
                stack.frames.append(.init(ruleID: match.ruleID, enterPosition: linePos, anchorPosition: anchorPosition,
                                          beginRuleCapturedEOL: matchEnd == lineLength, endPattern: nil,
                                          nameScopes: nameScopes, contentScopes: nameScopes))
                switch rule.kind {
                case .beginEnd, .beginWhile:
                    guard handleCaptures(line, isFirstLine: isFirstLine, stack: stack, producer: &producer,
                                         rules: rule.beginCaptures, captures: match.captures) else { return false }
                    producer.produce(stack.scopes, until: matchEnd)
                    anchorPosition = matchEnd
                    let last = stack.frames.count - 1
                    stack.frames[last].contentScopes = nameScopes + Self.scopes(rule.contentName, line: line, captures: match.captures)
                    if rule.kind == .beginEnd, rule.endHasBackReferences, let end = rule.end {
                        stack.frames[last].endPattern = Self.resolveBackReferences(end, line: line, captures: match.captures)
                    } else if rule.kind == .beginWhile, rule.whileHasBackReferences, let pattern = rule.whilePattern {
                        stack.frames[last].endPattern = Self.resolveBackReferences(pattern, line: line, captures: match.captures)
                    }
                    if !hasAdvanced, Self.hasSameRule(before, as: stack) {
                        stack.frames.removeLast()
                        producer.produce(stack.scopes, until: lineLength)
                        return true
                    }
                default:
                    guard handleCaptures(line, isFirstLine: isFirstLine, stack: stack, producer: &producer,
                                         rules: rule.captures, captures: match.captures) else { return false }
                    producer.produce(stack.scopes, until: matchEnd)
                    stack.frames.removeLast()
                    if !hasAdvanced {
                        if stack.frames.count > 1 { stack.frames.removeLast() }
                        producer.produce(stack.scopes, until: lineLength)
                        return true
                    }
                }
            }
            if matchEnd > linePos {
                linePos = matchEnd
                isFirstLine = false
            }
        }
    }

    /// The `while` rules still open must match at the start of each line, or they end.
    private func checkWhileConditions(_ line: NSString, isFirstLine: inout Bool, linePos: inout Int, anchorPosition: inout Int,
                                      stack: inout TextMateState, producer: inout Producer) -> Bool {
        anchorPosition = stack.top.beginRuleCapturedEOL ? 0 : -1
        let whileFrames = stack.frames.indices.filter { rules[stack.frames[$0].ruleID].kind == .beginWhile }
        for index in whileFrames {
            let frame = stack.frames[index]
            let rule = rules[frame.ruleID]
            let pattern = frame.endPattern ?? rule.whilePattern ?? "\u{FFFF}"
            let scanner = scanner(key: "while|\(isFirstLine)|\(anchorPosition == linePos)|\(pattern)", rule: rule,
                                  allowA: isFirstLine, allowG: anchorPosition == linePos) {
                [(pattern, Self.whileRuleID)]
            }
            guard let match = find(scanner, in: line, from: linePos) else {
                stack.frames.removeSubrange(index...)
                break
            }
            producer.produce(frame.contentScopes, until: match.captures[0].location)
            let frameStack = TextMateState(frames: Array(stack.frames[...index]))
            guard handleCaptures(line, isFirstLine: isFirstLine, stack: frameStack, producer: &producer,
                                 rules: rule.whileCaptures, captures: match.captures) else { return false }
            let end = NSMaxRange(match.captures[0])
            producer.produce(frame.contentScopes, until: end)
            anchorPosition = end
            if end > linePos {
                linePos = end
                isFirstLine = false
            }
        }
        return true
    }

    /// Scopes for the groups that have a rule in `captures`; a capture with `patterns` is
    /// tokenized again with them (only up to the capture's end).
    private func handleCaptures(_ line: NSString, isFirstLine: Bool, stack: TextMateState, producer: inout Producer,
                                rules captureRules: [Int: Int], captures: [NSRange]) -> Bool {
        guard !captureRules.isEmpty, let whole = captures.first else { return true }
        let maxEnd = NSMaxRange(whole)
        var local: [(scopes: [String], end: Int)] = []
        for (index, capture) in captures.enumerated() {
            guard let ruleID = captureRules[index], capture.location != NSNotFound, capture.length > 0 else { continue }
            if capture.location > maxEnd { break }
            while let last = local.last, last.end <= capture.location {
                producer.produce(last.scopes, until: last.end)
                local.removeLast()
            }
            producer.produce(local.last?.scopes ?? stack.scopes, until: capture.location)
            let rule = rules[ruleID]
            let base = local.last?.scopes ?? stack.scopes
            if let retokenize = rule.retokenizeID {
                let nameScopes = base + Self.scopes(rule.name, line: line, captures: captures)
                let contentScopes = nameScopes + Self.scopes(rule.contentName, line: line, captures: captures)
                var inner = stack
                inner.frames.append(.init(ruleID: retokenize, enterPosition: capture.location, anchorPosition: -1,
                                          beginRuleCapturedEOL: false, endPattern: nil,
                                          nameScopes: nameScopes, contentScopes: contentScopes))
                let substring = line.substring(to: NSMaxRange(capture)) as NSString
                let saved = searchCache
                searchCache.removeAll()
                let finished = tokenizeString(substring, isFirstLine: isFirstLine && capture.location == 0, linePos: capture.location,
                                              stack: &inner, producer: &producer, checkWhile: false)
                searchCache = saved
                guard finished else { return false }
                continue
            }
            let names = Self.scopes(rule.name, line: line, captures: captures)
            if !names.isEmpty { local.append((base + names, NSMaxRange(capture))) }
        }
        while let last = local.popLast() { producer.produce(last.scopes, until: last.end) }
        return true
    }

    private static func hasSameRule(_ before: TextMateState, as after: TextMateState) -> Bool {
        let top = after.top
        for frame in before.frames.reversed() {
            guard frame.enterPosition == top.enterPosition else { break }
            if frame.ruleID == top.ruleID { return true }
        }
        return false
    }

    // MARK: Matching

    private func matchRuleOrInjections(_ line: NSString, isFirstLine: Bool, linePos: Int, stack: TextMateState,
                                       anchorPosition: Int) -> Match? {
        let allowG = anchorPosition == linePos
        let regular = find(scanner(for: stack.top, allowA: isFirstLine, allowG: allowG), in: line, from: linePos)
        let injections = injectionList()
        guard !injections.isEmpty else { return regular }
        var best: Match?
        var bestLocation = Int.max
        let scopes = stack.scopes
        for injection in injections where injection.matcher.matches(scopes) {
            let rule = rules[injection.ruleID]
            let scanner = scanner(key: "injection|\(isFirstLine)|\(allowG)", rule: rule, allowA: isFirstLine, allowG: allowG) {
                var collected: [(String, Int)] = []
                var visited = Set<Int>()
                collect(injection.ruleID, into: &collected, visited: &visited)
                return collected
            }
            guard var found = find(scanner, in: line, from: linePos) else { continue }
            let location = found.captures[0].location
            if location > bestLocation { continue }
            found.priority = injection.priority
            best = found
            bestLocation = location
            if location == linePos { break }
        }
        guard let injected = best else { return regular }
        guard let regular else { return injected }
        let injectedStart = injected.captures[0].location, regularStart = regular.captures[0].location
        if injectedStart < regularStart || (injected.priority == -1 && injectedStart == regularStart) { return injected }
        return regular
    }

    /// The open rule's patterns (and its `end`, first unless `applyEndPatternLast`).
    private func scanner(for frame: TextMateState.Frame, allowA: Bool, allowG: Bool) -> Scanner {
        let rule = rules[frame.ruleID]
        let end = rule.kind == .beginEnd ? (frame.endPattern ?? rule.end ?? "\u{FFFF}") : ""
        return scanner(key: "\(allowA)|\(allowG)|\(end)", rule: rule, allowA: allowA, allowG: allowG) {
            var collected: [(String, Int)] = []
            var visited = Set<Int>()
            for id in rule.patterns { collect(id, into: &collected, visited: &visited) }
            if rule.kind == .beginEnd {
                if rule.applyEndPatternLast { collected.append((end, Self.endRuleID)) } else { collected.insert((end, Self.endRuleID), at: 0) }
            }
            return collected
        }
    }

    private func scanner(key: String, rule: Rule, allowA: Bool, allowG: Bool, sources: () -> [(String, Int)]) -> Scanner {
        if let cached = rule.scanners[key] { return cached }
        let entries = sources().map { source, ruleID in
            let pattern = Self.anchorVariant(source, allowA: allowA, allowG: allowG)
            return Scanner.Entry(regex: OnigurumaRegex.compile(pattern), ruleID: ruleID, anchored: allowG && pattern.contains("\\G"))
        }
        let scanner = Scanner(entries: entries)
        if rule.scanners.count > 64 { rule.scanners.removeAll() } // back-referenced ends vary per match
        rule.scanners[key] = scanner
        return scanner
    }

    /// The pattern's first match from `position`, of those starting earliest.
    private func find(_ scanner: Scanner, in line: NSString, from position: Int) -> Match? {
        var best: (location: Int, entry: Scanner.Entry, result: NSTextCheckingResult)?
        for entry in scanner.entries {
            guard let regex = entry.regex, let result = search(regex, anchored: entry.anchored, in: line, from: position) else { continue }
            if best == nil || result.range.location < best!.location {
                best = (result.range.location, entry, result)
                if result.range.location == position { break }
            }
        }
        guard let best else { return nil }
        let captures = (0..<best.result.numberOfRanges).map { best.result.range(at: $0) }
        return Match(ruleID: best.entry.ruleID, captures: captures)
    }

    /// A search from `position`, reusing the regex's previous search on this line when it
    /// started earlier and found nothing before `position` (most patterns are tried again and
    /// again as the line is scanned).
    private func search(_ regex: NSRegularExpression, anchored: Bool, in line: NSString, from position: Int) -> NSTextCheckingResult? {
        let key = ObjectIdentifier(regex)
        if !anchored, let cached = searchCache[key], cached.from <= position {
            guard let result = cached.result else { return nil }
            if result.range.location >= position { return result }
        }
        // Enumerated rather than `firstMatch`, to hear from a match that backtracks for long
        // and give up on it at the line's deadline.
        var result: NSTextCheckingResult?
        let deadline = self.deadline
        var gaveUp = false
        regex.enumerateMatches(in: line as String, options: [.reportProgress, .withTransparentBounds, .withoutAnchoringBounds],
                               range: NSRange(location: position, length: line.length - position)) { match, _, stop in
            if let match {
                result = match
                stop.pointee = true
            } else if DispatchTime.now().uptimeNanoseconds > deadline {
                gaveUp = true
                stop.pointee = true
            }
        }
        if !anchored, !gaveUp { searchCache[key] = (position, result) }
        return result
    }

    private func collect(_ id: Int, into collected: inout [(String, Int)], visited: inout Set<Int>) {
        let rule = rules[id]
        switch rule.kind {
        case .match, .beginEnd, .beginWhile:
            if let pattern = rule.pattern { collected.append((pattern, id)) }
        case .includeOnly:
            guard visited.insert(id).inserted else { return }
            for pattern in rule.patterns { collect(pattern, into: &collected, visited: &visited) }
        case .capture:
            break
        }
    }

    private func injectionList() -> [Injection] {
        if let injections { return injections }
        var result: [Injection] = []
        let repository = base.root.repository ?? [:]
        for (selector, raw) in base.injections {
            let id = compile(raw, grammar: base, repository: repository)
            for alternative in ScopeSelector(selector).alternatives {
                result.append(Injection(matcher: alternative.matcher, priority: alternative.priority, ruleID: id))
            }
        }
        for scope in source.injections(scopeName) {
            guard let grammar = grammar(scope), let selector = grammar.injectionSelector else { continue }
            let id = compile(grammar.root, grammar: grammar, repository: grammar.root.repository ?? [:])
            for alternative in ScopeSelector(selector).alternatives {
                result.append(Injection(matcher: alternative.matcher, priority: alternative.priority, ruleID: id))
            }
        }
        injections = result
        return result
    }

    // MARK: Compiling rules

    private func grammar(_ scope: String) -> TextMateRawGrammar? {
        if let known = grammars[scope] { return known }
        let found = source.grammar(scope)
        grammars[scope] = found
        return found
    }

    private func compile(_ raw: TextMateRawRule, grammar: TextMateRawGrammar, repository outer: [String: TextMateRawRule]) -> Int {
        if let id = ruleIDs[ObjectIdentifier(raw)] { return id }
        let id = rules.count
        let rule = Rule()
        rules.append(rule)
        ruleIDs[ObjectIdentifier(raw)] = id
        let repository = raw.repository.map { outer.merging($0) { $1 } } ?? outer
        rule.name = raw.name
        rule.contentName = raw.contentName
        if let match = raw.match {
            rule.kind = .match
            rule.pattern = match
            rule.captures = compileCaptures(raw.captures, grammar: grammar, repository: repository)
        } else if let begin = raw.begin {
            rule.pattern = begin
            rule.beginCaptures = compileCaptures(raw.beginCaptures ?? raw.captures, grammar: grammar, repository: repository)
            if let whilePattern = raw.whilePattern {
                rule.kind = .beginWhile
                rule.whilePattern = whilePattern
                rule.whileHasBackReferences = Self.hasBackReferences(whilePattern)
                rule.whileCaptures = compileCaptures(raw.whileCaptures ?? raw.captures, grammar: grammar, repository: repository)
            } else {
                rule.kind = .beginEnd
                rule.end = raw.end ?? "\u{FFFF}"
                rule.endHasBackReferences = Self.hasBackReferences(rule.end!)
                rule.endCaptures = compileCaptures(raw.endCaptures ?? raw.captures, grammar: grammar, repository: repository)
                rule.applyEndPatternLast = raw.applyEndPatternLast
            }
            var missing = false
            rule.patterns = compilePatterns(raw.patterns ?? [], grammar: grammar, repository: repository, missing: &missing)
            rule.hasMissingPatterns = missing
        } else {
            rule.kind = .includeOnly
            let patterns = raw.patterns ?? (raw.include != nil ? [raw] : [])
            var missing = false
            rule.patterns = compilePatterns(patterns, grammar: grammar, repository: repository, missing: &missing)
            rule.hasMissingPatterns = missing
        }
        return id
    }

    private func compileCaptures(_ captures: [Int: TextMateRawRule]?, grammar: TextMateRawGrammar,
                                 repository: [String: TextMateRawRule]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (index, raw) in captures ?? [:] {
            let rule = Rule()
            rule.kind = .capture
            rule.name = raw.name
            rule.contentName = raw.contentName
            if raw.patterns != nil { rule.retokenizeID = compile(raw, grammar: grammar, repository: repository) }
            result[index] = rules.count
            rules.append(rule)
        }
        return result
    }

    private func compilePatterns(_ patterns: [TextMateRawRule], grammar: TextMateRawGrammar,
                                 repository: [String: TextMateRawRule], missing: inout Bool) -> [Int] {
        var result: [Int] = []
        for pattern in patterns {
            let id: Int?
            if let include = pattern.include {
                id = resolveInclude(include, grammar: grammar, repository: repository)
            } else {
                id = compile(pattern, grammar: grammar, repository: repository)
            }
            guard let id else { missing = true; continue }
            // A rule left with nothing to match because what it includes is missing.
            let rule = rules[id]
            if rule.kind != .match, rule.kind != .capture, rule.hasMissingPatterns, rule.patterns.isEmpty { continue }
            result.append(id)
        }
        return result
    }

    /// `#key`, `$self`, `$base`, `source.other` or `source.other#key`.
    private func resolveInclude(_ include: String, grammar: TextMateRawGrammar, repository: [String: TextMateRawRule]) -> Int? {
        if include.hasPrefix("#") {
            guard let raw = repository[String(include.dropFirst())] else { return nil }
            return compile(raw, grammar: grammar, repository: repository)
        }
        if include == "$self" {
            return compile(grammar.root, grammar: grammar, repository: grammar.root.repository ?? [:])
        }
        if include == "$base" {
            return compile(base.root, grammar: base, repository: base.root.repository ?? [:])
        }
        let parts = include.split(separator: "#", maxSplits: 1).map(String.init)
        guard let first = parts.first, let other = self.grammar(first) else { return nil }
        let otherRepository = other.root.repository ?? [:]
        if parts.count == 2 {
            guard let raw = otherRepository[parts[1]] else { return nil }
            return compile(raw, grammar: other, repository: otherRepository)
        }
        return compile(other.root, grammar: other, repository: otherRepository)
    }

    // MARK: Helpers

    /// A rule's `name` or `contentName` as scopes: `$1` / `${1:/downcase}` filled in from the
    /// match, split on spaces (one name can add several scopes).
    static func scopes(_ name: String?, line: NSString, captures: [NSRange]) -> [String] {
        guard let name, !name.isEmpty else { return [] }
        let resolved = name.contains("$") ? substitute(name, line: line, captures: captures) : name
        return resolved.split(separator: " ").map(String.init)
    }

    static func substitute(_ name: String, line: NSString, captures: [NSRange]) -> String {
        let chars = Array(name)
        var output = ""
        var index = 0
        func captured(_ number: Int) -> String {
            guard number < captures.count, captures[number].location != NSNotFound else { return "" }
            // Leading dots would make an empty scope part.
            var text = line.substring(with: captures[number])
            while text.hasPrefix(".") { text.removeFirst() }
            return text
        }
        while index < chars.count {
            if chars[index] == "$", index + 1 < chars.count {
                if chars[index + 1].isNumber {
                    var end = index + 1
                    while end < chars.count, chars[end].isNumber { end += 1 }
                    output += captured(Int(String(chars[(index + 1)..<end])) ?? 0)
                    index = end
                    continue
                }
                if chars[index + 1] == "{", let close = chars[(index + 2)...].firstIndex(of: "}") {
                    let inner = String(chars[(index + 2)..<close])
                    let parts = inner.split(separator: ":", maxSplits: 1)
                    if let number = parts.first.flatMap({ Int($0) }) {
                        var text = captured(number)
                        if parts.count == 2 {
                            if parts[1] == "/downcase" { text = text.lowercased() } else if parts[1] == "/upcase" { text = text.uppercased() }
                        }
                        output += text
                        index = close + 1
                        continue
                    }
                }
            }
            output.append(chars[index])
            index += 1
        }
        return output
    }

    static func hasBackReferences(_ pattern: String) -> Bool {
        var escaped = false
        for c in pattern {
            if escaped {
                if c.isNumber, c != "0" { return true }
                escaped = false
            } else if c == "\\" {
                escaped = true
            }
        }
        return false
    }

    /// `end: "\\1"` after `begin: "(<<+)"` matched `<<<`: `<<<`, escaped.
    static func resolveBackReferences(_ pattern: String, line: NSString, captures: [NSRange]) -> String {
        let chars = Array(pattern)
        var output = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count {
                if chars[index + 1].isNumber, chars[index + 1] != "0" {
                    var end = index + 1
                    while end < chars.count, chars[end].isNumber, end - index <= 2 { end += 1 }
                    let number = Int(String(chars[(index + 1)..<end])) ?? 0
                    if number < captures.count, captures[number].location != NSNotFound {
                        output += NSRegularExpression.escapedPattern(for: line.substring(with: captures[number]))
                    }
                    index = end
                    continue
                }
                output.append(chars[index])
                output.append(chars[index + 1])
                index += 2
                continue
            }
            output.append(chars[index])
            index += 1
        }
        return output
    }

    /// `\A` matches only on the first line, `\G` only where the previous match ended: where
    /// they can't match, they become a character no text has.
    static func anchorVariant(_ source: String, allowA: Bool, allowG: Bool) -> String {
        guard source.contains("\\A") || source.contains("\\G") else { return source }
        if allowA, allowG { return source }
        let chars = Array(source)
        var output = ""
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                if (next == "A" && !allowA) || (next == "G" && !allowG) {
                    output += "\\x{FFFF}"
                } else {
                    output.append(chars[index])
                    output.append(next)
                }
                index += 2
                continue
            }
            output.append(chars[index])
            index += 1
        }
        return output
    }
}
