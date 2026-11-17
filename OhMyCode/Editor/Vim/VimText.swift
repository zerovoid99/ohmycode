import Foundation

/// The text as Vim's motions see it: lines (split at "\n", with a "\r" before it part of the
/// line break), characters (composed sequences: an emoji or a letter with its accent is one)
/// and the classes of characters words are made of. Offsets are UTF-16, like the text view's.
struct VimText {
    let string: NSString
    let lines: LineIndex

    init(_ string: NSString, lines: LineIndex? = nil) {
        self.string = string
        self.lines = lines ?? LineIndex(string: string)
    }

    var length: Int { string.length }
    var lineCount: Int { lines.lineCount }
    var lastLine: Int { lineCount - 1 }

    func char(_ index: Int) -> unichar { string.character(at: index) }

    func line(of offset: Int) -> Int { lines.line(containing: min(max(0, offset), length)) }

    func clampLine(_ line: Int) -> Int { min(max(0, line), lastLine) }

    func start(ofLine line: Int) -> Int { lines.lineStarts[clampLine(line)] }

    /// Where the next line starts (or the end of the text, on the last line).
    func end(ofLine line: Int) -> Int {
        let line = clampLine(line)
        return line + 1 < lineCount ? lines.lineStarts[line + 1] : length
    }

    /// Where the line's text ends, before its line break.
    func contentEnd(ofLine line: Int) -> Int {
        let start = start(ofLine: line)
        var end = end(ofLine: line)
        if end > start, char(end - 1) == 0x0A {
            end -= 1
            if end > start, char(end - 1) == 0x0D { end -= 1 }
        }
        return end
    }

    func isEmpty(line: Int) -> Bool { contentEnd(ofLine: line) == start(ofLine: line) }

    /// Only spaces and tabs (or nothing).
    func isBlank(line: Int) -> Bool {
        let end = contentEnd(ofLine: line)
        var index = start(ofLine: line)
        while index < end {
            if !isSpace(char(index)) { return false }
            index += 1
        }
        return true
    }

    func lineText(_ line: Int) -> String {
        let start = start(ofLine: line)
        return string.substring(with: NSRange(location: start, length: contentEnd(ofLine: line) - start))
    }

    func substring(_ start: Int, _ end: Int) -> String {
        let start = min(max(0, start), length), end = min(max(start, end), length)
        return string.substring(with: NSRange(location: start, length: end - start))
    }

    /// The start of the line's last character (the line's start when it's empty): where the
    /// cursor can go in Normal mode.
    func lastChar(ofLine line: Int) -> Int {
        let start = start(ofLine: line), end = contentEnd(ofLine: line)
        return end > start ? previous(end) : start
    }

    func firstNonBlank(ofLine line: Int) -> Int {
        let end = contentEnd(ofLine: line)
        var index = start(ofLine: line)
        while index < end, isSpace(char(index)) { index += 1 }
        return min(index, lastChar(ofLine: line))
    }

    /// How many characters `offset` is into its line.
    func column(of offset: Int) -> Int {
        var index = start(ofLine: line(of: offset)), column = 0
        while index < offset {
            index = next(index)
            column += 1
        }
        return column
    }

    /// The offset `column` characters into `line`, at most its last character (or its end, with
    /// `pastEnd`).
    func offset(line: Int, column: Int, pastEnd: Bool = false) -> Int {
        let end = contentEnd(ofLine: line)
        var index = start(ofLine: line), remaining = column
        while remaining > 0, index < end {
            index = next(index)
            remaining -= 1
        }
        if index >= end, !pastEnd { return lastChar(ofLine: line) }
        return index
    }

    // MARK: Characters

    func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    func isLineBreak(at index: Int) -> Bool {
        guard index >= 0, index < length else { return false }
        let c = char(index)
        return c == 0x0A || (c == 0x0D && index + 1 < length && char(index + 1) == 0x0A)
    }

    /// The offset after the character at `index` ("\r\n" is one).
    func next(_ index: Int) -> Int {
        guard index < length else { return length }
        guard index >= 0 else { return 0 }
        if char(index) == 0x0D, index + 1 < length, char(index + 1) == 0x0A { return index + 2 }
        return NSMaxRange(string.rangeOfComposedCharacterSequence(at: index))
    }

    /// The start of the character before `index`.
    func previous(_ index: Int) -> Int {
        guard index > 0 else { return 0 }
        let index = min(index, length)
        if char(index - 1) == 0x0A, index >= 2, char(index - 2) == 0x0D { return index - 2 }
        return string.rangeOfComposedCharacterSequence(at: index - 1).location
    }

    enum CharClass { case lineBreak, blank, word, punctuation }

    /// Words are runs of one class: letters, digits and "_" (in any script), or other
    /// non-blank characters. Big words (W, B, E) are runs of anything but blanks.
    func charClass(at index: Int, big: Bool = false) -> CharClass {
        guard index < length else { return .lineBreak }
        if isLineBreak(at: index) { return .lineBreak }
        let c = char(index)
        if isSpace(c) || c == 0x0D || c == 0x0B || c == 0x0C { return .blank }
        if big { return .word }
        if c < 0x80 {
            let isWord = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
            return isWord ? .word : .punctuation
        }
        let range = string.rangeOfComposedCharacterSequence(at: index)
        guard let scalar = string.substring(with: range).unicodeScalars.first else { return .punctuation }
        if scalar.properties.isWhitespace { return .blank }
        if scalar.properties.isAlphabetic { return .word }
        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .connectorPunctuation: return .word
        default: return .punctuation
        }
    }

    /// A line break that's a whole (empty) line.
    private func isEmptyLineBreak(_ index: Int) -> Bool {
        isLineBreak(at: index) && start(ofLine: line(of: index)) == index
    }

    // MARK: Word motions

    /// `w`: the start of the next word (an empty line counts as one).
    func wordForward(from offset: Int, big: Bool) -> Int {
        var index = offset
        guard index < length else { return length }
        let startClass = charClass(at: index, big: big)
        if startClass == .word || startClass == .punctuation {
            while index < length, charClass(at: index, big: big) == startClass { index = next(index) }
        }
        while index < length {
            switch charClass(at: index, big: big) {
            case .blank: index = next(index)
            case .lineBreak:
                index = next(index)
                if isLineBreak(at: index) { return index }
            default: return index
            }
        }
        return index
    }

    /// `b`: the start of this word or the one before.
    func wordBackward(from offset: Int, big: Bool) -> Int {
        guard offset > 0 else { return 0 }
        var index = previous(offset)
        while index > 0 {
            let cls = charClass(at: index, big: big)
            if cls == .blank { index = previous(index); continue }
            if cls == .lineBreak {
                if isEmptyLineBreak(index) { return index }
                index = previous(index)
                continue
            }
            break
        }
        let cls = charClass(at: index, big: big)
        guard cls == .word || cls == .punctuation else { return index }
        while index > 0 {
            let before = previous(index)
            guard charClass(at: before, big: big) == cls else { break }
            index = before
        }
        return index
    }

    /// `e`: the end (last character) of this word or the next one; nil at the last.
    func wordEnd(from offset: Int, big: Bool) -> Int? {
        var index = next(offset)
        while index < length {
            let cls = charClass(at: index, big: big)
            guard cls == .blank || cls == .lineBreak else { break }
            index = next(index)
        }
        guard index < length else { return nil }
        let cls = charClass(at: index, big: big)
        while true {
            let after = next(index)
            guard after < length, charClass(at: after, big: big) == cls else { break }
            index = after
        }
        return index
    }

    /// The last character of the word at `offset` (`cw` changes up to it).
    func endOfCurrentWord(from offset: Int, big: Bool) -> Int {
        let cls = charClass(at: offset, big: big)
        var index = offset
        while true {
            let after = next(index)
            guard after < length, charClass(at: after, big: big) == cls else { break }
            index = after
        }
        return index
    }

    /// `ge`: the end of the word before.
    func wordEndBackward(from offset: Int, big: Bool) -> Int {
        var index = offset
        let cls = charClass(at: index, big: big)
        if cls == .word || cls == .punctuation {
            while index > 0 {
                let before = previous(index)
                guard charClass(at: before, big: big) == cls else { break }
                index = before
            }
        }
        guard index > 0 else { return 0 }
        index = previous(index)
        while index > 0 {
            let cls = charClass(at: index, big: big)
            if cls == .blank { index = previous(index); continue }
            if cls == .lineBreak {
                if isEmptyLineBreak(index) { return index }
                index = previous(index)
                continue
            }
            break
        }
        return index
    }

    // MARK: Other motions

    /// `}`: the next empty line after this paragraph (or the end of the text).
    func paragraphForward(from offset: Int) -> Int {
        var line = line(of: offset)
        while line < lastLine, isEmpty(line: line) { line += 1 }
        while line < lastLine, !isEmpty(line: line) { line += 1 }
        return isEmpty(line: line) && line != self.line(of: offset) ? start(ofLine: line) : length
    }

    /// `{`: the empty line before this paragraph (or the start of the text).
    func paragraphBackward(from offset: Int) -> Int {
        var line = line(of: offset)
        while line > 0, isEmpty(line: line) { line -= 1 }
        while line > 0, !isEmpty(line: line) { line -= 1 }
        return start(ofLine: line)
    }

    /// `f`, `F`, `t`, `T`: the `count`th `target` on the line.
    func find(_ target: String, from offset: Int, forward: Bool, till: Bool, count: Int, skipAdjacent: Bool = false) -> Int? {
        let line = line(of: offset)
        let lineStart = start(ofLine: line), lineEnd = contentEnd(ofLine: line)
        let needle = target as NSString
        var index = offset
        var remaining = count
        // Repeating `t` from just before the character would stay put: look past it.
        if skipAdjacent, till {
            index = forward ? next(index) : previous(index)
        }
        while remaining > 0 {
            index = forward ? next(index) : (index > lineStart ? previous(index) : -1)
            guard index >= lineStart, index < lineEnd else { return nil }
            if string.compare(needle as String, options: .literal,
                              range: NSRange(location: index, length: min(needle.length, lineEnd - index))) == .orderedSame {
                remaining -= 1
            }
        }
        if till { return forward ? previous(index) : next(index) }
        return index
    }

    private static let brackets: [unichar: (match: unichar, open: Bool)] = [
        0x28: (0x29, true), 0x29: (0x28, false), 0x5B: (0x5D, true), 0x5D: (0x5B, false),
        0x7B: (0x7D, true), 0x7D: (0x7B, false),
    ]

    /// `%`: the bracket matching the first one at or after the cursor on its line.
    func matchingBracket(from offset: Int) -> Int? {
        let end = contentEnd(ofLine: line(of: offset))
        var index = offset
        while index < end, Self.brackets[char(index)] == nil { index += 1 }
        guard index < end, let (match, open) = Self.brackets[char(index)].map({ ($0.match, $0.open) }) else { return nil }
        let bracket = char(index)
        var depth = 0
        if open {
            var scan = index
            while scan < length {
                let c = char(scan)
                if c == bracket { depth += 1 } else if c == match { depth -= 1; if depth == 0 { return scan } }
                scan += 1
            }
        } else {
            var scan = index
            while scan >= 0 {
                let c = char(scan)
                if c == bracket { depth += 1 } else if c == match { depth -= 1; if depth == 0 { return scan } }
                scan -= 1
            }
        }
        return nil
    }

    // MARK: Text objects

    /// A text object's range, and whether it's whole lines.
    struct Span: Equatable {
        var start: Int
        var end: Int
        var linewise = false
    }

    /// `iw`, `aw`, `iW`, `aW`.
    func wordObject(at offset: Int, big: Bool, around: Bool, count: Int) -> Span? {
        let line = line(of: offset)
        let lineStart = start(ofLine: line), lineEnd = contentEnd(ofLine: line)
        guard lineEnd > lineStart else { return Span(start: lineStart, end: lineStart) }
        let offset = min(offset, lastChar(ofLine: line))
        func run(from index: Int) -> Int {
            let cls = charClass(at: index, big: big)
            var end = index
            while end < lineEnd, charClass(at: end, big: big) == cls { end = next(end) }
            return end
        }
        let cls = charClass(at: offset, big: big)
        var start = offset
        while start > lineStart, charClass(at: previous(start), big: big) == cls { start = previous(start) }
        var end = run(from: offset)
        if around {
            if cls == .blank {
                if end < lineEnd { end = run(from: end) }
            } else if end < lineEnd, charClass(at: end, big: big) == .blank {
                end = run(from: end)
            } else {
                while start > lineStart, charClass(at: previous(start), big: big) == .blank { start = previous(start) }
            }
        }
        for _ in 1..<max(1, count) where end < lineEnd {
            end = run(from: end)
            if around, end < lineEnd, charClass(at: end, big: big) == .blank { end = run(from: end) }
        }
        return Span(start: start, end: end)
    }

    /// `i(`, `a(`, `i{`… : the `count`th pair of brackets around the cursor.
    func bracketObject(open: unichar, close: unichar, at offset: Int, around: Bool, count: Int) -> Span? {
        guard length > 0 else { return nil }
        var from = min(offset, length - 1)
        var openIndex: Int?
        for level in 0..<max(1, count) {
            var depth = 0
            var scan = from
            if level == 0, char(scan) == open {
                openIndex = scan
                from = scan - 1
                continue
            }
            if level == 0, char(scan) == close { scan -= 1 }
            openIndex = nil
            while scan >= 0 {
                let c = char(scan)
                if c == close { depth += 1 } else if c == open {
                    if depth == 0 { openIndex = scan; break }
                    depth -= 1
                }
                scan -= 1
            }
            guard let found = openIndex else { return nil }
            from = found - 1
        }
        guard let openAt = openIndex else { return nil }
        var depth = 0
        var scan = openAt
        var closeAt: Int?
        while scan < length {
            let c = char(scan)
            if c == open { depth += 1 } else if c == close {
                depth -= 1
                if depth == 0 { closeAt = scan; break }
            }
            scan += 1
        }
        guard let closeAt else { return nil }
        if around { return Span(start: openAt, end: closeAt + 1) }
        var start = openAt + 1, end = closeAt
        // A block on lines of its own: the lines between the brackets, whole.
        if isLineBreak(at: start) {
            let closeLine = line(of: closeAt)
            let closeLineStart = self.start(ofLine: closeLine)
            let onlyIndent = (closeLineStart..<closeAt).allSatisfy { isSpace(char($0)) }
            if onlyIndent, closeLine > line(of: openAt) + 1 {
                start = next(start)
                end = closeLineStart
                return Span(start: start, end: end, linewise: true)
            }
            if onlyIndent { start = next(start); end = closeLineStart }
        }
        return Span(start: start, end: max(start, end))
    }

    /// `i"`, `a"` (and `'`, `` ` ``): the quoted text on the cursor's line.
    func quoteObject(quote: unichar, at offset: Int, around: Bool) -> Span? {
        let line = line(of: offset)
        let lineStart = start(ofLine: line), lineEnd = contentEnd(ofLine: line)
        var quotes: [Int] = []
        var index = lineStart
        while index < lineEnd {
            let c = char(index)
            if c == 0x5C { index += 2; continue } // escaped
            if c == quote { quotes.append(index) }
            index += 1
        }
        var pair: (Int, Int)?
        if let at = quotes.firstIndex(of: offset) {
            if at % 2 == 0, at + 1 < quotes.count { pair = (quotes[at], quotes[at + 1]) } else if at % 2 == 1 { pair = (quotes[at - 1], quotes[at]) }
        } else {
            let before = quotes.filter { $0 < offset }.count
            if before % 2 == 1, before < quotes.count {
                pair = (quotes[before - 1], quotes[before])
            } else if before + 1 < quotes.count {
                pair = (quotes[before], quotes[before + 1])
            }
        }
        guard let (open, close) = pair else { return nil }
        guard around else { return Span(start: open + 1, end: close) }
        var start = open, end = close + 1
        if end < lineEnd, isSpace(char(end)) {
            while end < lineEnd, isSpace(char(end)) { end += 1 }
        } else {
            while start > lineStart, isSpace(char(start - 1)) { start -= 1 }
        }
        return Span(start: start, end: end)
    }

    private static let tagPattern = try! NSRegularExpression(pattern: "<(/?)([A-Za-z][\\w:.-]*)(?:\\s[^<>]*?)?(/?)>")

    /// `it`, `at`: the `count`th XML/HTML element around the cursor.
    func tagObject(at offset: Int, around: Bool, count: Int) -> Span? {
        var stack: [(name: String, start: Int, end: Int)] = []
        var pairs: [(openStart: Int, openEnd: Int, closeStart: Int, closeEnd: Int)] = []
        for match in Self.tagPattern.matches(in: string as String, range: NSRange(location: 0, length: length)) {
            if match.range(at: 3).length > 0 { continue } // self-closing
            let name = string.substring(with: match.range(at: 2))
            if match.range(at: 1).length == 0 {
                stack.append((name, match.range.location, NSMaxRange(match.range)))
            } else if let at = stack.lastIndex(where: { $0.name == name }) {
                let open = stack[at]
                stack.removeSubrange(at...)
                pairs.append((open.start, open.end, match.range.location, NSMaxRange(match.range)))
            }
        }
        let containing = pairs.filter { $0.openStart <= offset && offset < $0.closeEnd }
            .sorted { ($0.closeEnd - $0.openStart) < ($1.closeEnd - $1.openStart) }
        guard containing.count >= count, let pair = containing.dropFirst(count - 1).first else { return nil }
        return around ? Span(start: pair.openStart, end: pair.closeEnd) : Span(start: pair.openEnd, end: pair.closeStart)
    }

    /// `ip`, `ap`: lines of a paragraph (or of blank lines), whole.
    func paragraphObject(at offset: Int, around: Bool, count: Int) -> Span {
        var first = line(of: offset), last = first
        let blank = isBlank(line: first)
        while first > 0, isBlank(line: first - 1) == blank { first -= 1 }
        while last < lastLine, isBlank(line: last + 1) == blank { last += 1 }
        func extend() {
            guard last < lastLine else { return }
            let kind = isBlank(line: last + 1)
            while last < lastLine, isBlank(line: last + 1) == kind { last += 1 }
        }
        if around {
            if last < lastLine { extend() } else {
                while first > 0, isBlank(line: first - 1) != blank { first -= 1 }
            }
        }
        for _ in 1..<max(1, count) {
            extend()
            if around { extend() }
        }
        return Span(start: start(ofLine: first), end: end(ofLine: last), linewise: true)
    }
}

/// Vim's regular expressions as `NSRegularExpression` ones: in Vim, `(`, `)`, `|`, `+`, `?`,
/// `{` and `}` are plain characters and their escaped forms are special, `\<` and `\>` are word
/// boundaries; `\v` turns that around (as written here), `\c` and `\C` set case.
enum VimRegex {
    static func make(_ pattern: String, ignoreCase: Bool = false, smartCase: Bool = false) -> NSRegularExpression? {
        var output = ""
        var caseless: Bool? = nil
        var veryMagic = false
        var inBrace = false
        var chars = Array(pattern)
        var index = 0
        // Flags anywhere in the pattern.
        while let at = (0..<max(0, chars.count - 1)).first(where: { i in
            chars[i] == "\\" && (chars[i + 1] == "c" || chars[i + 1] == "C") && (i == 0 || chars[i - 1] != "\\")
        }) {
            caseless = chars[at + 1] == "c"
            chars.removeSubrange(at...(at + 1))
        }
        while index < chars.count {
            let c = chars[index]
            if c == "\\", index + 1 < chars.count {
                let n = chars[index + 1]
                index += 2
                switch n {
                case "v": veryMagic = true
                case "m", "M", "V": veryMagic = false
                case "<", ">": output += "\\b"
                case _ where !veryMagic && "()|+?{}".contains(n):
                    output.append(n)
                    if n == "{" { inBrace = true } else if n == "}" { inBrace = false }
                case "=" where !veryMagic: output += "?"
                default: output += "\\" + String(n)
                }
                continue
            }
            index += 1
            if !veryMagic, c == "}", inBrace {
                // `\{2,3}` closes with a plain brace.
                output.append(c)
                inBrace = false
            } else if !veryMagic, "()|+?{}".contains(c) {
                output += "\\" + String(c)
            } else if veryMagic, c == "<" || c == ">" {
                output += "\\b"
            } else if veryMagic, c == "=" {
                output += "?"
            } else {
                output.append(c)
            }
        }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        let insensitive = caseless ?? (ignoreCase && !(smartCase && pattern.contains { $0.isUppercase }))
        if insensitive { options.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: output, options: options)
    }

    /// A substitution's replacement for one match: `&` and `\0` are the match, `\1`…`\9` its
    /// groups, `\r` and `\n` a line break, `\t` a tab; `\u`, `\l` (next character) and `\U`,
    /// `\L`, `\E` (until `\E`) change case.
    static func expand(_ replacement: String, match: NSTextCheckingResult, in string: NSString, lineBreak: String) -> String {
        func group(_ index: Int) -> String {
            guard index < match.numberOfRanges else { return "" }
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : string.substring(with: range)
        }
        var output = ""
        var oneShot: Character? // "u" or "l"
        var running: Character? // "U" or "L"
        func emit(_ text: String) {
            for character in text {
                var piece = String(character)
                if let shot = oneShot {
                    piece = shot == "u" ? piece.uppercased() : piece.lowercased()
                    oneShot = nil
                } else if let running {
                    piece = running == "U" ? piece.uppercased() : piece.lowercased()
                }
                output += piece
            }
        }
        let chars = Array(replacement)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\\", index + 1 < chars.count {
                let n = chars[index + 1]
                index += 2
                switch n {
                case "0"..."9": emit(group(Int(String(n))!))
                case "n", "r": output += lineBreak
                case "t": output += "\t"
                case "u", "l": oneShot = n
                case "U", "L": running = n
                case "E", "e": running = nil
                default: emit(String(n))
                }
                continue
            }
            index += 1
            if c == "&" { emit(group(0)) } else { emit(String(c)) }
        }
        return output
    }
}
