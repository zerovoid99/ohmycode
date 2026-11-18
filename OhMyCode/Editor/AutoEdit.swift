import AppKit

/// Typing helpers for a single cursor: Enter keeps (and after an opening bracket, deepens) the
/// indentation; brackets and quotes close themselves; typing a closer that's already there
/// steps over it; Backspace between an empty pair deletes both; a closing bracket typed on a
/// blank line moves back one indent level. A language with a configuration from an extension
/// (`language-configuration.json`) uses its pairs, `autoCloseBefore`, `onEnterRules` and
/// `indentationRules` instead.
extension EditorController {
    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}"]
    private static let quotes: Set<Character> = ["\"", "'", "`"]

    private var string: NSString { document.textStorage.mutableString }

    /// The language's configuration from an extension, if it has one.
    private var configuration: LanguageConfiguration? { LanguageRegistry.shared.configuration(for: document.language) }

    /// The pairs that close themselves: the configuration's (single characters), else the built-in ones.
    private var autoClosingPairs: [Character: Character] {
        guard let pairs = configuration?.autoClosingPairs ?? configuration?.brackets.map({ $0.map { LanguageConfiguration.Pair(open: $0.open, close: $0.close) } })
        else { return Self.pairs }
        var result: [Character: Character] = [:]
        for pair in pairs where pair.open.count == 1 && pair.close.count == 1 { result[pair.open.first!] = pair.close.first! }
        return result
    }

    /// Closing brackets (stepped over, outdented on a blank line).
    private var closingBrackets: Set<Character> {
        guard let configuration, let brackets = configuration.brackets ?? configuration.autoClosingPairs.map({ $0.map { ($0.open, $0.close) } })
        else { return Self.closers }
        return Set(brackets.compactMap { $0.close.count == 1 && $0.open != $0.close ? $0.close.first : nil })
    }

    private var quoteCharacters: Set<Character> {
        guard configuration?.autoClosingPairs != nil else { return Self.quotes }
        return Set(autoClosingPairs.filter { $0.key == $0.value }.map(\.key))
    }

    private func character(at offset: Int) -> Character? {
        guard offset >= 0, offset < string.length, let scalar = Unicode.Scalar(string.character(at: offset)) else { return nil }
        return Character(scalar)
    }

    /// One level of indentation, as the file indents (tabs or 2/4 spaces).
    var indentUnit: String {
        let (size, spaces) = document.indentation
        return spaces ? String(repeating: " ", count: size) : "\t"
    }

    /// Leading whitespace of `line`.
    private func leadingWhitespace(ofLine line: Int) -> String {
        let start = document.lineIndex.lineStarts[line]
        var end = start
        while let c = character(at: end), c == " " || c == "\t" { end += 1 }
        return string.substring(with: NSRange(location: start, length: end - start))
    }

    /// Replaces `range` through the text view (undo, typing coalescing) and places the cursor.
    private func replace(_ range: NSRange, with text: String, select selection: NSRange) {
        textView.insertText(text, replacementRange: range)
        textView.setSelectedRange(selection)
    }

    /// `indent` one level shallower.
    private func outdented(_ indent: String) -> String {
        var result = indent
        if result.hasSuffix(indentUnit) { result.removeLast(indentUnit.count) } else if !result.isEmpty { result.removeLast() }
        return result
    }

    // MARK: Typing

    /// Handles one typed character; false lets the text view insert it as usual.
    func handleTyped(_ text: String) -> Bool {
        if handleLinkedTyping(text) { return true }
        guard text.count == 1, let typed = text.first else { return false }
        let selection = textView.selectedRange()
        let next = character(at: NSMaxRange(selection))
        let autoClose = AppSettings.shared.autoClosePairs
        let configuration = configuration
        let pairs = autoClosingPairs, closers = closingBrackets, quotes = quoteCharacters

        // A closer (or closing quote) that's already next: step over it.
        if autoClose, selection.length == 0, typed == next, closers.contains(typed) || quotes.contains(typed) {
            textView.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return true
        }

        // A closing bracket typed on a blank line goes one level out (or a line the language's
        // `decreaseIndentPattern` matches once it's typed).
        if selection.length == 0 {
            let line = document.lineIndex.line(containing: selection.location)
            let lineStart = document.lineIndex.lineStarts[line]
            let prefix = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            if closers.contains(typed), !prefix.isEmpty, prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let replacement = outdented(prefix) + String(typed)
                replace(NSRange(location: lineStart, length: prefix.utf16.count), with: replacement,
                        select: NSRange(location: lineStart + replacement.utf16.count, length: 0))
                return true
            }
            if let decrease = configuration?.indentationRules?.decreaseIndent, handleDecreaseIndent(decrease, typed: typed, line: line) {
                return true
            }
        }

        // With a selection: wrap it (in the configuration's surrounding pairs, when it has them).
        if autoClose, selection.length > 0 {
            let surround: [Character: Character]
            if let surrounding = configuration?.surroundingPairs {
                surround = Dictionary(surrounding.compactMap { $0.open.count == 1 && $0.close.count == 1 ? ($0.open.first!, $0.close.first!) : nil },
                                      uniquingKeysWith: { first, _ in first })
            } else {
                surround = pairs
            }
            guard let close = surround[typed] else { return false }
            let inner = string.substring(with: selection)
            replace(selection, with: "\(typed)\(inner)\(close)", select: NSRange(location: selection.location + 1, length: selection.length))
            return true
        }

        guard autoClose else { return false }
        if let configuration, let pairs = configuration.autoClosingPairs {
            return autoCloseConfigured(typed, pairs: pairs, configuration: configuration, at: selection.location, next: next)
        }
        guard let close = pairs[typed] else { return false }
        // Only before whitespace, a closer or punctuation: not when it would break up a word.
        if let next, !(next.isWhitespace || closers.contains(next) || ",;:.".contains(next)) { return false }
        if quotes.contains(typed) {
            let previous = character(at: selection.location - 1)
            if let previous, previous.isLetter || previous.isNumber || previous == "_" { return false } // don't, x'
        }
        replace(selection, with: "\(typed)\(close)", select: NSRange(location: selection.location + 1, length: 0))
        return true
    }

    /// The configuration's `autoClosingPairs`: an opener (several characters too, `/**`) ending
    /// with what's typed closes, unless the cursor is where `notIn` says not to ("string",
    /// "comment") or the next character isn't in `autoCloseBefore`.
    private func autoCloseConfigured(_ typed: Character, pairs: [LanguageConfiguration.Pair], configuration: LanguageConfiguration,
                                     at location: Int, next: Character?) -> Bool {
        let line = document.lineIndex.line(containing: location)
        let lineStart = document.lineIndex.lineStarts[line]
        let before = string.substring(with: NSRange(location: lineStart, length: location - lineStart))
        let typedText = before + String(typed)
        guard let pair = pairs.filter({ typedText.hasSuffix($0.open) }).max(by: { $0.open.count < $1.open.count }) else { return false }
        if let next, !(configuration.autoCloseBefore ?? LanguageConfiguration.defaultAutoCloseBefore).contains(next) { return false }
        if !pair.notIn.isEmpty {
            let context = Self.context(of: before, lineComment: configuration.comments?.lineComment ?? document.language.lineComment,
                                       quotes: Set(pairs.filter { $0.open == $0.close && $0.open.count == 1 }.map { $0.open.first! }))
            if let context, pair.notIn.contains(context) { return false }
        }
        if pair.open == pair.close, pair.open.count == 1, let previous = before.last, previous.isLetter || previous.isNumber || previous == "_" {
            return false // don't, x'
        }
        replace(NSRange(location: location, length: 0), with: String(typed) + pair.close,
                select: NSRange(location: location + 1, length: 0))
        return true
    }

    /// Whether the end of `text` (a line up to the cursor) is in a "string" or a "comment" (nil:
    /// in code), by scanning its quotes and line comment.
    static func context(of text: String, lineComment: String?, quotes: Set<Character>) -> String? {
        var open: Character?
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let quote = open {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == quote { open = nil }
            } else if let lineComment, !lineComment.isEmpty, text[index...].hasPrefix(lineComment) {
                return "comment"
            } else if quotes.contains(character) {
                open = character
            }
            index = text.index(after: index)
        }
        return open == nil ? nil : "string"
    }

    /// `decreaseIndentPattern`: typing that makes the line match (`end`, `}`) moves it one level
    /// shallower than the line above, if it isn't already.
    private func handleDecreaseIndent(_ pattern: LanguageConfiguration.Pattern, typed: Character, line: Int) -> Bool {
        guard line > 0 else { return false }
        let selection = textView.selectedRange()
        let lineStart = document.lineIndex.lineStarts[line]
        let lineEnd = line + 1 < document.lineIndex.lineCount ? document.lineIndex.lineStarts[line + 1] : string.length
        var text = string.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
        if text.hasSuffix("\n") { text.removeLast() }
        let offset = selection.location - lineStart
        let typedLine = (text as NSString).replacingCharacters(in: NSRange(location: offset, length: 0), with: String(typed))
        guard pattern.matches(typedLine), !pattern.matches(text) else { return false }
        let indent = leadingWhitespace(ofLine: line)
        // The nearest line above with text sets the level.
        var above = line - 1
        while above > 0, document.lineIndex.lineText(above, in: string).allSatisfy(\.isWhitespace) { above -= 1 }
        let aboveIndent = leadingWhitespace(ofLine: above)
        let target = configuration?.indentationRules?.increaseIndent?.matches(document.lineIndex.lineText(above, in: string)) == true
            ? aboveIndent : outdented(aboveIndent)
        guard indent.count > target.count, indent.hasPrefix(target) else { return false }
        let indentLength = indent.utf16.count
        guard offset >= indentLength else { return false }
        let typedPart = (text as NSString).substring(with: NSRange(location: indentLength, length: offset - indentLength)) + String(typed)
        replace(NSRange(location: lineStart, length: offset), with: target + typedPart,
                select: NSRange(location: lineStart + (target + typedPart).utf16.count, length: 0))
        return true
    }

    // MARK: Enter and Backspace

    /// Enter: a new line with the current line's indentation, one level deeper after an opening
    /// bracket (or `:` in Python); between brackets, the closer moves to its own line. The
    /// language configuration's `onEnterRules`, then its `indentationRules`, decide first.
    func handleNewline() -> Bool {
        let selection = textView.selectedRange()
        let line = document.lineIndex.line(containing: selection.location)
        let lineStart = document.lineIndex.lineStarts[line]
        let indent = leadingWhitespace(ofLine: line)
        // The file's own line break: a "\n" typed into a "\r\n" file would mix the two.
        let lineBreak = document.lineEnding.characters

        if let configuration, handleConfiguredNewline(configuration, selection: selection, line: line, indent: indent, lineBreak: lineBreak) {
            return true
        }

        var before = selection.location - 1
        while before >= lineStart, let c = character(at: before), c == " " || c == "\t" { before -= 1 }
        let opener = before >= lineStart ? character(at: before) : nil
        let after = character(at: NSMaxRange(selection))
        let pairs = autoClosingPairs
        let openers = configuration?.brackets.map { Set($0.compactMap { $0.open.count == 1 ? $0.open.first : nil }) } ?? ["{", "(", "["]
        let opensBlock = opener.map { openers.contains($0) || ($0 == ":" && document.language == .python) } ?? false

        if opensBlock, let opener, let after, pairs[opener] == after {
            let text = lineBreak + indent + indentUnit + lineBreak + indent
            replace(selection, with: text,
                    select: NSRange(location: selection.location + (lineBreak + indent + indentUnit).utf16.count, length: 0))
        } else {
            let text = lineBreak + indent + (opensBlock ? indentUnit : "")
            replace(selection, with: text, select: NSRange(location: selection.location + text.utf16.count, length: 0))
        }
        return true
    }

    /// `onEnterRules` (the first that matches the text before the cursor, and after it and the
    /// line above when it says), else `indentationRules`; false when neither says anything.
    private func handleConfiguredNewline(_ configuration: LanguageConfiguration, selection: NSRange, line: Int, indent: String,
                                         lineBreak: String) -> Bool {
        let lineStart = document.lineIndex.lineStarts[line]
        let lineText = document.lineIndex.lineText(line, in: string)
        let cursorInLine = min(selection.location - lineStart, (lineText as NSString).length)
        let beforeText = (lineText as NSString).substring(to: cursorInLine)
        let afterText = (lineText as NSString).substring(from: min(NSMaxRange(selection) - lineStart, (lineText as NSString).length))
        let previousLine = line > 0 ? document.lineIndex.lineText(line - 1, in: string) : ""

        func insert(_ newIndent: String, append: String = "", closing: String? = nil) {
            var text = lineBreak + newIndent + append
            let cursor = selection.location + text.utf16.count
            if let closing { text += lineBreak + closing }
            replace(selection, with: text, select: NSRange(location: cursor, length: 0))
        }

        for rule in configuration.onEnterRules ?? [] {
            guard rule.beforeText.matches(beforeText) else { continue }
            if let pattern = rule.afterText, !pattern.matches(afterText) { continue }
            if let pattern = rule.previousLineText, !pattern.matches(previousLine) { continue }
            var base = indent
            if let remove = rule.removeText, remove > 0 { base = String(base.dropLast(min(remove, base.count))) }
            let append = rule.appendText ?? ""
            switch rule.indent {
            case .none: insert(base, append: append)
            case .indent: insert(base + indentUnit, append: append)
            case .outdent: insert(outdented(base), append: append)
            case .indentOutdent: insert(base + indentUnit, append: append, closing: base)
            }
            return true
        }

        guard let rules = configuration.indentationRules else { return false }
        let increases = rules.increaseIndent?.matches(beforeText) == true || rules.indentNextLine?.matches(beforeText) == true
        let decreasesAfter = rules.decreaseIndent?.matches(afterText) == true
        if increases && decreasesAfter && !afterText.trimmingCharacters(in: .whitespaces).isEmpty {
            insert(indent + indentUnit, closing: indent)
        } else if increases {
            insert(indent + indentUnit)
        } else if rules.unIndentedLine?.matches(beforeText) == true {
            insert(indent)
        } else {
            // The line after an `indentNextLinePattern` line (a brace-less `if`) goes back.
            let previousIndents = line > 0 && rules.indentNextLine?.matches(previousLine) == true
                && rules.increaseIndent?.matches(previousLine) != true
            insert(previousIndents ? outdented(indent) : indent)
        }
        return true
    }

    /// Backspace between an empty pair, `(|)`, deletes both.
    func handleDeleteBackward() -> Bool {
        let selection = textView.selectedRange()
        guard AppSettings.shared.autoClosePairs, selection.length == 0, selection.location > 0,
              let previous = character(at: selection.location - 1), let close = autoClosingPairs[previous],
              character(at: selection.location) == close else { return false }
        replace(NSRange(location: selection.location - 1, length: 2), with: "",
                select: NSRange(location: selection.location - 1, length: 0))
        return true
    }
}
