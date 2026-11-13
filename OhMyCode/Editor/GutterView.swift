import AppKit

/// Line-number gutter, placed beside the scroll view (simpler than `NSRulerView`, which on
/// current macOS overlays the clip view via content insets). Uses only TextKit 2 APIs (touching `NSTextView.layoutManager` would force a fallback
/// to TextKit 1) and draws just the line fragments in the visible rect.
@MainActor
final class GutterView: NSView {
    private weak var textView: NSTextView?
    private let document: EditorDocument
    private var digitCount = 0
    private(set) var width: CGFloat = 0

    /// Called when the width changes so the container can re-layout.
    var onWidthChange: (() -> Void)?
    /// Called with the zero-based line and its rect (in this view) when the gutter is clicked.
    var onLineClick: ((Int, NSRect) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inText = convert(point, to: textView)
        let origin = textView.textContainerOrigin
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: inText.y - origin.y)) else { return }
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        var line = document.lineIndex.line(containing: offset)
        // The last fragment can also hold the empty line after a trailing newline.
        let frame = fragment.layoutFragmentFrame
        for (i, lineFragment) in fragment.textLineFragments.enumerated()
        where inText.y - origin.y >= frame.minY + lineFragment.typographicBounds.minY {
            line = document.lineIndex.line(containing: offset) + i
        }
        let top = convert(NSPoint(x: 0, y: frame.minY + origin.y), from: textView).y
        onLineClick?(line, NSRect(x: 0, y: top, width: 8, height: frame.height))
    }

    init(textView: NSTextView, document: EditorDocument) {
        self.textView = textView
        self.document = document
        super.init(frame: .zero)
        clipsToBounds = true
        updateWidth()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// Font size or colors changed.
    func themeDidChange() {
        digitCount = 0 // re-measure with the new font
        updateWidth()
        needsDisplay = true
    }

    func updateWidth() {
        let digits = max(3, String(document.lineCount).count)
        guard digits != digitCount else { return }
        digitCount = digits
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: EditorTheme.gutterFont]).width
        width = ceil(digitWidth * CGFloat(digits)) + 20
        onWidthChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Since macOS 14 views don't clip to bounds by default and `dirtyRect` may extend past
        // them: filling it unclipped painted over the whole editor and hid all text.
        let theme = EditorTheme.current
        theme.background.setFill()
        dirtyRect.intersection(bounds).fill()

        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }

        let visibleRect = textView.visibleRect
        let containerOrigin = textView.textContainerOrigin
        let documentStart = contentManager.documentRange.location
        let currentLine = document.cursorLine - 1
        let gutterFont = EditorTheme.gutterFont

        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: gutterFont, .foregroundColor: theme.lineNumber,
        ]
        let currentAttributes: [NSAttributedString.Key: Any] = [
            .font: gutterFont, .foregroundColor: theme.currentLineNumber,
        ]

        // Read only what the text view's viewport pass already laid out, so drawing never
        // triggers text layout. The text view calls back after each layout pass, keeping
        // the gutter in sync.
        let viewport = layoutManager.textViewportLayoutController
        guard let viewportRange = viewport.viewportRange else { return }

        layoutManager.enumerateTextLayoutFragments(from: viewportRange.location, options: []) { fragment in
            if fragment.rangeInElement.location.compare(viewportRange.endLocation) == .orderedDescending { return false }
            guard fragment.state == .layoutAvailable else { return true }
            let fragmentFrame = fragment.layoutFragmentFrame
            if fragmentFrame.minY + containerOrigin.y > visibleRect.maxY { return false }
            if fragmentFrame.maxY + containerOrigin.y < visibleRect.minY { return true }

            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let firstLine = self.document.lineIndex.line(containing: offset)

            // Wrapping is off, so each fragment is one line, except the last one, which
            // also carries the empty "extra" line after a trailing newline.
            for (i, lineFragment) in fragment.textLineFragments.enumerated() {
                let line = firstLine + i
                let bounds = lineFragment.typographicBounds
                let yInTextView = fragmentFrame.minY + containerOrigin.y + bounds.minY
                let y = self.convert(NSPoint(x: 0, y: yInTextView), from: textView).y

                if let marker = self.document.diffMarkers[line] {
                    self.drawDiffMarker(marker, y: y, height: bounds.height)
                }

                let label = String(line + 1) as NSString
                let attributes = line == currentLine ? currentAttributes : normalAttributes
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: self.width - size.width - 10, y: y + (bounds.height - size.height) / 2),
                           withAttributes: attributes)
            }
            return true
        }
    }
}

extension GutterView {
    /// VS Code-style change bar at the gutter's left edge.
    fileprivate func drawDiffMarker(_ marker: DiffMarker, y: CGFloat, height: CGFloat) {
        switch marker {
        case .added:
            NSColor.systemGreen.setFill()
            NSRect(x: 2, y: y, width: 3, height: height).fill()
        case .modified:
            NSColor.systemBlue.setFill()
            NSRect(x: 2, y: y, width: 3, height: height).fill()
        case .deletedAbove:
            NSColor.systemRed.setFill()
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: 1, y: y - 4))
            triangle.line(to: NSPoint(x: 7, y: y))
            triangle.line(to: NSPoint(x: 1, y: y + 4))
            triangle.close()
            triangle.fill()
        }
    }
}

/// Gutter on the left, scroll view filling the rest.
@MainActor
final class EditorContainerView: NSView {
    let gutterView: GutterView
    let scrollView: NSScrollView

    init(gutterView: GutterView, scrollView: NSScrollView) {
        self.gutterView = gutterView
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(scrollView)
        addSubview(gutterView)
        gutterView.onWidthChange = { [weak self] in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let gutterWidth = gutterView.width
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
        gutterView.needsDisplay = true
    }
}
