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
    /// The widest line, in columns (tabs to the tab width, wide characters as two): how wide
    /// the text view is without word wrap. Only grows while editing; measured again when the
    /// file is opened or saved.
    @ObservationIgnored private(set) var longestLineColumns = 0
    /// The most room inlay hints take on one line (added to that width).
    @ObservationIgnored var widestInlayHints: CGFloat = 0
    /// How many spaces wide a tab is drawn (and indent guides step by).
    @ObservationIgnored private(set) var displayTabWidth = 4
    @ObservationIgnored private var appliedTabInterval: CGFloat = 0
    /// ⌥Z's word wrap for this file (nil: the setting's).
    @ObservationIgnored var wordWrapOverride: Bool?
    /// What the `.editorconfig` files above it set (indentation, what saving fixes).
    private(set) var editorConfig = EditorConfig()
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
    /// What the folds hide: `folds` joined where they nest (see `FoldRanges`).
    @ObservationIgnored private(set) var hiddenRanges: [NSRange] = []
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
    @ObservationIgnored private(set) var pendingReveal: NSRange?
    /// Scroll position and selection to restore when this tab is shown again.
    @ObservationIgnored var viewState: EditorViewState?
    /// Modification date of the version on disk that the buffer reflects.
    @ObservationIgnored private(set) var diskModificationDate: Date?
    /// Language server attached to this document, if one is available for its language.
    @ObservationIgnored var languageClient: LanguageClient?
    /// Diagnostics from the language server, in the server's (LSP) coordinates.
    private(set) var diagnostics: [Diagnostic] = []
    /// Symlink-resolved path, to match URIs the language server reports.
    @ObservationIgnored private(set) lazy var canonicalPath = FileWatcher.canonicalPath(url)
    var languageId: String { LanguageServerConfig.languageId(for: language) }

    /// Who last changed each line (git blame of the buffer); nil while unknown.
    @ObservationIgnored private(set) var blame: [BlameLine?]?
    /// The oldest and newest commit dates, for the blame column's age bar: read from a blame
    /// when it arrives (`setBlame`), not after each edit (the lines an edit touches aren't
    /// committed, and reading every line's date on each keystroke took 55 ms in 40,000 lines).
    @ObservationIgnored private(set) var blameDates: ClosedRange<Date>?
    @ObservationIgnored var blameProvider: ((String) async -> [BlameLine?]?)?
    @ObservationIgnored private var blameTask: Task<Void, Never>?
    /// Blame of every line beside the line numbers.
    @ObservationIgnored var showsBlameColumn = false {
        didSet {
            guard showsBlameColumn != oldValue else { return }
            for editor in editors { editor.gutterView.updateWidth(); editor.gutterView.needsDisplay = true }
        }
    }
    /// Whether the file can be blamed (it's in a git repository).
    var canBlame: Bool { blameProvider != nil }
    /// The window's extensions, for their language features (completion, hover, formatting).
    @ObservationIgnored weak var extensionHost: ExtensionHost?
    /// Lines (zero-based) an edit replaced with `count` lines, when that moved the lines after
    /// them (breakpoints follow).
    @ObservationIgnored var onLinesReplaced: ((Range<Int>, Int) -> Void)?
    /// The line the debugger is stopped at (zero-based), highlighted.
    @ObservationIgnored var executionLine: Int? {
        didSet {
            guard executionLine != oldValue else { return }
            editors.forEach { $0.diagnosticsOverlay?.needsDisplay = true }
            redrawGutters()
        }
    }
    /// Toggles the breakpoint on a line (zero-based); set by the workspace.
    @ObservationIgnored var toggleBreakpointAction: ((Int) -> Void)?
    /// Breakpoints on this file's lines (zero-based): true when the debugger confirmed them.
    @ObservationIgnored var breakpointMarks: (() -> [Int: BreakpointMark])?
    /// Tests and suites declared in the file, by line, with their last result (gutter marks).
    @ObservationIgnored var testMarks: (() -> [Int: TestController.State])?
    /// Runs the test or suite declared on a line.
    @ObservationIgnored var runTestAction: ((Int) -> Void)?
    /// Called after each edit and after saving (the window's extensions listen).
    @ObservationIgnored var onDidEdit: (() -> Void)?
    /// The file's declarations (Outline, breadcrumbs, Go to Symbol), updated shortly after edits.
    private(set) var symbols: [DocumentSymbol] = []
    @ObservationIgnored private var symbolsTask: Task<Void, Never>?
    @ObservationIgnored var inlayHintsTask: Task<Void, Never>?
    /// The language server's semantic tokens (see SemanticTokens.swift): moved along by edits.
    @ObservationIgnored var semanticTokens: [SemanticToken] = []
    @ObservationIgnored var semanticTokensTask: Task<Void, Never>?
    /// The language server's code lenses, by zero-based line (see CodeLenses.swift).
    @ObservationIgnored var codeLenses: [Int: [CodeLens]] = [:]
    @ObservationIgnored var codeLensesTask: Task<Void, Never>?
    /// Fold regions from the code's structure, by header line (see FoldRegions.swift).
    @ObservationIgnored var foldRegions: [Int: FoldRegion] = [:]
    @ObservationIgnored var foldRegionsTask: Task<Void, Never>?
    /// The language server's links in the text (see DocumentLinks.swift), for `serverLinksVersion`.
    @ObservationIgnored var serverLinks: [LSPDocumentLink] = []
    @ObservationIgnored var serverLinksVersion = -1
    @ObservationIgnored var linksTask: Task<Void, Never>?
    /// The next storage edit's exact replacement: `range` replaced by `length` characters.
    @ObservationIgnored var pendingReplacement: (range: NSRange, length: Int)?
    /// The folder it's open in (for the folder's snippets).
    @ObservationIgnored var workspaceRoot: URL?
    /// The window's workspace it's open in.
    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored var onDidSave: (() -> Void)?
    /// What the blame popover can do with a line's commit (set by the workspace).
    @ObservationIgnored var blameActions: BlameActions?
    /// Merge conflicts left in the text (`<<<<<<<` … `>>>>>>>`), re-read shortly after edits.
    @ObservationIgnored private(set) var conflicts: [MergeConflict] = []
    /// Whether the text had a `<<<<<<<` at the last scan: without one, only an edit that types
    /// one can make a conflict, and other edits skip the scan.
    @ObservationIgnored private var mayHaveConflicts = true
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
        let signpost = Signposts.begin("Open Document"); defer { Signposts.end("Open Document", signpost) }
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
            guard let self, !self.isReplacingBatch else { return }
            self.textDidEdit(range: range, changeInLength: delta)
        }
        textStorage.delegate = observer
        storageObserver = observer
        highlighter?.pointProvider = { [weak self] offset in self?.point(at: offset) ?? Point(row: 0, column: 0) }
        diskModificationDate = Self.modificationDate(of: url)
        editorConfig = EditorConfig.resolve(for: url)
        updateTabWidth()
        measureLongestLine()
        refreshFoldRegions()
        scheduleConflictScan()
        refreshSymbols()
    }

    /// Reads the `.editorconfig` files again (one of them changed).
    func reloadEditorConfig() {
        let config = EditorConfig.resolve(for: url)
        if config != editorConfig { editorConfig = config }
        updateTabWidth()
    }

    /// The content storage doesn't retain its delegate and may outlive the document.
    isolated deinit {
        textContentStorage.delegate = nil
    }

    func save() throws {
        // What .editorconfig asks for, as an undoable step of its own.
        let fixes = editorConfigEdits()
        if !fixes.isEmpty { try apply(fixes, actionName: "Apply .editorconfig") }
        let text = textStorage.string
        // The local history: what's on disk first if it's not kept yet (the version before
        // this session's first save, or another program's), then what's saved.
        let history = LocalHistory.shared
        if let previous = try? String(contentsOf: url, encoding: .utf8), previous != text {
            history.record(previous, for: url, reason: .beforeSave)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        history.record(text, for: url, reason: .saved)
        updateTabWidth() // the indentation may be clear now (a new file)
        let previousWidth = longestLineColumns
        measureLongestLine() // lines that got shorter (the width only grows while editing)
        if longestLineColumns != previousWidth { editors.forEach { $0.updateTextWidth() } }
        diskModificationDate = Self.modificationDate(of: url)
        isDirty = false
        hasExternalChanges = false
        languageClient?.didSave(url: url)
        onDidSave?()
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

    /// Whether a UTF-16 unit is part of an identifier (letters, digits, `_`; nil: past the text).
    static func isWordUnit(_ unit: unichar?) -> Bool {
        guard let unit else { return false }
        if unit < 0x80 {
            return (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x30 && unit <= 0x39) || unit == 0x5F
        }
        // Surrogates aren't scalars.
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// The identifier around `index` (or ending right at it).
    func wordRange(at index: Int) -> NSRange? {
        let text = textStorage.mutableString
        func isWord(_ at: Int) -> Bool {
            guard at >= 0, at < text.length else { return false }
            return Self.isWordUnit(text.character(at: at))
        }
        var start = index
        if !isWord(start) && isWord(start - 1) { start -= 1 }
        guard isWord(start) else { return nil }
        var end = start
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Indentation style for formatting and typing: what .editorconfig sets, otherwise tabs if
    /// most indented lines use them, otherwise 2 or 4 spaces judged from the indent widths in
    /// the first few thousand lines.
    var indentation: (tabSize: Int, insertSpaces: Bool) {
        let config = editorConfig
        if let style = config.indentStyle {
            // Tabs with no width given: 4 (the text's own space indents say nothing about tabs).
            let size = style == .tab ? config.tabWidth ?? config.indentSize ?? 4 : config.indentSize ?? guessedIndentation.tabSize
            return (size, style == .space)
        }
        if let size = config.indentSize { return (size, guessedIndentation.insertSpaces) }
        return guessedIndentation
    }

    /// The indentation the text itself uses.
    var guessedIndentation: (tabSize: Int, insertSpaces: Bool) {
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

    /// The language server's diagnostics (extensions' are added by `setExtensionDiagnostics`).
    func setDiagnostics(_ diagnostics: [Diagnostic]) {
        serverDiagnostics = diagnostics
        mergeDiagnostics()
    }

    /// One extension diagnostic collection's diagnostics for this file (empty removes them).
    func setExtensionDiagnostics(_ diagnostics: [Diagnostic], collection: String) {
        extensionDiagnostics[collection] = diagnostics.isEmpty ? nil : diagnostics
        mergeDiagnostics()
    }

    @ObservationIgnored private var serverDiagnostics: [Diagnostic] = []
    @ObservationIgnored private var extensionDiagnostics: [String: [Diagnostic]] = [:]

    private func mergeDiagnostics() {
        let merged = serverDiagnostics + extensionDiagnostics.keys.sorted().flatMap { extensionDiagnostics[$0]! }
        guard merged != diagnostics else { return }
        diagnostics = merged
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

        LocalHistory.shared.record(textStorage.mutableString as String, for: url, reason: .beforeReload)
        let selections = editors.map { ($0, $0.textView.selectedRange()) }
        editors.forEach { $0.textWillChange() }
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
        updateSymbolAtCursor()
    }

    /// The innermost symbol the cursor is in (the outline marks it). Observed on its own: what
    /// reads it is made again when the cursor enters another symbol, not on every cursor move.
    private(set) var symbolIDAtCursor: String?

    fileprivate func updateSymbolAtCursor() {
        let id = symbolPathAtCursor.last?.id
        if id != symbolIDAtCursor { symbolIDAtCursor = id }
    }

    /// Makes several replacements (sorted, not overlapping, in the current text's coordinates),
    /// as one storage edit for TextKit: after each storage edit it moves every text element it
    /// has made after that place, so 1,000 separate edits (typing at 1,000 cursors, Replace All)
    /// took 25 s in a 1 MB file. The document itself still sees them one by one, right as
    /// they're made: its line index, parser and LSP sync get ordinary single edits.
    func replaceCharacters(_ edits: [TextReplacement]) {
        let batched = edits.count > 1
        if batched {
            isReplacingBatch = true
            textStorage.beginEditing()
        }
        // Front to back, each range moved by the edits before it: the line index then only has
        // the lines between two edits to move for each (back to front, every edit moves all the
        // lines after it).
        var shift = 0
        for edit in edits {
            let length = (edit.text as NSString).length
            let range = NSRange(location: edit.range.location + shift, length: edit.range.length)
            pendingReplacement = (range, length)
            textStorage.replaceCharacters(in: range, with: NSAttributedString(string: edit.text, attributes: EditorTheme.baseAttributes))
            if batched {
                textDidEdit(range: NSRange(location: range.location, length: length), changeInLength: length - range.length)
            }
            shift += length - range.length
        }
        if batched {
            textStorage.endEditing() // tells the storage's delegate about all of it at once: ignored
            isReplacingBatch = false
        }
    }

    /// While `replaceCharacters` makes a batch: the storage's own report of it isn't an edit to handle.
    @ObservationIgnored private var isReplacingBatch = false

    private func textDidEdit(range: NSRange, changeInLength delta: Int) {
        let signpost = Signposts.begin("textDidEdit"); defer { Signposts.end("textDidEdit", signpost) }
        let start = range.location
        let oldEnd = start + range.length - delta
        let newEnd = NSMaxRange(range)
        // Points before/at the old end must be computed from the pre-edit index.
        let startPoint = point(at: start)
        let oldEndPoint = point(at: oldEnd)
        let lspRange = LSPRange(start: lspPosition(at: start), end: lspPosition(at: oldEnd))
        let startLine = lineIndex.line(containing: start), oldEndLine = lineIndex.line(containing: oldEnd)
        let oldEndsLine = oldEnd == lineIndex.lineStarts[oldEndLine]

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
        // Which lines the edit replaced, and with how many.
        let newEndLine = lineIndex.line(containing: newEnd)
        var old = startLine..<oldEndLine + 1, count = newEndLine - startLine + 1
        // Whole lines added or removed (the edit ends where a line starts, before and after):
        // the line after them is untouched.
        let newEndsLine = newEnd == lineIndex.lineStarts[newEndLine]
        if (oldEndsLine || oldEnd == start) && (newEndsLine || newEnd == start) && start == lineIndex.lineStarts[startLine]
            && (oldEnd > start || newEnd > start) {
            old = startLine..<old.upperBound - 1
            count -= 1
        }
        // The edited lines may be the widest now (the text view widens without word wrap).
        if noteWidth(ofLines: startLine...newEndLine) { editors.forEach { $0.updateTextWidth() } }
        if old.count != count {
            onLinesReplaced?(old, count)
            shiftFoldRegions(replacing: old, with: count)
            shiftCodeLenses(replacing: old, with: count)
        }
        // Until blame runs again on the new text: edited lines aren't committed, lines after
        // them move with the edit.
        if blame != nil {
            // In place (no `if let`: a second reference would make this copy every line's blame).
            BlameLine.shift(&blame!, replacing: old, with: count)
            editors.forEach { $0.diagnosticsOverlay?.needsDisplay = true }
            redrawGutters()
        }
        scheduleBlame(after: .milliseconds(800))
        // The edited lines, in the new text: they hold any `<<<<<<<` the edit made.
        let editedLines = NSRange(location: lineIndex.lineStarts[startLine],
                                  length: (newEndLine + 1 < lineIndex.lineCount ? lineIndex.lineStarts[newEndLine + 1] : textStorage.length)
                                      - lineIndex.lineStarts[startLine])
        if mayHaveConflicts || ConflictParser.hasStart(in: textStorage.mutableString, range: editedLines) {
            scheduleConflictScan(after: .milliseconds(100))
        }
        // The storage's edited range can be wider than what was replaced (attribute fixing);
        // snippet stops need the replacement itself, recorded by whoever made it.
        var exact = (start: start, oldEnd: oldEnd)
        if let pending = pendingReplacement, pending.length - pending.range.length == delta,
           pending.range.location >= start, NSMaxRange(pending.range) <= oldEnd {
            exact = (pending.range.location, NSMaxRange(pending.range))
        }
        pendingReplacement = nil
        for editor in editors {
            editor.snippetDocumentEdited(start: exact.start, oldEnd: exact.oldEnd, delta: delta)
            editor.syntaxColorsEdited(start: start, oldEnd: oldEnd, newLength: newEnd - start)
        }
        refreshSymbols(after: .milliseconds(400))
        refreshInlayHints(after: .milliseconds(500))
        refreshLinks(after: .milliseconds(500))
        shiftSemanticTokens(oldRange: NSRange(location: exact.start, length: exact.oldEnd - exact.start),
                            newLength: exact.oldEnd - exact.start + delta)
        refreshSemanticTokens(after: .milliseconds(400))
        refreshFoldRegions(after: .milliseconds(500))
        refreshCodeLenses(after: .milliseconds(800))
        onDidEdit?()
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
        let text = textStorage.mutableString
        mayHaveConflicts = ConflictParser.hasStart(in: text)
        let found = mayHaveConflicts ? ConflictParser.conflicts(in: text) : []
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
            setBlame(result)
            editors.forEach { $0.diagnosticsOverlay?.needsDisplay = true }
            redrawGutters()
        }
    }

    private func setBlame(_ lines: [BlameLine?]?) {
        blame = lines
        var oldest: Date?, newest: Date?
        for case let line? in lines ?? [] where !line.isUncommitted {
            oldest = oldest.map { min($0, line.date) } ?? line.date
            newest = newest.map { max($0, line.date) } ?? line.date
        }
        blameDates = oldest.flatMap { oldest in newest.map { oldest...$0 } }
    }

    /// Waits for pending blame (tests).
    func waitForBlame() async { await blameTask?.value }

    func redrawGutters() {
        for editor in editors { editor.gutterView.needsDisplay = true }
    }

    /// Replaces the folds and re-lays out every editor showing the document.
    func setFolds(_ newFolds: [NSRange], relayout: Bool = true) {
        let affected = relayout ? folds + newFolds : []
        folds = newFolds.sorted { $0.location < $1.location }
        hiddenRanges = FoldRanges.merged(folds)
        foldingDelegate.setHidden(hiddenRanges)
        guard relayout else { return }
        for editor in editors { editor.foldsDidChange(affected) }
    }

    /// New tab stops: lines with tabs are made again (an attribute-only edit: no undo, not dirty,
    /// nothing sent to the language server) and laid out.
    fileprivate func tabIntervalChanged(_ interval: CGFloat) {
        foldingDelegate.setTabInterval(interval)
        guard textStorage.mutableString.containsRun(of: 0x09) else { return } // no tabs to redraw
        textStorage.beginEditing()
        textStorage.edited(.editedAttributes, range: NSRange(location: 0, length: textStorage.length), changeInLength: 0)
        textStorage.endEditing()
        for editor in editors { editor.refreshAfterEdit() }
    }

    /// Drops the text elements after what the editors show. TextKit 2's content storage keeps
    /// the element (paragraph) of every line a viewport has laid out, and after each edit moves
    /// every one that comes after the edit: once the viewport had been to 400 places in a file,
    /// a keystroke at its top took 77 ms instead of 1.5. An attribute-only edit of the text
    /// after the viewports makes it forget those (no undo entry, not dirty, nothing for the
    /// parser or the language server); they're made again when scrolled to.
    func trimTextElements() {
        let length = textStorage.length
        var inUse: [NSRange] = []
        for editor in editors {
            // An editor that can't say (no layout yet, text being composed): not now.
            guard let range = editor.textRangeInUse else { return }
            inUse.append(range)
        }
        // Only what's after the last viewport. Those are the ones an edit in view moves; and
        // forgetting lines laid out above a viewport changes TextKit's estimate of how tall the
        // text above it is, which moves the viewport to other lines (thousands of lines away,
        // in a big file).
        guard let end = inUse.map(NSMaxRange).max(), end < length, !isReplacingBatch else { return }
        textStorage.edited(.editedAttributes, range: NSRange(location: end, length: length - end), changeInLength: 0)
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
        updateTabWidth() // the font's space width changed
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
                                   lineStarts: lineIndex.lineStarts.array)
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

/// The blame popover's commit actions, provided by the workspace.
struct BlameActions {
    /// The commit's whole message, email and date.
    let details: @MainActor (BlameLine) async -> CommitDetails?
    /// What the commit changed in this file, as a diff tab.
    let openChanges: @MainActor (BlameLine) -> Void
    /// The commit in the repository log.
    let showInTimeline: @MainActor (BlameLine) -> Void
}

// MARK: Symbols

extension EditorDocument {
    /// Reads the file's declarations again (after `delay`, restarted by every call): from the
    /// language server when it lists them, else from the syntax tree (headings for Markdown).
    func refreshSymbols(after delay: Duration = .zero) {
        symbolsTask?.cancel()
        symbolsTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            let version = self.editVersion
            let found = await self.loadSymbols()
            // A later edit's refresh has the newer list.
            guard !Task.isCancelled, version == self.editVersion else { return }
            if found != self.symbols { self.symbols = found }
            self.updateSymbolAtCursor()
        }
    }

    /// Waits for the refresh in progress (tests).
    func waitForSymbols() async {
        await symbolsTask?.value
    }

    private func loadSymbols() async -> [DocumentSymbol] {
        if language == .markdown {
            return DocumentSymbol.markdown(textStorage.mutableString.copy() as! NSString)
        }
        if let client = languageClient, client.state == .ready, client.supports(.documentSymbol),
           let result = try? await client.documentSymbols(url: url) {
            let symbols = DocumentSymbol.fromLSP(result) { [weak self] in self?.range(for: $0) ?? NSRange(location: 0, length: 0) }
            if !symbols.isEmpty { return symbols }
        }
        return await highlighter?.outline(for: language) ?? []
    }

    /// The cursor's offset (from its line and column).
    var cursorOffset: Int {
        let line = min(max(cursorLine - 1, 0), lineIndex.lineCount - 1)
        return min(lineIndex.lineStarts[line] + max(cursorColumn - 1, 0), textStorage.length)
    }

    /// The symbols the cursor is in, outermost first (the breadcrumbs).
    var symbolPathAtCursor: [DocumentSymbol] { DocumentSymbol.path(to: cursorOffset, in: symbols) }
}

extension EditorDocument {
    /// Tabs drawn as wide as `tab_width` (or the indentation's width) in spaces of the editor font.
    func updateTabWidth() {
        let width = max(1, editorConfig.tabWidth ?? indentation.tabSize)
        let space = (" " as NSString).size(withAttributes: [.font: EditorTheme.font]).width
        let interval = CGFloat(width) * space
        if displayTabWidth != width {
            displayTabWidth = width
            measureLongestLine() // tabs count differently
            editors.forEach { $0.updateTextWidth() }
        }
        guard abs(interval - appliedTabInterval) > 0.01 else { return }
        appliedTabInterval = interval
        tabIntervalChanged(interval)
    }
}

extension EditorDocument {
    /// The column after `unit`, at `column`: tabs go to the next tab stop, wide characters take
    /// two, line breaks and a surrogate pair's low half none.
    @inline(__always)
    nonisolated private static func column(after column: Int, _ unit: unichar, tabWidth: Int) -> Int {
        if unit == 0x09 { return column + tabWidth - column % tabWidth }
        if unit == 0x0A || unit == 0x0D || (unit >= 0xDC00 && unit <= 0xDFFF) { return column }
        if unit >= 0x1100 && (unit <= 0x115F || (unit >= 0x2E80 && unit <= 0xA4CF) || (unit >= 0xAC00 && unit <= 0xD7A3)
                              || (unit >= 0xF900 && unit <= 0xFAFF) || (unit >= 0xFF00 && unit <= 0xFF60)) {
            return column + 2
        }
        return column + 1
    }

    /// Columns a run of UTF-16 units takes. Not tied to the main actor (nor is `column`): the
    /// closure checked which actor it was on for every unit, 37 ms per megabyte edited.
    nonisolated private static func columns(_ units: UnsafeBufferPointer<unichar>, tabWidth: Int) -> Int {
        var result = 0
        for unit in units { result = column(after: result, unit, tabWidth: tabWidth) }
        return result
    }

    private func columns(ofLines lines: ClosedRange<Int>) -> Int {
        let text = textStorage.mutableString
        var widest = 0
        var buffer = [unichar](repeating: 0, count: 4096)
        for line in lines where line < lineIndex.lineCount {
            let start = lineIndex.lineStarts[line]
            let end = line + 1 < lineIndex.lineCount ? lineIndex.lineStarts[line + 1] : text.length
            let length = end - start
            if buffer.count < length { buffer = [unichar](repeating: 0, count: length) }
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: start, length: length))
                widest = max(widest, Self.columns(UnsafeBufferPointer(rebasing: pointer[0..<length]), tabWidth: displayTabWidth))
            }
        }
        return widest
    }

    /// Measures every line (opening, saving), in one pass over the text.
    func measureLongestLine() {
        var widest = 0, column = 0
        let tabWidth = displayTabWidth
        textStorage.mutableString.forEachChunk { units, _ in
            for unit in units {
                if unit == 0x0A {
                    widest = max(widest, column)
                    column = 0
                } else {
                    column = Self.column(after: column, unit, tabWidth: tabWidth)
                }
            }
            return true
        }
        longestLineColumns = max(widest, column)
    }

    /// Edited lines: true when one of them is now the widest.
    func noteWidth(ofLines lines: ClosedRange<Int>) -> Bool {
        let widest = columns(ofLines: lines)
        guard widest > longestLineColumns else { return false }
        longestLineColumns = widest
        return true
    }
}
