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
