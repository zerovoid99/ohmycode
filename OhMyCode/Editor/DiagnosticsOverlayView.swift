import AppKit

/// Draws squiggly underlines for diagnostics over the text view. TextKit 2 rendering attributes
/// don't draw underlines (colors work, underlines are ignored), so we draw them from the text
/// segment geometry ourselves. Also draws the "⋯" after folded lines. Transparent to mouse
/// events (the text view handles clicks on "⋯").
@MainActor
final class DiagnosticsOverlayView: NSView {
    private weak var textView: NSTextView?
    /// Weak: AppKit can keep a text view's subviews alive after the text view goes (the editor
    /// also removes this view when it closes), and that mustn't keep a closed file in memory.
    private weak var document: EditorDocument?
    /// Lenses after their lines, and the one under the mouse.
    var codeLenses: (() -> [CodeLensMark])?
    var hoveredCodeLens: (() -> NSRect?)?
    /// Spaces and tabs shown as · and →.
    var whitespace: (() -> [(rect: NSRect, isTab: Bool)])?
    /// Indent guides in a rect (one rect per line and level), brighter for the cursor's block.
    var indentGuides: ((NSRect) -> [(rect: NSRect, isActive: Bool)])?
    /// The bracket beside the cursor and its match: outlined.
    var brackets: (() -> [NSRect])?
    /// The link under the mouse while ⌘ is held: underlined.
    var linkUnderline: (() -> NSRect?)?
    /// Where the symbol under the cursor appears (written places are outlined too).
    var occurrences: (() -> [(rect: NSRect, isWrite: Bool)])?
    /// Placeholders for folded regions, in this view's (= the text view's) coordinates.
    var foldPlaceholders: (() -> [(rect: NSRect, header: Int)])?
    /// Extra cursors (multi-cursor): caret bars and selected text.
    var extraCursors: (() -> (carets: [NSRect], selections: [NSRect]))?
    /// Vim mode's block cursor (Normal and Visual mode), drawn over its character.
    var blockCaret: (() -> NSRect?)?
    /// Inlay hints: their labels' rects.
    var inlayHints: (() -> [(rect: NSRect, mark: InlayHintMark)])?
    /// An AI suggestion at the caret: its lines and where each starts (and the caret, in its gap).
    var ghostText: (() -> GhostDrawing)?
    /// The line the debugger is stopped at, highlighted across the editor.
    var executionLine: (() -> NSRect?)?
    /// Git blame of the cursor's line, drawn after its end.
    var blameAnnotation: (() -> BlameAnnotation?)?
    /// Merge conflicts: tinted sides, and the actions after each `<<<<<<<` line.
    var conflictBands: (() -> [(rect: NSRect, kind: ConflictBand)])?
    var conflictActions: (() -> [(rect: NSRect, conflict: MergeConflict, action: MergeConflict.Action)])?
    /// Unknown words (spell checking): dotted underlines, apart from the diagnostics' squiggles.
    var spellingUnderlines: (() -> [NSRect])?

    init(textView: NSTextView, document: EditorDocument) {
        self.textView = textView
        self.document = document
        super.init(frame: textView.bounds)
        autoresizingMask = [.width, .height]
        // Redrawn only where invalidated. The text view's height (so this view's) changes on
        // most layout passes in a big file, as TextKit refines its estimate: AppKit redrew all of
        // it each time. What's drawn stays where it is when the view grows or shrinks.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .topLeft
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { needsDisplay = true } // the execution line's band spans the width
    }

    // Drawn again whole for another screen's scale or appearance (the redraw policy above
    // leaves that to the view).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Out of a window (the editor closed): nothing is shown, and TextKit's paragraphs
        // aren't kept. Back in one, all of it is drawn again.
        drawnFragments = []
        drawnFrames = [:]
        drawnVisibleRect = .zero
        drawnMarks = []
        if window != nil { needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Tests: what was invalidated, and the rects each draw was asked for (nil: not recorded).
    var invalidations: [NSRect]?
    var draws: [[NSRect]]?

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        invalidations?.append(invalidRect.intersection(bounds))
        super.setNeedsDisplay(invalidRect)
    }

    // MARK: What to redraw

    /// Something drawn for the cursor (its brackets, its block's indent guide, the symbol's
    /// other places, its line's blame, extra cursors): redrawn where it was and where it goes.
    struct Mark: Hashable {
        let x, y, width, height: CGFloat
        let detail: String

        init(_ rect: NSRect, _ detail: String, outset: CGFloat = 3) {
            let rect = rect.insetBy(dx: -outset, dy: -outset)
            (x, y, width, height, self.detail) = (rect.minX, rect.minY, rect.width, rect.height, detail)
        }

        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    static func marks(brackets: [NSRect], activeGuides: [NSRect], occurrences: [(rect: NSRect, isWrite: Bool)],
                      annotation: BlameAnnotation?, extraCursors: (carets: [NSRect], selections: [NSRect])?,
                      blockCaret: NSRect? = nil) -> Set<Mark> {
        var marks = Set<Mark>()
        if let blockCaret { marks.insert(Mark(blockCaret, "block", outset: 1)) }
        for rect in brackets { marks.insert(Mark(rect, "bracket")) }
        for rect in activeGuides { marks.insert(Mark(rect, "guide", outset: 1)) }
        for (rect, isWrite) in occurrences { marks.insert(Mark(rect, isWrite ? "write" : "read")) }
        if let annotation {
            // Italic text leans past its width.
            marks.insert(Mark(annotation.rect, "blame \(annotation.isHovered) \(annotation.text)", outset: 6))
        }
        for rect in extraCursors?.carets ?? [] { marks.insert(Mark(rect, "caret")) }
        for rect in extraCursors?.selections ?? [] { marks.insert(Mark(rect, "selection", outset: 1)) }
        return marks
    }

    /// The cursor's marks now (the editor's: the same rects as drawn).
    var cursorMarks: (() -> Set<Mark>)?
    /// The cursor's marks as last drawn or invalidated to be drawn.
    private var drawnMarks = Set<Mark>()

    /// The cursor moved, or something it shows did: redraws the marks that changed.
    func marksDidChange() {
        guard let marks = cursorMarks?(), marks != drawnMarks else { return }
        for mark in marks.symmetricDifference(drawnMarks) { setNeedsDisplay(mark.rect) }
        drawnMarks = marks
    }

    /// The laid-out paragraphs as last drawn: kept (not just their identities) so that a
    /// new one can't reuse a dropped one's address.
    private var drawnFragments: [NSTextLayoutFragment] = []
    private var drawnFrames: [ObjectIdentifier: CGRect] = [:]
    private var drawnVisibleRect = NSRect.zero

    /// After a layout pass or a scroll: redraws what came into view, and the paragraphs that
    /// moved, appeared (edited ones are new) or went. Text that stayed put isn't redrawn.
    func layoutDidChange() {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else { return }
        let visible = visibleRect
        if visible != drawnVisibleRect {
            for piece in Self.subtract(drawnVisibleRect, from: visible) { setNeedsDisplay(piece) }
            drawnVisibleRect = visible
        }
        let origin = textView.textContainerOrigin
        var fragments: [NSTextLayoutFragment] = []
        var frames: [ObjectIdentifier: CGRect] = [:]
        layoutManager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            if fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedAscending { return false }
            guard fragment.state == .layoutAvailable else { return true }
            fragments.append(fragment)
            frames[ObjectIdentifier(fragment)] = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            return true
        }
        if frames != drawnFrames {
            let width = max(bounds.width, visible.maxX)
            func invalidate(_ frame: CGRect) {
                let rect = NSRect(x: 0, y: frame.minY - 2, width: width, height: frame.height + 4).intersection(visible)
                if !rect.isEmpty { setNeedsDisplay(rect) }
            }
            for (id, frame) in frames where drawnFrames[id] != frame { invalidate(frame) }
            for (id, frame) in drawnFrames where frames[id] != frame { invalidate(frame) }
        }
        drawnFragments = fragments
        drawnFrames = frames
        marksDidChange()
    }

    /// The parts of `rect` outside `other` (up to four bands).
    static func subtract(_ other: NSRect, from rect: NSRect) -> [NSRect] {
        let overlap = rect.intersection(other)
        guard !overlap.isEmpty else { return rect.isEmpty ? [] : [rect] }
        var pieces: [NSRect] = []
        if overlap.minY > rect.minY { pieces.append(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY)) }
        if overlap.maxY < rect.maxY { pieces.append(NSRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY)) }
        if overlap.minX > rect.minX { pieces.append(NSRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height)) }
        if overlap.maxX < rect.maxX { pieces.append(NSRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)) }
        return pieces
    }

    /// Rects (in this view) of the text each diagnostic covers, with its color. Visible for tests.
    func segments() -> [(rect: CGRect, color: NSColor)] {
        guard let textView, let document, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return [] }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -50)
        let length = document.textStorage.length
        var result: [(CGRect, NSColor)] = []
        // Only the diagnostics in the laid-out viewport: asking TextKit for the segments of
        // every diagnostic in the file, on each redraw (each keystroke and cursor move), took
        // 30 ms with 1,000 diagnostics. Compared by line first, which costs next to nothing.
        var viewport = NSRange(location: 0, length: length)
        if let viewportRange = layoutManager.textViewportLayoutController.viewportRange {
            let documentStart = contentManager.documentRange.location
            let start = contentManager.offset(from: documentStart, to: viewportRange.location)
            let end = contentManager.offset(from: documentStart, to: viewportRange.endLocation)
            viewport = NSRange(location: start, length: max(0, end - start))
        }
        let index = document.lineIndex
        let firstLine = index.line(containing: viewport.location), lastLine = index.line(containing: NSMaxRange(viewport))
        let lastDocumentLine = index.lineCount - 1

        for diagnostic in document.diagnostics {
            // Lines past the end are drawn at the end of the text.
            guard min(diagnostic.range.start.line, lastDocumentLine) <= lastLine,
                  min(diagnostic.range.end.line, lastDocumentLine) >= firstLine else { continue }
            var range = document.range(for: diagnostic.range)
            if range.length == 0 { // point diagnostics: underline the character there
                range = NSRange(location: min(range.location, max(0, length - 1)), length: length > 0 ? 1 : 0)
            }
            range = NSIntersectionRange(range, viewport) // one over many lines: the part in view
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
        let signpost = Signposts.begin("Overlay Draw"); defer { Signposts.end("Overlay Draw", signpost) }
        if draws != nil { draws?.append(rectsBeingDrawn()) }
        let theme = EditorTheme.current
        let isWhole = dirtyRect.contains(visibleRect)
        if isWhole { drawnVisibleRect = visibleRect }
        if let rect = executionLine?(), rect.intersects(dirtyRect) {
            NSColor.systemYellow.withAlphaComponent(0.22).setFill()
            rect.fill(using: .sourceOver)
        }
        let marks = whitespace?() ?? []
        if !marks.isEmpty {
            let color = theme.lineNumber.withAlphaComponent(0.6)
            color.setFill()
            color.setStroke()
            for (rect, isTab) in marks where rect.intersects(dirtyRect) {
                if isTab {
                    // An arrow across the tab's width.
                    let y = rect.midY.rounded() + 0.5
                    let arrow = NSBezierPath()
                    arrow.lineWidth = 1
                    arrow.move(to: NSPoint(x: rect.minX + 2, y: y))
                    arrow.line(to: NSPoint(x: rect.maxX - 2, y: y))
                    arrow.move(to: NSPoint(x: rect.maxX - 5, y: y - 3))
                    arrow.line(to: NSPoint(x: rect.maxX - 2, y: y))
                    arrow.line(to: NSPoint(x: rect.maxX - 5, y: y + 3))
                    arrow.stroke()
                } else {
                    let size: CGFloat = 2
                    NSBezierPath(ovalIn: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)).fill()
                }
            }
        }
        let guides = indentGuides?(dirtyRect) ?? []
        for (rect, isActive) in guides where rect.intersects(dirtyRect) {
            theme.lineNumber.withAlphaComponent(isActive ? 0.55 : 0.18).setFill()
            rect.fill(using: .sourceOver)
        }
        let brackets = brackets?() ?? []
        let occurrences = occurrences?() ?? []
        let annotation = blameAnnotation?()
        let extraCursors = extraCursors?()
        let block = blockCaret?()
        // Drawn whole: these are the cursor's marks shown now.
        if isWhole {
            let visible = visibleRect
            let activeGuides = guides.filter { $0.isActive && $0.rect.maxY >= visible.minY && $0.rect.minY <= visible.maxY }
            drawnMarks = Self.marks(brackets: brackets, activeGuides: activeGuides.map(\.rect), occurrences: occurrences,
                                    annotation: annotation, extraCursors: extraCursors, blockCaret: block)
        }
        if let block, block.intersects(dirtyRect) {
            theme.cursor.withAlphaComponent(0.45).setFill()
            block.fill(using: .sourceOver)
        }
        for rect in brackets where rect.intersects(dirtyRect.insetBy(dx: -2, dy: -2)) {
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            theme.selection.withAlphaComponent(0.3).setFill()
            box.fill()
            theme.foreground.withAlphaComponent(0.45).setStroke()
            box.lineWidth = 1
            box.stroke()
        }
        for (rect, isWrite) in occurrences where rect.intersects(dirtyRect) {
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: -0.5, dy: 0), xRadius: 2, yRadius: 2)
            theme.selection.withAlphaComponent(isWrite ? 0.5 : 0.35).setFill()
            box.fill()
            if isWrite {
                theme.foreground.withAlphaComponent(0.35).setStroke()
                box.lineWidth = 1
                box.stroke()
            }
        }
        for (rect, kind) in conflictBands?() ?? [] where rect.intersects(dirtyRect) {
            kind.color.setFill()
            rect.fill(using: .sourceOver)
        }
        let actions = conflictActions?() ?? []
        for (index, action) in actions.enumerated() where action.rect.intersects(dirtyRect) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: EditorController.conflictActionFont, .foregroundColor: NSColor.linkColor,
            ]
            let text = action.action.title as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: action.rect.minX, y: action.rect.midY - size.height / 2), withAttributes: attributes)
            // "|" between the actions of one conflict.
            if index + 1 < actions.count, actions[index + 1].conflict == action.conflict {
                let separator = "|" as NSString
                let separatorAttributes: [NSAttributedString.Key: Any] = [
                    .font: EditorController.conflictActionFont, .foregroundColor: theme.lineNumber,
                ]
                let gap = actions[index + 1].rect.minX - action.rect.maxX
                let width = separator.size(withAttributes: separatorAttributes).width
                separator.draw(at: NSPoint(x: action.rect.maxX + (gap - width) / 2, y: action.rect.midY - size.height / 2),
                               withAttributes: separatorAttributes)
            }
        }
        let hints = inlayHints?() ?? []
        if !hints.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: InlayHintStyle.font, .foregroundColor: theme.lineNumber]
            for (rect, mark) in hints where rect.intersects(dirtyRect) {
                theme.lineNumber.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                let text = mark.text as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            }
        }
        if let ghost = ghostText?(), !ghost.lines.isEmpty {
            let attributes = GhostTextStyle.attributes
            for (origin, text) in ghost.lines {
                let size = (text as NSString).size(withAttributes: attributes)
                guard NSRect(origin: origin, size: size).intersects(dirtyRect) else { continue }
                (text as NSString).draw(at: origin, withAttributes: attributes)
            }
            if let caret = ghost.caret, caret.intersects(dirtyRect) {
                theme.cursor.setFill()
                caret.fill()
            }
        }
        let lensHovered = hoveredCodeLens?()
        for mark in codeLenses?() ?? [] where mark.rect.intersects(dirtyRect) {
            let isHovered = mark.rect == lensHovered
            var attributes: [NSAttributedString.Key: Any] = [
                .font: EditorController.codeLensFont,
                .foregroundColor: isHovered ? NSColor.linkColor : theme.lineNumber.withAlphaComponent(0.9),
            ]
            if isHovered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            let text = mark.title as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: mark.rect.minX, y: mark.rect.midY - size.height / 2), withAttributes: attributes)
        }
        if let annotation {
            // Brighter and underlined while the mouse is on it: it can be clicked.
            let isHovered = annotation.isHovered
            var attributes: [NSAttributedString.Key: Any] = [
                .font: EditorController.blameFont,
                .foregroundColor: theme.lineNumber.withAlphaComponent(isHovered ? 1 : 0.8),
            ]
            if isHovered { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            (annotation.text as NSString).draw(at: annotation.rect.origin, withAttributes: attributes)
        }
        if let (carets, selections) = extraCursors {
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
        if let rect = linkUnderline?(), rect.intersects(dirtyRect.insetBy(dx: 0, dy: -2)) {
            NSColor.linkColor.setFill()
            NSRect(x: rect.minX, y: rect.maxY - 1.5, width: rect.width, height: 1).fill()
        }
        let spelling = spellingUnderlines?() ?? []
        if !spelling.isEmpty {
            Self.spellingColor.setFill()
            for rect in spelling where rect.intersects(dirtyRect.insetBy(dx: 0, dy: -4)) {
                // Dots 1.5 points square, 1.5 apart, along the bottom of the word.
                var x = rect.minX + 0.5
                while x + 1.5 <= rect.maxX + 0.5 {
                    NSRect(x: x, y: rect.maxY - 2, width: 1.5, height: 1.5).fill()
                    x += 3
                }
            }
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

    /// Teal, not a problem's color; it follows light and dark (the editor's appearance).
    static let spellingColor = NSColor.systemTeal.withAlphaComponent(0.85)

    static func color(for severity: Diagnostic.Severity) -> NSColor {
        switch severity {
        case .error: .systemRed
        case .warning: .systemYellow
        case .information, .hint: .systemBlue
        }
    }
}
