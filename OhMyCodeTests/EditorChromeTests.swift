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
}
