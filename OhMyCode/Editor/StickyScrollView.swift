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
        // Only the starts of the lines the task may ask about, not the line index: a task holding
        // the index made the next keystroke copy all of its line starts.
        let index = document.lineIndex
        let top = max(0, min(editor.topVisibleLine, index.lineCount - 1))
        let starts = Array(index.lineStarts[top..<min(top + Self.maxLines + 1, index.lineCount)])
        task = Task { [weak self] in
            func scopes(_ line: Int) async -> [Int] {
                let offset = min(line - top, starts.count - 1)
                return Array(await highlighter.enclosingScopeLines(line: top + offset, lineStart: starts[offset])
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
///
/// The picture is a pixel buffer kept from frame to frame and shown as a layer's contents. A
/// frame paints only the lines that changed (edited, scrolled in, or recolored by a new
/// highlight result) and copies the others' rows to where their lines are now. The slider is a
/// layer of its own: moving it paints nothing.
@MainActor
final class MinimapView: NSView, SyntaxHighlighterClient {
    static let width: CGFloat = 90
    static let lineHeight: CGFloat = 2
    static let charWidth: CGFloat = 1
    /// Characters of a line read for its row (90 pt holds 90 columns).
    private static let maxUnits = 512

    private weak var editor: EditorController?
    private var highlights: [NamedRange] = []
    private var highlightedRange: NSRange?
    /// The range asked for and not received yet (layout and scrolling both refresh, before
    /// the first ask's colors arrive).
    private var requestedRange: NSRange?

    /// What the picture is painted for: its size in pixels, and the colors it uses.
    private struct Canvas: Equatable {
        var width = 0, height = 0, charPixels = 1, linePixels = 1
        var generation = 0
        var appearance: NSAppearance.Name?
    }
    private var canvas = Canvas()
    private var background: UInt32 = 0, plain: UInt32 = 0
    /// The color of each character of `highlightedRange` (0: plain), resolved once per result.
    private var colors: [UInt32] = []
    private var colorsAreStale = true
    private var captureColors: [String: UInt32] = [:]
    /// The picture, `canvas.width` pixels a row, `linePixels` rows a line, and a spare to paint
    /// the next frame into.
    private var pixels: [UInt32] = [], spare: [UInt32] = []
    /// For each line in the picture, a hash of the colors it was painted with (nil: blank).
    private var lineColors: [UInt64?] = [], spareLineColors: [UInt64?] = []
    private(set) var paintedFirst = 0
    private var paintedLineCount = 0
    private var image: CGImage?

    private enum Pending: Equatable { case none, lines(ClosedRange<Int>), all }
    /// Text changes since the picture was painted: one edit's lines (in the new text), or
    /// anything (several edits, a theme).
    private var pending = Pending.all
    /// A highlight result arrived since the picture was painted.
    private var colorsChanged = false
    /// Lines painted in the last frame, not copied (tests).
    private(set) var paintedLines = 0
    /// The picture as last painted (tests).
    var paintedImage: CGImage? { image }
    /// Highlight results received (benchmarks).
    private(set) var highlightResults = 0

    private let contentLayer = CALayer()
    private let sliderLayer = CALayer()
    private var sliderColor: (key: Canvas, dragging: Bool, color: CGColor)?

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let still: [String: any CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                             "backgroundColor": NSNull(), "contentsScale": NSNull()]
        contentLayer.actions = still
        sliderLayer.actions = still
        contentLayer.magnificationFilter = .nearest
        contentLayer.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

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

    /// The lines shown, and half as many again each way: scrolling asks for colors once every
    /// half a minimap, not at every line (each request is a query of hundreds of lines).
    var highlightRange: NSRange? { lineRange(overscan: capacity / 2) }

    /// The text of the lines shown, and `overscan` lines each way.
    private func lineRange(overscan: Int) -> NSRange? {
        guard let editor, !isHidden, bounds.height > 0 else { return nil }
        let index = editor.document.lineIndex
        let first = max(0, firstLine - overscan)
        let last = min(index.lineCount, firstLine + capacity + overscan)
        let start = index.lineStarts[first]
        let end = last < index.lineCount ? index.lineStarts[last] : editor.document.textStorage.length
        return NSRange(location: start, length: end - start)
    }

    func applyHighlights(_ highlights: [NamedRange], in range: NSRange) {
        self.highlights = highlights
        highlightedRange = range
        requestedRange = nil
        highlightResults += 1
        colorsAreStale = true
        colorsChanged = true
        needsDisplay = true
    }

    // MARK: Updates

    /// The document's text changed: `lines` (in the new text) were edited, and the lines after
    /// them moved by however many lines were added or removed.
    func linesEdited(_ lines: ClosedRange<Int>) {
        pending = pending == .none ? .lines(lines) : .all
        if !isHidden { needsDisplay = true }
    }

    /// Everything is painted again (theme, settings).
    func invalidate() {
        pending = .all
        requestedRange = nil
        needsDisplay = true
    }

    /// After scrolling or editing: move the slider and repaint what changed (at the next
    /// display), and ask for colors if the lines shown moved past them.
    func refresh(textChanged: Bool = false) {
        guard !isHidden, let editor else { return }
        // A change that didn't say which lines (`linesEdited` comes first when it does).
        if textChanged, pending == .none { pending = .all }
        // The slider moves at the next display, after layout: where the top line is, asked
        // before an edit is laid out, is estimated through every paragraph from the start.
        needsDisplay = true
        if textChanged { requestedRange = nil; return } // the highlighter re-requests for all clients after edits
        guard let shown = lineRange(overscan: 0) else { return }
        for range in [highlightedRange, requestedRange] {
            if let range, NSIntersectionRange(range, shown) == shown { return }
        }
        requestedRange = highlightRange
        editor.document.highlighter?.requestHighlights(for: self)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        invalidate()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: Drawing

    override func updateLayer() {
        guard let layer else { return }
        if contentLayer.superlayer == nil {
            layer.addSublayer(contentLayer)
            layer.addSublayer(sliderLayer)
        }
        layer.backgroundColor = EditorTheme.current.background.cgColor
        contentLayer.frame = bounds
        contentLayer.contents = paint()
        updateSlider()
    }

    /// For `cacheDisplay` (and printing): the same picture, drawn.
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let theme = EditorTheme.current
        context.setFillColor(theme.background.cgColor)
        context.fill(bounds)
        if let image = paint() {
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

    private func updateSlider() {
        guard !isHidden, window != nil, !bounds.isEmpty else { return }
        let frame = sliderRect
        if sliderLayer.frame != frame { sliderLayer.frame = frame }
        if sliderColor == nil || sliderColor!.key != canvas || sliderColor!.dragging != isDragging {
            var color = CGColor(gray: 0, alpha: 0)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                color = EditorTheme.current.foreground.withAlphaComponent(isDragging ? 0.2 : 0.1).cgColor
            }
            sliderColor = (canvas, isDragging, color)
            sliderLayer.backgroundColor = color
        }
    }

    /// Brings the picture up to date and returns it: lines whose rows can be copied are, the
    /// rest are painted. Writing pixels directly: thousands of tiny fills through CoreGraphics
    /// would cost several milliseconds a frame.
    private func paint() -> CGImage? {
        guard let editor, !isHidden else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let theme = EditorTheme.current
        let appearance = theme.appearance ?? effectiveAppearance
        let next = Canvas(width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                          charPixels: max(1, Int((Self.charWidth * scale).rounded())),
                          linePixels: max(1, Int((Self.lineHeight * scale).rounded())),
                          generation: EditorTheme.generation, appearance: appearance.name)
        guard next.width > 0, next.height > 0 else { return nil }
        let index = editor.document.lineIndex
        let first = firstLine, rows = capacity
        var full = pending == .all || (pending == .none && index.lineCount != paintedLineCount)
        if next != canvas {
            canvas = next
            full = true
            captureColors.removeAll()
            colorsAreStale = true
            appearance.performAsCurrentDrawingAppearance {
                background = Self.pixel(theme.background)
                plain = Self.pixel(theme.foreground.withAlphaComponent(0.55), over: theme.background)
            }
        }
        if colorsAreStale {
            resolveColors(appearance: appearance, over: theme.background)
            colorsAreStale = false
        }
        if !full, pending == .none, !colorsChanged, first == paintedFirst, let image { paintedLines = 0; return image }

        let size = next.width * next.height
        if pixels.count != size || lineColors.count != rows {
            pixels = [UInt32](repeating: background, count: size)
            lineColors = [UInt64?](repeating: nil, count: rows)
            full = true
        }
        if spare.count != size { spare = [UInt32](repeating: background, count: size) }
        if spareLineColors.count != rows { spareLineColors = [UInt64?](repeating: nil, count: rows) }

        let edited: ClosedRange<Int>? = if case .lines(let lines) = pending { lines } else { nil }
        let delta = index.lineCount - paintedLineCount
        let rowPixels = next.width * next.linePixels
        let text = editor.document.textStorage.mutableString
        let region = highlightedRange ?? NSRange(location: 0, length: 0)
        var painted = 0
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: Self.maxUnits) { units in
            spare.withUnsafeMutableBufferPointer { out in
                pixels.withUnsafeBufferPointer { old in
                    colors.withUnsafeBufferPointer { colors in
                        for row in 0..<rows {
                            let line = first + row
                            let start = row * rowPixels
                            guard line < index.lineCount, start + rowPixels <= out.count else {
                                if start < out.count { out[start..<min(out.count, start + rowPixels)].update(repeating: background) }
                                spareLineColors[row] = nil
                                continue
                            }
                            let lineStart = index.lineStarts[line]
                            let lineEnd = line + 1 < index.lineCount ? index.lineStarts[line + 1] - 1 : text.length
                            let length = min(max(0, lineEnd - lineStart), Self.maxUnits)
                            // Where this line was painted last frame, if its text is the same.
                            var source: Int?
                            if !full {
                                let oldLine: Int? = if let edited {
                                    edited.contains(line) ? nil : line > edited.upperBound ? line - delta : line
                                } else { line }
                                if let oldLine, oldLine >= paintedFirst, oldLine - paintedFirst < rows, oldLine < paintedLineCount {
                                    source = oldLine - paintedFirst
                                }
                            }
                            if let source, let hash = lineColors[source] {
                                if !colorsChanged || Self.hash(colors, region, lineStart, length) == hash {
                                    let from = source * rowPixels
                                    out.baseAddress!.advanced(by: start).update(from: old.baseAddress!.advanced(by: from), count: rowPixels)
                                    spareLineColors[row] = hash
                                    continue
                                }
                            }
                            spareLineColors[row] = paintLine(into: out, at: start, units: units, text: text,
                                                             lineStart: lineStart, length: length, colors: colors, region: region)
                            painted += 1
                        }
                    }
                }
            }
        }
        // Rows below the last line (the height isn't a whole number of lines).
        let used = rows * rowPixels
        if used < size, full { spare[used..<size].withUnsafeMutableBufferPointer { $0.update(repeating: background) } }
        swap(&pixels, &spare)
        swap(&lineColors, &spareLineColors)
        paintedFirst = first
        paintedLineCount = index.lineCount
        pending = .none
        colorsChanged = false
        paintedLines = painted

        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        image = CGImage(width: next.width, height: next.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: next.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        return image
    }

    /// Paints one line's row (cleared first) and returns the hash of the colors it used.
    private func paintLine(into out: UnsafeMutableBufferPointer<UInt32>, at start: Int, units: UnsafeMutableBufferPointer<unichar>,
                           text: NSMutableString, lineStart: Int, length: Int,
                           colors: UnsafeBufferPointer<UInt32>, region: NSRange) -> UInt64 {
        let width = canvas.width, charPixels = canvas.charPixels
        let inkPixels = max(1, canvas.linePixels * 3 / 4)
        let maxColumns = width / charPixels
        out.baseAddress!.advanced(by: start).update(repeating: background, count: width * canvas.linePixels)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        guard length > 0 else { return hash }
        text.getCharacters(units.baseAddress!, range: NSRange(location: lineStart, length: length))
        var column = 0
        for i in 0..<length {
            let offset = lineStart + i - region.location
            let stored = offset >= 0 && offset < colors.count ? colors[offset] : 0
            hash = (hash ^ UInt64(stored)) &* 0x100_0000_01b3
            guard column < maxColumns else { continue }
            let unit = units[i]
            if unit == 0x20 { column += 1; continue }
            if unit == 0x09 { column += 4; continue }
            if unit == 0x0D { continue }
            let color = stored == 0 ? plain : stored
            let x0 = column * charPixels, x1 = min(width, x0 + charPixels)
            for y in 0..<inkPixels {
                let rowStart = start + y * width
                for x in x0..<x1 { out[rowStart + x] = color }
            }
            column += 1
        }
        return hash
    }

    /// The hash `paintLine` would return for a line with `colors`.
    private static func hash(_ colors: UnsafeBufferPointer<UInt32>, _ region: NSRange, _ lineStart: Int, _ length: Int) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in 0..<length {
            let offset = lineStart + i - region.location
            let stored = offset >= 0 && offset < colors.count ? colors[offset] : 0
            hash = (hash ^ UInt64(stored)) &* 0x100_0000_01b3
        }
        return hash
    }

    /// Each character's color from the highlights (later wins; 0 where none applies).
    private func resolveColors(appearance: NSAppearance, over background: NSColor) {
        guard let highlightedRange else { colors = []; return }
        if colors.count == highlightedRange.length {
            colors.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        } else {
            colors = [UInt32](repeating: 0, count: highlightedRange.length)
        }
        appearance.performAsCurrentDrawingAppearance {
            colors.withUnsafeMutableBufferPointer { colors in
                for highlight in highlights {
                    let clipped = NSIntersectionRange(highlight.range, highlightedRange)
                    guard clipped.length > 0 else { continue }
                    let color: UInt32
                    if let cached = captureColors[highlight.name] {
                        color = cached
                    } else {
                        color = EditorTheme.color(forCapture: highlight.name).map {
                            Self.pixel($0.withAlphaComponent(0.85), over: background)
                        } ?? 0
                        captureColors[highlight.name] = color
                    }
                    guard color != 0 else { continue }
                    let start = clipped.location - highlightedRange.location
                    colors[start..<(start + clipped.length)].update(repeating: color)
                }
            }
        }
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
        updateSlider()
        scroll(to: event)
    }

    override func mouseDragged(with event: NSEvent) { scroll(to: event) }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        updateSlider()
    }

    /// Centers the editor on the line under the pointer.
    private func scroll(to event: NSEvent) {
        guard let editor else { return }
        let y = convert(event.locationInWindow, from: nil).y
        let line = firstLine + Int(y / Self.lineHeight) - editor.visibleLineCount / 2
        editor.scrollLineToTop(max(0, min(line, editor.document.lineIndex.lineCount - 1)))
    }
}
