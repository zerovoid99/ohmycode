import AppKit
import SwiftTreeSitter
import SwiftUI

/// SwiftUI wrapper around a TextKit 2 `NSTextView`. TextKit 2 lays out only the
/// visible viewport, so large files stay responsive.
struct CodeEditorView: NSViewRepresentable {
    let document: EditorDocument
    /// The editor group (split pane) this editor is in.
    var group: EditorGroup?
    /// Called when this editor gets keyboard focus.
    var onFocus: (() -> Void)?

    func makeCoordinator() -> EditorController {
        EditorController(document: document, group: group)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        context.coordinator.onFocus = onFocus
        return context.coordinator.makeView()
    }

    func updateNSView(_ view: EditorContainerView, context: Context) {}

    static func dismantleNSView(_ view: EditorContainerView, coordinator: EditorController) {
        coordinator.saveViewState()
    }
}

@MainActor
final class EditorController: NSObject {
    let document: EditorDocument
    private(set) var textView: CodeTextView!
    private(set) var gutterView: GutterView!
    private(set) var diagnosticsOverlay: DiagnosticsOverlayView?
    /// The split pane showing this editor (nil outside the workspace, e.g. in tests).
    private(set) weak var group: EditorGroup?
    var onFocus: (() -> Void)?
    private var textLayoutManager: NSTextLayoutManager?
    private(set) lazy var completion = CompletionController(editor: self)
    private(set) lazy var hover = HoverController(editor: self)
    /// What the user just typed, captured before the change, for completion triggering.
    private var pendingTypedText: String?
    /// Range that currently has highlight colors applied; scrolling inside it is free.
    private(set) var highlightedRange: NSRange?

    init(document: EditorDocument, group: EditorGroup? = nil) {
        self.document = document
        self.group = group
    }

    /// The document's content storage keeps its layout managers alive: detach ours, or a closed
    /// split would keep being laid out on every edit.
    isolated deinit {
        if let textLayoutManager { document.textContentStorage.removeTextLayoutManager(textLayoutManager) }
    }

    func makeView() -> EditorContainerView {
        let textLayoutManager = NSTextLayoutManager()
        document.textContentStorage.addTextLayoutManager(textLayoutManager)
        self.textLayoutManager = textLayoutManager

        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 6
        textLayoutManager.textContainer = container

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = CodeTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize),
                                    textContainer: container)
        configure(textView)
        scrollView.documentView = textView
        self.textView = textView

        let overlay = DiagnosticsOverlayView(textView: textView, document: document)
        textView.addSubview(overlay)
        diagnosticsOverlay = overlay

        let gutter = GutterView(textView: textView, document: document)
        self.gutterView = gutter
        // Not textDidEndEditing: AppKit sends that after every edit while the window isn't key.
        textView.onResignFocus = { [weak self] in self?.completion.dismiss() }
        textView.onBecomeFocus = { [weak self] in self?.didBecomeFocused() }
        textView.onCommandClick = { [weak self] in
            guard let self else { return }
            self.completion.dismiss()
            self.hover.dismiss()
            self.goToDefinition()
        }
        textView.onMouseMoved = { [weak self] point in self?.hover.mouseMoved(to: point) }
        textView.onMouseExited = { [weak self] in self?.hover.mouseExited() }
        textView.onKeyDown = { [weak self] in self?.hover.dismiss() }
        gutter.onLineClick = { [weak self] line, rect in self?.showHunk(atLine: line, rect: rect) }
        textView.onLayout = { [weak self, weak gutter, weak overlay] in
            gutter?.needsDisplay = true
            overlay?.needsDisplay = true
            self?.refreshHighlights(force: false)
        }
        let containerView = EditorContainerView(gutterView: gutter, scrollView: scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportDidScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.document.attach(self)
            self.restoreViewState()
            self.document.editor = self
            textView.window?.makeFirstResponder(textView)
            self.document.highlighter?.addClient(self)
            self.applyDiagnostics()
        }
        return containerView
    }

    private func configure(_ textView: NSTextView) {
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = EditorTheme.font
        textView.typingAttributes = EditorTheme.baseAttributes
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 4, height: 6)

        // No line wrapping: grow horizontally, scroll sideways.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
    }

    // MARK: View state

    func saveViewState() {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        var offset = 0
        var delta: CGFloat = 0
        if let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visible.minY - origin.y))) {
            offset = contentManager.offset(from: contentManager.documentRange.location,
                                           to: fragment.rangeInElement.location)
            delta = visible.minY - (fragment.layoutFragmentFrame.minY + origin.y)
        }
        let state = EditorViewState(topLineOffset: offset, topLineDelta: delta,
                                    scrollX: visible.minX, selection: textView.selectedRange())
        document.viewState = state
        group?.viewStates[document.id] = state
    }

    /// This pane's own state for the document, or else the document's latest (so a new split
    /// opens where the other view is).
    func restoreViewState() {
        guard let state = group?.viewStates[document.id] ?? document.viewState,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let length = document.textStorage.length
        let location = min(state.selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(state.selection.length, length - location)))

        let documentStart = contentManager.documentRange.location
        guard let anchor = contentManager.location(documentStart, offsetBy: min(state.topLineOffset, length)) else { return }
        var anchorY: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: anchor, options: [.ensuresLayout]) { fragment in
            anchorY = fragment.layoutFragmentFrame.minY
            return false
        }
        textView.scroll(NSPoint(x: state.scrollX, y: anchorY + textView.textContainerOrigin.y + state.topLineDelta))
    }

    /// Zero-based line at the top of the viewport.
    var topVisibleLine: Int {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return 0 }
        let y = max(0, textView.visibleRect.minY - textView.textContainerOrigin.y)
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return 0 }
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        return document.lineIndex.line(containing: offset)
    }

    /// The document's text was replaced from disk: keep the cursor near where it was.
    func documentDidReload(previousSelection: NSRange?) {
        let length = document.textStorage.length
        if let previous = previousSelection {
            textView.setSelectedRange(NSRange(location: min(previous.location, length), length: 0))
        }
        gutterView.updateWidth()
        gutterView.needsDisplay = true
        refreshHighlights(force: true)
    }

    // MARK: Language features

    /// The editor doesn't know its workspace; the workspace owning the document handles these.
    func perform(_ command: EditorCommand) {
        NotificationCenter.default.post(name: .omcEditorCommand, object: document,
                                        userInfo: ["command": command.rawValue])
    }

    func goToDefinition() { perform(.goToDefinition) }

    @objc private func contextGoToDefinition(_ sender: Any?) { perform(.goToDefinition) }
    @objc private func contextFindReferences(_ sender: Any?) { perform(.findReferences) }
    @objc private func contextRename(_ sender: Any?) { perform(.rename) }
    @objc private func contextFormat(_ sender: Any?) { perform(.format) }

    /// Language actions at the top of the editor's context menu.
    fileprivate func languageMenuItems() -> [NSMenuItem] {
        guard let client = document.languageClient else { return [] }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [],
                  enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            return item
        }
        let f12 = String(Character(UnicodeScalar(NSF12FunctionKey)!))
        let f2 = String(Character(UnicodeScalar(NSF2FunctionKey)!))
        return [
            item("Go to Definition", #selector(contextGoToDefinition), f12),
            item("Find All References", #selector(contextFindReferences), f12, .shift,
                 enabled: client.supports(.references)),
            item("Rename Symbol", #selector(contextRename), f2, enabled: client.supports(.rename)),
            .separator(),
            item("Format Document", #selector(contextFormat), "f", [.shift, .option],
                 enabled: client.supports(.formatting)),
            .separator(),
        ]
    }

    /// Text changed without going through the text view (multi-edits, undo of those).
    func textDidChangeProgrammatically() {
        refreshAfterEdit()
        completion.dismiss()
        hover.dismiss()
    }

    /// Another editor (split view) changed the shared text.
    func refreshAfterEdit() {
        gutterView.updateWidth()
        gutterView.needsDisplay = true
        diagnosticsOverlay?.needsDisplay = true
    }

    private func didBecomeFocused() {
        document.editor = self
        // Edits and selection sync go through the primary layout manager.
        if let textLayoutManager { document.textContentStorage.primaryTextLayoutManager = textLayoutManager }
        document.updateCursor(forSelectionAt: textView.selectedRange().location)
        onFocus?()
    }

    // MARK: Geometry

    /// Bounding rect of `range` in text view coordinates (laid out on demand).
    func rect(for range: NSRange) -> NSRect? {
        guard let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager,
              NSMaxRange(range) <= document.textStorage.length,
              let textRange = textRange(for: range, in: contentManager) else { return nil }
        layoutManager.ensureLayout(for: textRange)
        var result: NSRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            result = result.map { $0.union(frame) } ?? frame
            return true
        }
        let origin = textView.textContainerOrigin
        return result?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The character whose glyph is under `point` (text view coordinates), if any.
    func characterIndex(at point: NSPoint) -> Int? {
        let length = document.textStorage.length
        let insertion = textView.characterIndexForInsertion(at: point)
        for index in [insertion, insertion - 1] where index >= 0 && index < length {
            if let rect = rect(for: NSRange(location: index, length: 1)), rect.insetBy(dx: -1, dy: -1).contains(point) {
                return index
            }
        }
        return nil
    }

    func wordRange(at index: Int) -> NSRange? { document.wordRange(at: index) }

    // MARK: Git hunks

    private var hunkPopover: NSPopover?

    /// Clicking a change marker shows the hunk with Revert.
    func showHunk(atLine line: Int, rect: NSRect) {
        guard let hunk = document.hunk(atLine: line) else { return }
        let (old, new) = document.lines(of: hunk)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: HunkPopoverView(
            oldLines: old, newLines: new,
            onRevert: { [weak self, weak popover] in
                self?.revert(hunk)
                popover?.performClose(nil)
            }
        ))
        hunkPopover = popover
        popover.show(relativeTo: rect, of: gutterView, preferredEdge: .maxX)
    }

    /// Reverts through the text view, so it's a normal undoable edit.
    func revert(_ hunk: DiffHunk) {
        guard let edit = document.revertEdit(for: hunk) else { return }
        textView.breakUndoCoalescing()
        textView.insertText(edit.replacement, replacementRange: edit.range)
        textView.breakUndoCoalescing()
    }

    /// Redraws diagnostic squiggles (drawn by an overlay; see DiagnosticsOverlayView).
    func applyDiagnostics() {
        diagnosticsOverlay?.needsDisplay = true
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    func reveal(_ range: NSRange) {
        let length = document.textStorage.length
        let clamped = NSRange(location: min(range.location, length),
                              length: min(range.length, length - min(range.location, length)))
        textView.setSelectedRange(clamped)
        textView.scrollRangeToVisible(clamped)
        focus()
    }

    func showFindInterface() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        focus()
        textView.performTextFinderAction(item)
    }

    @objc private func viewportDidScroll() {
        gutterView.needsDisplay = true
    }

    /// Asks for syntax colors when the viewport moved outside the highlighted range (or always,
    /// with `force`). Highlights are computed in the background and arrive in `applyHighlights`.
    func refreshHighlights(force: Bool) {
        guard let highlighter = document.highlighter else { return }
        if !force, let highlightedRange, let visible = visibleCharacterRange(),
           NSIntersectionRange(highlightedRange, visible) == visible { return }
        highlighter.requestHighlights(for: self)
    }

    /// The range the text view's viewport pass laid out (visible area plus TextKit's overdraw).
    private func visibleCharacterRange() -> NSRange? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let viewportRange = layoutManager.textViewportLayoutController.viewportRange else { return nil }
        let documentStart = contentManager.documentRange.location
        let start = contentManager.offset(from: documentStart, to: viewportRange.location)
        let end = contentManager.offset(from: documentStart, to: viewportRange.endLocation)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func textRange(for range: NSRange, in contentManager: NSTextContentManager) -> NSTextRange? {
        let documentStart = contentManager.documentRange.location
        guard let start = contentManager.location(documentStart, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}

extension EditorController: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        hover.dismiss()
        // Right-clicking outside the selection moves the cursor there, so actions apply to that word.
        let selection = view.selectedRange()
        if !(NSLocationInRange(charIndex, selection) || (selection.length == 0 && charIndex == selection.location)) {
            view.setSelectedRange(NSRange(location: charIndex, length: 0))
        }
        let items = languageMenuItems()
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        return menu
    }

    func textDidChange(_ notification: Notification) {
        hover.dismiss()
        // Highlighting is rescheduled by the document's edit observer.
        gutterView.updateWidth()
        gutterView.needsDisplay = true
        let typed = pendingTypedText
        pendingTypedText = nil
        completion.textDidChange(typed: typed)
        for other in document.editors where other !== self { other.refreshAfterEdit() }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        pendingTypedText = (replacementString?.isEmpty == false) ? replacementString : nil
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if completion.handle(selector) { return true }
        if selector == #selector(NSResponder.complete(_:)) {
            completion.triggerManually()
            return true
        }
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // The status bar follows the focused editor; other splits move their selection on edits.
        if document.editor === self || document.editor == nil {
            document.updateCursor(forSelectionAt: textView.selectedRange().location)
        }
        gutterView.needsDisplay = true
    }
}

/// `NSTextView` that reports each layout pass (TextKit 2 lays out its viewport in `layout()`),
/// so the gutter and syntax colors can follow the freshly laid-out viewport.
final class CodeTextView: NSTextView {
    var onLayout: (() -> Void)?
    var onCommandClick: (() -> Void)?
    var onResignFocus: (() -> Void)?
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onKeyDown: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?()
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onKeyDown?()
        super.scrollWheel(with: event)
    }

    var onBecomeFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onBecomeFocus?() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFocus?() }
        return resigned
    }

    /// ⌘-click: place the cursor there and go to the definition.
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onCommandClick else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        onCommandClick()
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

extension EditorController: SyntaxHighlighterClient {
    /// Visible lines plus one screen of overscan above and below.
    var highlightRange: NSRange? {
        guard textView != nil, let visible = visibleCharacterRange() else { return nil }
        let lineIndex = document.lineIndex
        let firstLine = lineIndex.line(containing: visible.location)
        let lastLine = lineIndex.line(containing: NSMaxRange(visible))
        let overscan = max(lastLine - firstLine, 20)
        let startLine = max(0, firstLine - overscan)
        let endLine = lastLine + overscan + 1
        let start = lineIndex.lineStarts[startLine]
        let end = endLine < lineIndex.lineCount ? lineIndex.lineStarts[endLine] : document.textStorage.length
        return NSRange(location: start, length: end - start)
    }

    /// Applied as TextKit 2 rendering attributes: they only affect drawing, so the text storage
    /// isn't edited and no layout is invalidated.
    func applyHighlights(_ highlights: [NamedRange], in range: NSRange) {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              NSMaxRange(range) <= document.textStorage.length,
              let fullTextRange = textRange(for: range, in: contentManager) else { return }
        layoutManager.removeRenderingAttribute(.foregroundColor, for: fullTextRange)
        for highlight in highlights {
            let clipped = NSIntersectionRange(highlight.range, range)
            guard clipped.length > 0,
                  let color = EditorTheme.color(forCapture: highlight.name),
                  let textRange = textRange(for: clipped, in: contentManager) else { continue }
            layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        }
        highlightedRange = range
    }
}

/// Language actions an editor asks its workspace to run (⌘-click, context menu).
enum EditorCommand: String {
    case goToDefinition, findReferences, rename, format
}

extension Notification.Name {
    /// Posted by an editor with `userInfo["command"]` (an `EditorCommand` raw value).
    static let omcEditorCommand = Notification.Name("omcEditorCommand")
}
