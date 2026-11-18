import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct ColorDecoratorTests {
    private func found(_ text: String, _ syntax: ColorSyntax) -> [String] {
        let ns = text as NSString
        return ColorLiterals.find(in: ns, range: NSRange(location: 0, length: ns.length), syntax: syntax).map(\.text)
    }

    private func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> RGBAColor {
        RGBAColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: Parsing and writing back

    @Test func parsesEachFormat() throws {
        let cases: [(String, RGBAColor)] = [
            ("#f00", color(1, 0, 0)), ("#F008", color(1, 0, 0, 0x88 / 255)), ("#00ff00", color(0, 1, 0)),
            ("#0000FF80", color(0, 0, 1, 0x80 / 255)),
            ("rgb(255, 0, 0)", color(1, 0, 0)), ("rgba(0,255,0,0.5)", color(0, 1, 0, 0.5)),
            ("rgb(0 0 255 / 25%)", color(0, 0, 1, 0.25)), ("rgb(100% 50% 0%)", color(1, 0.5, 0)),
            ("hsl(120, 100%, 50%)", color(0, 1, 0)), ("hsla(240deg 100% 50% / 0.5)", color(0, 0, 1, 0.5)),
            ("red", color(1, 0, 0)), ("RebeccaPurple", color(0x66 / 255, 0x33 / 255, 0x99 / 255)),
            ("Color(red: 1, green: 0.5, blue: 0)", color(1, 0.5, 0)),
            ("Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 0.5)", color(0, 0, 1, 0.5)),
            ("NSColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)", color(0.2, 0.4, 0.6)),
            ("NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.5)", color(1, 1, 1, 0.5)),
            ("UIColor(red: 0, green: 0, blue: 0, alpha: 1)", color(0, 0, 0)),
            ("Color(hue: 0.5, saturation: 1, brightness: 1)", color(0, 1, 1)),
        ]
        for (text, expected) in cases {
            let parsed = try #require(ColorLiterals.color(of: text), "\(text)")
            #expect(parsed.isClose(to: expected), "\(text) → \(parsed)")
        }
        for text in ["#ff", "#fffff", "#ggg", "rgb(1, 2)", "rgb(1 2 3 4)", "rgb(1, 2 3)", "hsl(10%, 1%, 1%)", "rgb(a, b, c)",
                     "Color(red: x, green: 0, blue: 0)", "Color(white: 1, opacity: 1)", "UIColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1)",
                     "NSColor(red: 1, green: 1, blue: 1, opacity: 1)", "notacolor"] {
            #expect(ColorLiterals.color(of: text) == nil, "\(text)")
        }
    }

    @Test func roundTripsKeepTheText() throws {
        for text in ["#fff", "#FFF", "#abcd", "#00ff00", "#1A2B3C", "#11223344", "rgb(255, 0, 0)", "rgba(255,0,0,0.5)",
                     "rgb(255 128 0 / 50%)", "rgb(100% 50% 0%)", "RGB(10, 20, 30)", "hsl(120, 100%, 50%)",
                     "hsla(210 50% 40% / 0.25)", "hsl(30deg 100% 50%)", "red", "navy", "grey", "Cyan",
                     "Color(red: 0.500, green: 0.250, blue: 1.000)",
                     "NSColor(calibratedRed: 0.100, green: 0.200, blue: 0.300, alpha: 1.000)",
                     "Color(.sRGB, red: 1.000, green: 0.000, blue: 0.000, opacity: 0.500)",
                     "UIColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 0.250)",
                     "Color(hue: 0.500, saturation: 1.000, brightness: 1.000)"] {
            let parsed = try #require(ColorLiterals.color(of: text), "\(text)")
            #expect(ColorLiterals.rewrite(text, to: parsed) == text)
        }
    }

    @Test func rewritesInTheSameFormat() {
        let half = color(1, 0, 0, 0.5)
        // Hex: case and length class kept; short only when the color fits; alpha added when needed.
        #expect(ColorLiterals.rewrite("#fff", to: color(1, 0, 0)) == "#f00")
        #expect(ColorLiterals.rewrite("#fff", to: color(0.5, 0.5, 0.5)) == "#808080")
        #expect(ColorLiterals.rewrite("#FFF", to: color(0, 0, 0, 0.6)) == "#0009")
        #expect(ColorLiterals.rewrite("#ABCDEF", to: half) == "#FF000080")
        #expect(ColorLiterals.rewrite("#ff000080", to: color(0, 1, 0)) == "#00ff00ff")
        #expect(ColorLiterals.rewrite("#123456", to: color(0, 0, 1)) == "#0000ff")
        // Functions: syntax, separators and units kept; alpha added (rgb → rgba with commas).
        #expect(ColorLiterals.rewrite("rgb(255, 255, 255)", to: color(0, 0.5, 1)) == "rgb(0, 128, 255)")
        #expect(ColorLiterals.rewrite("rgb(255, 255, 255)", to: half) == "rgba(255, 0, 0, 0.5)")
        #expect(ColorLiterals.rewrite("rgb(255,255,255)", to: half) == "rgba(255,0,0,0.5)")
        #expect(ColorLiterals.rewrite("rgb(255 255 255)", to: half) == "rgb(255 0 0 / 0.5)")
        #expect(ColorLiterals.rewrite("rgb(0 0 0 / 10%)", to: half) == "rgb(255 0 0 / 50%)")
        #expect(ColorLiterals.rewrite("rgba(0, 0, 0, 0.1)", to: color(0, 0, 1)) == "rgba(0, 0, 255, 1)")
        #expect(ColorLiterals.rewrite("rgb(0% 0% 0%)", to: color(1, 0.25, 0)) == "rgb(100% 25% 0%)")
        #expect(ColorLiterals.rewrite("hsl(0, 0%, 0%)", to: color(0, 0, 1)) == "hsl(240, 100%, 50%)")
        #expect(ColorLiterals.rewrite("hsl(0deg 0% 0%)", to: half) == "hsl(0deg 100% 50% / 0.5)")
        // Names: another name when there is one, else hex.
        #expect(ColorLiterals.rewrite("red", to: color(0, 0, 1)) == "blue")
        #expect(ColorLiterals.rewrite("red", to: color(0.1, 0.2, 0.3)) == "#1a334d")
        #expect(ColorLiterals.rewrite("red", to: half) == "#ff000080")
        // Swift: labels kept, 3 decimals, alpha added under the type's label.
        #expect(ColorLiterals.rewrite("Color(red: 1, green: 0, blue: 0)", to: color(0, 0.5, 1))
                == "Color(red: 0.000, green: 0.500, blue: 1.000)")
        #expect(ColorLiterals.rewrite("Color(red: 1, green: 0, blue: 0)", to: half)
                == "Color(red: 1.000, green: 0.000, blue: 0.000, opacity: 0.500)")
        #expect(ColorLiterals.rewrite("UIColor(red: 1, green: 0, blue: 0, alpha: 1)", to: half)
                == "UIColor(red: 1.000, green: 0.000, blue: 0.000, alpha: 0.500)")
        #expect(ColorLiterals.rewrite("NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)", to: color(0, 0, 0))
                == "NSColor(srgbRed: 0.000, green: 0.000, blue: 0.000, alpha: 1.000)")
        #expect(ColorLiterals.rewrite("Color(hue: 0, saturation: 0, brightness: 0)", to: color(0, 1, 1))
                == "Color(hue: 0.500, saturation: 1.000, brightness: 1.000)")
        #expect(ColorLiterals.rewrite("Color(.sRGB, red: 0, green: 0, blue: 0)", to: half)
                == "Color(.sRGB, red: 1.000, green: 0.000, blue: 0.000, opacity: 0.500)")
    }

    // MARK: Where colors are found

    @Test func findsCSSColorsOnlyWhereValuesAre() {
        let css = """
        #fff { color: red; }
        a:hover #abc { background: #00ff00; }
        .red, .tan { border: 1px solid rgb(0 0 255); outline-color: Tomato }
        $accent: #123; @base: hsl(0, 0%, 0%);
        x { color: var(--red); background: mix(#fff, #000); grid-area: content }
        #fff
        """
        #expect(found(css, .css) == ["red", "#00ff00", "rgb(0 0 255)", "Tomato", "#123", "hsl(0, 0%, 0%)", "#fff", "#000"])
    }

    @Test func findsHTMLColorsOnlyInStyles() {
        let html = """
        <p>Issue #123 is red: yes, and rgb(1, 2, 3) is text</p>
        <div style="color: red; background:#fff">#abc</div>
        <style>
        .a { color: blue; border-color: #0f0 }
        </style>
        <p>color: green</p>
        """
        #expect(found(html, .markup) == ["red", "#fff", "blue", "#0f0"])
    }

    @Test func findsScriptColorsOnlyInStrings() {
        let js = """
        const a = '#ff0000', b = "rgba(0, 0, 0, 0.5)"; // '#00ff00'
        const c = `hsl(10 20% 30%)`, name = "red", issue = 1 // #fff
        el.style.color = 'Red' + "#abc"
        """
        #expect(found(js, .script) == ["#ff0000", "rgba(0, 0, 0, 0.5)", "hsl(10 20% 30%)", "#abc"])
    }

    @Test func findsSwiftColorsWithNumberLiterals() {
        let swift = """
        let a = Color(red: 1, green: 0.5, blue: 0)
        let b = Color(red: x, green: 0, blue: 0), c = Color.red, d = NSColor(white: 1, alpha: 1)
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.3, alpha: 1).cgColor
        let e = SwiftUI.Color(hue: 0.5, saturation: 1, brightness: 1), f = "#fff"
        """
        #expect(found(swift, .swift) == ["Color(red: 1, green: 0.5, blue: 0)",
                                         "NSColor(calibratedRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)",
                                         "SwiftUI.Color(hue: 0.5, saturation: 1, brightness: 1)"])
    }

    // MARK: In the editor

    private func makeEditor(_ text: String, ext: String) throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-colors-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        document.attach(controller)
        return (document, controller, window)
    }

    private func swatches(_ document: EditorDocument) -> [String] {
        document.shownColorSwatches.map { document.textStorage.mutableString.substring(with: $0.range) }
    }

    @Test func swatchesAreLayoutOnlyAndFollowEdits() async throws {
        let text = "a { color: #ff0000; }\nb { background: rgb(0, 0, 255) }\n"
        let (document, controller, window) = try makeEditor(text, ext: "css")
        document.refreshColorDecorators()
        await document.waitForColorDecorators()
        #expect(swatches(document) == ["#ff0000", "rgb(0, 0, 255)"])
        // The text, its dirtiness and undo are untouched; the gap is a kern on the character before.
        #expect(document.textStorage.string == text && !document.isDirty && !document.undoManager.canUndo)
        #expect(document.textStorage.attribute(.kern, at: 10, effectiveRange: nil) as? CGFloat == ColorSwatchStyle.width)
        controller.textView.layoutSubtreeIfNeeded()
        let rects = controller.colorSwatchRects()
        #expect(rects.count == 2)
        // The swatch sits in the gap: after the space's glyph, before the literal's first one.
        // (Each character's segment takes half the gap.)
        let literal = try #require(controller.rect(for: NSRange(location: 11, length: 1)))
        let before = try #require(controller.rect(for: NSRange(location: 10, length: 1)))
        let glyph = (" " as NSString).size(withAttributes: [.font: EditorTheme.font]).width
        #expect(rects[0].rect.minX >= before.minX + glyph - 0.5)
        #expect(rects[0].rect.maxX <= literal.maxX - glyph + 0.5 && rects[0].rect.width > 5)

        // Typing right before a literal doesn't take its gap.
        controller.textView.setSelectedRange(NSRange(location: 11, length: 0))
        controller.textView.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(document.textStorage.attribute(.kern, at: 11, effectiveRange: nil) == nil)
        #expect(document.textStorage.attribute(.omcColorSwatch, at: 11, effectiveRange: nil) == nil)
        // Swatches move with the text, and come back where the colors are after the pause.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/* top */\n")
        await document.waitForColorDecorators()
        #expect(swatches(document) == ["#ff0000", "rgb(0, 0, 255)"])
        #expect(document.shownColorSwatches.map(\.range.location) == [22, 49])
        // Copying the text copies no swatch.
        controller.textView.setSelectedRange(NSRange(location: 10, length: 20))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("omc-colors-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(controller.textView.writeSelection(to: pasteboard, types: controller.textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == (document.textStorage.string as NSString).substring(with: NSRange(location: 10, length: 20)))

        // Turned off: gone.
        AppSettings.shared.showsColorDecorators = false
        defer { AppSettings.shared.showsColorDecorators = true }
        document.refreshColorDecorators()
        await document.waitForColorDecorators()
        #expect(document.shownColorSwatches.isEmpty && document.textStorage.attribute(.kern, at: 21, effectiveRange: nil) == nil)
        withExtendedLifetime(window) {}
    }

    /// Only what's in view is looked through; scrolling brings the colors there.
    @Test func onlyTheLinesInViewAreScanned() async throws {
        let text = String(repeating: "a { color: #fff; }\n", count: 20_000)
        let (document, controller, window) = try makeEditor(text, ext: "css")
        let clock = ContinuousClock()
        let start = clock.now
        document.refreshColorDecorators()
        await document.waitForColorDecorators()
        #expect(clock.now - start < .milliseconds(200))
        let first = document.shownColorSwatches
        #expect(!first.isEmpty && first.count < 500 && first.allSatisfy { $0.range.location < 20_000 })
        controller.reveal(NSRange(location: document.textStorage.length - 1, length: 0))
        controller.textView.layoutSubtreeIfNeeded()
        let end = document.textStorage.length
        #expect(try await LanguageClientTests.eventually { document.shownColorSwatches.contains { $0.range.location > end - 2_000 } })
        #expect(document.shownColorSwatches.count < 1_000)
        withExtendedLifetime(window) {}
    }

    @Test func pickingRewritesTheLiteralAsOneUndoStepPerDrag() async throws {
        ColorPickerSession.showsPanel = false
        defer { ColorPickerSession.showsPanel = true }
        let text = "a { color: #fff; }\n"
        let (document, controller, window) = try makeEditor(text, ext: "css")
        document.undoManager.groupsByEvent = false // as separate events from the panel would be
        document.refreshColorDecorators()
        await document.waitForColorDecorators()
        controller.textView.layoutSubtreeIfNeeded()
        let swatch = try #require(controller.colorSwatchRects().first)
        #expect(controller.handleColorSwatchClick(at: NSPoint(x: swatch.rect.midX, y: swatch.rect.midY)))
        let session = try #require(ColorPickerSession.current)
        #expect(controller.textView.selectedRange() == NSRange(location: 11, length: 0))

        // Not dragging: each change is a step of its own.
        session.isDragging = { false }
        session.change(to: color(1, 0, 0))
        #expect(document.textStorage.string == "a { color: #f00; }\n")
        session.change(to: color(0, 0, 1, 0.6))
        #expect(document.textStorage.string == "a { color: #00f9; }\n")
        document.undoManager.undo()
        #expect(document.textStorage.string == "a { color: #f00; }\n")

        // A drag: many changes, one step once the mouse is let go.
        var dragging = true
        session.isDragging = { dragging }
        for green in stride(from: 0.0, through: 1.0, by: 0.25) { session.change(to: color(0, green, 0)) }
        #expect(document.textStorage.string == "a { color: #0f0; }\n")
        dragging = false
        try await Task.sleep(for: .milliseconds(150))
        document.undoManager.undo()
        #expect(document.textStorage.string == "a { color: #f00; }\n")
        document.undoManager.redo()
        #expect(document.textStorage.string == "a { color: #0f0; }\n")

        // Moving the cursor off the literal ends picking.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(ColorPickerSession.current == nil)
        withExtendedLifetime(window) {}
    }

    @Test func swiftLiteralsAreRewrittenWithTheirLabels() async throws {
        ColorPickerSession.showsPanel = false
        defer { ColorPickerSession.showsPanel = true }
        let text = "let tint = NSColor(red: 1, green: 1, blue: 1, alpha: 1)\n"
        let (document, controller, window) = try makeEditor(text, ext: "swift")
        document.refreshColorDecorators()
        await document.waitForColorDecorators()
        let mark = try #require(document.textStorage.attribute(.omcColorSwatch, at: 10, effectiveRange: nil) as? ColorSwatchMark)
        let session = try #require(ColorPickerSession.begin(editor: controller, index: 10, mark: mark))
        session.isDragging = { false }
        session.change(to: color(0.25, 0.5, 0.75, 0.5))
        #expect(document.textStorage.string == "let tint = NSColor(red: 0.250, green: 0.500, blue: 0.750, alpha: 0.500)\n")
        document.undoManager.undo()
        #expect(document.textStorage.string == text)
        session.detach()
        withExtendedLifetime(window) {}
    }

    @Test func theServersColorsWinAndItsPresentationsRewriteThem() async throws {
        ColorPickerSession.showsPanel = false
        defer { ColorPickerSession.showsPanel = true }
        let base = LanguageClientTests.fakeServer
        let server = LanguageServerConfig(name: base.name, command: base.command + ["--colors"], languages: base.languages)
        // A format only the server knows, one both know (the server's answer wins), and one only
        // the editor knows (shown too: servers know fewer formats).
        let text = "let a = 1\nlet c = @color(255,0,0)\nlet d = Color(red: 0, green: 1, blue: 0)\nlet e = Color(red: 0.5, green: 1, blue: 0)\n"
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(text: text, server: server)
        #expect(try await LanguageClientTests.eventually { document.shownColorSwatches.map(\.fromServer) == [true, true, false] })
        #expect(swatches(document) == ["@color(255,0,0)", "Color(red: 0, green: 1, blue: 0)", "Color(red: 0.5, green: 1, blue: 0)"])
        #expect(document.shownColorSwatches[1].color.alpha == 0.5)

        let index = document.shownColorSwatches[0].range.location - 1
        let mark = try #require(document.textStorage.attribute(.omcColorSwatch, at: index, effectiveRange: nil) as? ColorSwatchMark)
        let session = try #require(ColorPickerSession.begin(editor: controller, index: index, mark: mark))
        session.isDragging = { false }
        session.change(to: color(0, 0, 1))
        #expect(try await LanguageClientTests.eventually { document.textStorage.string.contains("@color(0,0,255)") })
        document.undoManager.undo()
        #expect(document.textStorage.string == text)
        session.detach()
        withExtendedLifetime((workspace, window)) {}
    }
}
