import AppKit
import Observation

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
    let language: Language
    let textStorage: NSTextStorage
    let undoManager = UndoManager()

    private(set) var isDirty = false
    private(set) var lineCount = 1
    var cursorLine = 1
    var cursorColumn = 1

    @ObservationIgnored private(set) var lineIndex: LineIndex
    @ObservationIgnored private var storageObserver: TextStorageObserver?

    var fileName: String { url.lastPathComponent }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        if data.prefix(8192).contains(0) { throw EditorDocumentError.binaryFile(url) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw EditorDocumentError.unsupportedEncoding(url)
        }
        self.url = url
        self.language = Language(fileExtension: url.pathExtension)
        self.textStorage = NSTextStorage(string: text, attributes: EditorTheme.baseAttributes)
        self.lineIndex = LineIndex(string: textStorage.string as NSString)
        self.lineCount = lineIndex.lineCount

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

    func updateCursor(forSelectionAt location: Int) {
        let line = lineIndex.line(containing: location)
        cursorLine = line + 1
        cursorColumn = location - lineIndex.lineStarts[line] + 1
    }

    private func textDidEdit(range: NSRange, changeInLength delta: Int) {
        lineIndex.apply(editedRange: range, changeInLength: delta, in: textStorage.string as NSString)
        if lineCount != lineIndex.lineCount { lineCount = lineIndex.lineCount }
        if !isDirty { isDirty = true }
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
