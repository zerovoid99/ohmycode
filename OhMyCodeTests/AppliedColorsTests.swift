import AppKit
import SwiftTreeSitter
import Testing
@testable import Oh_My_Code

/// Syntax colors are given to TextKit only where they changed (`AppliedColors`): what TextKit
/// draws must still be exactly the highlights, after edits that move text, and after scrolling.
@MainActor
@Suite(.serialized)
struct AppliedColorsTests {
    /// The color TextKit has for each character of `range` (nil: none).
    private func renderedColors(_ controller: EditorController, in range: NSRange) -> [NSColor?] {
        var result = [NSColor?](repeating: nil, count: range.length)
        guard let layoutManager = controller.textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return result }
        let documentStart = contentManager.documentRange.location
        guard let start = contentManager.location(documentStart, offsetBy: range.location) else { return result }
        layoutManager.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, textRange in
            let lower = contentManager.offset(from: documentStart, to: textRange.location)
            let upper = contentManager.offset(from: documentStart, to: textRange.endLocation)
            if lower >= NSMaxRange(range) { return false }
            if let color = attributes[.foregroundColor] as? NSColor {
                for offset in max(lower, range.location)..<min(upper, NSMaxRange(range)) { result[offset - range.location] = color }
            }
            return true
        }
        return result
    }

    /// The colors as applying every capture in order over the range gives them (what
    /// `applyHighlights` did before it kept track of what it had applied).
    private func expectedColors(_ highlights: [NamedRange], in range: NSRange) -> [NSColor?] {
        var result = [NSColor?](repeating: nil, count: range.length)
        for highlight in highlights {
            let clipped = NSIntersectionRange(highlight.range, range)
            guard clipped.length > 0, let color = EditorTheme.color(forCapture: highlight.name) else { continue }
            for offset in clipped.location..<NSMaxRange(clipped) { result[offset - range.location] = color }
        }
        return result
    }

    private func check(_ controller: EditorController, _ document: EditorDocument, _ step: String) async throws {
        let highlighter = try #require(document.highlighter)
        await highlighter.waitUntilIdle()
        let range = try #require(controller.highlightedRange)
        let expected = expectedColors(await highlighter.highlights(in: range), in: range)
        let rendered = renderedColors(controller, in: range)
        let wrong = (0..<range.length).filter { expected[$0] != rendered[$0] }
        #expect(wrong.isEmpty, "\(step): \(wrong.count) of \(range.length) characters have the wrong color, first at \(wrong.first.map { $0 + range.location } ?? 0)")
        #expect(expected.contains { $0 != nil })
    }

    @Test func colorsStayRightAcrossEditsAndScrolling() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-colors-\(UUID().uuidString).swift")
        try PerformanceBenchmarks.code(bytes: 60_000).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        document.attach(controller)
        document.highlighter?.addClient(controller)
        let view = controller.textView!
        let lines = document.lineIndex.lineCount
        controller.reveal(NSRange(location: document.lineIndex.lineStarts[lines / 3], length: 0))
        view.layoutSubtreeIfNeeded()
        try await check(controller, document, "opened")

        // Typing that changes the colors of what follows (a string, a comment, a keyword),
        // deleting, newlines, a pasted block, and edits above what's shown.
        var generator = SeededGenerator(seed: 7)
        let insertions = ["a", "\"", "//", "/*", "*/", "\n", "let ", "struct X {\n", "}", "\"\"\"\n", "x\ny\nz\n", "  "]
        for step in 0..<80 {
            let visible = try #require(controller.visibleCharacterRange())
            let length = document.textStorage.length
            let location: Int
            if step % 9 == 4 {
                location = Int.random(in: 0..<max(1, visible.location), using: &generator) // above the view
            } else {
                location = min(length, visible.location + Int.random(in: 0..<max(1, visible.length), using: &generator))
            }
            let removed = step % 3 == 2 ? min(Int.random(in: 1...12, using: &generator), length - location) : 0
            let inserted = removed > 0 && step % 2 == 0 ? "" : insertions.randomElement(using: &generator)!
            view.setSelectedRange(NSRange(location: location, length: removed))
            if inserted.isEmpty { view.deleteBackward(nil) } else { view.insertText(inserted, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            view.layoutSubtreeIfNeeded()
            if step % 4 == 3 { try await check(controller, document, "edit \(step)") } // edits pile up between checks too
        }
        try await check(controller, document, "after editing")

        // Scrolling, some steps past the highlighted range.
        let scrollView = try #require(view.enclosingScrollView)
        for step in 0..<12 {
            var origin = scrollView.contentView.bounds.origin
            origin.y = max(0, origin.y + scrollView.contentSize.height * (step % 4 == 3 ? -1.7 : 0.6))
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            view.layoutSubtreeIfNeeded()
            try await check(controller, document, "scroll \(step)")
        }

        // Undo of all of it (edits made by the undo manager, not the text view).
        while document.undoManager.canUndo { document.undoManager.undo() }
        view.layoutSubtreeIfNeeded()
        try await check(controller, document, "undone")
        withExtendedLifetime(window) {}
    }

    /// Edits move what's known, as TextKit moves its rendering attributes; the edited text is unknown.
    @Test func editsMoveAppliedColors() {
        var colors = AppliedColors()
        let red = colors.index(of: .red)!, blue = colors.index(of: .blue)!
        #expect(colors.index(of: .red) == red && colors.color(red) == .red)
        let first = Array(repeating: red, count: 5) + Array(repeating: AppliedColors.none, count: 5) + Array(repeating: blue, count: 5)
        let spans = colors.update(to: first, in: NSRange(location: 100, length: 15))
        #expect(spans.count == 1 && spans[0].range == NSRange(location: 100, length: 15) && spans[0].remove)
        // The same again: nothing to do.
        #expect(colors.update(to: first, in: NSRange(location: 100, length: 15)).isEmpty)
        // Before it: moves; after it: nothing; inside: unknown.
        colors.edit(start: 10, oldEnd: 12, newLength: 5)
        #expect(colors.range == NSRange(location: 103, length: 15) && colors.applied(at: 103) == red)
        colors.edit(start: 200, oldEnd: 200, newLength: 3)
        #expect(colors.range == NSRange(location: 103, length: 15))
        colors.edit(start: 105, oldEnd: 106, newLength: 3)
        #expect(colors.range == NSRange(location: 103, length: 17))
        #expect(colors.applied(at: 104) == red && (105..<108).allSatisfy { colors.applied(at: $0) == AppliedColors.unknown })
        #expect(colors.applied(at: 108) == red && colors.applied(at: 119) == blue)
        // Only the edited characters (and whatever's close to them) are given again.
        var next = Array(repeating: red, count: 7) + Array(repeating: AppliedColors.none, count: 5) + Array(repeating: blue, count: 5)
        let again = colors.update(to: next, in: NSRange(location: 103, length: 17), gap: 1)
        #expect(again.map(\.range) == [NSRange(location: 105, length: 3)] && again[0].remove)
        // Scrolled: only what's new.
        next = Array(next[5...]) + Array(repeating: red, count: 4)
        let scrolled = colors.update(to: next, in: NSRange(location: 108, length: 16), gap: 1)
        #expect(scrolled.map(\.range) == [NSRange(location: 120, length: 4)])
        // Across its edge: forgotten.
        colors.edit(start: 100, oldEnd: 110, newLength: 0)
        #expect(colors.range.length == 0 && colors.applied(at: 115) == AppliedColors.unknown)
    }

    /// Colors that change after the text is drawn (a file opened, a window in the background)
    /// redraw it: TextKit draws each layout fragment into a view of its own and doesn't redraw
    /// those when rendering attributes change, so the text stayed plain until edited.
    @Test func colorsChangingAfterTheTextIsDrawnRedrawIt() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-colors-\(UUID().uuidString).swift")
        try PerformanceBenchmarks.code(bytes: 20_000).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        let highlighter = try #require(document.highlighter)
        highlighter.addClient(controller)
        await highlighter.waitUntilIdle()
        highlighter.removeClient(controller) // colors are applied below, when nothing else runs
        let range = try #require(controller.highlightedRange)
        let highlights = await highlighter.highlights(in: range)

        let view = controller.textView!
        let fragmentViews = view.subviews.filter { $0 !== controller.diagnosticsOverlay }.flatMap(\.subviews)
        func marked() -> Int {
            fragmentViews.filter { ($0.needsDisplay || $0.layer?.needsDisplay() == true)
                && $0.frame.intersects(view.convert(view.visibleRect, to: $0.superview)) }.count
        }
        func draw() {
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        #expect(!fragmentViews.isEmpty)
        draw()
        #expect(marked() == 0, "drawn already")

        // Colors taken off, then put back: each time, the text in view is redrawn.
        controller.applyHighlights([], in: range)
        #expect(marked() > 0, "the text isn't redrawn without its colors")
        draw()
        controller.applyHighlights(highlights, in: range)
        #expect(marked() > 0, "the text isn't redrawn with its colors")
        // The same colors again: nothing to redraw.
        draw()
        controller.applyHighlights(highlights, in: range)
        #expect(marked() == 0)
        withExtendedLifetime(window) {}
    }
}
