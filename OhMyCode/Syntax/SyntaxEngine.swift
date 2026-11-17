import Foundation
import SwiftTreeSitter

/// Immutable copy of the document text (or of the window being parsed, starting at `offset`)
/// handed to the background parser.
/// `@unchecked Sendable`: the wrapped NSString is an immutable copy and never mutated.
struct TextSnapshot: @unchecked Sendable {
    let string: NSString
    /// Where `string` starts in the document (UTF-16 offset).
    var offset = 0
}

/// Owns the tree-sitter parser and tree off the main thread. Edits, parses and highlight
/// queries are serialized by the actor; the main thread never waits on it.
actor SyntaxEngine {
    private let parser = Parser()
    private let query: Query?
    /// For a language without a grammar (`.http`): highlights straight from the text.
    private let lineHighlighter: (@Sendable (NSString, NSRange) -> [NamedRange])?
    private var tree: MutableTree?
    private var text: NSString = ""
    /// Where `text` starts in the document.
    private var offset = 0
    /// Whether only a window of the document is parsed (see `SyntaxHighlighter.windowThreshold`).
    private(set) var isWindowed = false

    init?(grammar: Grammar) {
        guard (try? parser.setLanguage(grammar.language)) != nil else { return nil }
        query = grammar.highlightsQuery
        lineHighlighter = nil
    }

    /// An engine that keeps the text and highlights it with `highlighter` (no syntax tree:
    /// the outline and folding come from elsewhere).
    init(lineHighlighter highlighter: @escaping @Sendable (NSString, NSRange) -> [NamedRange]) {
        query = nil
        lineHighlighter = highlighter
    }

    /// Applies `edits` (made since the previous snapshot) and reparses against `snapshot`, if
    /// given; then returns highlights for `range` in the resulting tree, if requested.
    /// With a `window`, only that part of the document is parsed (the snapshot holds just it);
    /// `reset` drops the old tree first (a new window, not an edited one).
    func process(snapshot: TextSnapshot?, edits: [InputEdit], highlightRange: NSRange?,
                 window: TSRange? = nil, reset: Bool = false) -> [NamedRange]? {
        if let snapshot, lineHighlighter != nil {
            text = snapshot.string
            offset = snapshot.offset
            isWindowed = window != nil
        } else if let snapshot {
            if reset { tree = nil }
            if let tree {
                for edit in edits { tree.edit(edit) }
            }
            text = snapshot.string
            offset = snapshot.offset
            isWindowed = window != nil
            // (A document stays windowed or not; an empty list here would crash SwiftTreeSitter.)
            if let window { parser.includedRanges = [window] }
            tree = parse(text, reusing: tree)
        }
        return highlightRange.map(highlights(in:))
    }

    /// The latest parsed tree's root and its text (for the outline and folding): only when the
    /// whole document is parsed, so a window doesn't pass for the whole file.
    var currentRoot: Node? { isWindowed ? nil : tree?.rootNode }
    var currentText: NSString { text }

    func highlights(in range: NSRange) -> [NamedRange] {
        if let lineHighlighter {
            let local = NSIntersectionRange(NSRange(location: range.location - offset, length: range.length),
                                            NSRange(location: 0, length: text.length))
            guard local.length > 0 || text.length == 0 else { return [] }
            let found = lineHighlighter(text, local)
            guard offset != 0 else { return found }
            return found.map { NamedRange(name: $0.name, range: NSRange(location: $0.range.location + offset, length: $0.range.length)) }
        }
        guard let query, let tree, let root = tree.rootNode else { return [] }
        let text = text, offset = self.offset
        let length = text.length
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(range)
        let context = Predicate.Context(textProvider: { range, _ in
            let local = NSRange(location: range.location - offset, length: range.length)
            return local.location >= 0 && NSMaxRange(local) <= length ? text.substring(with: local) : nil
        })
        return cursor.resolve(with: context).highlights()
    }

    /// Header lines (zero-based) of the declarations enclosing `line`, outermost first: the
    /// lines sticky scroll keeps on screen. `lineStart` is the line's UTF-16 offset.
    func enclosingScopeLines(line: Int, lineStart: Int) -> [Int] {
        guard let tree, let root = tree.rootNode, lineStart >= offset, lineStart - offset <= text.length else { return [] }
        let byte = UInt32(lineStart * 2)
        var node = root.descendant(in: byte..<(byte + 2))
        var lines: [Int] = []
        while let current = node {
            let start = Int(current.pointRange.lowerBound.row), end = Int(current.pointRange.upperBound.row)
            if start < line, end >= line, Self.isScope(current.nodeType) {
                // The declaration's name line, not a leading attribute line (`@MainActor`).
                // Pinned only once that line has scrolled past.
                let nameRow = current.child(byFieldName: "name").map { Int($0.pointRange.lowerBound.row) } ?? start
                if nameRow < line, !lines.contains(nameRow) { lines.append(nameRow) }
            }
            node = current.parent
        }
        return lines.reversed()
    }

    private static let scopeWords = ["class", "struct", "enum", "protocol", "extension", "function", "method",
                                     "impl", "trait", "interface", "module", "namespace", "object", "declaration",
                                     "definition", "init", "deinit", "subscript", "computed_property"]
    private static let excludedWords = ["call", "argument", "parameter", "type_annotation", "identifier", "body",
                                        "import", "comment"]

    private static func isScope(_ type: String?) -> Bool {
        guard let type else { return false }
        return scopeWords.contains { type.contains($0) } && !excludedWords.contains { type.contains($0) }
    }

    private func parse(_ string: NSString, reusing oldTree: MutableTree?) -> MutableTree? {
        let signpost = Signposts.begin("Parse"); defer { Signposts.end("Parse", signpost) }
        let length = string.length, offset = self.offset
        return parser.parse(tree: oldTree) { byteOffset, _ in
            let start = byteOffset / 2 - offset
            guard start >= 0, start < length else { return nil }
            let count = min(16 * 1024, length - start)
            var data = Data(count: count * 2)
            data.withUnsafeMutableBytes { buffer in
                string.getCharacters(buffer.baseAddress!.assumingMemoryBound(to: unichar.self),
                                     range: NSRange(location: start, length: count))
            }
            return data
        }
    }
}
