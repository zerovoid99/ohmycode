import Foundation
import SwiftTreeSitter

/// Immutable copy of the document text handed to the background parser.
/// `@unchecked Sendable`: the wrapped NSString is an immutable copy and never mutated.
struct TextSnapshot: @unchecked Sendable {
    let string: NSString
}

/// Owns the tree-sitter parser and tree off the main thread. Edits, parses and highlight
/// queries are serialized by the actor; the main thread never waits on it.
actor SyntaxEngine {
    private let parser = Parser()
    private let query: Query
    private var tree: MutableTree?
    private var text: NSString = ""

    init?(grammar: Grammar) {
        guard (try? parser.setLanguage(grammar.language)) != nil else { return nil }
        query = grammar.highlightsQuery
    }

    /// Applies `edits` (made since the previous snapshot) and reparses against `snapshot`, if
    /// given; then returns highlights for `range` in the resulting tree, if requested.
    func process(snapshot: TextSnapshot?, edits: [InputEdit], highlightRange: NSRange?) -> [NamedRange]? {
        if let snapshot {
            if let tree {
                for edit in edits { tree.edit(edit) }
            }
            text = snapshot.string
            tree = parse(text, reusing: tree)
        }
        return highlightRange.map(highlights(in:))
    }

    /// The latest parsed tree's root and its text (for the outline).
    var currentRoot: Node? { tree?.rootNode }
    var currentText: NSString { text }

    func highlights(in range: NSRange) -> [NamedRange] {
        guard let tree, let root = tree.rootNode else { return [] }
        let text = text
        let length = text.length
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(range)
        let context = Predicate.Context(textProvider: { range, _ in
            NSMaxRange(range) <= length ? text.substring(with: range) : nil
        })
        return cursor.resolve(with: context).highlights()
    }

    /// Header lines (zero-based) of the declarations enclosing `line`, outermost first: the
    /// lines sticky scroll keeps on screen. `lineStart` is the line's UTF-16 offset.
    func enclosingScopeLines(line: Int, lineStart: Int) -> [Int] {
        guard let tree, let root = tree.rootNode, lineStart <= text.length else { return [] }
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
        let length = string.length
        return parser.parse(tree: oldTree) { byteOffset, _ in
            let start = byteOffset / 2
            guard start < length else { return nil }
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
