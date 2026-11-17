import AppKit

extension NSAttributedString.Key {
    /// On the character before a suggestion that has text after it on its line: with a `.kern`
    /// that opens the gap its first line is drawn in (as inlay hints do).
    static let omcGhostGap = NSAttributedString.Key("omcGhostGap")
    /// On the caret's line while a suggestion of several lines shows: with a paragraph style
    /// whose spacing makes room below the line for the other lines.
    static let omcGhostSpacing = NSAttributedString.Key("omcGhostSpacing")
}

/// A suggestion shown at the caret: `text` would be inserted at `anchor`.
struct GhostText: Equatable {
    let anchor: Int
    let text: String
    /// The document's edit it's for: drawn only while the text is as it was.
    let editVersion: Int
}

/// AI inline suggestions (ghost text) for one editor. After a pause in typing it asks the
/// provider for what comes next at the caret, and shows it in grey: Tab inserts it, ⌘→ its next
/// word, Esc drops it. What's shown is drawn by the overlay; the room it needs is made with
/// attribute-only edits of the text storage, which the document ignores (not dirty, nothing to
/// undo, nothing sent to the language server, not saved).
@MainActor
final class InlineSuggestionController {
    private unowned let editor: EditorController
    var settings = AISettings.shared
    private(set) var ghost: GhostText?
    private var requestTask: Task<Void, Never>?
    /// Where the caret was when the pending request was scheduled.
    private var scheduledCaret: Int?
    /// While this changes the text or its attributes itself: the text view's notifications of it
    /// aren't edits or moves to react to.
    private var isApplying = false
    /// The text view's caret is hidden while a gap is open (TextKit puts it in the gap's middle):
    /// the overlay draws one at the gap's start instead.
    private var hidesCaret = false

    /// Bigger files aren't suggested in (the context is a window around the caret either way).
    static let maxDocumentLength = 4_000_000

    init(editor: EditorController) {
        self.editor = editor
    }

    private var document: EditorDocument { editor.document }
    private var textView: NSTextView { editor.textView }

    /// Whether a request is scheduled or running.
    var isPending: Bool { requestTask != nil }

    /// Waits for the pending request (tests).
    func waitForRequest() async { await requestTask?.value }

    // MARK: When to suggest

    /// Whether a suggestion can show at the caret now (`manual`: ⌥\, which doesn't need
    /// suggestions turned on).
    func canSuggest(manual: Bool) -> Bool {
        guard let textView = editor.textView, textView.isEditable, !textView.hasMarkedText() else { return false }
        guard manual || settings.inlineSuggestionsEnabled, settings.isConfigured else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0, !editor.hasExtraCursors, !editor.completion.isVisible,
              document.textStorage.length <= Self.maxDocumentLength else { return false }
        return Self.allowsSuggestion(in: document.textStorage, lineIndex: document.lineIndex, at: selection.location)
    }

    /// Only where the rest of the line is empty, or closing brackets, quotes and spaces (what
    /// typing an opening bracket leaves after the caret).
    static func allowsSuggestion(in storage: NSTextStorage, lineIndex: LineIndex, at caret: Int) -> Bool {
        let text = storage.mutableString
        guard caret <= text.length else { return false }
        let line = lineIndex.line(containing: caret)
        let lineStart = lineIndex.lineStarts[line]
        let lineEnd = line + 1 < lineIndex.lineCount ? lineIndex.lineStarts[line + 1] - 1 : text.length
        var hasCloser = false
        var index = caret
        while index < lineEnd {
            let unit = text.character(at: index)
            switch unit {
            case 0x20, 0x09, 0x0D: break
            case 0x29, 0x5D, 0x7D, 0x3E, 0x22, 0x27, 0x60: hasCloser = true // ) ] } > " ' `
            default: return false
            }
            index += 1
        }
        // Text after the caret: the suggestion's first line opens a gap after the character
        // before it, which a line's first column doesn't have (nor one an inlay hint has a gap at).
        if hasCloser {
            guard caret > lineStart, storage.attribute(.omcInlayHint, at: caret - 1, effectiveRange: nil) == nil else { return false }
        }
        return true
    }

    // MARK: Requests

    /// ⌥\: asks now, whatever the setting and the pause.
    func trigger() {
        guard settings.isConfigured else {
            settings.lastError = settings.configurationProblem
            NSSound.beep()
            return
        }
        hide()
        schedule(manual: true)
    }

    /// Asks for a suggestion at the caret, after the pause in typing (now when `manual`).
    func schedule(manual: Bool) {
        cancelRequest()
        guard canSuggest(manual: manual) else { return }
        let caret = textView.selectedRange().location
        let version = document.editVersion
        scheduledCaret = caret
        let delay: Duration = manual ? .zero : .milliseconds(settings.debounceMilliseconds)
        requestTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.request(at: caret, version: version, manual: manual)
        }
    }

    func cancelRequest() {
        requestTask?.cancel()
        requestTask = nil
        scheduledCaret = nil
    }

    private func request(at caret: Int, version: Int, manual: Bool) async {
        let settings = self.settings
        let provider: any AIProvider
        do {
            provider = try settings.makeProvider()
        } catch {
            settings.lastError = error.localizedDescription
            finishRequest()
            return
        }
        let context = AIPrompts.suggestionContext(text: document.textStorage.mutableString, caret: caret,
                                                  path: document.relativePath, languageId: document.languageId)
        let request = AIPrompts.suggestionRequest(context, model: settings.suggestionModel)
        settings.requestStarted()
        defer { settings.requestEnded() }
        var reply = ""
        do {
            for try await piece in provider.stream(request) {
                reply += piece
                if Task.isCancelled { return }
            }
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                settings.lastError = error.localizedDescription
                finishRequest()
            }
            return
        }
        // Typed on, moved, or the completion list came up meanwhile: this one's stale.
        guard !Task.isCancelled, version == document.editVersion, textView.selectedRange() == NSRange(location: caret, length: 0),
              canSuggest(manual: true) else { return }
        settings.lastError = nil
        finishRequest()
        let text = AIPrompts.sanitizeSuggestion(reply, before: context.before, after: context.after)
        guard !text.isEmpty else { return }
        show(GhostText(anchor: caret, text: text, editVersion: version))
    }

    private func finishRequest() {
        requestTask = nil
        scheduledCaret = nil
    }

    // MARK: Showing

    func show(_ ghost: GhostText) {
        removeRendering()
        self.ghost = ghost
        render()
    }

    /// Hides what's shown, and drops the pending request.
    func dismiss() {
        cancelRequest()
        hide()
    }

    /// Hides what's shown.
    func hide() {
        guard ghost != nil else { return }
        ghost = nil
        removeRendering()
        editor.diagnosticsOverlay?.needsDisplay = true
    }

    /// Opens the room the suggestion is drawn in: a gap for its first line when there's text
    /// after it on the line, and space below the line for the others.
    private func render() {
        guard let ghost else { return }
        let storage = document.textStorage
        let index = document.lineIndex
        let lines = ghost.text.components(separatedBy: "\n")
        let line = index.line(containing: ghost.anchor)
        let lineStart = index.lineStarts[line]
        let nextLineStart = line + 1 < index.lineCount ? index.lineStarts[line + 1] : storage.length
        let lineEnd = line + 1 < index.lineCount ? nextLineStart - 1 : storage.length
        let rest = storage.mutableString.substring(with: NSRange(location: ghost.anchor, length: max(0, lineEnd - ghost.anchor)))
        isApplying = true
        defer { isApplying = false }
        storage.beginEditing()
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ghost.anchor > lineStart, !lines[0].isEmpty {
            storage.addAttributes([.kern: GhostTextStyle.width(of: lines[0], tabWidth: document.displayTabWidth), .omcGhostGap: true],
                                  range: NSRange(location: ghost.anchor - 1, length: 1))
            if editor.textView != nil {
                hidesCaret = true
                textView.insertionPointColor = .clear
            }
        }
        if lines.count > 1, nextLineStart > lineStart {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = CGFloat(lines.count - 1) * lineHeight
            storage.addAttributes([.paragraphStyle: style, .omcGhostSpacing: true],
                                  range: NSRange(location: lineStart, length: nextLineStart - lineStart))
        }
        storage.endEditing()
        editor.diagnosticsOverlay?.needsDisplay = true
    }

    private var lineHeight: CGFloat {
        let font = EditorTheme.font
        return editor.textView == nil ? ceil(font.ascender - font.descender + font.leading) : editor.lineHeight
    }

    /// Takes the gap and the room away again (wherever edits since moved them).
    private func removeRendering() {
        let storage = document.textStorage
        let whole = NSRange(location: 0, length: storage.length)
        var gaps: [NSRange] = [], spacing: [NSRange] = []
        storage.enumerateAttribute(.omcGhostGap, in: whole) { value, range, _ in if value != nil { gaps.append(range) } }
        storage.enumerateAttribute(.omcGhostSpacing, in: whole) { value, range, _ in if value != nil { spacing.append(range) } }
        if hidesCaret, editor.textView != nil {
            hidesCaret = false
            textView.insertionPointColor = EditorTheme.current.cursor
        }
        guard !gaps.isEmpty || !spacing.isEmpty else { return }
        isApplying = true
        defer { isApplying = false }
        storage.beginEditing()
        for range in gaps {
            // An inlay hint that came since has its own gap there now.
            if storage.attribute(.omcInlayHint, at: range.location, effectiveRange: nil) == nil {
                storage.removeAttribute(.kern, range: range)
            }
            storage.removeAttribute(.omcGhostGap, range: range)
        }
        for range in spacing {
            storage.removeAttribute(.paragraphStyle, range: range)
            storage.removeAttribute(.omcGhostSpacing, range: range)
        }
        storage.endEditing()
    }

    /// The suggestion's lines as the overlay draws them (text view coordinates).
    func drawables() -> [(origin: NSPoint, text: String)] {
        drawing().lines
    }

    /// The suggestion's lines, and the caret drawn in place of the text view's (in a gap).
    func drawing() -> GhostDrawing {
        guard let ghost, editor.textView != nil else { return GhostDrawing() }
        guard ghost.editVersion == document.editVersion, ghost.anchor <= document.textStorage.length else {
            // Changed under it (another split, a reload): not drawn, and taken away after this draw.
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return GhostDrawing()
        }
        guard let caret = caretRect(at: ghost.anchor) else { return GhostDrawing() }
        let lines = ghost.text.components(separatedBy: "\n").map { GhostTextStyle.expandingTabs($0, tabWidth: document.displayTabWidth) }
        let left = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        var result: [(NSPoint, String)] = [(NSPoint(x: caret.minX, y: caret.minY), lines[0])]
        for (offset, line) in lines.dropFirst().enumerated() {
            result.append((NSPoint(x: left, y: caret.minY + CGFloat(offset + 1) * caret.height), line))
        }
        let caretBar = hidesCaret && document.editor === editor ? NSRect(x: caret.minX, y: caret.minY, width: 1, height: caret.height) : nil
        return GhostDrawing(lines: result, caret: caretBar)
    }

    /// Where the caret is: right after the character before it (at the start of its gap), or at
    /// the line's start.
    private func caretRect(at offset: Int) -> NSRect? {
        let storage = document.textStorage
        let index = document.lineIndex
        let lineStart = index.lineStarts[index.line(containing: offset)]
        if offset > lineStart, let rect = editor.rect(for: NSRange(location: offset - 1, length: 1)) {
            let character = storage.mutableString.substring(with: NSRange(location: offset - 1, length: 1)) as NSString
            var x = rect.maxX
            if storage.attribute(.kern, at: offset - 1, effectiveRange: nil) != nil {
                // The gap (the kern) starts right after the glyph.
                let font = storage.attribute(.font, at: offset - 1, effectiveRange: nil) as? NSFont ?? EditorTheme.font
                x = rect.minX + character.size(withAttributes: [.font: font]).width
            }
            return NSRect(x: x, y: rect.minY, width: 0, height: rect.height)
        }
        let left = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        if offset < storage.length, let rect = editor.rect(for: NSRange(location: offset, length: 1)) {
            return NSRect(x: left, y: rect.minY, width: 0, height: rect.height)
        }
        // The empty last line.
        let height = lineHeight
        if offset > 0, let previous = editor.rect(for: NSRange(location: offset - 1, length: 1)) {
            return NSRect(x: left, y: previous.minY + previous.height, width: 0, height: height)
        }
        return NSRect(x: left, y: textView.textContainerOrigin.y, width: 0, height: height)
    }

    // MARK: Accepting

    /// Tab: inserts the whole suggestion, as one undoable edit; the caret goes to its end.
    func acceptAll() {
        guard let ghost else { return }
        insert(ghost.text, at: ghost.anchor, remaining: "", separateUndo: true)
    }

    /// ⌘→: inserts the suggestion's next word; the rest stays.
    func acceptWord() {
        guard let ghost else { return }
        let word = Self.nextWord(of: ghost.text)
        insert(word, at: ghost.anchor, remaining: String(ghost.text.dropFirst(word.count)), separateUndo: true)
    }

    /// The start of `text` up to the end of its first word: spaces (and a line break with the
    /// next line's indentation) first, then a run of word characters, or else of punctuation.
    static func nextWord(of text: String) -> String {
        var end = text.startIndex
        while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
        guard end < text.endIndex else { return text }
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        let wordRun = isWord(text[end])
        while end < text.endIndex, !text[end].isWhitespace, isWord(text[end]) == wordRun { end = text.index(after: end) }
        return String(text[..<end])
    }

    private func insert(_ text: String, at anchor: Int, remaining: String, separateUndo: Bool) {
        hide()
        cancelRequest()
        isApplying = true
        if separateUndo { textView.breakUndoCoalescing() }
        textView.insertText(text, replacementRange: NSRange(location: anchor, length: 0))
        if separateUndo { textView.breakUndoCoalescing() }
        isApplying = false
        if !remaining.isEmpty {
            show(GhostText(anchor: anchor + (text as NSString).length, text: remaining, editVersion: document.editVersion))
        }
    }

    // MARK: The editor's events

    /// Typed text (before it's inserted): what matches the suggestion's start is typed through
    /// it and the rest stays; anything else drops it. True when handled here.
    func typed(_ text: String) -> Bool {
        guard let ghost else { return false }
        let selection = textView.selectedRange()
        guard !text.isEmpty, selection == NSRange(location: ghost.anchor, length: 0), ghost.text.hasPrefix(text) else {
            hide()
            return false
        }
        insert(text, at: ghost.anchor, remaining: String(ghost.text.dropFirst(text.count)), separateUndo: false)
        return true
    }

    /// The text view is about to change the text: what's shown goes first (its gap mustn't
    /// pass to the new text).
    func textWillChange() {
        guard !isApplying else { return }
        hide()
    }

    /// The text view changed the text (typing, deleting, pasting): a new suggestion after the pause.
    func textDidChange() {
        guard !isApplying else { return }
        hide()
        schedule(manual: false)
    }

    /// The text changed some other way (another split, a reload, a multi-cursor edit).
    func textChangedElsewhere() {
        guard !isApplying else { return }
        dismiss()
    }

    func selectionDidChange() {
        guard !isApplying, let textView = editor.textView else { return }
        let selection = textView.selectedRange()
        if let ghost, selection != NSRange(location: ghost.anchor, length: 0) { hide() }
        if let scheduledCaret, selection != NSRange(location: scheduledCaret, length: 0) { cancelRequest() }
    }

    /// Scrolled: a suggestion that went out of view goes.
    func viewportDidScroll() {
        guard let ghost, let rect = caretRect(at: ghost.anchor) else { return }
        if !textView.visibleRect.intersects(rect.insetBy(dx: -1, dy: 0)) { dismiss() }
    }

    /// Tab, ⌘→ and Esc while a suggestion shows. True when handled.
    func handle(_ selector: Selector) -> Bool {
        guard ghost != nil else {
            if selector == #selector(NSResponder.cancelOperation(_:)) { cancelRequest() }
            return false
        }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            // Tab keeps its meaning in the completion list and in a snippet's stops.
            guard !editor.completion.isVisible, editor.snippetSession == nil else { return false }
            acceptAll()
        case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)):
            // ⌘→ (not End, which is a scroll and has no selector here).
            guard NSApp.currentEvent.map({ $0.type != .keyDown || $0.modifierFlags.contains(.command) }) ?? true else { return false }
            acceptWord()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }
}

/// What the overlay draws for a suggestion.
struct GhostDrawing {
    var lines: [(origin: NSPoint, text: String)] = []
    var caret: NSRect?
}

/// How suggestions look.
@MainActor
enum GhostTextStyle {
    static var attributes: [NSAttributedString.Key: Any] {
        [.font: EditorTheme.font, .foregroundColor: EditorTheme.current.foreground.withAlphaComponent(0.4)]
    }

    static func expandingTabs(_ text: String, tabWidth: Int) -> String {
        text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: max(1, tabWidth)))
    }

    /// The gap the first line needs.
    static func width(of text: String, tabWidth: Int) -> CGFloat {
        ceil((expandingTabs(text, tabWidth: tabWidth) as NSString).size(withAttributes: [.font: EditorTheme.font]).width)
    }
}

extension EditorDocument {
    /// The path from the folder it's open in (or its name), as sent to AI providers.
    var relativePath: String {
        let root = (workspaceRoot ?? workspace?.rootURL)?.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if let root, path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            return String(path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
        }
        return url.lastPathComponent
    }
}
