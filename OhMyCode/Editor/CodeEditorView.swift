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
    /// The word wrap the view is laid out for (nil: not yet).
    var appliedWordWrap: Bool?
    /// Strings and comments in the highlighted text (brackets there don't match), for `nonCodeVersion`.
    var nonCodeRanges: [NSRange] = []
    var nonCodeVersion = -1
    /// The cursor's bracket pair as last looked for, with the cursor and text it was for: the
    /// overlay asks on every redraw, and a bracket without a match is a long walk.
    var bracketCache: (location: Int, version: Int, pair: (Int, Int)?)?
    /// The code lens under the mouse (underlined), by its rect.
    var hoveredCodeLens: NSRect?
    /// The link under the mouse while ⌘ is held (underlined).
    var hoveredLink: EditorLink?
    /// Where the symbol under the cursor appears.
    private(set) lazy var occurrences = OccurrenceHighlighter(editor: self)
    /// What the user just typed, captured before the change, for completion triggering.
    private var pendingTypedText: String?
    /// Range that currently has highlight colors applied; scrolling inside it is free.
    private(set) var highlightedRange: NSRange?
    /// The syntax colors given to TextKit, and the document edit they're in step with.
    private var appliedColors = AppliedColors()
    private var appliedColorsVersion = -1
    private var textElementTrimTask: Task<Void, Never>?
    /// The text changed: sticky scroll is updated after the next layout pass.
    private var stickyNeedsUpdate = false

    init(document: EditorDocument, group: EditorGroup? = nil) {
        self.document = document
        self.group = group
    }

    /// The document's content storage keeps its layout managers alive: detach ours, or a closed
    /// split would keep being laid out on every edit.
    /// The views are taken apart too: a view still in a superview when it goes is kept forever by
    /// AppKit (an observer `-[NSView _commonAwake]` registers captures it), and so is everything
    /// under it — our overlay, TextKit's line views with their drawn glyphs, the scroll pockets.
    isolated deinit {
        if let textLayoutManager { document.textContentStorage.removeTextLayoutManager(textLayoutManager) }
        textView?.removeAllSubviews()
    }

    func makeView() -> EditorContainerView {
        let textLayoutManager = NSTextLayoutManager()
        document.textContentStorage.addTextLayoutManager(textLayoutManager)
        self.textLayoutManager = textLayoutManager

        // The container always tracks the text view's width: one that's wider than its view
        // (the usual way to turn wrapping off) makes TextKit 2 update every paragraph after an
        // edit, which made typing in big files slow. Without word wrap the view is made as wide
        // as the widest line instead (see `updateTextWidth`).
        let container = NSTextContainer(size: NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
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
        textView.finder.client = textView
        textView.finder.findBarContainer = scrollView
        textView.finder.isIncrementalSearchingEnabled = true
        textView.finder.incrementalSearchingShouldDimContentView = true
        textView.onFinderReplace = { [weak self] edits in
            (try? self?.document.apply(edits, actionName: "Replace")) ?? false
        }

        let overlay = DiagnosticsOverlayView(textView: textView, document: document)
        textView.addSubview(overlay)
        diagnosticsOverlay = overlay
        overlay.codeLenses = { [weak self] in self?.codeLensMarks() ?? [] }
        overlay.hoveredCodeLens = { [weak self] in self?.hoveredCodeLens }
        overlay.whitespace = { [weak self] in self?.whitespaceMarks() ?? [] }
        overlay.indentGuides = { [weak self] in self?.indentGuideRects() ?? [] }
        overlay.brackets = { [weak self] in self?.bracketRects() ?? [] }
        overlay.linkUnderline = { [weak self] in self?.linkUnderlineRect() }
        overlay.occurrences = { [weak self] in self?.occurrenceRects() ?? [] }
        overlay.foldPlaceholders = { [weak self] in self?.foldPlaceholderRects() ?? [] }
        overlay.extraCursors = { [weak self] in self?.extraCursorShapes() ?? ([], []) }
        overlay.blameAnnotation = { [weak self] in self?.blameAnnotation() }
        overlay.executionLine = { [weak self] in self?.executionLineRect() }
        overlay.inlayHints = { [weak self] in self?.inlayHintRects() ?? [] }
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
        textView.onCommandKey = { [weak self] event in self?.handleLineCommandKey(event) ?? false }
        textView.onCommandClickAt = { [weak self] point in self?.followLink(at: point) ?? false }
        textView.onFlagsChanged = { [weak self] point, modifiers in self?.updateLinkHover(at: point, modifiers: modifiers) }
        textView.onMouseMoved = { [weak self] point in
            guard let self else { return }
            self.updateLinkHover(at: point, modifiers: NSEvent.modifierFlags)
            let lens = self.codeLens(at: point)
            if lens?.rect != self.hoveredCodeLens {
                self.hoveredCodeLens = lens?.rect
                self.diagnosticsOverlay?.needsDisplay = true
            }
            if lens != nil { NSCursor.pointingHand.set(); self.hover.dismiss(); return }
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
            if self?.handleCodeLensClick(at: point) == true { return true }
            if self?.handleBlameClick(at: point) == true { return true }
            guard let self, let hit = self.foldPlaceholderRects().first(where: { $0.rect.contains(point) }) else { return false }
            self.document.unfold(atHeader: hit.header)
            return true
        }
        textView.onMouseExited = { [weak self] in
            self?.hover.mouseExited()
            self?.blameHover.mouseExited()
            self?.updateLinkHover(at: nil, modifiers: [])
        }
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
            if self?.stickyNeedsUpdate == true {
                self?.stickyNeedsUpdate = false
                self?.stickyView?.update()
            }
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
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewDidResize),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)
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
        textView.isAutomaticTextCompletionEnabled = false // the Touch Bar's word suggestions (code has its own)
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 4, height: 6)

        // The width is set by `updateTextWidth` (the widest line, or the view without wrap).
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.height]
    }

    // MARK: Theme and font

    @objc private func settingsDidChange() { projectSettingsChanged() }

    /// The app's settings or the folder's (.omc/settings.json) changed.
    func projectSettingsChanged() {
        document.refreshInlayHints() // turned on or off, or the font changed
        document.refreshSemanticTokens()
        document.refreshCodeLenses()
        occurrences.update()
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

        applyWordWrap()
        updateTextWidth() // the font's width changed
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
        // Only the folds whose header is laid out: asking TextKit where every fold in the file
        // is lays out a line at each one, on every redraw (40 ms with 230 folds), and leaves it
        // with that many more text elements to move on every edit.
        guard !document.folds.isEmpty, let viewport = visibleCharacterRange() else { return [] }
        let folds = document.folds
        // A fold starts right after its header's newline.
        var index = FoldRanges.firstIndex(in: folds, startingAtOrAfter: viewport.location)
        while index < folds.count, folds[index].location - 1 <= NSMaxRange(viewport) {
            let fold = folds[index]
            index += 1
            let header = document.lineIndex.line(containing: fold.location) - 1
            guard header >= 0, !document.isHidden(document.lineIndex.lineStarts[header]) else { continue }
            let lineEnd = fold.location - 1 // the header's newline
            guard lineEnd > document.lineIndex.lineStarts[header] || lineEnd == document.lineIndex.lineStarts[header],
                  let last = laidOutRect(ofCharacterAt: max(document.lineIndex.lineStarts[header], lineEnd - 1))
                    ?? rect(for: NSRange(location: max(document.lineIndex.lineStarts[header], lineEnd - 1), length: 1))
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

    /// Height of one line (one row of a wrapped line).
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
        guard wrapsLines, let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager,
              let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, textView.visibleRect.maxY - textView.textContainerOrigin.y - 1)))
        else { return max(1, Int(textView.visibleRect.height / max(1, lineHeight))) }
        // Wrapped lines are taller: count the lines from the top one to the bottom one.
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        return max(1, document.lineIndex.line(containing: offset) - topVisibleLine + 1)
    }

    /// Scrolls so `line` (zero-based) is the first visible line.
    func scrollLineToTop(_ line: Int) {
        guard let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager else { return }
        let index = document.lineIndex
        let offset = index.lineStarts[min(max(0, line), index.lineCount - 1)]
        guard let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset) else { return }
        // Heights above the line may be estimates (wrapped lines): laying out the new viewport
        // corrects them and moves the line, so measure again until it stays put.
        for _ in 0..<4 {
            var y: CGFloat = 0
            layoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
                y = fragment.layoutFragmentFrame.minY
                return false
            }
            let target = y + textView.textContainerOrigin.y
            if abs(textView.visibleRect.minY - target) < 0.5 { break }
            textView.scroll(NSPoint(x: textView.visibleRect.minX, y: target))
            layoutManager.textViewportLayoutController.layoutViewport()
        }
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
    @objc private func contextFormatSelection(_ sender: Any?) { perform(.formatSelection) }
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
            item("Format Selection", #selector(contextFormatSelection), enabled: client.supports(.rangeFormatting)),
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
        occurrences.update()
        gutterView.updateWidth()
        gutterView.needsDisplay = true
        diagnosticsOverlay?.needsDisplay = true
        minimapView?.refresh(textChanged: true)
        updateStickyAfterLayout()
    }

    /// Sticky scroll follows the line at the top of the view, which isn't known until the
    /// edited text is laid out again: asked right after a big edit (pasting over all of a
    /// 5 MB file, undoing a paste), TextKit had to estimate where that line is from the start
    /// of the text, through every paragraph: 300 ms.
    private func updateStickyAfterLayout() {
        guard stickyView != nil else { return }
        stickyNeedsUpdate = true
        textView.needsLayout = true
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

    /// Where the character at `offset` is, read from its line as laid out (nil if it isn't):
    /// what `rect(for:)` gives for one character, without its layout pass. That pass looks
    /// for the line after it too, and after a fold's header that's through every hidden line
    /// (the "⋯" of 17 folds in view took 1.6 ms a redraw).
    func laidOutRect(ofCharacterAt offset: Int) -> NSRect? {
        guard let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager,
              offset < document.textStorage.length else { return nil }
        let documentStart = contentManager.documentRange.location
        guard let location = contentManager.location(documentStart, offsetBy: offset),
              let fragment = layoutManager.textLayoutFragment(for: location),
              let elementStart = fragment.textElement?.elementRange?.location else { return nil }
        let index = offset - contentManager.offset(from: documentStart, to: elementStart)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(index, $0.characterRange) }) else { return nil }
        let start = line.locationForCharacter(at: index).x
        let end = line.locationForCharacter(at: index + 1).x
        let frame = fragment.layoutFragmentFrame
        let bounds = line.typographicBounds
        let origin = textView.textContainerOrigin
        return NSRect(x: frame.minX + bounds.minX + min(start, end) + origin.x, y: frame.minY + bounds.minY + origin.y,
                      width: abs(end - start), height: bounds.height)
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

    /// The editor got wider or narrower: the text view follows (see `updateTextWidth`).
    @objc private func clipViewDidResize() { updateTextWidth() }

    @objc private func viewportDidScroll() {
        NotificationCenter.default.post(name: Self.didScrollNotification, object: self)
        lightbulb.viewportMoved()
        gutterView.needsDisplay = true
        minimapView?.refresh()
        stickyView?.update()
        scheduleTextElementTrim()
    }

    /// How long after the last scroll the text elements left behind are dropped.
    nonisolated(unsafe) static var textElementTrimDelay: Duration = .seconds(1)

    /// Once scrolling has stopped: has the document drop the text elements TextKit made at the
    /// places the viewport passed (see `EditorDocument.trimTextElements`).
    private func scheduleTextElementTrim() {
        textElementTrimTask?.cancel()
        textElementTrimTask = Task { [weak self] in
            try? await Task.sleep(for: Self.textElementTrimDelay)
            guard !Task.isCancelled, let self else { return }
            self.document.trimTextElements()
        }
    }

    /// The text this editor needs its text elements for: what's laid out, with the lines around
    /// it that have their syntax colors (those are rendering attributes of the laid-out text).
    var textRangeInUse: NSRange? {
        guard textView != nil, !textView.hasMarkedText(), var range = highlightRange else { return nil }
        if let highlightedRange { range = NSUnionRange(range, highlightedRange) }
        if let visible = visibleCharacterRange() { range = NSUnionRange(range, visible) }
        return NSIntersectionRange(range, NSRange(location: 0, length: document.textStorage.length))
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
    func visibleCharacterRange() -> NSRange? {
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
        var items = linkMenuItems(at: charIndex) + languageMenuItems()
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
        hoveredLink = nil
        clearExtraCursors() // an edit that bypassed the cursors (paste, completion): positions are stale
        // Highlighting is rescheduled by the document's edit observer.
        gutterView.updateWidth()
        gutterView.needsDisplay = true
        let typed = pendingTypedText
        pendingTypedText = nil
        completion.textDidChange(typed: typed)
        signatureHelp.textDidChange(typed: typed)
        minimapView?.refresh(textChanged: true)
        updateStickyAfterLayout()
        for other in document.editors where other !== self { other.refreshAfterEdit() }
    }

    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        strippingInlayHint(newTypingAttributes)
    }

    /// The text is about to change. The find bar searches it on a background thread: a change
    /// it wasn't told about first crashed there (reading the string as it moved).
    func textWillChange() {
        textView?.finder.noteClientStringWillChange()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        textWillChange()
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
        if selector == #selector(NSResponder.deleteBackward(_:)) { return handleLinkedDelete(forward: false) || handleDeleteBackward() }
        if selector == #selector(NSResponder.deleteForward(_:)), handleLinkedDelete(forward: true) { return true }
        // Esc with nothing else to dismiss: twice leaves zen mode.
        if selector == #selector(NSResponder.cancelOperation(_:)), document.workspace?.zenEscape() == true { return true }
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
        occurrences.update()
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
final class CodeTextView: NSTextView, @preconcurrency NSTextFinderClient {
    /// The find bar's finder: the editor's own, not the text view's built-in one, which only
    /// hears of changes made through the text view. Edits made straight to the text storage
    /// (Replace in Files, rename, formatting, a reload) have to announce themselves too, and
    /// there's no way to reach the built-in one for that (see `EditorController.textWillChange`).
    let finder = NSTextFinder()

    override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? (sender as? NSControl)?.tag,
              let action = NSTextFinder.Action(rawValue: tag), finder.validateAction(action) else { return }
        finder.performAction(action)
    }

    /// The older action (same tags): not to the built-in finder either.
    override func performFindPanelAction(_ sender: Any?) {
        performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)) || item.action == #selector(performFindPanelAction(_:)) {
            return NSTextFinder.Action(rawValue: item.tag).map(finder.validateAction) ?? false
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Makes the find bar's replacements (Replace, Replace All) as one edit; returns false when
    /// nothing changed.
    var onFinderReplace: (([TextReplacement]) -> Bool)?
    private var finderReplaced = false

    /// The find bar is about to replace these. `NSTextView` answers by working out the text
    /// after the change, moving the rest of a copy of it for every replacement (61,000 in
    /// 20 MB: 24 s); here they're made at once, through the document, and the calls to
    /// `replaceCharacters(in:with:)` that follow a yes have nothing left to do.
    func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
        guard isEditable, ranges.count == strings.count, let onFinderReplace else { return false }
        finderReplaced = onFinderReplace(zip(ranges, strings).map { TextReplacement(range: $0.rangeValue, text: $1) })
        // `didReplaceCharacters` ends it; should that not come, it doesn't outlive this event.
        if finderReplaced { DispatchQueue.main.async { [weak self] in self?.finderReplaced = false } }
        return finderReplaced
    }

    override func replaceCharacters(in range: NSRange, with string: String) {
        if finderReplaced { return }
        super.replaceCharacters(in: range, with: string)
    }

    func didReplaceCharacters() {
        finderReplaced = false
    }

    /// The text the text checker asks for after every layout pass: all the viewport's
    /// characters, folded ones too (with everything folded, a fifth of what a keystroke cost),
    /// though with nothing checked as one types there's nothing to do with it. The text view
    /// answers it as an `NSTextCheckingClient`, a conformance Swift doesn't see: this takes
    /// its place by selector and hands it on when something is being checked.
    @objc(annotatedSubstringForProposedRange:actualRange:)
    func annotatedSubstringForChecking(proposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        if isContinuousSpellCheckingEnabled || isGrammarCheckingEnabled || isAutomaticSpellingCorrectionEnabled
            || isAutomaticTextReplacementEnabled || isAutomaticQuoteSubstitutionEnabled || isAutomaticDashSubstitutionEnabled
            || isAutomaticLinkDetectionEnabled || isAutomaticDataDetectionEnabled || isAutomaticTextCompletionEnabled,
            let implementation = Self.textViewAnnotatedSubstring {
            return implementation(self, #selector(annotatedSubstringForChecking(proposedRange:actualRange:)), range, actualRange)
        }
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
        return nil
    }

    private typealias AnnotatedSubstring = @convention(c) (NSTextView, Selector, NSRange, NSRangePointer?) -> NSAttributedString?
    private static let textViewAnnotatedSubstring: AnnotatedSubstring? = {
        let selector = #selector(annotatedSubstringForChecking(proposedRange:actualRange:))
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: AnnotatedSubstring.self)
    }()

    var onLayout: (() -> Void)?
    var onCommandClick: (() -> Void)?
    var onResignFocus: (() -> Void)?
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onKeyDown: (() -> Void)?
    /// ⌘-click; returns true if handled (a link), before Go to Definition.
    var onCommandClickAt: ((NSPoint) -> Bool)?
    /// Modifier keys changed, with the mouse's point in the view (nil: outside it).
    var onFlagsChanged: ((NSPoint?, NSEvent.ModifierFlags) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        onFlagsChanged?(visibleRect.contains(point) ? point : nil, event.modifierFlags)
    }

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

    /// A key press bound to an editor command (line commands); returns true if handled.
    var onCommandKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        onKeyDown?()
        if onCommandKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// ⌘ keys reach views before the menus: the editor's own commands go first while it's focused.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, onCommandKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
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
        if event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command, onCommandClickAt?(point) == true { return }
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        onCommandClick()
    }

    override func layout() {
        super.layout()
        LaunchTrace.mark("editor.firstLayout")
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

    /// The document's text changed (`start..<oldEnd` replaced by `newLength` characters):
    /// TextKit moved the colors after it, and the edited text has none it can be sure of.
    func syntaxColorsEdited(start: Int, oldEnd: Int, newLength: Int) {
        if appliedColorsVersion == document.editVersion - 1 {
            appliedColors.edit(start: start, oldEnd: oldEnd, newLength: newLength)
            appliedColorsVersion = document.editVersion
        } else {
            appliedColors.reset()
        }
    }

    /// Applied as TextKit 2 rendering attributes: they only affect drawing, so the text storage
    /// isn't edited and no layout is invalidated. Only the characters whose color differs from
    /// what was applied before are given to TextKit (see `AppliedColors`).
    func applyHighlights(_ highlights: [NamedRange], in range: NSRange) {
        let signpost = Signposts.begin("applyHighlights"); defer { Signposts.end("applyHighlights", signpost) }
        LaunchTrace.mark("highlight.first")
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              NSMaxRange(range) <= document.textStorage.length else { return }
        if appliedColorsVersion != document.editVersion || appliedColors.palette.count > 200 { appliedColors.reset() }
        // Each character's color: later captures over earlier ones, the server's over both.
        var colors = [AppliedColors.Index](repeating: AppliedColors.none, count: range.length)
        var byCapture: [String: AppliedColors.Index] = [:]
        colors.withUnsafeMutableBufferPointer { colors in
            func paint(_ target: NSRange, _ index: AppliedColors.Index) {
                let clipped = NSIntersectionRange(target, range)
                guard clipped.length > 0 else { return }
                let start = clipped.location - range.location
                colors[start..<start + clipped.length].update(repeating: index)
            }
            for highlight in highlights {
                let index: AppliedColors.Index
                if let known = byCapture[highlight.name] {
                    index = known
                } else {
                    index = EditorTheme.color(forCapture: highlight.name).flatMap { appliedColors.index(of: $0) } ?? AppliedColors.none
                    byCapture[highlight.name] = index
                }
                if index != AppliedColors.none { paint(highlight.range, index) }
            }
            semanticColors(in: range) { target, color in
                if let index = appliedColors.index(of: color) { paint(target, index) }
            }
        }
        for span in appliedColors.update(to: colors, in: range) {
            if span.remove, let textRange = textRange(for: span.range, in: contentManager) {
                layoutManager.removeRenderingAttribute(.foregroundColor, for: textRange)
            }
            // Each run of one color in it.
            var start = span.range.location
            while start < NSMaxRange(span.range) {
                let index = colors[start - range.location]
                var end = start + 1
                while end < NSMaxRange(span.range), colors[end - range.location] == index { end += 1 }
                if let color = appliedColors.color(index),
                   let textRange = textRange(for: NSRange(location: start, length: end - start), in: contentManager) {
                    layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
                }
                start = end
            }
        }
        appliedColorsVersion = document.editVersion
        highlightedRange = range
        rememberNonCode(highlights)
        diagnosticsOverlay?.needsDisplay = true // brackets in strings stop matching
    }
}

/// Language actions an editor asks its workspace to run (⌘-click, context menu).
enum EditorCommand: String {
    case goToDefinition, findReferences, rename, format, formatSelection, stageSelectedLines, revertSelectedLines
    case goToImplementation, callHierarchy, codeActions
}

extension Notification.Name {
    /// Posted by an editor with `userInfo["command"]` (an `EditorCommand` raw value).
    static let omcEditorCommand = Notification.Name("omcEditorCommand")
}
