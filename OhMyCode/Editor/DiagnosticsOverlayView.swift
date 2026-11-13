import AppKit

/// Draws squiggly underlines for diagnostics over the text view. TextKit 2 rendering attributes
/// don't draw underlines (colors work, underlines are ignored), so we draw them from the text
/// segment geometry ourselves. Also draws the "⋯" after folded lines. Transparent to mouse
/// events (the text view handles clicks on "⋯").
@MainActor
final class DiagnosticsOverlayView: NSView {
    private weak var textView: NSTextView?
    private let document: EditorDocument
    /// Placeholders for folded regions, in this view's (= the text view's) coordinates.
    var foldPlaceholders: (() -> [(rect: NSRect, header: Int)])?
    /// Extra cursors (multi-cursor): caret bars and selected text.
    var extraCursors: (() -> (carets: [NSRect], selections: [NSRect]))?

    init(textView: NSTextView, document: EditorDocument) {
        self.textView = textView
        self.document = document
        super.init(frame: textView.bounds)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Rects (in this view) of the text each diagnostic covers, with its color. Visible for tests.
    func segments() -> [(rect: CGRect, color: NSColor)] {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return [] }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -50)
        let length = document.textStorage.length
        var result: [(CGRect, NSColor)] = []

        for diagnostic in document.diagnostics {
            var range = document.range(for: diagnostic.range)
            if range.length == 0 { // point diagnostics: underline the character there
                range = NSRange(location: min(range.location, max(0, length - 1)), length: length > 0 ? 1 : 0)
            }
            guard range.length > 0,
                  let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
                  let end = contentManager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            let color = Self.color(for: diagnostic.severity)
            layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
                let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                if rect.intersects(visible) { result.append((rect, color)) }
                return true
            }
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = EditorTheme.current
        if let (carets, selections) = extraCursors?() {
            theme.selection.withAlphaComponent(0.55).setFill()
            for rect in selections where rect.intersects(dirtyRect) { rect.fill(using: .sourceOver) }
            theme.cursor.setFill()
            for rect in carets where rect.intersects(dirtyRect) { rect.fill() }
        }
        for (rect, _) in foldPlaceholders?() ?? [] where rect.intersects(dirtyRect) {
            let box = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            theme.lineNumber.withAlphaComponent(0.25).setFill()
            box.fill()
            let dots = "⋯" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: EditorTheme.font, .foregroundColor: theme.foreground]
            let size = dots.size(withAttributes: attributes)
            dots.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
        for (rect, color) in segments() where rect.intersects(dirtyRect.insetBy(dx: 0, dy: -4)) {
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.2
            let y = rect.maxY - 1.5
            var x = rect.minX
            path.move(to: NSPoint(x: x, y: y))
            var up = true
            while x < rect.maxX {
                x = min(x + 2, rect.maxX)
                path.line(to: NSPoint(x: x, y: up ? y - 2 : y))
                up.toggle()
            }
            path.stroke()
        }
    }

    static func color(for severity: Diagnostic.Severity) -> NSColor {
        switch severity {
        case .error: .systemRed
        case .warning: .systemYellow
        case .information, .hint: .systemBlue
        }
    }
}
