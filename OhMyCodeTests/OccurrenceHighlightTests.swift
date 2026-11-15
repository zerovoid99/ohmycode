import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct OccurrenceHighlightTests {
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// An editor on a plain-text file (no language server: words are matched).
    private func makeEditor(_ text: String) throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-occ-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        return (document, controller, window)
    }

    private func texts(_ document: EditorDocument, _ ranges: [NSRange]) -> [String] {
        ranges.map { document.textStorage.mutableString.substring(with: $0) }
    }

    @Test func wholeWordsWithoutALanguageServer() async throws {
        let (document, controller, window) = try makeEditor("count = 1\nrecount(count)\ncount_2 + count\n42 + 42\n")
        let highlighter = controller.occurrences

        controller.textView.setSelectedRange(NSRange(location: 2, length: 0)) // in "count"
        await highlighter.waitForUpdate()
        // Whole words only: not "recount" or "count_2".
        #expect(highlighter.ranges.map(\.location) == [0, 18, 35])
        #expect(highlighter.highlights.allSatisfy { $0.kind == .text })
        controller.textView.layoutSubtreeIfNeeded()
        #expect(controller.occurrenceRects().count == 3)

        // F7 steps through them, wrapping; the selected one keeps the others highlighted.
        controller.moveToOccurrence(forward: true)
        #expect(controller.textView.selectedRange() == NSRange(location: 18, length: 5))
        await highlighter.waitForUpdate()
        #expect(highlighter.ranges.count == 3)
        controller.moveToOccurrence(forward: true)
        controller.moveToOccurrence(forward: true)
        #expect(controller.textView.selectedRange() == NSRange(location: 0, length: 5))
        controller.moveToOccurrence(forward: false)
        #expect(controller.textView.selectedRange() == NSRange(location: 35, length: 5))

        // Numbers, and words found once, aren't highlighted.
        controller.textView.setSelectedRange(NSRange(location: 42, length: 0)) // "42"
        await highlighter.waitForUpdate()
        #expect(highlighter.ranges.isEmpty)
        controller.textView.setSelectedRange(NSRange(location: 12, length: 0)) // "recount"
        await highlighter.waitForUpdate()
        #expect(highlighter.ranges.isEmpty)

        // Typing clears them at once; they come back for the new text.
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        await highlighter.waitForUpdate()
        #expect(highlighter.ranges.count == 3)
        controller.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(highlighter.ranges.isEmpty)
        await highlighter.waitForUpdate()
        #expect(highlighter.ranges.isEmpty) // "coxunt" is only there once
        withExtendedLifetime(window) {}
    }

    @Test func selectedTextAndTheSetting() async throws {
        let (document, controller, window) = try makeEditor("a.b(1)\nx = a.b(2)\nab\n")
        let highlighter = controller.occurrences
        controller.textView.setSelectedRange(NSRange(location: 0, length: 3)) // "a.b"
        await highlighter.waitForUpdate()
        #expect(texts(document, highlighter.ranges) == ["a.b", "a.b"])
        // The selection itself isn't drawn again.
        controller.textView.layoutSubtreeIfNeeded()
        #expect(controller.occurrenceRects().count == 1)
        // Across lines: nothing.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 9))
        await highlighter.waitForUpdate()
        #expect(highlighter.ranges.isEmpty)

        AppSettings.shared.highlightsOccurrences = false
        defer { AppSettings.shared.highlightsOccurrences = true }
        controller.textView.setSelectedRange(NSRange(location: 0, length: 3))
        await highlighter.waitForUpdate()
        #expect(highlighter.ranges.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func theServersHighlightsTellWritesFromReads() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "var total = 0\ntotal = total + 1\nprint(total)\nlet subtotal = 2\n")
        #expect(try await eventually { document.languageClient?.state == .ready })
        let highlighter = controller.occurrences
        controller.textView.setSelectedRange(NSRange(location: 40, length: 0)) // print(total)
        #expect(try await eventually { highlighter.ranges.count == 4 })
        #expect(highlighter.highlights.map(\.kind) == [.write, .write, .read, .read])
        #expect(texts(document, highlighter.ranges) == ["total", "total", "total", "total"])
        // Nothing the server highlights (a keyword): nothing, not the word.
        controller.textView.setSelectedRange(NSRange(location: 1, length: 0)) // "var"
        #expect(try await eventually { highlighter.ranges.isEmpty })
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func readsHighlights() {
        let read = DocumentHighlight(json: ["range": ["start": ["line": 1, "character": 2], "end": ["line": 1, "character": 5]], "kind": 3])
        #expect(read?.kind == .write && read?.range.start.character == 2)
        #expect(DocumentHighlight(json: ["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 1]]])?.kind == .text)
        #expect(DocumentHighlight(json: ["kind": 2]) == nil)
    }
}
