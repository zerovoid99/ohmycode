import AppKit
import Observation
import SwiftTreeSitter

enum EditorDocumentError: LocalizedError {
    case binaryFile(URL)
    case unsupportedEncoding(URL)

    var errorDescription: String? {
        switch self {
        case .binaryFile(let url): "\(url.lastPathComponent) is a binary file and can't be opened in the editor."
        case .unsupportedEncoding(let url): "\(url.lastPathComponent) uses an unsupported text encoding."
        }
    }
}

/// An open file. The `NSTextStorage` is the single source of truth for the text;
/// it is never round-tripped through a SwiftUI `String` binding (that would copy
/// the whole file on every keystroke).
@MainActor
@Observable
final class EditorDocument: Identifiable {
    let id = UUID()
    let url: URL
    let language: SourceLanguage
    let textStorage: NSTextStorage
    let undoManager = UndoManager()

    private(set) var isDirty = false
    private(set) var lineCount = 1
    var cursorLine = 1
    var cursorColumn = 1

    @ObservationIgnored private(set) var lineIndex: LineIndex
    @ObservationIgnored private(set) var highlighter: SyntaxHighlighter?
    @ObservationIgnored private var storageObserver: TextStorageObserver?
    /// The editor currently showing this document, if any.
    @ObservationIgnored weak var editor: EditorController? {
        didSet {
            if let editor, let range = pendingReveal {
                pendingReveal = nil
                editor.reveal(range)
            }
        }
    }
    @ObservationIgnored private var pendingReveal: NSRange?

    var fileName: String { url.lastPathComponent }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        if data.prefix(8192).contains(0) { throw EditorDocumentError.binaryFile(url) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EditorDocumentError.unsupportedEncoding(url)
        }
        self.url = url
        self.language = SourceLanguage(fileExtension: url.pathExtension)
        self.textStorage = NSTextStorage(string: text, attributes: EditorTheme.baseAttributes)
        self.lineIndex = LineIndex(string: textStorage.string as NSString)
        self.lineCount = lineIndex.lineCount
        self.highlighter = SyntaxHighlighter(language: language, textStorage: textStorage)

        let observer = TextStorageObserver { [weak self] range, delta in
            self?.textDidEdit(range: range, changeInLength: delta)
        }
        textStorage.delegate = observer
        storageObserver = observer
    }

    func save() throws {
        try textStorage.string.write(to: url, atomically: true, encoding: .utf8)
        isDirty = false
    }

    /// Selects and scrolls to `line` (1-based), now or once an editor shows this document.
    func revealLine(_ line: Int) {
        let index = min(max(line, 1), lineIndex.lineCount) - 1
        reveal(NSRange(location: lineIndex.lineStarts[index], length: 0))
    }

    func reveal(_ range: NSRange) {
        if let editor { editor.reveal(range) } else { pendingReveal = range }
    }

    func updateCursor(forSelectionAt location: Int) {
        let line = lineIndex.line(containing: location)
        cursorLine = line + 1
        cursorColumn = location - lineIndex.lineStarts[line] + 1
    }

    private func textDidEdit(range: NSRange, changeInLength delta: Int) {
        let start = range.location
        let oldEnd = start + range.length - delta
        let newEnd = NSMaxRange(range)
        // Points before/at the old end must be computed from the pre-edit index.
        let startPoint = point(at: start)
        let oldEndPoint = point(at: oldEnd)

        lineIndex.apply(editedRange: range, changeInLength: delta, in: textStorage.string as NSString)

        highlighter?.applyEdit(InputEdit(
            startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
            startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: point(at: newEnd)
        ))
        if lineCount != lineIndex.lineCount { lineCount = lineIndex.lineCount }
        if !isDirty { isDirty = true }
    }

    /// tree-sitter point for a UTF-16 offset (columns are in UTF-16LE bytes).
    private func point(at offset: Int) -> Point {
        let row = lineIndex.line(containing: offset)
        return Point(row: row, column: (offset - lineIndex.lineStarts[row]) * 2)
    }
}

/// Forwards character edits (not attribute-only edits, e.g. syntax highlighting) to the document.
@MainActor
private final class TextStorageObserver: NSObject {
    let onEdit: (NSRange, Int) -> Void
    init(onEdit: @escaping (NSRange, Int) -> Void) { self.onEdit = onEdit }
}

extension TextStorageObserver: @preconcurrency NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        onEdit(editedRange, delta)
    }
}
