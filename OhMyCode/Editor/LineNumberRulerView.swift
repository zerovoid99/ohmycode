import AppKit

/// Gutter with line numbers. Uses only TextKit 2 APIs (touching
/// `NSTextView.layoutManager` would force a slow fallback to TextKit 1) and
/// draws just the layout fragments in the visible rect.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let document: EditorDocument
    private var digitCount = 0

    init(textView: NSTextView, document: EditorDocument) {
        self.textView = textView
        self.document = document
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func updateThickness() {
        let digits = max(3, String(document.lineCount).count)
        guard digits != digitCount else { return }
        digitCount = digits
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: EditorTheme.gutterFont]).width
        ruleThickness = ceil(digitWidth * CGFloat(digits)) + 20
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        rect.fill()

        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }

        let visibleRect = textView.visibleRect
        let containerOrigin = textView.textContainerOrigin
        let documentStart = contentManager.documentRange.location
        let currentLine = document.cursorLine - 1

        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: EditorTheme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let currentAttributes: [NSAttributedString.Key: Any] = [
            .font: EditorTheme.gutterFont, .foregroundColor: NSColor.labelColor,
        ]

        let topPoint = CGPoint(x: 0, y: max(0, visibleRect.minY - containerOrigin.y))
        let startLocation = layoutManager.textLayoutFragment(for: topPoint)?.rangeInElement.location
            ?? documentStart

        layoutManager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
            let fragmentFrame = fragment.layoutFragmentFrame
            if fragmentFrame.minY + containerOrigin.y > visibleRect.maxY { return false }

            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let firstLine = self.document.lineIndex.line(containing: offset)

            // Wrapping is off, so each fragment is one line — except the last one, which
            // also carries the empty "extra" line after a trailing newline.
            for (i, lineFragment) in fragment.textLineFragments.enumerated() {
                let line = firstLine + i
                let bounds = lineFragment.typographicBounds
                let yInTextView = fragmentFrame.minY + containerOrigin.y + bounds.minY
                let y = self.convert(NSPoint(x: 0, y: yInTextView), from: textView).y

                let label = String(line + 1) as NSString
                let attributes = line == currentLine ? currentAttributes : normalAttributes
                let size = label.size(withAttributes: attributes)
                let baselineOffset = (bounds.height - size.height) / 2
                label.draw(at: NSPoint(x: self.ruleThickness - size.width - 10, y: y + baselineOffset),
                           withAttributes: attributes)
            }
            return true
        }
    }
}
