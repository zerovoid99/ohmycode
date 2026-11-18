import Foundation
import SwiftTreeSitter

/// A document's TextMate tokens, line by line, kept across edits: an edit drops the tokens of
/// the lines it touched, and the lines after it keep theirs until tokenizing reaches them. If
/// the state a kept line starts in comes out the same as before, it and every kept line after
/// it are still right and aren't tokenized again (typing inside a function doesn't re-tokenize
/// the rest of the file; opening a block comment does, as far as the comment goes).
/// Lines are only tokenized as far as something asks to see.
final class TextMateDocument {
    let tokenizer: TextMateTokenizer
    private(set) var text: NSString = ""
    /// Where each line starts (UTF-16).
    private(set) var lineStarts: [Int] = [0]

    private struct Line {
        /// The state tokenizing this line started from.
        var start: TextMateState?
        var tokens: [TextMateToken]?
        var end: TextMateState?
    }

    private var lines: [Line] = [Line()]
    /// Lines before this have tokens computed from the right start state.
    private(set) var validLines = 0
    /// How many lines were tokenized (tests: what an edit cost).
    private(set) var tokenizedLineCount = 0

    init(tokenizer: TextMateTokenizer) {
        self.tokenizer = tokenizer
    }

    var lineCount: Int { lineStarts.count }

    /// New text, after `edits` (in order, each with tree-sitter's rows); none: a different
    /// text altogether.
    func update(text newText: NSString, edits: [InputEdit]) {
        let oldCount = lineStarts.count
        text = newText
        lineStarts = Self.lineStarts(of: newText)
        let newCount = lineStarts.count
        guard !edits.isEmpty, validLines > 0 || lines.contains(where: { $0.tokens != nil }) else {
            lines = Array(repeating: Line(), count: newCount)
            validLines = 0
            return
        }
        // The first line an edit touched, and how many lines at the end no edit reached.
        var first = Int.max
        var count = oldCount
        var untouchedSuffix = Int.max
        for edit in edits {
            first = min(first, Int(edit.startPoint.row))
            count += Int(edit.newEndPoint.row) - Int(edit.oldEndPoint.row)
            untouchedSuffix = min(untouchedSuffix, count - 1 - Int(edit.newEndPoint.row))
        }
        first = min(max(first, 0), newCount)
        untouchedSuffix = max(0, min(untouchedSuffix, newCount - first - 1, oldCount - first - 1))
        let delta = newCount - oldCount
        var updated = Array(lines.prefix(first))
        updated.reserveCapacity(newCount)
        // The first edited line keeps its start state (the lines before it didn't change).
        let dirtyEnd = newCount - untouchedSuffix
        for index in first..<dirtyEnd {
            updated.append(Line(start: index == first && first < lines.count ? lines[first].start : nil))
        }
        for index in dirtyEnd..<newCount {
            let old = index - delta
            updated.append(old >= 0 && old < lines.count ? lines[old] : Line())
        }
        lines = updated
        validLines = min(validLines, first)
    }

    /// Tokenizes up to and including `line` (as far as needed).
    func tokenize(through line: Int) {
        let target = min(line, lines.count - 1)
        while validLines <= target {
            let index = validLines
            let start: TextMateState? = index == 0 ? nil : lines[index - 1].end
            // A kept line whose start state is unchanged: it and the kept lines after it stand.
            if index > 0, lines[index].tokens != nil, lines[index].start == start {
                var next = index
                while next < lines.count, lines[next].tokens != nil,
                      next == index || lines[next].start == lines[next - 1].end {
                    next += 1
                }
                validLines = next
                continue
            }
            let (tokens, end) = tokenizer.tokenize(line: lineText(index), state: start)
            tokenizedLineCount += 1
            lines[index] = Line(start: start, tokens: tokens, end: end)
            validLines = index + 1
        }
    }

    func lineText(_ index: Int) -> NSString {
        let start = lineStarts[index]
        var end = index + 1 < lineStarts.count ? lineStarts[index + 1] : text.length
        // Without the line break ("\r\n" too).
        if end > start, text.character(at: end - 1) == 0x0A { end -= 1 }
        if end > start, text.character(at: end - 1) == 0x0D { end -= 1 }
        return text.substring(with: NSRange(location: start, length: end - start)) as NSString
    }

    func line(containing offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// A line's tokens (tokenizing up to it if needed).
    func tokens(line: Int) -> [TextMateToken] {
        tokenize(through: line)
        return lines[line].tokens ?? []
    }

    /// The scopes at a document offset, outermost first.
    func scopes(at offset: Int) -> [String] {
        let line = line(containing: offset)
        let column = offset - lineStarts[line]
        let tokens = tokens(line: line)
        return (tokens.first { $0.start <= column && column < $0.end } ?? tokens.last)?.scopes ?? [tokenizer.scopeName]
    }

    /// Highlights for the lines `range` touches: one per token that has a scope beyond the
    /// grammar's own, named by its scopes joined with spaces (see `TextMateScopes`).
    func highlights(in range: NSRange) -> [NamedRange] {
        guard text.length > 0 else { return [] }
        let firstLine = line(containing: range.location)
        let lastLine = line(containing: max(range.location, NSMaxRange(range) - 1))
        tokenize(through: lastLine)
        var result: [NamedRange] = []
        for index in firstLine...lastLine {
            let start = lineStarts[index]
            for token in lines[index].tokens ?? [] where token.scopes.count > 1 {
                result.append(NamedRange(name: token.scopes.joined(separator: " "),
                                         range: NSRange(location: start + token.start, length: token.end - token.start)))
            }
        }
        return result
    }

    static func lineStarts(of text: NSString) -> [Int] {
        var starts = [0]
        let length = text.length
        let chunk = 64 * 1024
        var buffer = [unichar](repeating: 0, count: chunk)
        var position = 0
        while position < length {
            let count = min(chunk, length - position)
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: position, length: count))
                for index in 0..<count where pointer[index] == 0x0A { starts.append(position + index + 1) }
            }
            position += count
        }
        return starts
    }
}
