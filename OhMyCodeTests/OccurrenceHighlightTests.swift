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
        let (_, controller, window) = try makeEditor("count = 1\nrecount(count)\ncount_2 + count\n42 + 42\n")
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

    /// A big file: the part in view first, then the whole file off the main thread.
    @Test func bigFilesAreScannedInViewThenInTheBackground() async throws {
        let filler = String(repeating: "let value = other + 1\n", count: 400)
        let (document, controller, window) = try makeEditor("alpha beta\n" + filler + "alpha beta\n" + filler + "alpha\n")
        let highlighter = controller.occurrences
        highlighter.backgroundThreshold = 0
        var shownBeforeScan: [String]?
        highlighter.willApplyBackgroundScan = { shownBeforeScan = self.texts(document, highlighter.ranges) }
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0)) // in "alpha"
        await highlighter.waitForUpdate()
        #expect(shownBeforeScan?.isEmpty == true, "only one alpha in view: not highlighted until the whole file is scanned")
        #expect(texts(document, highlighter.ranges) == ["alpha", "alpha", "alpha"])
        #expect(highlighter.ranges.last.map(NSMaxRange) == document.textStorage.length - 1)

        // A selection works the same way.
        controller.textView.setSelectedRange(NSRange(location: 6, length: 4)) // "beta"
        await highlighter.waitForUpdate()
        #expect(texts(document, highlighter.ranges) == ["beta", "beta"])
        withExtendedLifetime(window) {}
    }

    /// The text changes (or the cursor moves on) while the whole file is scanned: the result is
    /// dropped, never shown at the old places.
    @Test func aStaleBackgroundScanIsDropped() async throws {
        let filler = String(repeating: "let value = other + 1\n", count: 400)
        let (document, controller, window) = try makeEditor("alpha beta\n" + filler + "alpha beta\n")
        let highlighter = controller.occurrences
        highlighter.backgroundThreshold = 0
        let textView = controller.textView!

        // Edited after the scan read the text: everything after the edit moved by 3.
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        var edited = false
        highlighter.willApplyBackgroundScan = {
            guard !edited else { return }
            edited = true
            document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// ")
            controller.textDidChangeProgrammatically() // as an edit made elsewhere is told
            textView.setSelectedRange(NSRange(location: 5, length: 0)) // still in "alpha"
        }
        await highlighter.waitForUpdate()
        #expect(edited)
        #expect(texts(document, highlighter.ranges).allSatisfy { $0 == "alpha" })
        // The newer lookup finds them where they are now.
        #expect(try await eventually { self.texts(document, highlighter.ranges) == ["alpha", "alpha"] })
        #expect(highlighter.ranges.first?.location == 3)

        // The cursor moved to another word meanwhile, with nothing edited: the newer word wins.
        var moved = false
        highlighter.willApplyBackgroundScan = {
            guard !moved else { return }
            moved = true
            textView.setSelectedRange(NSRange(location: 10, length: 0)) // in "beta"
        }
        textView.setSelectedRange(NSRange(location: 19, length: 0)) // in the first "value"
        await highlighter.waitForUpdate()
        #expect(moved)
        #expect(try await eventually { self.texts(document, highlighter.ranges) == ["beta", "beta"] })
        withExtendedLifetime(window) {}
    }

    /// A one-letter name found more than `maxMatches` times: those in view are still highlighted
    /// when they come after the first `maxMatches`.
    @Test func capturedMatchesIncludeThoseInView() async throws {
        let (document, controller, window) = try makeEditor(String(repeating: "x = x + 1\n", count: 1_500))
        let highlighter = controller.occurrences
        highlighter.backgroundThreshold = 0
        let textView = controller.textView!
        let last = document.textStorage.length - 10
        textView.setSelectedRange(NSRange(location: last, length: 0))
        textView.scrollRangeToVisible(NSRange(location: last, length: 0))
        textView.layoutSubtreeIfNeeded()
        await highlighter.waitForUpdate()
        #expect(highlighter.ranges.count > OccurrenceHighlighter.maxMatches)
        #expect(highlighter.ranges.contains(NSRange(location: last, length: 1)))
        #expect(!controller.occurrenceRects().isEmpty)
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
