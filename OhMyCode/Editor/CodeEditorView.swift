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
    private weak var containerView: EditorContainerView?
    /// Cursors besides the text view's own selection (see MultiCursor.swift).
    var extraSelections: [NSRange] = []
    /// The 💡 for the cursor line's fixes.
    private(set) lazy var lightbulb = LightbulbController(editor: self)
    /// Parameter hints while typing a call's arguments.
    private(set) lazy var signatureHelp = SignatureHelpController(editor: self)
    /// The inserted snippet whose stops Tab steps through.
    var snippetSession: SnippetSession?
    private(set) var minimapView: MinimapView?
    private(set) var stickyView: StickyScrollView?
    private(set) lazy var completion = CompletionController(editor: self)
    private(set) lazy var hover = HoverController(editor: self)
    private(set) lazy var blameHover = BlameHoverController(editor: self)
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
        overlay.foldPlaceholders = { [weak self] in self?.foldPlaceholderRects() ?? [] }
        overlay.extraCursors = { [weak self] in self?.extraCursorShapes() ?? ([], []) }
        overlay.blameAnnotation = { [weak self] in self?.blameAnnotation() }
        overlay.executionLine = { [weak self] in self?.executionLineRect() }
        overlay.conflictBands = { [weak self] in self?.conflictBands() ?? [] }
        overlay.conflictActions = { [weak self] in self?.conflictActionRects() ?? [] }

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
        textView.onMouseMoved = { [weak self] point in
            guard let self else { return }
            if self.blameHover.mouseMoved(to: point) { self.hover.dismiss() } else { self.hover.mouseMoved(to: point) }
        }
        textView.onOptionClick = { [weak self] location in self?.toggleCursor(at: location) }
        textView.onInsertText = { [weak self] text in
            guard let self else { return false }
            if self.hasExtraCursors {
                self.insertAtAllCursors(text)
                return true
            }
            return self.handleTyped(text)
        }
        textView.onClick = { [weak self] point in
            self?.clearExtraCursors()
            if self?.handleConflictClick(at: point) == true { return true }
            if self?.handleBlameClick(at: point) == true { return true }
            guard let self, let hit = self.foldPlaceholderRects().first(where: { $0.rect.contains(point) }) else { return false }
            self.document.unfold(atHeader: hit.header)
            return true
        }
        textView.onMouseExited = { [weak self] in self?.hover.mouseExited(); self?.blameHover.mouseExited() }
        textView.onKeyDown = { [weak self] in self?.hover.dismiss(); self?.blameHover.dismiss() }
        gutter.onLineClick = { [weak self] line, rect in self?.showHunk(atLine: line, rect: rect) }
        gutter.onFoldClick = { [weak self] line in self?.document.toggleFold(atLine: line) }
        gutter.onTestClick = { [weak self] line in self?.document.runTestAction?(line) }
        gutter.onBreakpointClick = { [weak self] line in
            guard let self else { return }
            self.document.toggleBreakpointAction?(line)
        }
        gutter.onBlameHover = { [weak self] line, rect in self?.blameHover.gutterMouseMoved(line: line, rect: rect) }
        gutter.onBlameExited = { [weak self] in self?.blameHover.mouseExited() }
        gutter.onBlameClick = { [weak self] line in self?.handleBlameColumnClick(line: line) }
        gutter.menuForLine = { [weak self] line in self?.gutterMenu(line: line) }
        textView.onLayout = { [weak self, weak gutter, weak overlay] in
            gutter?.needsDisplay = true
            overlay?.needsDisplay = true
            self?.refreshHighlights(force: false)
            self?.minimapView?.refresh()
        }
        let containerView = EditorContainerView(gutterView: gutter, scrollView: scrollView)
        self.containerView = containerView
        let minimap = MinimapView(editor: self)
        containerView.minimapView = minimap
        minimapView = minimap
        let sticky = StickyScrollView(editor: self)
        sticky.onHeightChange = { [weak containerView] in containerView?.needsLayout = true }
        containerView.stickyView = sticky
        stickyView = sticky
        applySettings()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: AppSettings.didChange, object: nil)

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
            if let minimap = self.minimapView, !minimap.isHidden { self.document.highlighter?.addClient(minimap) }
            self.stickyView?.update()
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
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 4, height: 6)

        // No line wrapping: grow horizontally, scroll sideways.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
    }

    // MARK: Theme and font

    @objc private func settingsDidChange() {
        applySettings()
    }

    /// Applies the current theme and font (also live, from the Settings window).
    func applySettings() {
        let theme = EditorTheme.current
        document.refreshStyleIfNeeded()
        // Fixed light/dark themes draw the editor with that appearance (gutter, scrollers).
        containerView?.appearance = theme.appearance
        textView.font = EditorTheme.font
        textView.typingAttributes = EditorTheme.baseAttributes
        textView.backgroundColor = theme.background
        textView.insertionPointColor = theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection]
        textView.enclosingScrollView?.backgroundColor = theme.background
        gutterView.themeDidChange()
        diagnosticsOverlay?.needsDisplay = true
        refreshHighlights(force: true)

        let settings = AppSettings.shared
        if let minimapView, minimapView.isHidden == settings.showsMinimap {
            minimapView.isHidden = !settings.showsMinimap
            if settings.showsMinimap { document.highlighter?.addClient(minimapView) }
            containerView?.needsLayout = true
        }
        minimapView?.needsDisplay = true
        stickyView?.update()
    }

    // MARK: Folding

    /// Folds changed: lay out the affected lines again (hidden lines come and go).
    func foldsDidChange(_ ranges: [NSRange]) {
        guard let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager else { return }
        let length = document.textStorage.length
        if var union = ranges.first {
            for range in ranges.dropFirst() { union = NSUnionRange(union, range) }
            // From the line before (the header) through the hidden lines.
            let start = max(0, min(union.location, length) - 1)
            let end = min(length, NSMaxRange(union))
            if let textRange = textRange(for: NSRange(location: start, length: end - start), in: contentManager) {
                layoutManager.invalidateLayout(for: textRange)
            }
        }
        layoutManager.textViewportLayoutController.layoutViewport()
        textView.needsLayout = true
        gutterView.needsDisplay = true
        diagnosticsOverlay?.needsDisplay = true
        stickyView?.update()
    }

    /// Folds or unfolds the region at the cursor (⌥⌘[ and ⌥⌘]).
    func foldAtCursor(_ fold: Bool) {
        let line = document.lineIndex.line(containing: textView.selectedRange().location)
        if fold { document.foldEnclosing(line: line) } else { document.unfoldEnclosing(line: line) }
        // Keep the cursor visible: on the header when its line got hidden.
        let selection = textView.selectedRange()
        if document.isHidden(selection.location), let header = document.folds.first(where: { NSLocationInRange(selection.location, $0) }) {
            let headerLine = document.lineIndex.line(containing: header.location) - 1
            textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[max(0, headerLine)], length: 0))
        }
    }

    /// Where the "⋯" after a folded header is drawn (text view coordinates).
    func foldPlaceholderRects() -> [(rect: NSRect, header: Int)] {
        let visible = textView.visibleRect
        var result: [(NSRect, Int)] = []
        for fold in document.folds {
            let header = document.lineIndex.line(containing: fold.location) - 1
            guard header >= 0, !document.isHidden(document.lineIndex.lineStarts[header]) else { continue }
            let lineEnd = fold.location - 1 // the header's newline
            guard lineEnd > document.lineIndex.lineStarts[header] || lineEnd == document.lineIndex.lineStarts[header],
                  let last = rect(for: NSRange(location: max(document.lineIndex.lineStarts[header], lineEnd - 1), length: 1))
            else { continue }
            let rect = NSRect(x: last.maxX + 6, y: last.minY + 1, width: 22, height: max(1, last.height - 2))
            if rect.intersects(visible) { result.append((rect, header)) }
        }
        return result
    }

    // MARK: Debugging

    /// The stopped line's band, across the editor's width.
    func executionLineRect() -> NSRect? {
        guard let line = document.executionLine, line < document.lineIndex.lineCount else { return nil }
        let start = document.lineIndex.lineStarts[line]
        let length = document.textStorage.length
        guard let rect = rect(for: NSRange(location: start, length: start < length ? 1 : 0)) else { return nil }
        return NSRect(x: 0, y: rect.minY, width: max(textView.bounds.width, textView.visibleRect.maxX), height: rect.height)
    }

    // MARK: Blame

    /// The blame annotation for the cursor's line: its text, where it's drawn (after the line)
    /// and the line's blame.
    func blameAnnotation() -> BlameAnnotation? {
        guard AppSettings.shared.showsLineBlame, !hasExtraCursors, let blame = document.blame else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        let index = document.lineIndex
        let line = index.line(containing: selection.location)
        guard line < blame.count, let entry = blame[line] else { return nil }
        let start = index.lineStarts[line]
        let end = line + 1 < index.lineCount ? index.lineStarts[line + 1] - 1 : document.textStorage.length
        let anchor: NSRect?
        if end > start {
            anchor = rect(for: NSRange(location: end - 1, length: 1)).map { NSRect(x: $0.maxX, y: $0.minY, width: 0, height: $0.height) }
        } else {
            anchor = rect(for: NSRange(location: start, length: min(1, document.textStorage.length - start)))
                .map { NSRect(x: $0.minX, y: $0.minY, width: 0, height: $0.height) }
        }
        guard let anchor else { return nil }
        let text = Self.describe(entry)
        let size = (text as NSString).size(withAttributes: [.font: Self.blameFont])
        return BlameAnnotation(text: text, rect: NSRect(x: anchor.maxX + 28, y: anchor.minY, width: ceil(size.width),
                                                        height: max(anchor.height, size.height)),
                               blame: entry, isHovered: blameHover.isMouseOnAnnotation && !entry.isUncommitted)
    }

    static var blameFont: NSFont { NSFontManager.shared.convert(EditorTheme.font, toHaveTrait: .italicFontMask) }

    nonisolated static func describe(_ blame: BlameLine, now: Date = Date()) -> String {
        if blame.isUncommitted { return "Not committed yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: blame.date, relativeTo: now)
        return "\(blame.author), \(when) • \(blame.summary)"
    }

    // MARK: Line geometry (minimap, sticky scroll)

    /// Height of one line; lines don't wrap, so all have the same height.
    var lineHeight: CGFloat {
        if let layoutManager = textView.textLayoutManager,
           let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, textView.visibleRect.minY - textView.textContainerOrigin.y))),
           let line = fragment.textLineFragments.first {
            return line.typographicBounds.height
        }
        let font = EditorTheme.font
        return ceil(font.ascender - font.descender + font.leading)
    }

    var visibleLineCount: Int {
        max(1, Int(textView.visibleRect.height / max(1, lineHeight)))
    }

    /// Scrolls so `line` (zero-based) is the first visible line.
    func scrollLineToTop(_ line: Int) {
        guard let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager else { return }
        let index = document.lineIndex
        let offset = index.lineStarts[min(max(0, line), index.lineCount - 1)]
        guard let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset) else { return }
        var y: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            y = fragment.layoutFragmentFrame.minY
            return false
        }
        textView.scroll(NSPoint(x: textView.visibleRect.minX, y: y + textView.textContainerOrigin.y))
    }

    /// Puts the cursor at the start of `line` with that line at the top, below any sticky lines.
    func reveal(line: Int) {
        let index = document.lineIndex
        let line = min(max(0, line), index.lineCount - 1)
        textView.setSelectedRange(NSRange(location: index.lineStarts[line], length: 0))
        scrollLineToTop(line - (stickyView?.lines.filter { $0 < line }.count ?? 0))
        focus()
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
    @objc private func contextGoToImplementation(_ sender: Any?) { perform(.goToImplementation) }
    @objc private func contextCallHierarchy(_ sender: Any?) { perform(.callHierarchy) }
    @objc private func contextCodeActions(_ sender: Any?) { perform(.codeActions) }
    @objc private func contextRename(_ sender: Any?) { perform(.rename) }
    @objc private func contextFormat(_ sender: Any?) { perform(.format) }
    @objc private func contextStageLines(_ sender: Any?) { perform(.stageSelectedLines) }
    @objc private func contextRevertLines(_ sender: Any?) { perform(.revertSelectedLines) }

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
            item("Go to Implementation", #selector(contextGoToImplementation), f12, .command,
                 enabled: client.supports(.implementation)),
            item("Find All References", #selector(contextFindReferences), f12, .shift,
                 enabled: client.supports(.references)),
            item("Show Call Hierarchy", #selector(contextCallHierarchy), "h", [.option, .shift],
                 enabled: client.supports(.callHierarchy)),
            item("Rename Symbol", #selector(contextRename), f2, enabled: client.supports(.rename)),
            item("Quick Fix & Refactor…", #selector(contextCodeActions), ".", .command, enabled: client.supports(.codeAction)),
            .separator(),
            item("Format Document", #selector(contextFormat), "f", [.shift, .option],
                 enabled: client.supports(.formatting)),
            .separator(),
        ]
    }

    /// Text changed without going through the text view (multi-edits, undo of those).
    func textDidChangeProgrammatically() {
        // Extra cursors don't follow edits made elsewhere (multi-cursor edits set them again after).
        extraSelections = []
        refreshAfterEdit()
        completion.dismiss()
        hover.dismiss()
    }

    /// Another editor (split view) changed the shared text.
    func refreshAfterEdit() {
        gutterView.updateWidth()
        gutterView.needsDisplay = true
        diagnosticsOverlay?.needsDisplay = true
        minimapView?.refresh(textChanged: true)
        stickyView?.update()
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
            },
            onStage: document.stageHunkAction.map { stage in
                { [weak popover] in
                    stage(hunk)
                    popover?.performClose(nil)
                }
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
        lightbulb.update() // a new problem on the cursor's line may have fixes
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    func reveal(_ range: NSRange) {
        guard textView != nil else { return } // no view yet
        document.unfold(containing: range)
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
        NotificationCenter.default.post(name: Self.didScrollNotification, object: self)
        lightbulb.viewportMoved()
        gutterView.needsDisplay = true
        minimapView?.refresh()
        stickyView?.update()
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
        var items = languageMenuItems()
        // In a git repository, with changes: stage what the selection touches.
        if document.stageHunkAction != nil, !document.diffHunks.isEmpty {
            let stage = NSMenuItem(title: "Stage Selected Lines", action: #selector(contextStageLines), keyEquivalent: "")
            stage.target = self
            let revert = NSMenuItem(title: "Revert Selected Lines", action: #selector(contextRevertLines), keyEquivalent: "")
            revert.target = self
            items += [stage, revert, .separator()]
        }
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: offset) }
        return menu
    }

    func textDidChange(_ notification: Notification) {
        hover.dismiss()
        clearExtraCursors() // an edit that bypassed the cursors (paste, completion): positions are stale
        // Highlighting is rescheduled by the document's edit observer.
        gutterView.updateWidth()
        gutterView.needsDisplay = true
        let typed = pendingTypedText
        pendingTypedText = nil
        completion.textDidChange(typed: typed)
        signatureHelp.textDidChange(typed: typed)
        minimapView?.refresh(textChanged: true)
        stickyView?.update()
        for other in document.editors where other !== self { other.refreshAfterEdit() }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        pendingTypedText = (replacementString?.isEmpty == false) ? replacementString : nil
        if let replacementString { document.pendingReplacement = (range, (replacementString as NSString).length) }
        return true
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if completion.handle(selector) { return true }
        if signatureHelp.handle(selector) { return true }
        if handleSnippetCommand(selector) { return true }
        if handleMultiCursorCommand(selector) { return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { return handleNewline() }
        if selector == #selector(NSResponder.deleteBackward(_:)) { return handleDeleteBackward() }
        if selector == #selector(NSResponder.complete(_:)) {
            completion.triggerManually()
            return true
        }
        return false
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        diagnosticsOverlay?.needsDisplay = true // extra cursors are drawn there
        snippetSelectionChanged()
        lightbulb.update()
        signatureHelp.selectionChanged()
        // The cursor went into folded lines (arrow keys, find): show them.
        if !document.folds.isEmpty { document.unfold(containing: textView.selectedRange()) }
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
    /// A plain click; returns true if handled (e.g. on a fold's "⋯").
    var onClick: ((NSPoint) -> Bool)?
    /// ⌥-click: add or remove a cursor at that character index.
    var onOptionClick: ((Int) -> Void)?
    /// Typed text; returns true if handled (several cursors).
    var onInsertText: ((String) -> Bool)?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String)
        if replacementRange.location == NSNotFound, !hasMarkedText(), let text, onInsertText?(text) == true { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .shift, .control]) == .option, event.clickCount == 1,
           let onOptionClick {
            onOptionClick(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
            return
        }
        if event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty,
           onClick?(convert(event.locationInWindow, from: nil)) == true { return }
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
    case goToDefinition, findReferences, rename, format, stageSelectedLines, revertSelectedLines
    case goToImplementation, callHierarchy, codeActions
}

extension Notification.Name {
    /// Posted by an editor with `userInfo["command"]` (an `EditorCommand` raw value).
    static let omcEditorCommand = Notification.Name("omcEditorCommand")
}
