import AppKit
import SwiftTreeSitter
import SwiftUI

/// SwiftUI wrapper around a TextKit 2 `NSTextView`. TextKit 2 lays out only the
/// visible viewport, so large files stay responsive.
struct CodeEditorView: NSViewRepresentable {
    let document: EditorDocument

    func makeCoordinator() -> EditorController {
        EditorController(document: document)
    }

    func makeNSView(context: Context) -> EditorContainerView {
        context.coordinator.makeView()
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
    // NSTextLayoutManager only holds its content manager weakly.
    private let textContentStorage = NSTextContentStorage()
    /// Range that currently has highlight colors applied; scrolling inside it is free.
    private var highlightedRange: NSRange?

    init(document: EditorDocument) {
        self.document = document
    }

    func makeView() -> EditorContainerView {
        let textLayoutManager = NSTextLayoutManager()
        textContentStorage.addTextLayoutManager(textLayoutManager)
        textContentStorage.textStorage = document.textStorage

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

        let gutter = GutterView(textView: textView, document: document)
        self.gutterView = gutter
        textView.onLayout = { [weak self, weak gutter] in
            gutter?.needsDisplay = true
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
            textView.window?.makeFirstResponder(textView)
            self.restoreViewState()
            self.document.editor = self
            self.document.highlighter?.client = self
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
        document.viewState = EditorViewState(topLineOffset: offset, topLineDelta: delta,
                                             scrollX: visible.minX, selection: textView.selectedRange())
    }

    func restoreViewState() {
        guard let state = document.viewState,
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
        highlighter.requestHighlights()
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

    func textDidChange(_ notification: Notification) {
        // Highlighting is rescheduled by the document's edit observer.
        gutterView.updateWidth()
        gutterView.needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        document.updateCursor(forSelectionAt: textView.selectedRange().location)
        gutterView.needsDisplay = true
    }
}

/// `NSTextView` that reports each layout pass (TextKit 2 lays out its viewport in `layout()`),
/// so the gutter and syntax colors can follow the freshly laid-out viewport.
final class CodeTextView: NSTextView {
    var onLayout: (() -> Void)?

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
