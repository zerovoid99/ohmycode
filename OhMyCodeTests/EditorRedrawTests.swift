import AppKit
import Testing
@testable import Oh_My_Code

/// What the gutter and the overlay redraw after a cursor move, a keystroke, a scroll, folding,
/// new diagnostics or a new bracket pair: only what changed, and enough of it. Each change is
/// checked twice: by the rects invalidated (and drawn), and by pixels, two full renders before
/// and after it differing only inside what was invalidated.
@MainActor
@Suite(.serialized)
struct EditorRedrawTests {
    /// Functions of 8 lines: a header, an indented body with a nested block, a blank line.
    static let text = (0..<60).map { index in
        [
            "func work\(index)() {",
            "    let first = \(index)",
            "    let second = first + 1",
            "    if first > second {",
            "        print(first)",
            "    }",
            "}",
            "",
        ].joined(separator: "\n") + "\n"
    }.joined()

    @MainActor private struct Editor {
        let document: EditorDocument
        let controller: EditorController
        let window: NSWindow
        var gutter: GutterView { controller.gutterView }
        var overlay: DiagnosticsOverlayView { controller.diagnosticsOverlay! }
        var lineStarts: LineIndex.LineStarts { document.lineIndex.lineStarts }
    }

    private func makeEditor() async throws -> Editor {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-redraw-\(UUID().uuidString).swift")
        try Self.text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        let editor = Editor(document: document, controller: controller, window: window)
        try await Task.sleep(for: .milliseconds(50)) // the editor's setup after it's shown
        await document.highlighter?.waitUntilIdle()
        await document.waitForFoldRegions()
        controller.scrollLineToTop(96) // work12 starts at line 96
        controller.textView.setSelectedRange(NSRange(location: editor.lineStarts[98] + 8, length: 0)) // in "let second"
        settle(editor)
        try await Task.sleep(for: .milliseconds(50))
        settle(editor)
        return editor
    }

    /// Lays out and draws what's dirty, as at the end of an event.
    private func settle(_ editor: Editor) {
        editor.controller.textView.layoutSubtreeIfNeeded()
        editor.window.displayIfNeeded()
        CATransaction.flush()
    }

    private func record(_ editor: Editor) {
        editor.gutter.invalidations = []
        editor.gutter.draws = []
        editor.overlay.invalidations = []
        editor.overlay.draws = []
    }

    private func union(_ rects: [NSRect]) -> NSRect {
        rects.filter { !$0.isEmpty }.reduce(NSRect.null) { $0.union($1) }
    }

    /// Where a line's row is in the gutter.
    private func row(_ editor: Editor, _ line: Int) throws -> GutterView.Row {
        try #require(editor.gutter.visibleRows().first { $0.line == line })
    }

    /// A line's band in the overlay (text view coordinates).
    private func band(_ editor: Editor, _ line: Int) throws -> NSRect {
        try #require(editor.controller.rect(for: NSRange(location: editor.lineStarts[line], length: 1)))
    }

    // MARK: Pixels

    @MainActor private struct Pixels {
        let rep: NSBitmapImageRep
        let rect: NSRect
        var scale: CGFloat { CGFloat(rep.pixelsWide) / rect.width }

        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            let bytes = rep.bitsPerPixel / 8
            let base = rep.bitmapData! + y * rep.bytesPerRow + x * bytes
            var value: UInt32 = 0
            for byte in 0..<min(bytes, 4) { value = value << 8 | UInt32(base[byte]) }
            return value
        }
    }

    /// The view drawn alone into a bitmap (flipped views: the first row is the rect's top).
    private func render(_ view: NSView, _ rect: NSRect) throws -> Pixels {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: rep)
        return Pixels(rep: rep, rect: rect)
    }

    /// Checks that `before` and `after` (renders of the same rect) differ only inside `rects`;
    /// returns how many pixels differ.
    @discardableResult
    private func expectChangesCovered(_ before: Pixels, _ after: Pixels, by rects: [NSRect],
                                      sourceLocation: SourceLocation = #_sourceLocation) -> Int {
        #expect(before.rep.pixelsWide == after.rep.pixelsWide && before.rep.pixelsHigh == after.rep.pixelsHigh,
                sourceLocation: sourceLocation)
        let scale = after.scale
        var differing = 0, uncovered = 0
        var firstUncovered: NSPoint?
        for y in 0..<after.rep.pixelsHigh {
            for x in 0..<after.rep.pixelsWide where before.pixel(x, y) != after.pixel(x, y) {
                differing += 1
                let point = NSPoint(x: after.rect.minX + (CGFloat(x) + 0.5) / scale, y: after.rect.minY + (CGFloat(y) + 0.5) / scale)
                if !rects.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) {
                    uncovered += 1
                    firstUncovered = firstUncovered ?? point
                }
            }
        }
        #expect(uncovered == 0, "\(uncovered) changed pixels outside what was redrawn, first at \(String(describing: firstUncovered))",
                sourceLocation: sourceLocation)
        return differing
    }

    /// Checks that drawing just `rect` gives the pixels a full draw gives there.
    private func expectPartialDrawMatches(_ view: NSView, _ full: Pixels, in rect: NSRect,
                                          sourceLocation: SourceLocation = #_sourceLocation) throws {
        let rect = rect.integral.intersection(full.rect)
        guard !rect.isEmpty else { return }
        let part = try render(view, rect)
        let scale = full.scale
        let dx = Int(((rect.minX - full.rect.minX) * scale).rounded()), dy = Int(((rect.minY - full.rect.minY) * scale).rounded())
        var differing = 0
        for y in 0..<part.rep.pixelsHigh where y + dy < full.rep.pixelsHigh {
            for x in 0..<part.rep.pixelsWide where x + dx < full.rep.pixelsWide && part.pixel(x, y) != full.pixel(x + dx, y + dy) {
                differing += 1
            }
        }
        #expect(differing == 0, "drawing \(rect) alone differs from a full draw in \(differing) pixels", sourceLocation: sourceLocation)
    }

    /// The overlay's visible rect, on whole points.
    private func overlayArea(_ editor: Editor) -> NSRect { editor.overlay.visibleRect.integral.intersection(editor.overlay.bounds) }

    // MARK: Cursor

    @Test func cursorMoveWithinALineRedrawsNothing() async throws {
        let editor = try await makeEditor()
        record(editor)
        editor.controller.textView.setSelectedRange(NSRange(location: editor.lineStarts[98] + 10, length: 0))
        settle(editor)
        #expect(editor.gutter.invalidations == [])
        #expect(editor.overlay.invalidations == [])
        #expect(editor.gutter.draws == [])
        #expect(editor.overlay.draws == [])
        withExtendedLifetime(editor.window) {}
    }

    @Test func cursorMoveAcrossLinesRedrawsTheirRows() async throws {
        let editor = try await makeEditor()
        let (old, new) = (try row(editor, 98), try row(editor, 97))
        let gutterBefore = try render(editor.gutter, editor.gutter.bounds)
        record(editor)
        // Up a line, in the same block: the line numbers' highlight moves; the overlay's marks don't.
        editor.controller.textView.setSelectedRange(NSRange(location: editor.lineStarts[97] + 8, length: 0))
        settle(editor)
        let rows = NSRect(x: 0, y: new.y - GutterView.rowOverhang, width: editor.gutter.bounds.width,
                          height: old.y + old.height - new.y + 2 * GutterView.rowOverhang)
        let invalidated = try #require(editor.gutter.invalidations)
        #expect(invalidated.count == 2)
        #expect(rows.contains(union(invalidated)))
        // (Drawn on whole pixels.)
        #expect(rows.insetBy(dx: 0, dy: -1).contains(union(try #require(editor.gutter.draws).flatMap { $0 })),
                "\(String(describing: editor.gutter.draws)) vs \(rows)")
        #expect(editor.overlay.invalidations == [])
        let gutterAfter = try render(editor.gutter, editor.gutter.bounds)
        #expect(expectChangesCovered(gutterBefore, gutterAfter, by: invalidated) > 0) // the highlight moved
        try expectPartialDrawMatches(editor.gutter, gutterAfter, in: union(invalidated))

        // Into the nested block: its indent guide is the active one now, nothing else changes.
        let overlayBefore = try render(editor.overlay, overlayArea(editor))
        record(editor)
        editor.controller.textView.setSelectedRange(NSRange(location: editor.lineStarts[100] + 9, length: 0)) // in "print"
        settle(editor)
        let marks = try #require(editor.overlay.invalidations)
        #expect(!marks.isEmpty)
        #expect(marks.allSatisfy { $0.width <= 8 }, "only indent guides change: \(marks)")
        let overlayAfter = try render(editor.overlay, overlayArea(editor))
        #expect(expectChangesCovered(overlayBefore, overlayAfter, by: marks) > 0)
        withExtendedLifetime(editor.window) {}
    }

    @Test func bracketPairRedrawsBothBrackets() async throws {
        let editor = try await makeEditor()
        let header = editor.lineStarts[96]
        let open = header + ("func work12() " as NSString).length // the "{"
        let overlayBefore = try render(editor.overlay, overlayArea(editor))
        record(editor)
        editor.controller.textView.setSelectedRange(NSRange(location: open + 1, length: 0))
        settle(editor)
        let brackets = editor.controller.bracketRects()
        #expect(brackets.count == 2)
        let invalidated = try #require(editor.overlay.invalidations)
        for bracket in brackets {
            #expect(invalidated.contains { $0.contains(bracket) }, "bracket at \(bracket) not redrawn")
        }
        // Nothing across the width: the brackets, the guides and the line numbers that changed.
        #expect(invalidated.allSatisfy { $0.width < 100 }, "\(invalidated)")
        let overlayAfter = try render(editor.overlay, overlayArea(editor))
        #expect(expectChangesCovered(overlayBefore, overlayAfter, by: invalidated) > 0)
        try expectPartialDrawMatches(editor.overlay, overlayAfter, in: union(invalidated))

        // Away from them: where they were is redrawn.
        record(editor)
        editor.controller.textView.setSelectedRange(NSRange(location: editor.lineStarts[98] + 8, length: 0))
        settle(editor)
        let cleared = try #require(editor.overlay.invalidations)
        for bracket in brackets {
            #expect(cleared.contains { $0.contains(bracket) }, "old bracket at \(bracket) not redrawn")
        }
        expectChangesCovered(overlayAfter, try render(editor.overlay, overlayArea(editor)), by: cleared)
        withExtendedLifetime(editor.window) {}
    }

    // MARK: Typing

    @Test func typingACharacterRedrawsItsLine() async throws {
        let editor = try await makeEditor()
        let line = 98
        let edited = try row(editor, line)
        let lineBand = try band(editor, line)
        let gutterBefore = try render(editor.gutter, editor.gutter.bounds)
        let overlayBefore = try render(editor.overlay, overlayArea(editor))
        record(editor)
        editor.controller.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(editor)
        // The gutter: the line.
        let gutterRects = try #require(editor.gutter.invalidations)
        let rows = union(gutterRects)
        #expect(rows.minY >= edited.y - GutterView.rowOverhang - 0.5)
        #expect(rows.maxY <= edited.y + edited.height + GutterView.rowOverhang + 0.5, "\(gutterRects) vs \(edited)")
        // The overlay: the line's band (and the next line's: TextKit makes its paragraph again).
        let overlayRects = try #require(editor.overlay.invalidations)
        let overlayUnion = union(overlayRects)
        #expect(overlayUnion.minY >= lineBand.minY - 4 && overlayUnion.maxY <= lineBand.maxY + lineBand.height + 4,
                "\(overlayRects) vs line \(lineBand)")
        let drawn = union(try #require(editor.overlay.draws).flatMap { $0 })
        #expect(drawn.height <= 2 * lineBand.height + 8, "\(overlayRects)")

        expectChangesCovered(gutterBefore, try render(editor.gutter, editor.gutter.bounds), by: gutterRects)
        let overlayAfter = try render(editor.overlay, overlayArea(editor))
        expectChangesCovered(overlayBefore, overlayAfter, by: overlayRects)
        try expectPartialDrawMatches(editor.overlay, overlayAfter, in: overlayUnion)
        withExtendedLifetime(editor.window) {}
    }

    @Test func newlineRedrawsTheLinesBelow() async throws {
        let editor = try await makeEditor()
        let line = 98
        let edited = try row(editor, line)
        let lineBand = try band(editor, line)
        let gutterBefore = try render(editor.gutter, editor.gutter.bounds)
        let overlayBefore = try render(editor.overlay, overlayArea(editor))
        record(editor)
        editor.controller.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(editor)
        // The gutter from the edited line down (the numbers below changed), nothing above it.
        let gutterRects = try #require(editor.gutter.invalidations)
        let rows = union(gutterRects)
        #expect(rows.minY >= edited.y - GutterView.rowOverhang - 0.5)
        #expect(rows.maxY >= editor.gutter.bounds.maxY - 0.5)
        // The overlay the same way: the text below moved (above it, at most the cursor's block's
        // guide, a thin line).
        let overlayRects = try #require(editor.overlay.invalidations)
        let overlayUnion = union(overlayRects.filter { $0.width > 8 })
        #expect(overlayUnion.minY >= lineBand.minY - 4, "\(overlayRects) vs \(lineBand)")
        #expect(overlayUnion.maxY >= editor.overlay.visibleRect.maxY - 0.5)

        let gutterAfter = try render(editor.gutter, editor.gutter.bounds)
        #expect(expectChangesCovered(gutterBefore, gutterAfter, by: gutterRects) > 0)
        try expectPartialDrawMatches(editor.gutter, gutterAfter, in: rows)
        expectChangesCovered(overlayBefore, try render(editor.overlay, overlayArea(editor)), by: overlayRects)
        withExtendedLifetime(editor.window) {}
    }

    // MARK: Scrolling, folding, diagnostics

    @Test func scrollingRedrawsWhatCameIntoView() async throws {
        let editor = try await makeEditor()
        let scrollView = try #require(editor.controller.textView.enclosingScrollView)
        let before = editor.overlay.visibleRect
        let overlayBefore = try render(editor.overlay, overlayArea(editor))
        record(editor)
        var origin = scrollView.contentView.bounds.origin
        origin.y = (origin.y + 48).rounded()
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(editor)
        // The overlay scrolls with the text: only the strip that came into view.
        let after = editor.overlay.visibleRect
        let strip = NSRect(x: after.minX, y: before.maxY, width: after.width, height: after.maxY - before.maxY)
        // (A paragraph across the strip's top may be redrawn whole; what left the view may be too.)
        let overlayRects = try #require(editor.overlay.invalidations)
        let inView = overlayRects.map { $0.intersection(after) }.filter { !$0.isEmpty }
        #expect(!inView.isEmpty)
        #expect(union(inView).minY >= strip.minY - 20, "\(overlayRects) vs \(strip)")
        // What was in view before and still is: unchanged.
        let common = before.integral.intersection(after.integral)
        expectChangesCovered(try render(editor.overlay, common), try render(editor.overlay, common), by: overlayRects)
        let shared = try render(editor.overlay, common)
        let old = overlayBefore, scale = old.scale
        var moved = 0
        let dy = Int(((common.minY - old.rect.minY) * scale).rounded())
        for y in 0..<shared.rep.pixelsHigh where y + dy < old.rep.pixelsHigh {
            for x in 0..<shared.rep.pixelsWide where shared.pixel(x, y) != old.pixel(x, y + dy) { moved += 1 }
        }
        #expect(moved == 0, "the overlay's content in view before and after the scroll changed in \(moved) pixels")
        // The gutter doesn't scroll: all of it.
        #expect(union(try #require(editor.gutter.invalidations)).contains(editor.gutter.bounds.insetBy(dx: 0, dy: 1)))
        withExtendedLifetime(editor.window) {}
    }

    @Test func foldingRedrawsBoth() async throws {
        let editor = try await makeEditor()
        let gutterBefore = try render(editor.gutter, editor.gutter.bounds)
        record(editor)
        #expect(editor.document.foldLines(atHeader: 96))
        settle(editor)
        let gutterRects = try #require(editor.gutter.invalidations)
        #expect(union(gutterRects).contains(editor.gutter.bounds))
        #expect(union(try #require(editor.overlay.invalidations)).contains(editor.overlay.visibleRect))
        #expect(expectChangesCovered(gutterBefore, try render(editor.gutter, editor.gutter.bounds), by: gutterRects) > 0)
        withExtendedLifetime(editor.window) {}
    }

    @Test func newDiagnosticsRedrawTheOverlay() async throws {
        let editor = try await makeEditor()
        let overlayBefore = try render(editor.overlay, overlayArea(editor))
        record(editor)
        editor.document.setDiagnostics([
            Diagnostic(range: LSPRange(start: LSPPosition(line: 99, character: 7), end: LSPPosition(line: 99, character: 12)),
                       severity: .error, message: "bad", source: nil),
        ])
        settle(editor)
        let overlayRects = try #require(editor.overlay.invalidations)
        let squiggle = try #require(editor.overlay.segments().first?.rect)
        #expect(overlayRects.contains { $0.contains(squiggle) })
        let overlayAfter = try render(editor.overlay, overlayArea(editor))
        #expect(expectChangesCovered(overlayBefore, overlayAfter, by: overlayRects) > 0)
        // And gone again.
        record(editor)
        editor.document.setDiagnostics([])
        settle(editor)
        let cleared = try #require(editor.overlay.invalidations)
        #expect(cleared.contains { $0.contains(squiggle) })
        #expect(expectChangesCovered(overlayAfter, try render(editor.overlay, overlayArea(editor)), by: cleared) > 0)
        withExtendedLifetime(editor.window) {}
    }

    // MARK: Drawing

    /// Line numbers are drawn from the digits' glyphs, exactly as `NSString` drew them.
    @Test func lineNumbersMatchStringDrawing() async throws {
        let editor = try await makeEditor()
        defer { GutterView.drawsNumbersAsStrings = false }
        GutterView.drawsNumbersAsStrings = true
        let strings = try render(editor.gutter, editor.gutter.bounds)
        GutterView.drawsNumbersAsStrings = false
        let glyphs = try render(editor.gutter, editor.gutter.bounds)
        #expect(expectChangesCovered(strings, glyphs, by: []) == 0)
        withExtendedLifetime(editor.window) {}
    }

    /// A draw of part of the gutter or the overlay gives what a full draw gives there.
    @Test func partialDrawsMatchFullDraws() async throws {
        let editor = try await makeEditor()
        // The overlay with guides, a bracket pair and a squiggle in view.
        editor.document.setDiagnostics([
            Diagnostic(range: LSPRange(start: LSPPosition(line: 99, character: 7), end: LSPPosition(line: 99, character: 12)),
                       severity: .warning, message: "w", source: nil),
        ])
        editor.controller.textView.setSelectedRange(NSRange(location: editor.lineStarts[99] + ("    if first > second " as NSString).length + 1, length: 0))
        settle(editor)
        let gutter = try render(editor.gutter, editor.gutter.bounds)
        let row = try row(editor, 100)
        try expectPartialDrawMatches(editor.gutter, gutter, in: NSRect(x: 0, y: row.y, width: editor.gutter.bounds.width, height: row.height))
        try expectPartialDrawMatches(editor.gutter, gutter, in: NSRect(x: 0, y: row.y - 20, width: editor.gutter.bounds.width, height: 60))
        let area = overlayArea(editor)
        let overlay = try render(editor.overlay, area)
        // Lines' bands, outset as the overlay invalidates them: Core Graphics skips a stroke whose
        // path is outside the clip even when its width reaches in, so an edge just past a box or
        // a squiggle would lose its antialiasing.
        for lines in [99...99, 100...100, 101...101, 98...101] {
            let top = try band(editor, lines.lowerBound), bottom = try band(editor, lines.upperBound)
            try expectPartialDrawMatches(editor.overlay, overlay,
                                         in: NSRect(x: area.minX, y: top.minY - 2, width: area.width, height: bottom.maxY - top.minY + 4))
        }
        withExtendedLifetime(editor.window) {}
    }
}
