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
    /// Called with the zero-based line when its fold chevron is clicked.
    var onFoldClick: ((Int) -> Void)?
    /// Hovering the blame column: the line and its rect there (nil: the mouse left it).
    var onBlameHover: ((Int?, NSRect) -> Void)?
    var onBlameExited: (() -> Void)?
    /// A click in the blame column, with the line.
    var onBlameClick: ((Int) -> Void)?
    /// The context menu for a line (blame toggle and the line's commit).
    var menuForLine: ((Int?) -> NSMenu?)?
    /// Width of the blame column at the left edge (0 when hidden).
    private(set) var blameWidth: CGFloat = 0
    /// Width of the test column after it (0 when the file has no tests).
    private(set) var testWidth: CGFloat = 0
    static let testColumnWidth: CGFloat = 18
    /// What comes before the change strip.
    var leadingWidth: CGFloat { blameWidth + testWidth }
    /// A click on a test's mark: run it.
    var onTestClick: ((Int) -> Void)?
    /// Width of the fold chevron column at the right edge.
    static let foldColumnWidth: CGFloat = 14
    private var isHovering = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    // Chevrons for unfolded regions show while the pointer is over the gutter, as in VS Code.
    override func mouseEntered(with event: NSEvent) { isHovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        onBlameExited?()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard point.x < blameWidth, let (line, rect) = line(at: point) else { onBlameHover?(nil, .zero); return }
        onBlameHover?(line, NSRect(x: 0, y: rect.minY, width: blameWidth, height: rect.height))
    }

    /// The line at a point in this view, and its rect.
    func line(at point: NSPoint) -> (Int, NSRect)? {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        let inText = convert(point, to: textView)
        let origin = textView.textContainerOrigin
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: inText.y - origin.y)) else { return nil }
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        var line = document.lineIndex.line(containing: offset)
        // The last fragment can also hold the empty line after a trailing newline.
        let frame = fragment.layoutFragmentFrame
        var lineTop = frame.minY, lineHeight = frame.height
        // The row under the point is in a line; a wrapped line's rect covers all its rows.
        let rows = fragment.textLineFragments.map { lineFragment -> (line: Int, bounds: CGRect) in
            let start = offset + lineFragment.characterRange.location
            let found = start >= document.textStorage.length && lineFragment.characterRange.length == 0
                ? document.lineIndex.lineCount - 1 : document.lineIndex.line(containing: start)
            return (found, lineFragment.typographicBounds)
        }
        if let hit = rows.last(where: { inText.y - origin.y >= frame.minY + $0.bounds.minY }) ?? rows.first {
            line = hit.line
            let own = rows.filter { $0.line == hit.line }.map(\.bounds)
            lineTop = frame.minY + (own.map(\.minY).min() ?? 0)
            lineHeight = frame.minY + (own.map(\.maxY).max() ?? 0) - lineTop
        }
        let top = convert(NSPoint(x: 0, y: lineTop + origin.y), from: textView).y
        return (line, NSRect(x: 0, y: top, width: width, height: lineHeight))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (line, lineRect) = line(at: point) else { return }
        if point.x < blameWidth {
            onBlameClick?(line)
            return
        }
        if point.x < leadingWidth {
            if document.testMarks?()[line] != nil { onTestClick?(line) }
            return
        }
        if point.x >= width - Self.foldColumnWidth, document.isFolded(line: line) || document.isFoldable(line: line) {
            onFoldClick?(line)
            return
        }
        // The change bar's strip shows the change; the rest of the numbers toggles a breakpoint.
        if point.x < leadingWidth + Self.changeStripWidth || onBreakpointClick == nil {
            onLineClick?(line, NSRect(x: leadingWidth, y: lineRect.minY, width: 8, height: lineRect.height))
        } else {
            onBreakpointClick?(line)
        }
    }

    /// Width of the change bars' strip at the left of the line numbers.
    static let changeStripWidth: CGFloat = 8
    /// A click on a line number: toggle its breakpoint.
    var onBreakpointClick: ((Int) -> Void)?

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

    private static let foldedChevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Unfold")
    private static let openChevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Fold")

    private func drawFoldChevron(line: Int, y: CGFloat, height: CGFloat, color: NSColor) {
        let folded = document.isFolded(line: line)
        guard folded || (isHovering && document.isFoldable(line: line)),
              let symbol = folded ? Self.foldedChevron : Self.openChevron else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(.init(paletteColors: [folded ? EditorTheme.current.foreground : color]))
        guard let image = symbol.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: width - Self.foldColumnWidth + (Self.foldColumnWidth - size.width) / 2 - 2,
                              y: y + (height - size.height) / 2, width: size.width, height: size.height))
    }

    func updateWidth() {
        let digits = max(3, String(document.lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: EditorTheme.gutterFont]).width
        let blame = document.showsBlameColumn ? ceil(digitWidth * 30) : 0
        let tests = document.testMarks?().isEmpty == false ? Self.testColumnWidth : 0
        guard digits != digitCount || blame != blameWidth || tests != testWidth else { return }
        testWidth = tests
        digitCount = digits
        blameWidth = blame
        width = blame + tests + ceil(digitWidth * CGFloat(digits)) + 20 + Self.foldColumnWidth
        onWidthChange?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuForLine?(line(at: convert(event.locationInWindow, from: nil))?.0)
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
        let blame = blameWidth > 0 ? BlameColumn(document: document, width: blameWidth) : nil
        if blame != nil {
            theme.lineNumber.withAlphaComponent(0.06).setFill()
            NSRect(x: 0, y: dirtyRect.minY, width: blameWidth, height: dirtyRect.height).fill(using: .sourceOver)
        }
        var firstDrawnLine: Int?
        let breakpoints = document.breakpointMarks?() ?? [:]
        let testMarks = testWidth > 0 ? document.testMarks?() ?? [:] : [:]
        let executionLine = document.executionLine

        layoutManager.enumerateTextLayoutFragments(from: viewportRange.location, options: []) { fragment in
            if fragment.rangeInElement.location.compare(viewportRange.endLocation) == .orderedDescending { return false }
            guard fragment.state == .layoutAvailable else { return true }
            let fragmentFrame = fragment.layoutFragmentFrame
            if fragmentFrame.minY + containerOrigin.y > visibleRect.maxY { return false }
            if fragmentFrame.maxY + containerOrigin.y < visibleRect.minY { return true }

            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let firstLine = self.document.lineIndex.line(containing: offset)

            // A fragment is one line: wrapped, it has a line fragment per row (marks go on the
            // first); the last one also carries the empty "extra" line after a trailing newline.
            for lineFragment in fragment.textLineFragments {
                let start = offset + lineFragment.characterRange.location
                let line = start >= self.document.textStorage.length && lineFragment.characterRange.length == 0
                    ? self.document.lineIndex.lineCount - 1 : self.document.lineIndex.line(containing: start)
                guard line >= firstLine, start == self.document.lineIndex.lineStarts[line] else { continue }
                let bounds = lineFragment.typographicBounds
                let yInTextView = fragmentFrame.minY + containerOrigin.y + bounds.minY
                let y = self.convert(NSPoint(x: 0, y: yInTextView), from: textView).y

                if let blame {
                    blame.draw(line: line, isFirstShown: firstDrawnLine == nil, y: y, height: bounds.height,
                               isCurrent: line == currentLine)
                }
                if firstDrawnLine == nil { firstDrawnLine = line }
                if let marker = self.document.diffMarkers[line] {
                    self.drawDiffMarker(marker, x: self.leadingWidth, y: y, height: bounds.height)
                }

                if let state = testMarks[line] {
                    self.drawTestMark(state, y: y, height: bounds.height)
                }
                if let mark = breakpoints[line] {
                    self.drawBreakpoint(mark, y: y, height: bounds.height)
                }
                if line == executionLine {
                    self.drawExecutionArrow(y: y, height: bounds.height)
                }
                let label = String(line + 1) as NSString
                let attributes = line == currentLine ? currentAttributes : normalAttributes
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: self.width - Self.foldColumnWidth - size.width - 6,
                                       y: y + (bounds.height - size.height) / 2),
                           withAttributes: attributes)
                self.drawFoldChevron(line: line, y: y, height: bounds.height, color: theme.lineNumber)
            }
            return true
        }
    }
}

extension GutterView {
    /// A red dot before the line number (a diamond for a logpoint): hollow when the debugger
    /// couldn't place it, grey when disabled, with a bar when it has a condition.
    fileprivate func drawBreakpoint(_ mark: BreakpointMark, y: CGFloat, height: CGFloat) {
        let size = min(10, height - 4)
        let rect = NSRect(x: leadingWidth + Self.changeStripWidth + 1, y: y + (height - size) / 2, width: size, height: size)
        let color = mark.isEnabled ? NSColor.systemRed : NSColor.systemGray
        // A logpoint is a diamond.
        let dot: NSBezierPath
        if mark.isLogpoint {
            dot = NSBezierPath()
            dot.move(to: NSPoint(x: rect.midX, y: rect.minY))
            dot.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            dot.line(to: NSPoint(x: rect.midX, y: rect.maxY))
            dot.line(to: NSPoint(x: rect.minX, y: rect.midY))
            dot.close()
        } else {
            dot = NSBezierPath(ovalIn: rect)
        }
        if mark.isVerified == false {
            color.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        } else {
            color.setFill()
            dot.fill()
        }
        if mark.hasCondition {
            NSColor.white.setFill()
            NSRect(x: rect.minX + 2.5, y: rect.midY - 0.75, width: rect.width - 5, height: 1.5).fill()
        }
    }

    /// A yellow arrow where the debugger is stopped.
    /// ▶ for a test not run yet, ✓ passed, ✗ failed, a ring while it runs.
    fileprivate func drawTestMark(_ state: TestController.State, y: CGFloat, height: CGFloat) {
        let (symbol, color): (String, NSColor) = switch state {
        case .passed: ("checkmark.circle.fill", .systemGreen)
        case .failed: ("xmark.circle.fill", .systemRed)
        case .running, .queued: ("circle.dotted", .systemOrange)
        case .skipped: ("forward.circle", .secondaryLabelColor)
        case .notRun: ("exclamationmark.circle", .systemOrange)
        case .unknown: ("play.fill", .systemGreen)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: min(12, height * 0.8), weight: .bold)
            // Filled circles: a white mark on the color.
            .applying(.init(paletteColors: symbol.hasSuffix(".fill") && symbol.contains("circle") ? [.white, color] : [color]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: blameWidth + (testWidth - size.width) / 2, y: y + (height - size.height) / 2,
                              width: size.width, height: size.height))
    }

    fileprivate func drawExecutionArrow(y: CGFloat, height: CGFloat) {
        let size = min(12, height - 2)
        let x = leadingWidth + Self.changeStripWidth
        let top = y + (height - size) / 2
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: x, y: top + size * 0.25))
        arrow.line(to: NSPoint(x: x + size * 0.5, y: top + size * 0.25))
        arrow.line(to: NSPoint(x: x + size * 0.5, y: top))
        arrow.line(to: NSPoint(x: x + size, y: top + size / 2))
        arrow.line(to: NSPoint(x: x + size * 0.5, y: top + size))
        arrow.line(to: NSPoint(x: x + size * 0.5, y: top + size * 0.75))
        arrow.line(to: NSPoint(x: x, y: top + size * 0.75))
        arrow.close()
        NSColor.systemYellow.setFill()
        arrow.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        arrow.lineWidth = 0.75
        arrow.stroke()
    }

    /// VS Code-style change bar at the gutter's left edge.
    fileprivate func drawDiffMarker(_ marker: DiffMarker, x: CGFloat, y: CGFloat, height: CGFloat) {
        switch marker {
        case .added:
            NSColor.systemGreen.setFill()
            NSRect(x: x + 2, y: y, width: 3, height: height).fill()
        case .modified:
            NSColor.systemBlue.setFill()
            NSRect(x: x + 2, y: y, width: 3, height: height).fill()
        case .deletedAbove:
            NSColor.systemRed.setFill()
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: x + 1, y: y - 4))
            triangle.line(to: NSPoint(x: x + 7, y: y))
            triangle.line(to: NSPoint(x: x + 1, y: y + 4))
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
    var minimapView: MinimapView? {
        didSet { oldValue?.removeFromSuperview(); if let minimapView { addSubview(minimapView) }; needsLayout = true }
    }
    var stickyView: StickyScrollView? {
        didSet { oldValue?.removeFromSuperview(); if let stickyView { addSubview(stickyView, positioned: .above, relativeTo: nil) }; needsLayout = true }
    }

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
        let showsMinimap = minimapView.map { !$0.isHidden } ?? false
        let minimapWidth = showsMinimap ? MinimapView.width : 0
        let textWidth = max(0, bounds.width - gutterWidth - minimapWidth)
        gutterView.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: textWidth, height: bounds.height)
        minimapView?.frame = NSRect(x: gutterWidth + textWidth, y: 0, width: minimapWidth, height: bounds.height)
        if let stickyView {
            // Across the gutter and the text, at the top (this view isn't flipped).
            let height = min(stickyView.height, bounds.height / 2)
            stickyView.frame = NSRect(x: 0, y: bounds.height - height, width: gutterWidth + textWidth, height: height)
            stickyView.isHidden = height == 0
        }
        gutterView.needsDisplay = true
    }
}

/// Draws the blame column: each run of lines from one commit starts with its author and age,
/// and a bar on the right is brighter for newer commits.
@MainActor
struct BlameColumn {
    let document: EditorDocument
    let width: CGFloat
    private let blame: [BlameLine?]
    private let dates: ClosedRange<Date>?

    init(document: EditorDocument, width: CGFloat) {
        self.document = document
        self.width = width
        blame = document.blame ?? []
        dates = document.blameDates
    }

    static var font: NSFont { EditorTheme.gutterFont }

    func entry(_ line: Int) -> BlameLine? { line >= 0 && line < blame.count ? blame[line] : nil }

    /// Whether a line starts a run of lines from one commit.
    func startsRun(_ line: Int) -> Bool { entry(line - 1)?.commit != entry(line)?.commit }

    /// How recent the commit is among the file's, from 0 (oldest) to 1 (newest).
    func recency(_ entry: BlameLine) -> Double {
        if entry.isUncommitted { return 1 }
        guard let dates, dates.upperBound > dates.lowerBound else { return 1 }
        return entry.date.timeIntervalSince(dates.lowerBound) / dates.upperBound.timeIntervalSince(dates.lowerBound)
    }

    func draw(line: Int, isFirstShown: Bool, y: CGFloat, height: CGFloat, isCurrent: Bool) {
        guard let entry = entry(line) else { return }
        let theme = EditorTheme.current
        let bar = entry.isUncommitted ? NSColor.systemBlue : NSColor.systemOrange
        bar.withAlphaComponent(0.2 + 0.8 * recency(entry)).setFill()
        NSRect(x: width - 4, y: y, width: 2, height: height).fill()
        let starts = startsRun(line)
        if starts, line > 0 {
            theme.lineNumber.withAlphaComponent(0.18).setFill()
            NSRect(x: 0, y: y, width: width, height: 1).fill(using: .sourceOver)
        }
        guard starts || isFirstShown else { return }
        let color = isCurrent ? theme.currentLineNumber : theme.lineNumber
        let (author, age) = Self.texts(entry)
        let ageAttributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color.withAlphaComponent(0.8)]
        let ageSize = (age as NSString).size(withAttributes: ageAttributes)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let authorAttributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color, .paragraphStyle: paragraph]
        let textY = y + (height - ageSize.height) / 2
        let right = width - 10
        (age as NSString).draw(at: NSPoint(x: right - ageSize.width, y: textY), withAttributes: ageAttributes)
        (author as NSString).draw(with: NSRect(x: 6, y: textY, width: max(0, right - ageSize.width - 14), height: ageSize.height),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: authorAttributes)
    }

    /// The author and a short age ("3 days ago"); edited lines say so instead.
    nonisolated static func texts(_ entry: BlameLine, now: Date = Date()) -> (author: String, age: String) {
        if entry.isUncommitted { return ("Not committed", "") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return (entry.author, formatter.localizedString(for: entry.date, relativeTo: now))
    }
}

extension NSView {
    /// Removes every view under this one, deepest first, so none is left in a superview.
    func removeAllSubviews() {
        for view in subviews {
            view.removeAllSubviews()
            view.removeFromSuperview()
        }
    }
}
