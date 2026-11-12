import AppKit
import SwiftTreeSitter

/// Keeps an incrementally updated tree-sitter tree for one document and answers
/// highlight queries for arbitrary ranges (the editor only asks for the viewport).
@MainActor
final class SyntaxHighlighter {
    /// Files above this size open as plain text.
    static let maxFileLength = 8 * 1024 * 1024

    private let parser = Parser()
    private let query: Query
    private let textStorage: NSTextStorage
    private var tree: MutableTree?

    init?(language: SourceLanguage, textStorage: NSTextStorage) {
        guard textStorage.length <= Self.maxFileLength,
              let grammar = GrammarRegistry.grammar(for: language),
              (try? parser.setLanguage(grammar.language)) != nil
        else { return nil }
        self.query = grammar.highlightsQuery
        self.textStorage = textStorage
        self.tree = parse(reusing: nil)
    }

    /// Call after the text storage changed, with the edit expressed in tree-sitter terms.
    func applyEdit(_ edit: InputEdit) {
        tree?.edit(edit)
        tree = parse(reusing: tree)
    }

    /// Highlight captures intersecting `range` (UTF-16), ordered so later entries win.
    func highlights(in range: NSRange) -> [NamedRange] {
        guard let tree, let root = tree.rootNode else { return [] }
        let string = textStorage.string as NSString
        let length = string.length

        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(range)
        let context = Predicate.Context(textProvider: { range, _ in
            NSMaxRange(range) <= length ? string.substring(with: range) : nil
        })
        return cursor.resolve(with: context).highlights()
    }

    /// Feeds tree-sitter UTF-16 chunks straight from the NSString backing store, no full-file copy.
    private func parse(reusing oldTree: MutableTree?) -> MutableTree? {
        let string = textStorage.string as NSString
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
