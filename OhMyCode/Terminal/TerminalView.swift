import AppKit
import CoreText
import GhosttyVt

/// Draws a `TerminalSession` with CoreText and forwards keyboard, mouse and clipboard input.
///
/// Rendering reads Ghostty's render state and rebuilds cached text runs only for rows it marks
/// dirty; AppKit coalesces redraws to the display refresh, so bursts of output cost one frame.
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

    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private lazy var boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private lazy var italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    private lazy var boldItalicFont = NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
    private(set) var cellWidth: CGFloat = 0
    private(set) var cellHeight: CGFloat = 0
    private var baseline: CGFloat = 0

    // Render state iteration handles, reused every frame.
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?

    private struct Run {
        var column: Int
        var span: Int
        var line: CTLine?
        var background: CGColor?
        var foreground: CGColor
        var underline = false
        var strikethrough = false
    }

    private struct RowRender {
        var runs: [Run] = []
        /// Text per column, for redrawing the character under a block cursor.
        var cells: [String] = []
    }

    private var rowCache: [RowRender] = []
    private var colors = GhosttyRenderStateColors()
    private var colorCache: [UInt32: CGColor] = [:]
    private var scrollAccumulator: CGFloat = 0
    private var selectionAnchor: (x: UInt16, y: UInt16)?
    private var didDrag = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        measureFont()
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
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    // MARK: Layout

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
        effectiveAppearance.performAsCurrentDrawingAppearance {
            foreground = Self.rgb(NSColor.textColor)
            background = Self.rgb(NSColor.textBackgroundColor)
        }
        session.setDefaultColors(foreground: foreground, background: background)
        rowCache.removeAll()
    }

    private static func rgb(_ color: NSColor) -> GhosttyColorRgb {
        let c = color.usingColorSpace(.sRGB) ?? .black
        return GhosttyColorRgb(r: UInt8(c.redComponent * 255), g: UInt8(c.greenComponent * 255),
                               b: UInt8(c.blueComponent * 255))
    }

    private func cgColor(_ rgb: GhosttyColorRgb, alpha: CGFloat = 1) -> CGColor {
        let key = UInt32(rgb.r) << 24 | UInt32(rgb.g) << 16 | UInt32(rgb.b) << 8 | UInt32(alpha * 255)
        if let cached = colorCache[key] { return cached }
        let color = CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                            blue: CGFloat(rgb.b) / 255, alpha: alpha)
        colorCache[key] = color
        return color
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let session else {
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            return
        }
        let cursor = updateRows(session)

        context.setFillColor(cgColor(colors.background))
        context.fill(bounds)

        let pad = Self.padding
        for (row, render) in rowCache.enumerated() {
            let y = pad + CGFloat(row) * cellHeight
            for run in render.runs {
                guard let background = run.background else { continue }
                context.setFillColor(background)
                context.fill(CGRect(x: pad + CGFloat(run.column) * cellWidth, y: y,
                                    width: CGFloat(run.span) * cellWidth, height: cellHeight))
            }
        }

        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // CoreText in a flipped view
        for (row, render) in rowCache.enumerated() {
            let y = pad + CGFloat(row) * cellHeight
            for run in render.runs {
                let x = pad + CGFloat(run.column) * cellWidth
                if let line = run.line {
                    context.textPosition = CGPoint(x: x, y: y + baseline)
                    CTLineDraw(line, context)
                }
                if run.underline || run.strikethrough {
                    context.setFillColor(run.foreground)
                    let width = CGFloat(run.span) * cellWidth
                    if run.underline { context.fill(CGRect(x: x, y: y + baseline + 2, width: width, height: 1)) }
                    if run.strikethrough {
                        context.fill(CGRect(x: x, y: y + baseline - font.xHeight / 2, width: width, height: 1))
                    }
                }
            }
        }

        drawCursor(cursor, in: context)
    }

    /// Pulls the latest state from the terminal and rebuilds cached rows Ghostty marks dirty.
    private func updateRows(_ session: TerminalSession) -> GhosttyRenderStateCursor {
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

        let full = dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || rowCache.count != Int(rows)
        if full { rowCache = Array(repeating: RowRender(), count: Int(rows)) }

        if full || dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE {
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
            var row = 0
            while ghostty_render_state_row_iterator_next(rowIterator), row < rowCache.count {
                var rowDirty = false
                ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                if full || rowDirty { rowCache[row] = buildRow() }
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

    private func buildRow() -> RowRender {
        var render = RowRender()
        ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &rowCells)

        var selection = GhosttyRenderStateRowSelection()
        selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        let hasSelection = ghostty_render_state_row_get(
            rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS

        var runStart = 0, runText = "", runStyle: RunStyle?
        var column = 0
        var utf8 = [UInt8](repeating: 0, count: 64)

        func flush(endingAt end: Int) {
            defer { runText = ""; runStyle = nil }
            guard let style = runStyle, end > runStart else { return }
            let isBlank = runText.allSatisfy { $0 == " " }
            if isBlank && style.background == nil && !style.underline && !style.strikethrough { return }
            render.runs.append(makeRun(column: runStart, span: end - runStart, text: runText, style: style,
                                       skipText: isBlank || style.invisible))
        }

        while ghostty_render_state_row_cells_next(rowCells) {
            defer { column += 1 }
            var raw = GhosttyCell()
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD {
                render.cells.append("")
                continue
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
            render.cells.append(text)

            var style = cellStyle()
            if hasSelection, column >= Int(selection.start_x), column <= Int(selection.end_x) {
                style.background = selectionColor
            }

            if wide == GHOSTTY_CELL_WIDE_WIDE {
                flush(endingAt: column)
                runStart = column; runText = text; runStyle = style
                flush(endingAt: column + 2)
                runStart = column + 2
                continue
            }
            if runStyle != style {
                flush(endingAt: column)
                runStart = column
                runStyle = style
            }
            runText += text
        }
        flush(endingAt: column)
        return render
    }

    private var selectionColor: GhosttyColorRgb {
        var rgb = GhosttyColorRgb()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            rgb = Self.rgb(NSColor.selectedTextBackgroundColor)
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

    private func makeRun(column: Int, span: Int, text: String, style: RunStyle, skipText: Bool) -> Run {
        let foreground = cgColor(style.foreground, alpha: style.faint ? 0.5 : 1)
        var line: CTLine?
        if !skipText {
            let runFont = style.bold ? (style.italic ? boldItalicFont : boldFont) : (style.italic ? italicFont : font)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: runFont, .foregroundColor: NSColor(cgColor: foreground) ?? .textColor,
            ])
            line = CTLineCreateWithAttributedString(attributed)
        }
        return Run(column: column, span: span, line: line, background: style.background.map { cgColor($0) },
                   foreground: foreground, underline: style.underline, strikethrough: style.strikethrough)
    }

    private func drawCursor(_ cursor: GhosttyRenderStateCursor, in context: CGContext) {
        guard cursor.visible, cursor.viewport_has_value, Int(cursor.viewport_y) < rowCache.count else { return }
        let color = cgColor(colors.cursor_has_value ? colors.cursor : colors.foreground)
        let rect = CGRect(x: Self.padding + CGFloat(cursor.viewport_x) * cellWidth,
                          y: Self.padding + CGFloat(cursor.viewport_y) * cellHeight,
                          width: cellWidth, height: cellHeight)
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        context.setFillColor(color)
        context.setStrokeColor(color)

        if !focused {
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5), width: 1)
            return
        }
        switch cursor.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR:
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height))
        case GHOSTTY_CURSOR_STYLE_UNDERLINE:
            context.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2))
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW:
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5), width: 1)
        default:
            context.fill(rect)
            // Redraw the character under the block in the background color.
            let cells = rowCache[Int(cursor.viewport_y)].cells
            let column = Int(cursor.viewport_x)
            if column < cells.count, !cells[column].trimmingCharacters(in: .whitespaces).isEmpty {
                let attributed = NSAttributedString(string: cells[column], attributes: [
                    .font: font, .foregroundColor: NSColor(cgColor: cgColor(colors.background)) ?? .black,
                ])
                context.textPosition = CGPoint(x: rect.minX, y: rect.minY + baseline)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
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
        session.send(TerminalKeyMap.input(for: event, action: action))
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        selectionAnchor = cell(at: convert(event.locationInWindow, from: nil))
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = selectionAnchor else { return }
        didDrag = true
        session?.select(from: anchor, to: cell(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { session?.clearSelectionIfAny() }
        selectionAnchor = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * cellHeight
        scrollAccumulator += delta
        let rows = Int(scrollAccumulator / cellHeight)
        guard rows != 0 else { return }
        scrollAccumulator -= CGFloat(rows) * cellHeight
        session.scrollViewport(byRows: -rows)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }
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
