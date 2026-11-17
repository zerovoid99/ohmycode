import AppKit
import Testing
@testable import Oh_My_Code

/// Sticky scroll and minimap.
@MainActor
struct EditorChromeTests {
    /// A Swift file: a class (with an attribute line) holding many functions of 30 lines each.
    private func makeEditor(functions: Int = 20, height: CGFloat = 400)
        throws -> (EditorDocument, EditorController, NSWindow) {
        var lines = ["@MainActor", "final class Outer {"]
        for f in 0..<functions {
            lines.append("    func work\(f)() {")
            for i in 0..<28 { lines.append("        let value\(i) = \"text\" + String(\(i))") }
            lines.append("    }")
        }
        lines.append("}")
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-chrome-\(UUID().uuidString).swift")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.attach(controller)
        return (document, controller, window)
    }

    @Test func findsEnclosingDeclarationsFromTheSyntaxTree() async throws {
        let (document, _, window) = try makeEditor(functions: 3)
        let highlighter = try #require(document.highlighter)
        await highlighter.waitUntilIdle()
        func scopes(_ line: Int) async -> [Int] {
            await highlighter.enclosingScopeLines(line: line, lineStart: document.lineIndex.lineStarts[line])
        }
        // Line 40 is inside work1 (lines 32–61): the class's name line (not "@MainActor") and the func.
        #expect(await scopes(40) == [1, 32])
        #expect(await scopes(32) == [1])     // a header line itself isn't sticky yet
        #expect(await scopes(1).isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func stickyLinesFollowScrollingAndJumpOnClick() async throws {
        let (document, controller, window) = try makeEditor()
        await document.highlighter?.waitUntilIdle()
        let sticky = try #require(controller.stickyView)

        controller.scrollLineToTop(100) // inside work3 (lines 92–121)
        controller.textView.layoutSubtreeIfNeeded()
        #expect(controller.topVisibleLine == 100)
        sticky.update()
        await sticky.waitUntilUpdated()
        #expect(sticky.lines == [1, 92])
        let container = try #require(controller.textView.enclosingScrollView?.superview)
        container.layoutSubtreeIfNeeded()
        #expect(abs(sticky.frame.height - 2 * controller.lineHeight) < 0.5)
        #expect(sticky.frame.maxY == container.bounds.maxY) // pinned to the top

        // The pinned lines show the declarations' text.
        let bitmap = try #require(sticky.bitmapImageRepForCachingDisplay(in: sticky.bounds))
        sticky.cacheDisplay(in: sticky.bounds, to: bitmap)
        var dark = 0
        for x in Int(controller.gutterView.width)..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 { dark += 1 }
        }
        #expect(dark > 100, "sticky line text not drawn")

        // Clicking the func line goes to it.
        controller.reveal(line: sticky.lines[1])
        #expect(document.lineIndex.line(containing: controller.textView.selectedRange().location) == 92)

        // At the top of the file there's nothing to pin; turned off, nothing either.
        controller.scrollLineToTop(0)
        sticky.update()
        await sticky.waitUntilUpdated()
        #expect(sticky.lines.isEmpty)
        let settings = AppSettings.shared
        settings.stickyScroll = false
        defer { settings.stickyScroll = true }
        controller.scrollLineToTop(100)
        sticky.update()
        await sticky.waitUntilUpdated()
        #expect(sticky.lines.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func minimapScrollsWithTheEditorAndDrawsSyntaxColors() async throws {
        let (document, controller, window) = try makeEditor(functions: 40) // 1,203 lines
        let minimap = try #require(controller.minimapView)
        #expect(!minimap.isHidden && minimap.frame.width == MinimapView.width)
        let capacity = Int(minimap.bounds.height / MinimapView.lineHeight)
        #expect(document.lineIndex.lineCount > capacity)
        #expect(minimap.firstLine == 0)

        // The minimap scrolls in proportion: at the end it shows the last lines.
        controller.scrollLineToTop(document.lineIndex.lineCount - 1)
        controller.textView.layoutSubtreeIfNeeded()
        #expect(minimap.firstLine == document.lineIndex.lineCount - capacity)
        #expect(minimap.sliderRect.maxY <= minimap.bounds.height + MinimapView.lineHeight)

        // Colors: it's a highlighter client with its own range.
        let highlighter = try #require(document.highlighter)
        highlighter.addClient(minimap)
        await highlighter.waitUntilIdle()
        let bitmap = try #require(minimap.bitmapImageRepForCachingDisplay(in: minimap.bounds))
        minimap.cacheDisplay(in: minimap.bounds, to: bitmap)
        let keyword = EditorTheme.hex(0xAD3DA4) // the Default theme's light keyword color (the window is light)
        var keywordPixels = 0, inked = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.brightnessComponent < 0.9 { inked += 1 }
                if abs(c.hueComponent - keyword.hueComponent) < 0.05 && c.saturationComponent > 0.25 { keywordPixels += 1 }
            }
        }
        #expect(inked > 1000, "minimap text blocks not drawn")
        #expect(keywordPixels > 50, "minimap doesn't use syntax colors")

        // Clicking scrolls the editor around that line.
        let y = minimap.bounds.height / 2
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: minimap.convert(NSPoint(x: 20, y: y), to: nil),
                                                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let target = minimap.firstLine + Int(y / MinimapView.lineHeight)
        minimap.mouseDown(with: event)
        minimap.mouseUp(with: event)
        controller.textView.layoutSubtreeIfNeeded()
        let center = controller.topVisibleLine + controller.visibleLineCount / 2
        #expect(abs(center - target) <= 2, "clicked line \(target), editor centered on \(center)")

        // Turning it off gives its width back to the text.
        let textWidth = controller.textView.enclosingScrollView!.frame.width
        AppSettings.shared.showsMinimap = false
        defer { AppSettings.shared.showsMinimap = true }
        controller.textView.enclosingScrollView!.superview!.layoutSubtreeIfNeeded()
        #expect(minimap.isHidden)
        #expect(controller.textView.enclosingScrollView!.frame.width == textWidth + MinimapView.width)
        withExtendedLifetime(window) {}
    }

    /// The minimap's pixels, as painted.
    private func pixels(_ image: CGImage?) throws -> [UInt8] {
        let image = try #require(image)
        let data = try #require(image.dataProvider?.data) as Data
        return [UInt8](data)
    }

    /// Paints `minimap` as a frame does: it paints at most `edited` lines, plus those the
    /// minimap scrolled in (it scrolls in proportion, so an edit that changes the text's
    /// height can move it). Once the new colors are in, a frame that applies them gets the same
    /// pixels as painting everything again.
    private func expectFrame(_ minimap: MinimapView, _ highlighter: SyntaxHighlighter, paintsAtMost edited: Int,
                             _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let scrolled = abs(minimap.firstLine - minimap.paintedFirst)
        minimap.updateLayer()
        #expect(minimap.paintedLines <= edited + scrolled,
                "\(comment): painted \(minimap.paintedLines) lines, scrolled \(scrolled)", sourceLocation: sourceLocation)
        await highlighter.waitUntilIdle()
        minimap.updateLayer()
        let partial = try pixels(minimap.paintedImage)
        minimap.invalidate()
        minimap.updateLayer()
        let full = try pixels(minimap.paintedImage)
        #expect(partial == full, "\(comment): differs from a full paint", sourceLocation: sourceLocation)
    }

    @Test func minimapPaintsOnlyChangedLinesAndMatchesAFullPaint() async throws {
        let (document, controller, window) = try makeEditor(functions: 40) // 1,203 lines
        let minimap = try #require(controller.minimapView)
        let highlighter = try #require(document.highlighter)
        highlighter.addClient(minimap)
        controller.scrollLineToTop(300)
        controller.textView.layoutSubtreeIfNeeded()
        minimap.refresh()
        await highlighter.waitUntilIdle()
        minimap.invalidate()
        minimap.updateLayer()
        let capacity = Int(minimap.bounds.height / MinimapView.lineHeight)
        #expect(minimap.paintedLines == capacity)

        // Nothing changed: nothing painted.
        minimap.updateLayer()
        #expect(minimap.paintedLines == 0)

        // A keystroke paints its line; a newline its two (the rest move down a row); joining
        // them back, the one, and the line that comes in at the bottom.
        let textView = controller.textView!
        textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[minimap.firstLine + 20] + 8, length: 0))
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.layoutSubtreeIfNeeded()
        try await expectFrame(minimap, highlighter, paintsAtMost: 1, "keystroke")
        textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.layoutSubtreeIfNeeded()
        try await expectFrame(minimap, highlighter, paintsAtMost: 2, "newline")
        textView.deleteBackward(nil)
        textView.layoutSubtreeIfNeeded()
        try await expectFrame(minimap, highlighter, paintsAtMost: 2, "joined lines")

        // Scrolling a little: the lines that came in.
        controller.scrollLineToTop(330)
        textView.layoutSubtreeIfNeeded()
        minimap.refresh()
        try await expectFrame(minimap, highlighter, paintsAtMost: 0, "scroll")

        // New colors (a line turned into a comment): that line, and any that came in at an edge
        // with the edit (painted plain until their colors came).
        let before = minimap.paintedFirst
        textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[minimap.firstLine + 30], length: 0))
        textView.insertText("// ", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.layoutSubtreeIfNeeded()
        minimap.updateLayer()
        let cameIn = abs(minimap.paintedFirst - before)
        await highlighter.waitUntilIdle()
        try await expectFrame(minimap, highlighter, paintsAtMost: 1 + cameIn, "recolored")
        withExtendedLifetime(window) {}
    }

    /// Scrolling a line at a time doesn't ask for the minimap's colors at every line (each ask
    /// is a query of the hundreds of lines it shows): only once the lines shown pass the ones
    /// it has colors for.
    @Test func minimapAsksForColorsOncePastWhatItHas() async throws {
        let (document, controller, window) = try makeEditor(functions: 40) // 1,203 lines
        let minimap = try #require(controller.minimapView)
        let highlighter = try #require(document.highlighter)
        highlighter.addClient(minimap)
        controller.scrollLineToTop(300)
        controller.textView.layoutSubtreeIfNeeded()
        minimap.refresh()
        await highlighter.waitUntilIdle()
        let capacity = Int(minimap.bounds.height / MinimapView.lineHeight)
        try #require(capacity >= 40 && document.lineIndex.lineCount > capacity * 2)

        func scroll(toLine line: Int) async {
            controller.scrollLineToTop(line)
            controller.textView.layoutSubtreeIfNeeded()
            minimap.refresh()
            await highlighter.waitUntilIdle()
        }
        let asked = minimap.highlightResults, first = minimap.firstLine
        var line = 300
        while minimap.firstLine - first < capacity / 2 - 2 {
            line += 1
            await scroll(toLine: line)
        }
        #expect(minimap.highlightResults == asked, "asked for colors while scrolling within its overscan")

        await scroll(toLine: line + capacity)
        #expect(minimap.highlightResults == asked + 1, "asked \(minimap.highlightResults - asked) times for one scroll")
        minimap.updateLayer()
        let painted = try pixels(minimap.paintedImage)
        minimap.invalidate()
        minimap.updateLayer()
        #expect(try pixels(minimap.paintedImage) == painted)
        withExtendedLifetime(window) {}
    }

    /// The layer shows the picture the right way up, with the slider over the lines in view:
    /// the same as drawing it.
    @Test func minimapLayerMatchesItsDrawing() async throws {
        let (document, controller, window) = try makeEditor(functions: 40)
        let minimap = try #require(controller.minimapView)
        await document.highlighter?.waitUntilIdle()
        controller.scrollLineToTop(200)
        controller.textView.layoutSubtreeIfNeeded()
        minimap.refresh()
        minimap.updateLayer()
        // The window's content as Core Animation composites it, from the root layer down
        // (flips included), cut to the minimap.
        let root = try #require(window.contentView?.layer)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let drawn = try #require(minimap.bitmapImageRepForCachingDisplay(in: minimap.bounds))
        minimap.cacheDisplay(in: minimap.bounds, to: drawn)
        let scale = CGFloat(drawn.pixelsWide) / minimap.bounds.width
        let whole = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(content.bounds.width * scale),
                                                  pixelsHigh: Int(content.bounds.height * scale), bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                  bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: whole)?.cgContext)
        context.scaleBy(x: scale, y: scale)
        root.render(in: context)
        let frame = minimap.convert(minimap.bounds, to: nil) // window coordinates, y up
        let crop = CGRect(x: frame.minX * scale, y: (content.bounds.height - frame.maxY) * scale,
                          width: frame.width * scale, height: frame.height * scale)
        let cropped = try #require(whole.cgImage?.cropping(to: crop))
        let rendered = NSBitmapImageRep(cgImage: cropped)

        // Compare brightness a line at a time (2 pt; the bitmaps may sample the 2x picture
        // differently): where the ink and the slider are.
        func profile(_ bitmap: NSBitmapImageRep) -> [Double] {
            let rowsPerLine = Int(CGFloat(bitmap.pixelsHigh) / minimap.bounds.height * MinimapView.lineHeight)
            return stride(from: 0, to: bitmap.pixelsHigh - rowsPerLine + 1, by: rowsPerLine).map { top in
                (top..<top + rowsPerLine).reduce(0.0) { sum, y in
                    (0..<bitmap.pixelsWide).reduce(sum) { $0 + Double(bitmap.colorAt(x: $1, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) }
                } / Double(rowsPerLine * bitmap.pixelsWide)
            }
        }
        let a = profile(drawn), b = profile(rendered)
        let differing = zip(a, b).filter { abs($0 - $1) > 0.03 }.count
        let flipped = zip(a, b.reversed()).filter { abs($0 - $1) > 0.03 }.count
        #expect(a.contains { $0 < 0.95 } && a.contains { $0 > 0.97 }, "nothing drawn to compare")
        #expect(differing < a.count / 50, "\(differing) of \(a.count) lines differ between the layer and the drawing (\(flipped) if flipped)")
        withExtendedLifetime(window) {}
    }
}
