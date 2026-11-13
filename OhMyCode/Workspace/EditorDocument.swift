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
    /// Theme/font generation the text's base attributes were set for.
    @ObservationIgnored private var styleGeneration = EditorTheme.generation
    /// Bumped on every text change; lets async results (formatting, rename) detect staleness.
    @ObservationIgnored private(set) var editVersion = 0
    private(set) var lineCount = 1
    var cursorLine = 1
    var cursorColumn = 1

    @ObservationIgnored private(set) var lineIndex: LineIndex
    @ObservationIgnored private(set) var highlighter: SyntaxHighlighter?
    @ObservationIgnored private var storageObserver: TextStorageObserver?
    /// Shared by every editor showing this document (split views): each adds its own
    /// layout manager, so edits in one view lay out in all of them.
    @ObservationIgnored let textContentStorage = NSTextContentStorage()
    /// Hidden (folded) line ranges, in characters; see Folding.swift.
    @ObservationIgnored private(set) var folds: [NSRange] = []
    @ObservationIgnored private let foldingDelegate = FoldingDelegate()
    /// Every editor showing this document (weak).
    @ObservationIgnored private let editorTable = NSHashTable<EditorController>.weakObjects()
    var editors: [EditorController] { editorTable.allObjects }

    /// The editor that cursor-based actions use: the focused one, or the last one shown.
    @ObservationIgnored weak var editor: EditorController? {
        didSet {
            if let editor { editorTable.add(editor) }
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

    /// Who last changed each line (git blame of the buffer); nil while unknown.
    @ObservationIgnored private(set) var blame: [BlameLine?]?
    @ObservationIgnored var blameProvider: ((String) async -> [BlameLine?]?)?
    @ObservationIgnored private var blameTask: Task<Void, Never>?
    /// Merge conflicts left in the text (`<<<<<<<` … `>>>>>>>`), re-read shortly after edits.
    @ObservationIgnored private(set) var conflicts: [MergeConflict] = []
    @ObservationIgnored private var conflictTask: Task<Void, Never>?
    /// Opens a conflict's two sides in a diff tab (set by the workspace).
    @ObservationIgnored var compareConflictAction: ((MergeConflict) -> Void)?
    /// Stages one hunk of this document (set by the workspace for files in a git repository).
    @ObservationIgnored var stageHunkAction: ((DiffHunk) -> Void)?

    /// Gutter change markers against the git index, keyed by zero-based line.
    @ObservationIgnored private(set) var diffMarkers: [Int: DiffMarker] = [:]
    /// Observed: the diff view follows it as you type.
    private(set) var diffHunks: [DiffHunk] = []
    @ObservationIgnored private var diffBase: String?
    /// The staged (index) version's lines, or nil if untracked or not in a repository.
    @ObservationIgnored private(set) var diffBaseLines: [Substring]?
    /// Bumped when the diff base changes (staging, committing), for the diff view.
    private(set) var diffBaseVersion = 0
    /// Bumped with every diff of new text (even when the hunks come out the same, e.g. after
    /// typing inside an already changed line), so diff views re-read the text.
    private(set) var diffTextVersion = 0
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
        textContentStorage.textStorage = textStorage
        textContentStorage.delegate = foldingDelegate

        let observer = TextStorageObserver { [weak self] range, delta in
            self?.textDidEdit(range: range, changeInLength: delta)
        }
        textStorage.delegate = observer
        storageObserver = observer
        diskModificationDate = Self.modificationDate(of: url)
        scheduleConflictScan()
    }

    /// The content storage doesn't retain its delegate and may outlive the document.
    isolated deinit {
        textContentStorage.delegate = nil
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
        lineIndex.offset(for: position, length: textStorage.length)
    }

    func range(for lspRange: LSPRange) -> NSRange {
        lineIndex.range(for: lspRange, length: textStorage.length)
    }

    /// The identifier around `index` (or ending right at it).
    func wordRange(at index: Int) -> NSRange? {
        let text = textStorage.mutableString
        func isWord(_ at: Int) -> Bool {
            guard at >= 0, at < text.length else { return false }
            let unit = text.character(at: at)
            if unit == 0x5F { return true } // _
            if CFStringIsSurrogateHighCharacter(unit) || CFStringIsSurrogateLowCharacter(unit) { return false }
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        var start = index
        if !isWord(start) && isWord(start - 1) { start -= 1 }
        guard isWord(start) else { return nil }
        var end = start
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Indentation style for formatting: tabs if most indented lines use them, otherwise
    /// 2 or 4 spaces judged from the indent widths in the first few thousand lines.
    var indentation: (tabSize: Int, insertSpaces: Bool) {
        let text = textStorage.mutableString
        var tabs = 0, spaces = 0, twoSpaceSteps = 0
        for line in 0..<min(lineIndex.lineCount, 5_000) {
            let start = lineIndex.lineStarts[line]
            guard start < text.length else { break }
            let first = text.character(at: start)
            if first == 0x09 { tabs += 1; continue }
            guard first == 0x20 else { continue }
            var width = 0
            while start + width < text.length, text.character(at: start + width) == 0x20 { width += 1 }
            spaces += 1
            if width % 4 == 2 { twoSpaceSteps += 1 }
        }
        if tabs > spaces { return (4, false) }
        return (spaces > 0 && twoSpaceSteps * 5 >= spaces ? 2 : 4, true)
    }

    func setDiagnostics(_ diagnostics: [Diagnostic]) {
        guard diagnostics != self.diagnostics else { return }
        self.diagnostics = diagnostics
        editors.forEach { $0.applyDiagnostics() }
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

        let selections = editors.map { ($0, $0.textView.selectedRange()) }
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                      with: NSAttributedString(string: text, attributes: EditorTheme.baseAttributes))
        isDirty = false
        hasExternalChanges = false
        // Undo entries refer to the old text's ranges.
        undoManager.removeAllActions()
        for (editor, selection) in selections { editor.documentDidReload(previousSelection: selection) }
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
        editVersion += 1
        adjustFolds(editStart: start, oldEnd: oldEnd, delta: delta)

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
        // Line numbers moved: hide blame until it's computed again for the new text.
        if blame != nil { blame = nil; editors.forEach { $0.diagnosticsOverlay?.needsDisplay = true } }
        scheduleBlame(after: .milliseconds(800))
        scheduleConflictScan(after: .milliseconds(100))
    }

    /// Re-reads the conflict markers. A file without "<<<<<<<" costs one search.
    func scheduleConflictScan(after delay: Duration = .zero) {
        conflictTask?.cancel()
        guard delay > .zero else { updateConflicts(); return }
        conflictTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            updateConflicts()
        }
    }

    private func updateConflicts() {
        let found = ConflictParser.conflicts(in: textStorage.mutableString)
        guard found != conflicts else { return }
        conflicts = found
        for editor in editors { editor.diagnosticsOverlay?.needsDisplay = true }
    }

    // MARK: Git diff markers

    /// The file as staged in git (nil if untracked or not in a repository).
    func setDiffBase(_ text: String?) {
        guard text != diffBase || (text == nil && !diffMarkers.isEmpty) else { return }
        diffBase = text
        diffBaseLines = text.map(LineDiff.lines)
        diffBaseVersion += 1
        scheduleDiff(after: .zero)
    }

    /// Diffs off the main thread, debounced while typing; the main thread only copies the text.
    private func scheduleDiff(after delay: Duration) {
        diffTask?.cancel()
        guard let base = diffBaseLines else {
            if !diffMarkers.isEmpty { diffMarkers = [:]; diffHunks = []; redrawGutters() }
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
            if diffHunks != hunks { diffHunks = hunks }
            diffTextVersion += 1
            diffMarkers = LineDiff.markers(for: hunks)
            redrawGutters()
        }
    }

    // MARK: Blame

    /// Blames the current text (unsaved lines show as not committed) after `delay`; set by the
    /// workspace for files in a git repository.
    func scheduleBlame(after delay: Duration) {
        blameTask?.cancel()
        guard let blameProvider else { return }
        blameTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let version = editVersion
            let result = await blameProvider(textStorage.mutableString as String)
            guard !Task.isCancelled, version == editVersion else { return }
            blame = result
            editors.forEach { $0.diagnosticsOverlay?.needsDisplay = true }
        }
    }

    /// Waits for pending blame (tests).
    func waitForBlame() async { await blameTask?.value }

    private func redrawGutters() {
        for editor in editors { editor.gutterView.needsDisplay = true }
    }

    /// Replaces the folds and re-lays out every editor showing the document.
    func setFolds(_ newFolds: [NSRange], relayout: Bool = true) {
        let affected = (folds + newFolds)
        folds = newFolds.sorted { $0.location < $1.location }
        foldingDelegate.setHidden(folds)
        guard relayout else { return }
        for editor in editors { editor.foldsDidChange(affected) }
    }

    /// Registers an editor showing this document (without making it the target of actions).
    func attach(_ editor: EditorController) {
        editorTable.add(editor)
    }

    /// The editor showing this document in an editor group, if any.
    func editor(inGroup group: EditorGroup) -> EditorController? {
        editors.first { $0.group === group }
    }

    /// Applies the current editor font and text color to the whole text, after a settings
    /// change. Attribute-only: no undo entry, no reparse, not dirty.
    func refreshStyleIfNeeded() {
        guard styleGeneration != EditorTheme.generation else { return }
        styleGeneration = EditorTheme.generation
        textStorage.addAttributes(EditorTheme.baseAttributes, range: NSRange(location: 0, length: textStorage.length))
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
