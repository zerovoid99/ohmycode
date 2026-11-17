import AppKit

/// Vim mode in one editor: hosts the engine on the editor's text view and document, and turns
/// the text view's key presses into Vim keys. Only the code editor's text view comes here: the
/// find bar and other text fields keep their usual keys, and ⌘ shortcuts always pass through.
///
/// Extra cursors (⌥-click, ⌘D) switch to Insert mode, so typing goes to every cursor; Esc
/// removes them first (as without Vim), a second Esc returns to Normal mode, where commands act
/// on the one cursor.
@MainActor
final class VimBridge: VimHost {
    private unowned let editor: EditorController
    private(set) lazy var engine = VimEngine(host: self)
    /// The pasteboard registers + and * use (tests use one of their own).
    nonisolated(unsafe) static var pasteboard: NSPasteboard = .general
    private var changeDepth = 0
    /// A change keeps one undo group open across key presses (Insert mode's typing); the
    /// undo manager must not close it at the end of each event meanwhile.
    private var ownsUndoGroup = false
    /// A change started and has made no edit yet.
    private var wantsUndoGroup = false
    private var closesOuterGroup = false
    private var observers: [NSObjectProtocol] = []

    init(editor: EditorController) {
        self.editor = editor
        let undoManager = editor.document.undoManager
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
            observers.append(center.addObserver(forName: name, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.undoWillRun() }
            })
        }
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(center.addObserver(forName: name, object: undoManager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.undoDidRun() }
            })
        }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Vim mode was turned off: back to the text view's own caret and keys.
    func detach() {
        engine.reset()
        closeUndoGroup()
        editor.textView?.insertionPointColor = EditorTheme.current.cursor
        if editor.document.vimStatus != nil, editor.document.editor === editor || editor.document.editor == nil {
            editor.document.vimStatus = nil
        }
        editor.diagnosticsOverlay?.marksDidChange()
    }

    // MARK: Keys

    /// A key press in the text view; true when Vim took it. `isKeyEquivalent`: asked before the
    /// app's shortcuts, which is only for the Control keys Vim uses (^R would be Open Recent).
    func handle(_ event: NSEvent, isKeyEquivalent: Bool) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        guard let textView = editor.textView, textView.window?.firstResponder === textView || !isKeyEquivalent else { return false }
        if isKeyEquivalent {
            guard flags.contains(.control), let key = Self.key(for: event), wantsControlKey(key) else { return false }
            return dispatch(key)
        }
        // Composing (an input method): its keys are its own.
        if textView.hasMarkedText() { return false }
        if editor.hasExtraCursors, engine.mode != .insert {
            engine.enterInsertKeepingSelection()
        }
        if flags.contains(.option), engine.mode != .insert, editor.handleLineCommandKey(event) { return true }
        guard let key = Self.key(for: event) else { return engine.mode != .insert }
        return dispatch(key)
    }

    private func wantsControlKey(_ key: String) -> Bool {
        switch engine.mode {
        case .insert, .replace: return key == "<Esc>" || key == "<C-c>"
        default:
            if engine.commandLine != nil { return ["<Esc>", "<C-c>", "<C-u>", "<C-w>", "<C-h>"].contains(key) }
            return ["<Esc>", "<C-c>", "<C-r>", "<C-d>", "<C-u>", "<C-f>", "<C-b>", "<C-e>", "<C-y>"].contains(key)
        }
    }

    private func dispatch(_ key: String) -> Bool {
        switch engine.mode {
        case .insert:
            guard VimParser.isEscape(key) else { return false }
            // Esc closes what's open first (completion, a suggestion, extra cursors, the find bar).
            if escapeHasSomethingToClose { return false }
            if hideFindBar() { return true }
            engine.handle(key)
            return true
        case .replace:
            engine.handle(key)
            return true
        default:
            if VimParser.isEscape(key), engine.isIdle, !engine.isVisual {
                if escapeHasSomethingToClose { return false }
                if hideFindBar() { return true }
                if editor.document.workspace?.zenEscape() == true { return true }
            }
            engine.handle(key == "<C-h>" ? "<BS>" : key)
            return true
        }
    }

    private var escapeHasSomethingToClose: Bool {
        editor.completion.isVisible || editor.inlineSuggestions.ghost != nil || editor.signatureHelp.isShown
            || editor.hasExtraCursors || editor.snippetSession != nil
    }

    private func hideFindBar() -> Bool {
        guard let textView = editor.textView, textView.enclosingScrollView?.isFindBarVisible == true else { return false }
        textView.finder.performAction(.hideFindInterface)
        textView.enclosingScrollView?.isFindBarVisible = false
        return true
    }

    /// The key as the engine names it: the character typed, or "<Esc>", "<CR>", "<C-r>"…
    static func key(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let base = event.charactersIgnoringModifiers, let scalar = base.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case 0x1B: return "<Esc>"
        case 0x0D, 0x03: return "<CR>"
        case 0x7F, 0x08: return "<BS>"
        case 0x09, 0x19: return "<Tab>"
        case NSUpArrowFunctionKey: return "<Up>"
        case NSDownArrowFunctionKey: return "<Down>"
        case NSLeftArrowFunctionKey: return "<Left>"
        case NSRightArrowFunctionKey: return "<Right>"
        case NSDeleteFunctionKey: return "<Del>"
        case NSHomeFunctionKey: return "<Home>"
        case NSEndFunctionKey: return "<End>"
        case NSPageUpFunctionKey: return "<PageUp>"
        case NSPageDownFunctionKey: return "<PageDown>"
        case NSInsertFunctionKey: return "<Insert>"
        case 0xF700...0xF8FF: return nil
        default: break
        }
        if flags.contains(.control) {
            let name = base.lowercased()
            return name == "[" ? "<Esc>" : "<C-\(name)>"
        }
        guard let typed = event.characters, !typed.isEmpty else { return nil }
        return typed
    }

    /// ⌘V while typing a command line: into it.
    func paste() -> Bool {
        guard engine.commandLine != nil else { return false }
        let text = Self.pasteboard.string(forType: .string) ?? ""
        engine.typeIntoCommandLine(text.components(separatedBy: .newlines).first ?? "")
        return true
    }

    // MARK: Selection and caret

    /// The selection changed (the engine's own moves come back here too).
    func selectionDidChange() {
        engine.selectionDidChange()
    }

    /// Where the block cursor is drawn (Normal and Visual mode), or Replace mode's underline.
    func blockCaretRect() -> NSRect? {
        guard engine.mode != .insert, let textView = editor.textView else { return nil }
        let string = editor.document.textStorage.mutableString
        let length = string.length
        let location = min(engine.cursorLocation, length)
        let space = (" " as NSString).size(withAttributes: [.font: EditorTheme.font]).width
        let text = VimText(string, lines: editor.document.lineIndex)
        var rect: NSRect?
        if location < length, !text.isLineBreak(at: location) {
            rect = editor.rect(for: NSRange(location: location, length: text.next(location) - location))
        } else if location > 0, !text.isLineBreak(at: location - 1),
                  let before = editor.rect(for: NSRange(location: text.previous(location), length: location - text.previous(location))) {
            rect = NSRect(x: before.maxX, y: before.minY, width: space, height: before.height)
        } else if location < length, let lineBreak = editor.rect(for: NSRange(location: location, length: 1)) {
            rect = NSRect(x: lineBreak.minX, y: lineBreak.minY, width: space, height: lineBreak.height)
        } else {
            let y = (editor.rect(for: NSRange(location: max(0, length - 1), length: min(1, length))).map(\.maxY) ?? textView.textContainerOrigin.y)
            rect = NSRect(x: textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0), y: y,
                          width: space, height: editor.lineHeight)
        }
        guard var caret = rect else { return nil }
        caret.size.width = max(caret.width, space / 2)
        if engine.mode == .replace {
            caret = NSRect(x: caret.minX, y: caret.maxY - 2, width: caret.width, height: 2)
        }
        return caret
    }

    /// The text view's own (bar) caret shows only in Insert mode.
    func updateCaret() {
        guard let textView = editor.textView else { return }
        let color: NSColor = engine.mode == .insert ? EditorTheme.current.cursor : .clear
        if textView.insertionPointColor != color {
            textView.insertionPointColor = color
            textView.updateInsertionPointStateAndRestartTimer(true)
        }
        editor.diagnosticsOverlay?.marksDidChange()
    }

    /// The mode in the status bar (the focused editor's).
    func publishStatus() {
        let document = editor.document
        guard document.editor === editor || document.editor == nil else { return }
        var status = engine.statusText
        if engine.commandLine != nil { status += "▏" }
        if document.vimStatus != status { document.vimStatus = status }
    }

    // MARK: Undo

    private func undoWillRun() {
        // ⌘Z in the middle of a change (Insert mode): the undo manager closes its group.
        guard ownsUndoGroup else { return }
        closeUndoGroup()
    }

    private func undoDidRun() {
        // Undo selects what it put back: Normal mode keeps a cursor.
        guard engine.mode != .insert, engine.mode != .replace, let textView = editor.textView else { return }
        let selection = textView.selectedRange()
        if selection.length > 0 { textView.setSelectedRange(NSRange(location: selection.location, length: 0)) }
    }

    private func closeUndoGroup() {
        changeDepth = 0
        wantsUndoGroup = false
        guard ownsUndoGroup else { return }
        ownsUndoGroup = false
        let undoManager = editor.document.undoManager
        if undoManager.groupingLevel > 0 { undoManager.endUndoGrouping() }
        if closesOuterGroup, undoManager.groupingLevel > 0 { undoManager.endUndoGrouping() }
        closesOuterGroup = false
        undoManager.groupsByEvent = true
    }

    // MARK: VimHost

    var vimText: NSString { editor.document.textStorage.mutableString }
    var vimLines: LineIndex { editor.document.lineIndex }
    var vimSelection: NSRange { editor.textView?.selectedRange() ?? NSRange(location: 0, length: 0) }

    func vimSetSelection(_ range: NSRange, reveal: Int) {
        guard let textView = editor.textView else { return }
        textView.setSelectedRange(range)
        let length = editor.document.textStorage.length
        textView.scrollRangeToVisible(NSRange(location: min(max(0, reveal), length), length: 0))
    }

    func vimApply(_ edits: [TextReplacement]) -> Bool {
        (try? editor.document.apply(edits, actionName: "Edit")) ?? false
    }

    /// The group opens with the change's first edit (`textWillChange`): one that changes
    /// nothing (`gU` on capitals, `i` and Esc) would leave an undo step that does nothing.
    func vimBeginChange() {
        changeDepth += 1
        guard changeDepth == 1 else { return }
        editor.textView?.breakUndoCoalescing()
        wantsUndoGroup = true
    }

    func vimEndChange() {
        guard changeDepth > 0 else { return }
        changeDepth -= 1
        guard changeDepth == 0 else { return }
        editor.textView?.breakUndoCoalescing()
        closeUndoGroup()
    }

    /// The text is about to change (typed, or edited by the document).
    func textWillChange() {
        guard wantsUndoGroup, !ownsUndoGroup else { return }
        let undoManager = editor.document.undoManager
        guard !undoManager.isUndoing, !undoManager.isRedoing else { return }
        // A group the undo manager opened for this event (something registered before) is
        // closed with ours.
        closesOuterGroup = undoManager.groupingLevel > 0
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        ownsUndoGroup = true
    }

    func vimUndo() -> Bool {
        let undoManager = editor.document.undoManager
        guard undoManager.canUndo else { return false }
        undoManager.undo()
        return true
    }

    func vimRedo() -> Bool {
        let undoManager = editor.document.undoManager
        guard undoManager.canRedo else { return false }
        undoManager.redo()
        return true
    }

    var vimIsEditable: Bool { editor.textView?.isEditable ?? false }

    var vimVisibleLines: ClosedRange<Int> {
        guard editor.textView != nil else { return 0...0 }
        let top = editor.topVisibleLine
        return top...max(top, top + editor.visibleLineCount - 1)
    }

    func vimScroll(lines: Int) {
        guard let textView = editor.textView else { return }
        let visible = textView.visibleRect
        let maxY = max(0, textView.bounds.height - visible.height)
        let y = min(max(0, visible.minY + CGFloat(lines) * editor.lineHeight), maxY)
        textView.scroll(NSPoint(x: visible.minX, y: y))
    }

    func vimScrollCursor(to position: VimScrollPosition) {
        let line = editor.document.lineIndex.line(containing: engine.cursorLocation)
        let count = editor.visibleLineCount
        switch position {
        case .top: editor.scrollLineToTop(line)
        case .center: editor.scrollLineToTop(max(0, line - count / 2))
        case .bottom: editor.scrollLineToTop(max(0, line - count + 1))
        }
    }

    var vimLineBreak: String { editor.document.lineEnding.characters }
    var vimIndentUnit: String { editor.indentUnit }

    var vimClipboard: String? {
        get { Self.pasteboard.string(forType: .string) }
        set {
            Self.pasteboard.clearContents()
            if let newValue { Self.pasteboard.setString(newValue, forType: .string) }
        }
    }

    func vimRun(_ command: VimHostCommand) -> String? {
        let document = editor.document
        guard let workspace = document.workspace else { return "Not available here" }
        let group = editor.group
        switch command {
        case .write:
            workspace.formatAndSave(document)
            return "\"\(document.url.lastPathComponent)\" written"
        case .writeAll:
            workspace.saveAll()
            return nil
        case .quit(let force):
            if document.isDirty, !force { return "E37: No write since last change (add ! to override)" }
            // After this key press: closing takes this editor apart.
            DispatchQueue.main.async {
                if force, document.isDirty { document.revertToSaved() }
                workspace.close(document, in: group)
            }
            return nil
        case .writeQuit(let onlyIfChanged):
            Task {
                if document.isDirty || !onlyIfChanged {
                    guard await workspace.formatAndSave(document).value else { return }
                }
                workspace.close(document, in: group)
            }
            return nil
        }
    }

    func vimStateDidChange() {
        updateCaret()
        publishStatus()
    }
}
