import AppKit
import SwiftTreeSitter
import SwiftUI

/// A syntax-colored piece of one line: its UTF-16 range within the line and the capture name.
struct LineSpan: Sendable, Equatable {
    let range: NSRange
    let capture: String
}

/// Syntax colors for one side of a diff. Each side is a whole file version (HEAD, index or the
/// buffer), parsed by its own tree-sitter engine off the main thread and split into lines.
enum DiffSyntax {
    /// Larger versions are shown without colors.
    static let maxLength = 2 * 1024 * 1024

    /// Spans for each line of `text` (lines split on "\n", like `LineDiff.lines`); nil if the
    /// language has no grammar or the text is too large.
    @MainActor
    static func highlight(_ text: String, language: SourceLanguage) async -> [[LineSpan]]? {
        let string = NSString(string: text)
        guard string.length <= maxLength, let grammar = GrammarRegistry.grammar(for: language),
              let engine = SyntaxEngine(grammar: grammar) else { return nil }
        let length = string.length
        let highlights = await engine.process(snapshot: TextSnapshot(string: string), edits: [],
                                              highlightRange: NSRange(location: 0, length: length)) ?? []
        let snapshot = TextSnapshot(string: string)
        return await Task.detached(priority: .utility) {
            spansByLine(highlights.map { ($0.range, $0.name) }, in: snapshot.string)
        }.value
    }

    /// Splits highlights (UTF-16 ranges of the whole text) into per-line spans, clipping ones
    /// that cross lines. Order is kept: later highlights win where they overlap.
    nonisolated static func spansByLine(_ highlights: [(range: NSRange, name: String)], in text: NSString) -> [[LineSpan]] {
        let index = LineIndex(string: text)
        let starts = index.lineStarts
        var lines = [[LineSpan]](repeating: [], count: starts.count)
        for (range, name) in highlights where range.length > 0 && NSMaxRange(range) <= text.length {
            var line = index.line(containing: range.location)
            while line < starts.count, starts[line] < NSMaxRange(range) {
                let lineStart = starts[line]
                let lineEnd = line + 1 < starts.count ? starts[line + 1] - 1 : text.length // without "\n"
                let clipped = NSIntersectionRange(range, NSRange(location: lineStart, length: lineEnd - lineStart))
                if clipped.length > 0 {
                    lines[line].append(LineSpan(range: NSRange(location: clipped.location - lineStart, length: clipped.length),
                                                capture: name))
                }
                line += 1
            }
        }
        return lines
    }
}

/// Which words changed within a changed line, for highlighting inside the line.
enum WordDiff {
    /// Longer lines only get the whole-line tint.
    static let maxLineLength = 2_000

    /// UTF-16 ranges of the removed parts of `old` and the inserted parts of `new`. Empty when
    /// the lines share no words (rewritten entirely: the line tint already says that).
    static func changes(old: String, new: String) -> (old: [NSRange], new: [NSRange]) {
        let oldString = old as NSString, newString = new as NSString
        guard oldString.length <= maxLineLength, newString.length <= maxLineLength else { return ([], []) }
        let oldTokens = tokens(oldString), newTokens = tokens(newString)
        let difference = newTokens.map(\.text).difference(from: oldTokens.map(\.text))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Something other than whitespace must be in common, or the diff is just noise.
        let shared = oldTokens.indices.contains { !removed.contains($0) && !oldTokens[$0].isSpace }
        guard shared else { return ([], []) }
        return (merged(removed.sorted().map { oldTokens[$0].range }), merged(inserted.sorted().map { newTokens[$0].range }))
    }

    struct Token {
        let text: String
        let range: NSRange
        let isSpace: Bool
    }

    /// Words (letters, digits, `_`), runs of whitespace, and single other characters.
    static func tokens(_ string: NSString) -> [Token] {
        enum Kind { case word, space, other }
        func kind(_ unit: unichar) -> Kind {
            if UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) { return .word }
            guard let scalar = Unicode.Scalar(unit) else { return .other }
            if scalar == "_" || CharacterSet.alphanumerics.contains(scalar) { return .word }
            if CharacterSet.whitespaces.contains(scalar) { return .space }
            return .other
        }
        var result: [Token] = []
        var start = 0
        let length = string.length
        while start < length {
            let first = kind(string.character(at: start))
            var end = start + 1
            if first != .other {
                while end < length, kind(string.character(at: end)) == first { end += 1 }
            }
            let range = NSRange(location: start, length: end - start)
            result.append(Token(text: string.substring(with: range), range: range, isSpace: first == .space))
            start = end
        }
        return result
    }

    /// Joins ranges that touch.
    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges {
            if let last = result.last, NSMaxRange(last) == range.location {
                result[result.count - 1].length += range.length
            } else {
                result.append(range)
            }
        }
        return result
    }
}

/// Builds a diff line's styled text.
@MainActor
enum DiffLineStyle {
    static func attributed(_ line: String, spans: [LineSpan]?, words: [NSRange], wordTint: Color?) -> AttributedString {
        var text = AttributedString(line.isEmpty ? " " : line)
        text.foregroundColor = Color(nsColor: EditorTheme.current.foreground)
        guard !line.isEmpty else { return text }
        let length = (line as NSString).length
        for span in spans ?? [] where NSMaxRange(span.range) <= length {
            guard let color = EditorTheme.color(forCapture: span.capture),
                  let range = Range(span.range, in: text) else { continue }
            text[range].foregroundColor = Color(nsColor: color)
        }
        if let wordTint {
            for word in words where NSMaxRange(word) <= length {
                guard let range = Range(word, in: text) else { continue }
                text[range].backgroundColor = wordTint
            }
        }
        return text
    }
}
