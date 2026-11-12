import AppKit
import Observation
import SwiftTreeSitter

/// Where the user was in a document, kept while its tab is hidden.
struct EditorViewState {
    /// UTF-16 offset of the line at the top of the viewport, and how far it was scrolled past.
    /// Anchoring to text rather than a raw y offset survives TextKit 2's estimated heights.
    var topLineOffset: Int
    var topLineDelta: CGFloat
    var scrollX: CGFloat
    var selection: NSRange
}

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
    /// Scroll position and selection to restore when this tab is shown again.
    @ObservationIgnored var viewState: EditorViewState?
    /// Modification date of the version on disk that the buffer reflects.
    @ObservationIgnored private var diskModificationDate: Date?
    /// Set when the file changed on disk while there were unsaved edits.
    private(set) var hasExternalChanges = false

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
        self.lineIndex = LineIndex(string: textStorage.mutableString)
        self.lineCount = lineIndex.lineCount
        self.highlighter = SyntaxHighlighter(language: language, textStorage: textStorage)

        let observer = TextStorageObserver { [weak self] range, delta in
            self?.textDidEdit(range: range, changeInLength: delta)
        }
        textStorage.delegate = observer
        storageObserver = observer
        diskModificationDate = Self.modificationDate(of: url)
    }

    func save() throws {
        try textStorage.string.write(to: url, atomically: true, encoding: .utf8)
        diskModificationDate = Self.modificationDate(of: url)
        isDirty = false
        hasExternalChanges = false
    }

    /// Picks up edits made by other programs. Unsaved edits are never overwritten: the
    /// document is flagged instead. Our own saves are recognized by modification date.
    func reloadFromDiskIfChanged() {
        guard let date = Self.modificationDate(of: url), date != diskModificationDate else { return }
        guard !isDirty else {
            hasExternalChanges = true
            return
        }
        guard let data = try? Data(contentsOf: url), !data.prefix(8192).contains(0),
              let text = String(data: data, encoding: .utf8) else { return }
        diskModificationDate = date
        guard text != textStorage.mutableString as String else { return }

        let selection = editor?.textView.selectedRange()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                      with: NSAttributedString(string: text, attributes: EditorTheme.baseAttributes))
        isDirty = false
        hasExternalChanges = false
        // Undo entries refer to the old text's ranges.
        undoManager.removeAllActions()
        editor?.documentDidReload(previousSelection: selection)
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
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

        // `mutableString`, not `string`: bridging `string` to Swift copies the whole text.
        lineIndex.apply(editedRange: range, changeInLength: delta, in: textStorage.mutableString)

        highlighter?.didEdit(InputEdit(
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
