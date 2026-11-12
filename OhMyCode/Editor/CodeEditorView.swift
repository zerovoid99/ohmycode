import AppKit
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
            self.refreshHighlights(force: true)
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

    @objc private func viewportDidScroll() {
        gutterView.needsDisplay = true
    }

    /// Applies syntax colors to the visible lines plus one screen of overscan above and below.
    /// Uses TextKit 2 rendering attributes: they only affect drawing, so the text storage
    /// isn't edited and no layout is invalidated.
    func refreshHighlights(force: Bool) {
        guard let highlighter = document.highlighter,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let visible = visibleCharacterRange() else { return }

        if !force, let highlightedRange,
           NSIntersectionRange(highlightedRange, visible) == visible { return }

        let lineIndex = document.lineIndex
        let firstLine = lineIndex.line(containing: visible.location)
        let lastLine = lineIndex.line(containing: NSMaxRange(visible))
        let overscan = max(lastLine - firstLine, 20)
        let startLine = max(0, firstLine - overscan)
        let endLine = lastLine + overscan + 1
        let length = document.textStorage.length
        let start = lineIndex.lineStarts[startLine]
        let end = endLine < lineIndex.lineCount ? lineIndex.lineStarts[endLine] : length
        let range = NSRange(location: start, length: end - start)

        guard let fullTextRange = textRange(for: range, in: contentManager) else { return }
        layoutManager.removeRenderingAttribute(.foregroundColor, for: fullTextRange)
        for highlight in highlighter.highlights(in: range) {
            let clipped = NSIntersectionRange(highlight.range, range)
            guard clipped.length > 0,
                  let color = EditorTheme.color(forCapture: highlight.name),
                  let textRange = textRange(for: clipped, in: contentManager) else { continue }
            layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        }
        highlightedRange = range
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
        gutterView.updateWidth()
        gutterView.needsDisplay = true
        refreshHighlights(force: true)
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
