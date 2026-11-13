import AppKit
import CoreText
import Metal
import QuartzCore
import GhosttyVt

/// Draws a `TerminalSession` with Metal and forwards keyboard, mouse and clipboard input.
///
/// Rendering reads Ghostty's render state and rebuilds GPU geometry only for rows it marks dirty;
/// frames are drawn with Metal (see TerminalRenderer) at most once per display refresh, so bursts
/// of output cost one frame.
@MainActor
final class TerminalView: NSView {
    var session: TerminalSession? {
        didSet {
            guard session !== oldValue else { return }
            oldValue?.onContentChange = nil
            session?.onContentChange = { [weak self] in self?.needsDisplay = true }
            rowCache.removeAll()
            applyAppearanceColors()
            updateGridSize()
            needsDisplay = true
        }
    }

    static let padding: CGFloat = 6

    // From Settings (terminal font); replaced live when it changes.
    private var font = AppSettings.shared.terminalFont()
    private var boldFont = AppSettings.shared.terminalFont(bold: true)
    private var italicFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldItalicFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private(set) var cellWidth: CGFloat = 0
    private(set) var cellHeight: CGFloat = 0
    private var baseline: CGFloat = 0

    // Render state iteration handles, reused every frame.
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?

    /// GPU geometry for one row, rebuilt only when Ghostty marks the row dirty.
    private struct RowRender {
        var rects: [RectInstance] = []
        var glyphs: [GlyphInstance] = []
        /// Text and font per column, for redrawing the character under a block cursor.
        var cells: [String] = []
        var fonts: [Int] = []
    }

    private var rowCache: [RowRender] = []
    /// Scale and atlas generation the cached rows were built for.
    private var rowCacheScale: CGFloat = 0
    private var rowCacheAtlasGeneration = -1
    private var colors = GhosttyRenderStateColors()
    private let renderer = TerminalRenderer.shared
    /// Forces the focused/unfocused cursor look (tests; offscreen windows never become key).
    var focusOverride: Bool?
    /// Frames sent to the screen (tests).
    private(set) var presentedFrames = 0
    private var scrollAccumulator: CGFloat = 0
    /// A button press went to the program (mouse tracking), so drags/release follow it there.
    private var mouseCapturedByProgram = false
    private var trackingArea: NSTrackingArea?

    // Input method state (NSTextInputClient).
    private(set) var markedText = ""
    /// Text committed by the input method while handling the current keyDown.
    private var keyTextAccumulator: [String]?
    private var cursorRect: CGRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        loadFonts()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: AppSettings.didChange, object: nil)
        ghostty_render_state_row_iterator_new(nil, &rowIterator)
        ghostty_render_state_row_cells_new(nil, &rowCells)
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer?.device
        layer.pixelFormat = TerminalRenderer.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.needsDisplayOnBoundsChange = true
        return layer
    }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    // MARK: Layout

    private func loadFonts() {
        font = AppSettings.shared.terminalFont()
        boldFont = AppSettings.shared.terminalFont(bold: true)
        italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        boldItalicFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
        measureFont()
    }

    /// Font or theme changed in Settings: re-measure cells (the grid may change size) and
    /// rebuild every row.
    @objc private func settingsDidChange() {
        loadFonts()
        updateGridSize()
        applyAppearanceColors()
        rowCache.removeAll()
        needsDisplay = true
    }

    private func measureFont() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        cellWidth = ceil(advance * scale) / scale
        let ctFont = font as CTFont
        let height = CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)
        cellHeight = ceil(height * 1.1 * scale) / scale
        baseline = ((cellHeight - height) / 2 + CTFontGetAscent(ctFont)).rounded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        measureFont()
        updateGridSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
        // During live resize, draw right away so the content keeps up with the frame.
        if inLiveResize { renderFrame() } else { scheduleRender() }
    }

    private func updateGridSize() {
        guard let session, cellWidth > 0, cellHeight > 0 else { return }
        let columns = max(1, Int((bounds.width - 2 * Self.padding) / cellWidth))
        let rows = max(1, Int((bounds.height - 2 * Self.padding) / cellHeight))
        let scale = window?.backingScaleFactor ?? 2
        session.resize(columns: UInt16(min(columns, 1000)), rows: UInt16(min(rows, 500)),
                       cellWidth: UInt16(cellWidth * scale), cellHeight: UInt16(cellHeight * scale))
    }

    func cell(at point: NSPoint) -> (x: UInt16, y: UInt16) {
        guard let session else { return (0, 0) }
        let column = Int((point.x - Self.padding) / cellWidth)
        let row = Int((point.y - Self.padding) / cellHeight)
        return (UInt16(clamping: min(max(column, 0), Int(session.columns) - 1)),
                UInt16(clamping: min(max(row, 0), Int(session.rows) - 1)))
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    /// Default foreground/background follow the app's light or dark appearance.
    private func applyAppearanceColors() {
        guard let session else { return }
        var foreground = GhosttyColorRgb(), background = GhosttyColorRgb()
        let theme = EditorTheme.current
        var cursor: GhosttyColorRgb?
        (theme.appearance ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            foreground = Self.rgb(theme.foreground)
            background = Self.rgb(theme.background)
            if theme.isDark != nil { cursor = Self.rgb(theme.cursor) } // fixed themes only
        }
        let palette = theme.terminalPalette?.map {
            GhosttyColorRgb(r: UInt8($0 >> 16 & 0xFF), g: UInt8($0 >> 8 & 0xFF), b: UInt8($0 & 0xFF))
        }
        session.setDefaultColors(foreground: foreground, background: background, cursor: cursor, palette: palette)
        rowCache.removeAll()
    }

    private static func rgb(_ color: NSColor) -> GhosttyColorRgb {
        let c = color.usingColorSpace(.sRGB) ?? .black
        return GhosttyColorRgb(r: UInt8(c.redComponent * 255), g: UInt8(c.greenComponent * 255),
                               b: UInt8(c.blueComponent * 255))
    }

    private static func color(_ rgb: GhosttyColorRgb, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float(rgb.r) / 255, Float(rgb.g) / 255, Float(rgb.b) / 255, alpha)
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: Drawing (Metal)

    /// AppKit calls this once per display refresh at most when `needsDisplay` is set.
    // CAMetalLayer never asks its delegate to draw (no `updateLayer`), so frames are driven by
    // a display link: `needsDisplay` schedules one, it renders once on the next screen refresh
    // (ProMotion rate included) and stops. Idle terminals cost nothing.
    private var displayLink: CADisplayLink?
    private var renderPending = false

    override var needsDisplay: Bool {
        // The new value, not a read-back: for this layer AppKit reports false once shown.
        willSet { if newValue { scheduleRender() } }
    }

    private func scheduleRender() {
        renderPending = true
        guard window != nil, displayLink == nil else { return }
        // One-shot: a paused display link doesn't reliably resume, so each frame gets a new one.
        let link = displayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        link.invalidate()
        if displayLink === link { displayLink = nil }
        guard renderPending else { return }
        renderPending = false
        renderFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        // The cursor is drawn hollow while the window isn't key.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyStateChanged), name: name, object: window)
        }
        scheduleRender()
    }

    @objc private func windowKeyStateChanged() {
        needsDisplay = true
    }

    /// Draws the current state into the next drawable and presents it.
    func renderFrame() {
        guard let layer = layer as? CAMetalLayer, let renderer, window != nil else { return }
        let scale = scale
        layer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0 else { return }
        if layer.drawableSize != size { layer.drawableSize = size }
        let frame = makeFrame(scale: scale)
        guard let drawable = layer.nextDrawable() else { return }
        if renderer.render(frame, to: drawable.texture, drawable: drawable) != nil { presentedFrames += 1 }
    }

    /// Renders the current state offscreen and returns the pixels (tests, screenshots).
    func snapshot(scale: CGFloat = 2) -> NSBitmapImageRep? {
        guard let renderer else { return nil }
        return renderer.snapshot(makeFrame(scale: scale), width: Int((bounds.width * scale).rounded()),
                                 height: Int((bounds.height * scale).rounded()))
    }

    /// Everything to draw this frame, in pixels at `scale`.
    func makeFrame(scale: CGFloat) -> TerminalFrame {
        guard let session else {
            var background = SIMD4<Float>(1, 1, 1, 1)
            let theme = EditorTheme.current
            (theme.appearance ?? effectiveAppearance).performAsCurrentDrawingAppearance {
                background = Self.color(Self.rgb(theme.background))
            }
            return TerminalFrame(clearColor: background)
        }
        if scale != rowCacheScale {
            rowCache.removeAll()
            rowCacheScale = scale
        }
        var cursor = updateRows(session, scale: scale)
        if renderer?.atlas.generation != rowCacheAtlasGeneration {
            // The atlas was cleared (it filled up, possibly while building these rows): cached
            // rows point at glyphs that are gone, so rebuild all of them.
            rowCache.removeAll()
            cursor = updateRows(session, scale: scale, forceFull: true)
        }
        rowCacheAtlasGeneration = renderer?.atlas.generation ?? 0

        var frame = TerminalFrame(clearColor: Self.color(colors.background))
        frame.rects.reserveCapacity(rowCache.reduce(0) { $0 + $1.rects.count })
        frame.glyphs.reserveCapacity(rowCache.reduce(0) { $0 + $1.glyphs.count })
        for row in rowCache {
            frame.rects += row.rects
            frame.glyphs += row.glyphs
        }
        addCursor(cursor, to: &frame, scale: scale)
        addMarkedText(to: &frame, scale: scale)
        return frame
    }

    private func font(_ index: Int) -> NSFont {
        switch index {
        case 1: boldFont
        case 2: italicFont
        case 3: boldItalicFont
        default: font
        }
    }

    /// A glyph instance for `text` drawn in the cell at (column, row).
    private func glyphInstance(_ text: String, fontIndex: Int, column: CGFloat, row: Int, color: SIMD4<Float>,
                               scale: CGFloat) -> GlyphInstance? {
        guard let renderer,
              let glyph = renderer.atlas.glyph(text, font: font(fontIndex), scale: scale)
        else { return nil }
        let x = Float(((Self.padding + column * cellWidth) * scale).rounded())
        let baselineY = Float(((Self.padding + CGFloat(row) * cellHeight + baseline) * scale).rounded())
        return GlyphInstance(origin: SIMD2(x, baselineY) + glyph.offset, size: glyph.size, uvOrigin: glyph.uvOrigin,
                             uvSize: glyph.size, color: color, isColor: glyph.isColor)
    }

    private func rectInstance(_ rect: CGRect, color: SIMD4<Float>, scale: CGFloat) -> RectInstance {
        let minX = (rect.minX * scale).rounded(), minY = (rect.minY * scale).rounded()
        return RectInstance(origin: SIMD2(Float(minX), Float(minY)),
                            size: SIMD2(Float((rect.maxX * scale).rounded() - minX), Float((rect.maxY * scale).rounded() - minY)),
                            color: color)
    }

    private func cellRect(column: Int, row: Int, span: Int = 1) -> CGRect {
        CGRect(x: Self.padding + CGFloat(column) * cellWidth, y: Self.padding + CGFloat(row) * cellHeight,
               width: CGFloat(span) * cellWidth, height: cellHeight)
    }

    /// Text being composed by an input method (e.g. Japanese, dead keys), drawn over the cursor.
    private func addMarkedText(to frame: inout TerminalFrame, scale: CGFloat) {
        guard !markedText.isEmpty else { return }
        let foreground = Self.color(colors.foreground)
        var advance: CGFloat = 0
        var glyphs: [GlyphInstance] = []
        let row = Int(((cursorRect.minY - Self.padding) / cellHeight).rounded())
        let startColumn = (cursorRect.minX - Self.padding) / cellWidth
        for character in markedText {
            let text = String(character)
            if let glyph = glyphInstance(text, fontIndex: 0, column: startColumn + advance / cellWidth, row: row,
                                         color: foreground, scale: scale) {
                glyphs.append(glyph)
            }
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            advance += max(cellWidth, (width / cellWidth).rounded() * cellWidth)
        }
        let rect = CGRect(x: cursorRect.minX, y: cursorRect.minY, width: max(cellWidth, advance), height: cellHeight)
        frame.overlayRects.append(rectInstance(rect, color: Self.color(colors.background), scale: scale))
        frame.overlayRects.append(rectInstance(CGRect(x: rect.minX, y: rect.minY + baseline + 2, width: rect.width, height: 1),
                                               color: foreground, scale: scale))
        frame.overlayGlyphs += glyphs
    }

    /// Pulls the latest state from the terminal and rebuilds cached rows Ghostty marks dirty.
    private func updateRows(_ session: TerminalSession, scale: CGFloat, forceFull: Bool = false) -> GhosttyRenderStateCursor {
        let state = session.renderState
        ghostty_render_state_update(state, session.terminal)

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        var rows: UInt16 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)

        let full = forceFull || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || rowCache.count != Int(rows)
        if full { rowCache = Array(repeating: RowRender(), count: Int(rows)) }

        if full || dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE {
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
            var row = 0
            while ghostty_render_state_row_iterator_next(rowIterator), row < rowCache.count {
                var rowDirty = false
                ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                if full || rowDirty { rowCache[row] = buildRow(row, scale: scale) }
                row += 1
            }
            ghostty_render_state_clean(state)
        }
        return cursor
    }

    private struct RunStyle: Equatable {
        var foreground: GhosttyColorRgb
        var background: GhosttyColorRgb?
        var bold = false, italic = false, faint = false, underline = false, strikethrough = false, invisible = false

        static func == (a: RunStyle, b: RunStyle) -> Bool {
            a.foreground.r == b.foreground.r && a.foreground.g == b.foreground.g && a.foreground.b == b.foreground.b
                && a.background?.r == b.background?.r && a.background?.g == b.background?.g
                && a.background?.b == b.background?.b && (a.background == nil) == (b.background == nil)
                && a.bold == b.bold && a.italic == b.italic && a.faint == b.faint
                && a.underline == b.underline && a.strikethrough == b.strikethrough && a.invisible == b.invisible
        }
    }

    /// Geometry for the row the iterator is on: one rect per run of equal background, one
    /// glyph per non-blank cell, and rects for underlines and strikethroughs.
    private func buildRow(_ row: Int, scale: CGFloat) -> RowRender {
        var render = RowRender()
        ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)

        var selection = GhosttyRenderStateRowSelection()
        selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        let hasSelection = ghostty_render_state_row_get(
            rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS

        var column = 0
        var utf8 = [UInt8](repeating: 0, count: 64)
        // Pending background run.
        var backgroundStart = 0
        var backgroundColor: GhosttyColorRgb?

        func flushBackground(endingAt end: Int) {
            defer { backgroundColor = nil }
            guard let color = backgroundColor, end > backgroundStart else { return }
            render.rects.append(rectInstance(cellRect(column: backgroundStart, row: row, span: end - backgroundStart),
                                             color: Self.color(color), scale: scale))
        }

        var decorations: [RectInstance] = []
        while ghostty_render_state_row_cells_next(rowCells) {
            defer { column += 1 }
            var raw = GhosttyCell()
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD {
                render.cells.append("")
                render.fonts.append(0)
                continue // covered by the wide cell before it
            }

            var text = " "
            var buffer = GhosttyBuffer(ptr: nil, cap: 0, len: 0)
            let written: Int = utf8.withUnsafeMutableBufferPointer { storage in
                buffer.ptr = storage.baseAddress
                buffer.cap = storage.count
                guard ghostty_render_state_row_cells_get(
                    rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer) == GHOSTTY_SUCCESS
                else { return 0 }
                return buffer.len
            }
            if written > 0 { text = String(decoding: utf8[..<written], as: UTF8.self) }

            var style = cellStyle()
            if hasSelection, column >= Int(selection.start_x), column <= Int(selection.end_x) {
                style.background = selectionColor
            }
            let span = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1
            let fontIndex = (style.bold ? 1 : 0) + (style.italic ? 2 : 0)
            render.cells.append(text)
            render.fonts.append(fontIndex)

            let sameBackground = backgroundColor.map { current in
                style.background.map { $0.r == current.r && $0.g == current.g && $0.b == current.b } ?? false
            } ?? (style.background == nil)
            if !sameBackground {
                flushBackground(endingAt: column)
                backgroundStart = column
                backgroundColor = style.background
            }

            let foreground = Self.color(style.foreground, alpha: style.faint ? 0.5 : 1)
            if !style.invisible, !text.allSatisfy({ $0 == " " }),
               let glyph = glyphInstance(text, fontIndex: fontIndex, column: CGFloat(column), row: row,
                                         color: foreground, scale: scale) {
                render.glyphs.append(glyph)
            }
            let cell = cellRect(column: column, row: row, span: span)
            if style.underline {
                decorations.append(rectInstance(CGRect(x: cell.minX, y: cell.minY + baseline + 2, width: cell.width, height: 1),
                                                color: foreground, scale: scale))
            }
            if style.strikethrough {
                decorations.append(rectInstance(CGRect(x: cell.minX, y: cell.minY + baseline - font.xHeight / 2,
                                                       width: cell.width, height: 1), color: foreground, scale: scale))
            }
        }
        flushBackground(endingAt: column)
        render.rects += decorations // over the backgrounds
        return render
    }

    private var selectionColor: GhosttyColorRgb {
        var rgb = GhosttyColorRgb()
        let theme = EditorTheme.current
        (theme.appearance ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            rgb = Self.rgb(theme.selection)
        }
        return rgb
    }

    private func cellStyle() -> RunStyle {
        var foreground = colors.foreground
        var background: GhosttyColorRgb?
        var rgb = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &rgb) == GHOSTTY_SUCCESS {
            foreground = rgb
        }
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &rgb) == GHOSTTY_SUCCESS {
            background = rgb
        }
        var style = RunStyle(foreground: foreground, background: background)

        var hasStyling = false
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
        guard hasStyling else { return style }
        var cellStyle = GhosttyStyle()
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &cellStyle)
        let flags = UInt16(cellStyle.flags)
        style.bold = flags & 0x01 != 0
        style.italic = flags & 0x02 != 0
        style.faint = flags & 0x04 != 0
        style.invisible = flags & 0x20 != 0
        style.strikethrough = flags & 0x40 != 0
        style.underline = (flags >> 8) & 0x7 != 0
        if flags & 0x10 != 0 { // inverse
            let newBackground = style.foreground
            style.foreground = style.background ?? colors.background
            style.background = newBackground
        }
        return style
    }

    private func addCursor(_ cursor: GhosttyRenderStateCursor, to frame: inout TerminalFrame, scale: CGFloat) {
        guard cursor.visible, cursor.viewport_has_value, Int(cursor.viewport_y) < rowCache.count else { return }
        let color = Self.color(colors.cursor_has_value ? colors.cursor : colors.foreground)
        let row = Int(cursor.viewport_y), column = Int(cursor.viewport_x)
        let rect = cellRect(column: column, row: row)
        cursorRect = rect
        if !markedText.isEmpty { return } // the composition is drawn there instead
        let focused = focusOverride ?? (window?.firstResponder === self && window?.isKeyWindow == true)

        func outline() {
            for edge in [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1),
                         CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1),
                         CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height),
                         CGRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height)] {
                frame.overlayRects.append(rectInstance(edge, color: color, scale: scale))
            }
        }
        guard focused else { outline(); return }
        switch cursor.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR:
            frame.overlayRects.append(rectInstance(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height),
                                                   color: color, scale: scale))
        case GHOSTTY_CURSOR_STYLE_UNDERLINE:
            frame.overlayRects.append(rectInstance(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2),
                                                   color: color, scale: scale))
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW:
            outline()
        default:
            frame.overlayRects.append(rectInstance(rect, color: color, scale: scale))
            // The character under the block, in the background color.
            let cells = rowCache[row].cells
            if column < cells.count, !cells[column].trimmingCharacters(in: .whitespaces).isEmpty,
               let glyph = glyphInstance(cells[column], fontIndex: rowCache[row].fonts[column], column: CGFloat(column),
                                         row: row, color: Self.color(colors.background), scale: scale) {
                frame.overlayGlyphs.append(glyph)
            }
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event) // ⌘ shortcuts belong to the app's menus
            return
        }
        session.clearSelectionIfAny()
        let action = event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS

        // Let the input method see the key first: it may compose (dead keys, CJK input) or
        // commit text. Keys it doesn't turn into text (arrows, ctrl-c, enter) are encoded as keys.
        let wasComposing = !markedText.isEmpty
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let committed = keyTextAccumulator ?? []
        keyTextAccumulator = nil

        if !committed.isEmpty {
            for text in committed {
                var input = TerminalKeyMap.input(for: event, action: action)
                input.text = text
                input.consumedMods = input.mods & GhosttyMods(GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_ALT)
                session.send(input)
            }
        } else if markedText.isEmpty && !wasComposing {
            session.send(TerminalKeyMap.input(for: event, action: action))
        }
        needsDisplay = true
    }

    override func keyUp(with event: NSEvent) {
        guard let session, !event.modifierFlags.contains(.command) else { return }
        // Only produces bytes when the program enabled kitty key release events.
        session.send(TerminalKeyMap.input(for: event, action: GHOSTTY_KEY_ACTION_RELEASE))
    }

    // MARK: Clipboard

    @objc func copy(_ sender: Any?) {
        guard let text = session?.text(selectionOnly: true), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session?.paste(text)
    }


    // MARK: Mouse

    private var geometry: TerminalSession.Geometry {
        TerminalSession.Geometry(width: bounds.width, height: bounds.height, cellWidth: cellWidth,
                                 cellHeight: cellHeight, padding: Self.padding)
    }

    /// Programs that track the mouse (vim, htop, tmux) get the events, unless Shift is held,
    /// which keeps local selection available, as in other terminals.
    private func reportsToProgram(_ event: NSEvent) -> Bool {
        session?.isMouseTrackingEnabled == true && !event.modifierFlags.contains(.shift)
    }

    private func report(_ event: NSEvent, action: GhosttyMouseAction, button: GhosttyMouseButton?, pressed: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        session?.sendMouse(action: action, button: button, mods: TerminalKeyMap.ghosttyMods(event.modifierFlags),
                           x: point.x, y: point.y, geometry: geometry, anyButtonPressed: pressed)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let session else { return }
        if reportsToProgram(event) {
            mouseCapturedByProgram = true
            report(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT, pressed: true)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        session.selectionPress(cell: cell(at: point), x: point.x, y: point.y,
                               timestampNs: UInt64(event.timestamp * 1_000_000_000))
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseCapturedByProgram {
            report(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_LEFT, pressed: true)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        session?.selectionDrag(cell: cell(at: point), x: point.x, y: point.y, geometry: geometry)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseCapturedByProgram {
            mouseCapturedByProgram = false
            report(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_LEFT, pressed: false)
            return
        }
        session?.selectionRelease(cell: cell(at: convert(event.locationInWindow, from: nil)))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard reportsToProgram(event) else { return super.rightMouseDown(with: event) }
        report(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_RIGHT, pressed: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard reportsToProgram(event) else { return super.rightMouseUp(with: event) }
        report(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_RIGHT, pressed: false)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard reportsToProgram(event), event.buttonNumber == 2 else { return }
        report(event, action: GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_MIDDLE, pressed: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard reportsToProgram(event), event.buttonNumber == 2 else { return }
        report(event, action: GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_MIDDLE, pressed: false)
    }

    override func mouseMoved(with event: NSEvent) {
        // Only "any event" tracking (mode 1003) reports plain motion; the encoder drops the rest.
        guard reportsToProgram(event) else { return }
        report(event, action: GHOSTTY_MOUSE_ACTION_MOTION, button: nil, pressed: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * cellHeight
        scrollAccumulator += delta
        let rows = Int(scrollAccumulator / cellHeight)
        guard rows != 0 else { return }
        scrollAccumulator -= CGFloat(rows) * cellHeight
        let point = convert(event.locationInWindow, from: nil)
        session.scrollWheel(rows: rows, x: point.x, y: point.y, geometry: geometry,
                            mods: TerminalKeyMap.ghosttyMods(event.modifierFlags))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
}

extension TerminalView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text) // committed while handling a key: encoded in keyDown
        } else if !text.isEmpty {
            session?.sendText(text) // e.g. from the character viewer, outside any key event
        }
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the input method should place its candidate window: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(cursorRect, to: nil))
    }

    /// Keys like arrows or Enter reach here as commands; keyDown encodes them itself.
    override func doCommand(by selector: Selector) {}
}

extension TerminalView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): session?.hasSelection == true
        case #selector(paste(_:)): NSPasteboard.general.string(forType: .string) != nil
        default: true
        }
    }
}

extension TerminalSession {
    func clearSelectionIfAny() {
        if hasSelection { clearSelection() }
    }
}
