import AppKit
import SwiftTreeSitter

/// Keeps the header lines of the declarations enclosing the top of the viewport (class, func,
/// …) pinned above the text, found from the tree-sitter tree in the background.
@MainActor
final class StickyScrollView: NSView {
    static let maxLines = 5

    private weak var editor: EditorController?
    /// Header lines shown, outermost first (zero-based).
    private(set) var lines: [Int] = []
    private var highlights: [Int: [NamedRange]] = [:]
    private var task: Task<Void, Never>?
    /// Line height used for the current frame.
    private(set) var rowHeight: CGFloat = 0
    var onHeightChange: (() -> Void)?

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    var height: CGFloat { CGFloat(lines.count) * rowHeight }

    /// Recomputes after scrolling or editing; the result arrives asynchronously.
    func update() {
        task?.cancel()
        guard AppSettings.shared.stickyScroll, let editor, let highlighter = editor.document.highlighter else {
            set([], highlights: [:])
            return
        }
        let document = editor.document
        let index = document.lineIndex
        let top = editor.topVisibleLine
        task = Task { [weak self] in
            func scopes(_ line: Int) async -> [Int] {
                let line = min(line, index.lineCount - 1)
                return Array(await highlighter.enclosingScopeLines(line: line, lineStart: index.lineStarts[line])
                    .suffix(Self.maxLines))
            }
            // The pinned lines cover the first lines of the viewport, so what matters is the
            // first line readable below them.
            var rows = await scopes(top)
            if !rows.isEmpty { rows = await scopes(top + rows.count) }
            guard !Task.isCancelled, let self else { return }
            var colors: [Int: [NamedRange]] = [:]
            for row in rows where row < document.lineIndex.lineCount {
                colors[row] = await highlighter.currentHighlights(in: self.range(ofLine: row, in: document))
            }
            guard !Task.isCancelled else { return }
            self.set(rows, highlights: colors)
        }
    }

    /// Waits for the pending update (tests).
    func waitUntilUpdated() async { await task?.value }

    private func set(_ rows: [Int], highlights: [Int: [NamedRange]]) {
        let height = editor?.lineHeight ?? 0
        let changed = rows != lines || height != rowHeight
        lines = rows
        self.highlights = highlights
        rowHeight = height
        if changed { onHeightChange?() }
        needsDisplay = true
    }

    private func range(ofLine line: Int, in document: EditorDocument) -> NSRange {
        let index = document.lineIndex
        let start = index.lineStarts[line]
        let end = line + 1 < index.lineCount ? index.lineStarts[line + 1] - 1 : document.textStorage.length
        return NSRange(location: start, length: max(0, min(end - start, 400)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let editor, let textView = editor.textView else { return }
        let theme = EditorTheme.current
        theme.background.setFill()
        dirtyRect.intersection(bounds).fill()
        let document = editor.document
        let gutterWidth = editor.gutterView.width
        let text = document.textStorage.mutableString
        let gutterFont = EditorTheme.gutterFont
        let textX = gutterWidth + textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
            - textView.visibleRect.minX

        for (i, line) in lines.enumerated() where line < document.lineIndex.lineCount {
            let y = CGFloat(i) * rowHeight
            let number = String(line + 1) as NSString
            let numberAttributes: [NSAttributedString.Key: Any] = [.font: gutterFont, .foregroundColor: theme.lineNumber]
            let numberSize = number.size(withAttributes: numberAttributes)
            number.draw(at: NSPoint(x: gutterWidth - numberSize.width - 10, y: y + (rowHeight - numberSize.height) / 2),
                        withAttributes: numberAttributes)

            let range = range(ofLine: line, in: document)
            let attributed = NSMutableAttributedString(string: text.substring(with: range), attributes: EditorTheme.baseAttributes)
            for highlight in highlights[line] ?? [] {
                let clipped = NSIntersectionRange(highlight.range, range)
                guard clipped.length > 0, let color = EditorTheme.color(forCapture: highlight.name) else { continue }
                attributed.addAttribute(.foregroundColor, value: color,
                                        range: NSRange(location: clipped.location - range.location, length: clipped.length))
            }
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: gutterWidth, y: y, width: bounds.width - gutterWidth, height: rowHeight).clip()
            attributed.draw(at: NSPoint(x: textX, y: y + (rowHeight - attributed.size().height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        // Separator from the scrolling text.
        theme.lineNumber.withAlphaComponent(0.35).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    /// Clicking a sticky line jumps to it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard rowHeight > 0 else { return }
        let index = Int(point.y / rowHeight)
        guard lines.indices.contains(index), let editor else { return }
        editor.reveal(line: lines[index])
    }
}

/// A zoomed-out picture of the document beside the editor: each character a 1×2 pt block in
/// its syntax color, with the visible region shown as a slider. Click or drag to scroll.
@MainActor
final class MinimapView: NSView, SyntaxHighlighterClient {
    static let width: CGFloat = 90
    static let lineHeight: CGFloat = 2
    static let charWidth: CGFloat = 1

    private weak var editor: EditorController?
    private var highlights: [NamedRange] = []
    private var highlightedRange: NSRange?

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Lines the minimap has room for.
    private var capacity: Int { max(1, Int(bounds.height / Self.lineHeight)) }

    /// First document line drawn: when the document is taller than the minimap, the minimap
    /// scrolls in proportion to the editor.
    var firstLine: Int {
        guard let editor, let textView = editor.textView else { return 0 }
        let lineCount = editor.document.lineIndex.lineCount
        guard lineCount > capacity else { return 0 }
        let visible = textView.visibleRect
        let scrollable = max(1, textView.frame.height - visible.height)
        let fraction = min(1, max(0, visible.minY / scrollable))
        return Int((CGFloat(lineCount - capacity) * fraction).rounded())
    }

    // MARK: SyntaxHighlighterClient

    var highlightRange: NSRange? {
        guard let editor, !isHidden, bounds.height > 0 else { return nil }
        let index = editor.document.lineIndex
        let first = firstLine
        let last = min(index.lineCount, first + capacity)
        let start = index.lineStarts[first]
        let end = last < index.lineCount ? index.lineStarts[last] : editor.document.textStorage.length
        return NSRange(location: start, length: end - start)
    }

    func applyHighlights(_ highlights: [NamedRange], in range: NSRange) {
        self.highlights = highlights
        highlightedRange = range
        needsDisplay = true
    }

    /// After scrolling or editing: redraw, and ask for colors if the drawn lines moved past them.
    func refresh(textChanged: Bool = false) {
        guard !isHidden, let editor else { return }
        needsDisplay = true
        if textChanged { return } // the highlighter re-requests for all clients after edits
        if let highlightedRange, let wanted = highlightRange,
           NSIntersectionRange(highlightedRange, wanted) == wanted { return }
        editor.document.highlighter?.requestHighlights(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let theme = EditorTheme.current
        context.setFillColor(theme.background.cgColor)
        context.fill(bounds)
        if let image = renderImage(scale: window?.backingScaleFactor ?? 2) {
            context.saveGState()
            // The image's rows run top-down; this view is flipped.
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(origin: .zero, size: bounds.size))
            context.restoreGState()
        }
        context.setFillColor(theme.foreground.withAlphaComponent(isDragging ? 0.2 : 0.1).cgColor)
        context.fill(sliderRect)
    }

    /// The minimap as pixels, written directly into a buffer: thousands of tiny fills through
    /// CoreGraphics would cost several milliseconds per frame on a large file.
    func renderImage(scale: CGFloat) -> CGImage? {
        guard let editor, let region = highlightRange else { return nil }
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }
        let theme = EditorTheme.current
        let appearance = theme.appearance ?? effectiveAppearance
        var background = 0 as UInt32, plain = 0 as UInt32
        appearance.performAsCurrentDrawingAppearance {
            background = Self.pixel(theme.background)
            plain = Self.pixel(theme.foreground.withAlphaComponent(0.55), over: theme.background)
        }

        // Color per character of the drawn region: plain text, then highlights (later wins).
        var colors = [UInt32](repeating: plain, count: region.length)
        if let highlightedRange, NSIntersectionRange(highlightedRange, region).length > 0 {
            var resolved: [String: UInt32?] = [:]
            appearance.performAsCurrentDrawingAppearance {
                for highlight in highlights {
                    let clipped = NSIntersectionRange(highlight.range, region)
                    guard clipped.length > 0 else { continue }
                    let color: UInt32?
                    if let cached = resolved[highlight.name] {
                        color = cached
                    } else {
                        color = EditorTheme.color(forCapture: highlight.name).map {
                            Self.pixel($0.withAlphaComponent(0.85), over: theme.background)
                        }
                        resolved[highlight.name] = color
                    }
                    guard let color else { continue }
                    let start = clipped.location - region.location
                    for i in start..<(start + clipped.length) { colors[i] = color }
                }
            }
        }

        var pixels = [UInt32](repeating: background, count: width * height)
        let document = editor.document
        let text = document.textStorage.mutableString
        let index = document.lineIndex
        let charPixels = max(1, Int((Self.charWidth * scale).rounded()))
        let linePixels = max(1, Int((Self.lineHeight * scale).rounded()))
        let inkPixels = max(1, linePixels * 3 / 4)
        let maxColumns = width / charPixels
        var buffer = [unichar](repeating: 0, count: 512)
        let first = firstLine
        pixels.withUnsafeMutableBufferPointer { out in
            for line in first..<min(index.lineCount, first + capacity) {
                let start = index.lineStarts[line]
                let end = line + 1 < index.lineCount ? index.lineStarts[line + 1] - 1 : text.length
                let length = min(end - start, buffer.count)
                guard length > 0 else { continue }
                text.getCharacters(&buffer, range: NSRange(location: start, length: length))
                let top = (line - first) * linePixels
                var column = 0
                for i in 0..<length where column < maxColumns {
                    let unit = buffer[i]
                    if unit == 0x20 { column += 1; continue }
                    if unit == 0x09 { column += 4; continue }
                    if unit == 0x0D { continue }
                    let offset = start + i - region.location
                    let color = offset >= 0 && offset < colors.count ? colors[offset] : plain
                    let x0 = column * charPixels
                    for y in top..<min(height, top + inkPixels) {
                        let row = y * width
                        for x in x0..<min(width, x0 + charPixels) { out[row + x] = color }
                    }
                    column += 1
                }
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// An opaque BGRA pixel (little-endian xRGB), `color` blended over `background`.
    private static func pixel(_ color: NSColor, over background: NSColor? = nil) -> UInt32 {
        let c = color.usingColorSpace(.sRGB) ?? .black
        let b = background?.usingColorSpace(.sRGB) ?? c
        let a = background == nil ? 1 : c.alphaComponent
        func channel(_ top: CGFloat, _ bottom: CGFloat) -> UInt32 { UInt32(((top * a + bottom * (1 - a)) * 255).rounded()) }
        return 0xFF00_0000 | channel(c.redComponent, b.redComponent) << 16
            | channel(c.greenComponent, b.greenComponent) << 8 | channel(c.blueComponent, b.blueComponent)
    }

    var sliderRect: CGRect {
        guard let editor else { return .zero }
        let top = CGFloat(editor.topVisibleLine - firstLine) * Self.lineHeight
        return CGRect(x: 0, y: top, width: bounds.width, height: CGFloat(editor.visibleLineCount) * Self.lineHeight)
    }

    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        scroll(to: event)
    }

    override func mouseDragged(with event: NSEvent) { scroll(to: event) }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        needsDisplay = true
    }

    /// Centers the editor on the line under the pointer.
    private func scroll(to event: NSEvent) {
        guard let editor else { return }
        let y = convert(event.locationInWindow, from: nil).y
        let line = firstLine + Int(y / Self.lineHeight) - editor.visibleLineCount / 2
        editor.scrollLineToTop(max(0, min(line, editor.document.lineIndex.lineCount - 1)))
    }
}
