import AppKit
import Foundation
import SwiftTreeSitter
import Testing
@testable import Oh_My_Code

@MainActor
struct SyntaxHighlighterTests {
    private func makeDocument(_ text: String, ext: String = "swift") throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try EditorDocument(url: url)
    }

    private func names(_ highlights: [NamedRange], in text: String) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for h in highlights {
            result[(text as NSString).substring(with: h.range), default: []].insert(h.name)
        }
        return result
    }

    @Test(arguments: [SourceLanguage.swift, .javascript, .typescript, .tsx, .python, .json, .rust, .go])
    func grammarAndQueryLoad(language: SourceLanguage) {
        #expect(GrammarRegistry.grammar(for: language) != nil)
    }

    @Test func highlightsSwift() async throws {
        let text = "let greeting = \"hi\" // note\nfunc run() {}\n"
        let document = try makeDocument(text)
        let highlighter = try #require(document.highlighter)
        let found = names(await highlighter.highlights(in: NSRange(location: 0, length: (text as NSString).length)), in: text)

        #expect(found["let"]?.contains { $0.hasPrefix("keyword") } == true)
        #expect(found["\"hi\""]?.contains { $0.hasPrefix("string") } == true
                || found["hi"]?.contains { $0.hasPrefix("string") } == true)
        #expect(found["// note"]?.contains { $0.hasPrefix("comment") } == true)
        #expect(found["func"]?.contains { $0.hasPrefix("keyword") } == true)
    }

    /// Incremental reparsing must give the same highlights as parsing the final text from scratch.
    @Test func incrementalParseMatchesFreshParse() async throws {
        let document = try makeDocument("struct A {\n    var x = 1\n}\n")
        let pieces = ["let ", "\"", "//", "\n", "func f() {}", "}", "{", " 42", "/* c */", "x"]
        for _ in 0..<300 {
            let length = document.textStorage.length
            let location = Int.random(in: 0...length)
            let removeLength = Int.random(in: 0...min(4, length - location))
            document.textStorage.replaceCharacters(in: NSRange(location: location, length: removeLength),
                                                   with: pieces.randomElement()!)
        }
        let text = document.textStorage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        let incremental = await (try #require(document.highlighter)).highlights(in: full)
        let fresh = await (try #require(try makeDocument(text).highlighter)).highlights(in: full)
        #expect(incremental == fresh)
    }

    @Test func unsupportedLanguageHasNoHighlighter() throws {
        #expect(try makeDocument("hello", ext: "txt").highlighter == nil)
    }

    /// Renders the editor into a bitmap and checks syntax colors are actually drawn.
    @Test func colorsAreRendered() async throws {
        let text = (1...200).map { "let value\($0) = \"text\" // comment" }.joined(separator: "\n")
        let document = try makeDocument(text)
        let controller = EditorController(document: document)
        let editorView = controller.makeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = editorView
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()
        document.highlighter?.addClient(controller)
        await document.highlighter?.waitUntilIdle()
        controller.textView.layoutSubtreeIfNeeded()

        // Capture the whole editor (gutter + scroll view), not just the text view: a gutter
        // implemented as NSRulerView once hid all text while the text view alone looked fine.
        let view: NSView = editorView
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)

        // Glyph edges are antialiased, so compare hue of saturated pixels rather than exact RGB.
        func hue(_ hex: UInt32) -> CGFloat {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1).hueComponent
        }
        var hues: [CGFloat] = []
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<min(bitmap.pixelsHigh, 120) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.saturationComponent > 0.4, c.brightnessComponent > 0.3 else { continue }
                hues.append(c.hueComponent)
            }
        }
        func drawn(_ hex: UInt32) -> Bool {
            let target = hue(hex)
            return hues.filter { min(abs($0 - target), 1 - abs($0 - target)) < 0.04 }.count > 20
        }
        #expect(drawn(0xAD3DA4), "keyword color not drawn")
        #expect(drawn(0xC41A16), "string color not drawn")
    }

    /// Regression: the gutter filled its unclipped `dirtyRect` and painted over all the text.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func plainTextIsVisibleNextToGutter(appearance: NSAppearance.Name) throws {
        let document = try makeDocument(String(repeating: "Hello world, plain text here\n", count: 20), ext: "md")
        let controller = EditorController(document: document)
        let editorView = controller.makeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = editorView
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()

        let bitmap = try #require(editorView.bitmapImageRepForCachingDisplay(in: editorView.bounds))
        editorView.cacheDisplay(in: editorView.bounds, to: bitmap)
        let background = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 2, y: bitmap.pixelsHigh - 2))
        let gutterEnd = Int(controller.gutterView.width) + 10
        var textPixels = 0
        for x in gutterEnd..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y) else { continue }
                if abs(c.brightnessComponent - background.brightnessComponent) > 0.3 { textPixels += 1 }
            }
        }
        #expect(textPixels > 500, "no text drawn right of the gutter")
    }

    /// Edits made while a parse is in flight are batched into the next job and the final tree
    /// matches the final text.
    @Test func editsDuringBackgroundParseAreNotLost() async throws {
        let document = try makeDocument(String(repeating: "let a = 1\n", count: 20_000))
        let highlighter = try #require(document.highlighter)
        for i in 0..<50 {
            // Don't await between edits: they land while earlier jobs are still running.
            document.textStorage.replaceCharacters(in: NSRange(location: i * 3, length: 0), with: "\"//")
        }
        let length = document.textStorage.length
        let full = NSRange(location: 0, length: length)
        let incremental = await highlighter.highlights(in: full)
        let fresh = await (try #require(try makeDocument(document.textStorage.string).highlighter)).highlights(in: full)
        #expect(incremental == fresh)
    }

    /// Typing must stay off the parser: the main thread only records edits.
    @Test func performanceOnLargeFile() async throws {
        let unit = """
        struct Item\u{24}N: Codable {
            let id: Int
            var name: String = "item"
            func describe() -> String { "\\(id): \\(name)" } // comment
        }

        """
        let text = (0..<10_000).map { unit.replacingOccurrences(of: "\u{24}N", with: String($0)) }.joined()
        let clock = ContinuousClock()

        var document: EditorDocument!
        let openTime = try clock.measure { document = try makeDocument(text) }
        let highlighter = try #require(document.highlighter)
        let initialParse = await clock.measure { await highlighter.waitUntilIdle() }

        let middle = document.textStorage.length / 2
        var worstEdit = Duration.zero
        var totalEdit = Duration.zero
        for i in 0..<100 {
            let edit = clock.measure {
                document.textStorage.replaceCharacters(in: NSRange(location: middle + i, length: 0), with: "x")
            }
            totalEdit += edit
            worstEdit = max(worstEdit, edit)
            if i % 10 == 0 { await Task.yield() } // let some background jobs interleave
        }
        let catchUp = await clock.measure { await highlighter.waitUntilIdle() }
        let query = await clock.measure { _ = await highlighter.highlights(in: NSRange(location: middle, length: 8_000)) }

        print("PERF lines=\(document.lineCount) open(main)=\(openTime) initialParse(bg)=\(initialParse) "
              + "edit(main) avg=\(totalEdit / 100) worst=\(worstEdit) catchUp(bg)=\(catchUp) viewportQuery(bg)=\(query)")
        #if !DEBUG // Timing budgets only mean something with optimizations on (tree-sitter is C, -O0 in Debug).
        #expect(openTime < .milliseconds(100), "opening must not wait for the parser")
        #expect(totalEdit / 100 < .milliseconds(1), "a keystroke must cost the main thread well under 1ms")
        #expect(worstEdit < .milliseconds(8), "no keystroke may miss a 120Hz frame")
        #expect(initialParse < .seconds(1))
        #endif
    }
}

/// Grammars compile once, on whichever thread asks first (the launch warm-up, an opened file).
struct GrammarRegistryTests {
    @Test func threadsShareOneCompiledGrammar() async {
        let languages: [SourceLanguage] = [.rust, .go, .rust, .go, .rust, .go, .markdown, .markdown]
        let queries = await withTaskGroup(of: (SourceLanguage, ObjectIdentifier?).self) { group in
            for language in languages {
                group.addTask { (language, GrammarRegistry.grammar(for: language).map { ObjectIdentifier($0.highlightsQuery) }) }
            }
            return await group.reduce(into: [SourceLanguage: Set<ObjectIdentifier?>]()) { $0[$1.0, default: []].insert($1.1) }
        }
        #expect(queries[.rust]?.count == 1 && queries[.rust]?.first! != nil)
        #expect(queries[.go]?.count == 1 && queries[.go]?.first! != nil)
        #expect(queries[.markdown] == [nil]) // no grammar, asked for twice
    }
}
