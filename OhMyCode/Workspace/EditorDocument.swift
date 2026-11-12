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
    /// Language server attached to this document, if one is available for its language.
    @ObservationIgnored var languageClient: LanguageClient?
    /// Diagnostics from the language server, in the server's (LSP) coordinates.
    private(set) var diagnostics: [Diagnostic] = []
    /// Symlink-resolved path, to match URIs the language server reports.
    @ObservationIgnored private(set) lazy var canonicalPath = FileWatcher.canonicalPath(url)
    var languageId: String { LanguageServerConfig.languageId(for: language) }

    /// Gutter change markers against the git index, keyed by zero-based line.
    @ObservationIgnored private(set) var diffMarkers: [Int: DiffMarker] = [:]
    @ObservationIgnored private(set) var diffHunks: [DiffHunk] = []
    @ObservationIgnored private var diffBase: String?
    @ObservationIgnored private var diffBaseLines: [Substring]?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
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
        languageClient?.didSave(url: url)
    }

    // MARK: Language server coordinates

    /// LSP position (line, UTF-16 column) for a UTF-16 offset in the current text.
    func lspPosition(at offset: Int) -> LSPPosition {
        let line = lineIndex.line(containing: offset)
        return LSPPosition(line: line, character: offset - lineIndex.lineStarts[line])
    }

    /// UTF-16 offset for an LSP position, clamped to the document.
    func offset(for position: LSPPosition) -> Int {
        let length = textStorage.length
        guard position.line < lineIndex.lineCount else { return length }
        let lineStart = lineIndex.lineStarts[max(0, position.line)]
        let lineEnd = position.line + 1 < lineIndex.lineCount ? lineIndex.lineStarts[position.line + 1] - 1 : length
        return min(lineStart + max(0, position.character), max(lineStart, lineEnd))
    }

    func range(for lspRange: LSPRange) -> NSRange {
        let start = offset(for: lspRange.start)
        let end = max(start, offset(for: lspRange.end))
        return NSRange(location: start, length: end - start)
    }

    func setDiagnostics(_ diagnostics: [Diagnostic]) {
        guard diagnostics != self.diagnostics else { return }
        self.diagnostics = diagnostics
        editor?.applyDiagnostics()
    }

    /// The most severe diagnostic on the cursor's line, for the status bar.
    var diagnosticAtCursor: Diagnostic? {
        diagnostics.filter { $0.range.start.line <= cursorLine - 1 && $0.range.end.line >= cursorLine - 1 }
            .min { $0.severity.rawValue < $1.severity.rawValue }
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
        let lspRange = LSPRange(start: lspPosition(at: start), end: lspPosition(at: oldEnd))

        // `mutableString`, not `string`: bridging `string` to Swift copies the whole text.
        lineIndex.apply(editedRange: range, changeInLength: delta, in: textStorage.mutableString)

        if let languageClient {
            let inserted = textStorage.mutableString.substring(with: range)
            languageClient.didChange(url: url, range: lspRange, text: inserted,
                                     fullText: { self.textStorage.mutableString as String })
        }

        highlighter?.didEdit(InputEdit(
            startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
            startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: point(at: newEnd)
        ))
        if lineCount != lineIndex.lineCount { lineCount = lineIndex.lineCount }
        if !isDirty { isDirty = true }
        scheduleDiff(after: .milliseconds(200))
    }

    // MARK: Git diff markers

    /// The file as staged in git (nil if untracked or not in a repository).
    func setDiffBase(_ text: String?) {
        guard text != diffBase || (text == nil && !diffMarkers.isEmpty) else { return }
        diffBase = text
        diffBaseLines = text.map(LineDiff.lines)
        scheduleDiff(after: .zero)
    }

    /// Diffs off the main thread, debounced while typing; the main thread only copies the text.
    private func scheduleDiff(after delay: Duration) {
        diffTask?.cancel()
        guard let base = diffBaseLines else {
            if !diffMarkers.isEmpty { diffMarkers = [:]; diffHunks = []; editor?.gutterView.needsDisplay = true }
            return
        }
        diffTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let text = textStorage.mutableString as String
            let hunks = await Task.detached(priority: .utility) {
                LineDiff.hunks(base: base, current: LineDiff.lines(text))
            }.value
            guard !Task.isCancelled else { return }
            diffHunks = hunks
            diffMarkers = LineDiff.markers(for: hunks)
            editor?.gutterView.needsDisplay = true
        }
    }

    func hunk(atLine line: Int) -> DiffHunk? {
        diffHunks.first { $0.contains(line: line) }
    }

    /// The base (index) lines a hunk replaced, and the current lines it covers.
    func lines(of hunk: DiffHunk) -> (old: [String], new: [String]) {
        let base = diffBaseLines ?? []
        let old = base[hunk.oldStart..<min(base.count, hunk.oldStart + hunk.oldCount)].map(String.init)
        let text = textStorage.mutableString
        let new = (hunk.newStart..<(hunk.newStart + hunk.newCount)).compactMap { line -> String? in
            guard line < lineIndex.lineCount else { return nil }
            let start = lineIndex.lineStarts[line]
            let end = line + 1 < lineIndex.lineCount ? lineIndex.lineStarts[line + 1] - 1 : text.length
            return text.substring(with: NSRange(location: start, length: max(0, end - start)))
        }
        return (old, new)
    }

    /// The edit that reverts `hunk` to the staged version (applied through the text view).
    func revertEdit(for hunk: DiffHunk) -> (range: NSRange, replacement: String)? {
        guard let base = diffBaseLines else { return nil }
        return LineDiff.revertEdit(for: hunk, base: base, text: textStorage.mutableString,
                                   lineStarts: lineIndex.lineStarts)
    }

    /// Waits for a pending diff (tests).
    func waitForDiff() async {
        await diffTask?.value
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
