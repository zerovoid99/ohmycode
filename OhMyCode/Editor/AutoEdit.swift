import AppKit

/// Typing helpers for a single cursor: Enter keeps (and after an opening bracket, deepens) the
/// indentation; brackets and quotes close themselves; typing a closer that's already there
/// steps over it; Backspace between an empty pair deletes both; a closing bracket typed on a
/// blank line moves back one indent level.
extension EditorController {
    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}"]
    private static let quotes: Set<Character> = ["\"", "'", "`"]

    private var string: NSString { document.textStorage.mutableString }

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

    // MARK: Typing

    /// Handles one typed character; false lets the text view insert it as usual.
    func handleTyped(_ text: String) -> Bool {
        if handleLinkedTyping(text) { return true }
        guard text.count == 1, let typed = text.first else { return false }
        let selection = textView.selectedRange()
        let next = character(at: NSMaxRange(selection))
        let autoClose = AppSettings.shared.autoClosePairs

        // A closer (or closing quote) that's already next: step over it.
        if autoClose, selection.length == 0, typed == next, Self.closers.contains(typed) || Self.quotes.contains(typed) {
            textView.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return true
        }

        // A closing bracket typed on a blank line goes one level out.
        if Self.closers.contains(typed), selection.length == 0 {
            let line = document.lineIndex.line(containing: selection.location)
            let lineStart = document.lineIndex.lineStarts[line]
            let prefix = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
            if !prefix.isEmpty, prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let unit = indentUnit
                var outdented = prefix
                if outdented.hasSuffix(unit) { outdented.removeLast(unit.count) } else { outdented.removeLast() }
                let replacement = outdented + String(typed)
                replace(NSRange(location: lineStart, length: prefix.utf16.count), with: replacement,
                        select: NSRange(location: lineStart + replacement.utf16.count, length: 0))
                return true
            }
        }

        guard autoClose, let close = Self.pairs[typed] else { return false }
        // With a selection: wrap it.
        if selection.length > 0 {
            let inner = string.substring(with: selection)
            replace(selection, with: "\(typed)\(inner)\(close)", select: NSRange(location: selection.location + 1, length: selection.length))
            return true
        }
        // Only before whitespace, a closer or punctuation: not when it would break up a word.
        if let next, !(next.isWhitespace || Self.closers.contains(next) || ",;:.".contains(next)) { return false }
        if Self.quotes.contains(typed) {
            let previous = character(at: selection.location - 1)
            if let previous, previous.isLetter || previous.isNumber || previous == "_" { return false } // don't, x'
        }
        replace(selection, with: "\(typed)\(close)", select: NSRange(location: selection.location + 1, length: 0))
        return true
    }

    // MARK: Enter and Backspace

    /// Enter: a new line with the current line's indentation, one level deeper after an opening
    /// bracket (or `:` in Python); between brackets, the closer moves to its own line.
    func handleNewline() -> Bool {
        let selection = textView.selectedRange()
        let line = document.lineIndex.line(containing: selection.location)
        let lineStart = document.lineIndex.lineStarts[line]
        let indent = leadingWhitespace(ofLine: line)

        var before = selection.location - 1
        while before >= lineStart, let c = character(at: before), c == " " || c == "\t" { before -= 1 }
        let opener = before >= lineStart ? character(at: before) : nil
        let after = character(at: NSMaxRange(selection))
        let opensBlock = opener.map { "{([".contains($0) || ($0 == ":" && document.language == .python) } ?? false

        if opensBlock, let opener, let after, Self.pairs[opener] == after {
            let text = "\n" + indent + indentUnit + "\n" + indent
            replace(selection, with: text, select: NSRange(location: selection.location + 1 + (indent + indentUnit).utf16.count, length: 0))
        } else {
            let text = "\n" + indent + (opensBlock ? indentUnit : "")
            replace(selection, with: text, select: NSRange(location: selection.location + text.utf16.count, length: 0))
        }
        return true
    }

    /// Backspace between an empty pair, `(|)`, deletes both.
    func handleDeleteBackward() -> Bool {
        let selection = textView.selectedRange()
        guard AppSettings.shared.autoClosePairs, selection.length == 0, selection.location > 0,
              let previous = character(at: selection.location - 1), let close = Self.pairs[previous],
              character(at: selection.location) == close else { return false }
        replace(NSRange(location: selection.location - 1, length: 2), with: "",
                select: NSRange(location: selection.location - 1, length: 0))
        return true
    }
}
