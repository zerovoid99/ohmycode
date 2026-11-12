import AppKit
import SwiftUI

/// SwiftUI wrapper around a TextKit 2 `NSTextView`. TextKit 2 lays out only the
/// visible viewport, so large files stay responsive.
struct CodeEditorView: NSViewRepresentable {
    let document: EditorDocument

    func makeCoordinator() -> EditorController {
        EditorController(document: document)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}

@MainActor
final class EditorController: NSObject {
    let document: EditorDocument
    private(set) var textView: NSTextView!
    private(set) var rulerView: LineNumberRulerView!
    // NSTextLayoutManager only holds its content manager weakly.
    private let textContentStorage = NSTextContentStorage()
    /// Range that currently has highlight colors applied; scrolling inside it is free.
    private var highlightedRange: NSRange?

    init(document: EditorDocument) {
        self.document = document
    }

    func makeScrollView() -> NSScrollView {
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

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize),
                                  textContainer: container)
        configure(textView)
        scrollView.documentView = textView
        self.textView = textView

        let ruler = LineNumberRulerView(textView: textView, document: document)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        self.rulerView = ruler

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportDidScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportDidScroll),
            name: NSView.frameDidChangeNotification, object: scrollView
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            textView.window?.makeFirstResponder(textView)
            self.refreshHighlights(force: true)
        }
        return scrollView
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
        rulerView.needsDisplay = true
        refreshHighlights(force: false)
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

    private func visibleCharacterRange() -> NSRange? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let documentRange = contentManager.documentRange
        let top = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visible.minY - origin.y)))
        let bottom = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visible.maxY - origin.y)))
        let startLocation = top?.rangeInElement.location ?? documentRange.location
        let endLocation = bottom?.rangeInElement.endLocation ?? documentRange.endLocation
        let start = contentManager.offset(from: documentRange.location, to: startLocation)
        let end = contentManager.offset(from: documentRange.location, to: endLocation)
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
        rulerView.updateThickness()
        rulerView.needsDisplay = true
        refreshHighlights(force: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        document.updateCursor(forSelectionAt: textView.selectedRange().location)
        rulerView.needsDisplay = true
    }
}
