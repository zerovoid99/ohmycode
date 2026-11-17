import AppKit
import Testing
@testable import Oh_My_Code

/// Guards for the cost of language-server traffic: what's decoded where, what a keystroke
/// touches, and what's left alone when an answer changes nothing.
@MainActor
struct LSPPipelineTests {
    private func document(_ text: String) throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-pipeline-\(UUID().uuidString).swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try EditorDocument(url: url)
    }

    /// Squiggles are drawn for the diagnostics in view only. Asking TextKit where far-away ones
    /// are lays out the text there: with problems all over a long file, the whole file, on
    /// every redraw (and typing in a fully laid-out file is slow from then on).
    @Test func farAwayDiagnosticsAreNotLaidOut() throws {
        let lines = 6000
        let document = try document((0..<lines).map { "let value\($0) = \($0)\n" }.joined())
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()
        document.editor = controller

        func diagnostic(_ start: Int, _ end: Int, _ severity: Diagnostic.Severity = .error) -> Diagnostic {
            Diagnostic(range: LSPRange(start: LSPPosition(line: start, character: 4), end: LSPPosition(line: end, character: 9)),
                       severity: severity, message: "problem", source: "test")
        }
        // One per ten lines down the whole file, and one over all of it.
        document.setDiagnostics(stride(from: 1, to: lines, by: 10).map { diagnostic($0, $0) } + [diagnostic(0, lines - 1, .warning)])
        let overlay = try #require(controller.diagnosticsOverlay)
        let segments = overlay.segments()
        // The ones in view are there: line 1's, and the long one's lines.
        #expect(segments.contains { $0.color == NSColor.systemRed })
        #expect(segments.count { $0.color == NSColor.systemYellow } > 5)

        let layoutManager = try #require(controller.textView.textLayoutManager)
        var laidOut = 0
        layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            if fragment.state == .layoutAvailable { laidOut += 1 }
            return true
        }
        #expect(laidOut < lines / 4, "\(laidOut) of \(lines) lines were laid out to draw the squiggles in view")
        withExtendedLifetime(window) {}
    }

    /// Messages are parsed where they're read (off the main thread), diagnostics included.
    @Test func messagesAreParsedWithTheirDiagnostics() throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": [
            "uri": "file:///tmp/a.swift",
            "diagnostics": [["range": ["start": ["line": 2, "character": 4], "end": ["line": 2, "character": 7]],
                             "severity": 2, "message": "unused", "source": "fake", "code": "W1"]],
        ]]
        let message = try #require(IncomingMessage(try JSONSerialization.data(withJSONObject: body)))
        let diagnostics = try #require(message.diagnostics)
        #expect(diagnostics.url == URL(string: "file:///tmp/a.swift"))
        #expect(diagnostics.list.count == 1)
        #expect(diagnostics.list.first?.range == LSPRange(start: LSPPosition(line: 2, character: 4), end: LSPPosition(line: 2, character: 7)))
        #expect(diagnostics.list.first?.severity == .warning && diagnostics.list.first?.message == "unused")
        // The server's own JSON goes back with a code action request (its code, its data).
        #expect(diagnostics.list.first?.json["code"] as? String == "W1")

        let answer = try #require(IncomingMessage(Data(#"{"jsonrpc":"2.0","id":4,"result":{"data":[0,4,1,2,0,1,0,3,1,0]}}"#.utf8)))
        #expect(answer.diagnostics == nil && answer.object["id"] as? Int == 4)
        #expect(SemanticTokens.numbers((answer.object["result"] as? [String: Any])?["data"]) == [0, 4, 1, 2, 0, 1, 0, 3, 1, 0])
        #expect(SemanticTokens.numbers(nil).isEmpty)
        #expect(IncomingMessage(Data("not json".utf8)) == nil)
    }

    /// A request whose task is cancelled (typing on) stops waiting, and the server is told.
    @Test func cancellingARequestTellsTheServer() async throws {
        let (workspace, document, _, window) = try LanguageClientTests.makeWorkspace(text: "let SLOW = 1\n")
        #expect(try await LanguageClientTests.eventually { document.languageClient?.state == .ready })
        let client = try #require(document.languageClient)
        // The fake server takes a second to format a file with SLOW in it.
        let task = Task { try await client.formatting(url: document.url, tabSize: 4, insertSpaces: true) }
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        let result = await task.result
        #expect(clock.now - start < .milliseconds(500), "cancelling waited for the answer")
        #expect(throws: CancellationError.self) { try result.get() }
        let stats = try await client.request("omc/stats", params: nil) as? [String: Any]
        #expect(stats?["cancelled"] as? Int == 1)
        // The late answer to the cancelled request is dropped; the client still works.
        #expect(try await client.request("omc/text", params: ["uri": document.url.absoluteString]) as? String == "let SLOW = 1\n")
        withExtendedLifetime((workspace, window)) {}
    }

    /// The list's rows: best match first, the server's order (sortText) among equals, cut off.
    @Test func completionRowsAreRankedAndLimited() {
        func item(_ id: Int, _ label: String, sort: String? = nil, filter: String? = nil) -> CompletionItem {
            CompletionItem(id: id, label: label, detail: nil, kind: 3, filterText: filter, sortText: sort, insertText: label, isSnippet: false)
        }
        let items = [item(0, "other"), item(1, "fooBaz", sort: "2"), item(2, "fooBar", sort: "1"), item(3, "xfoo"),
                     item(4, "shown", filter: "foohidden")]
        let candidates = items.map { FuzzyCandidate($0.filterText) }
        func labels(_ prefix: String, limit: Int = 200) -> [String] {
            CompletionController.rows(items: items, candidates: candidates, prefix: prefix, limit: limit).map(\.item.label)
        }
        // Nothing typed: everything, in the server's order.
        #expect(labels("") == ["fooBar", "fooBaz", "other", "shown", "xfoo"])
        // A match at the start beats one inside; equal matches keep the server's order.
        #expect(Array(labels("foo").prefix(2)) == ["fooBar", "fooBaz"])
        #expect(Set(labels("foo")) == ["fooBar", "fooBaz", "xfoo", "shown"])
        #expect(labels("foo", limit: 1) == ["fooBar"])
        #expect(labels("zzz").isEmpty)
        // Matched letters are highlighted in the label only when the label is what was matched.
        let rows = CompletionController.rows(items: items, candidates: candidates, prefix: "foo")
        #expect(rows.first { $0.item.label == "fooBar" }?.matches == [0, 1, 2])
        #expect(rows.first { $0.item.label == "shown" }?.matches == [])
    }

    /// The same hints again (every pause in typing asks for them) leave the text alone: writing
    /// attributes makes TextKit lay the text out again. Only what changed is written.
    @Test func unchangedInlayHintsAreNotRewritten() throws {
        let document = try document("let total = 42\nlet other = 7\nlet third = 9\n")
        func mark(_ index: Int) -> InlayHintMark? { document.textStorage.attribute(.omcInlayHint, at: index, effectiveRange: nil) as? InlayHintMark }
        func kern(_ index: Int) -> CGFloat? { document.textStorage.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat }
        func shown() -> [String] { document.shownInlayHints.map { "\($0.index)\($0.text)" } }
        var hints = [InlayHint(position: LSPPosition(line: 0, character: 9), label: ": Int", kind: .type),
                     InlayHint(position: LSPPosition(line: 1, character: 9), label: ": Int", kind: .type),
                     InlayHint(position: LSPPosition(line: 2, character: 9), label: ": Int", kind: .type)]
        document.setInlayHints(hints)
        #expect(shown() == ["8: Int", "23: Int", "37: Int"])
        let first = try #require(mark(8)), second = try #require(mark(23)), third = try #require(mark(37))

        let edits = Tally()
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: document.textStorage, queue: nil) { _ in edits.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        document.setInlayHints(hints)
        #expect(edits.count == 0)
        #expect(mark(8) === first && mark(23) === second && mark(37) === third)

        // One changes, one goes: the third stays as it was.
        hints[0].label = ": Double"
        hints.remove(at: 1)
        document.setInlayHints(hints)
        #expect(edits.count == 1)
        #expect(shown() == ["8: Double", "37: Int"])
        #expect(mark(8) !== first && mark(37) === third)
        #expect(mark(23) == nil && kern(23) == nil)
        #expect(kern(8) == InlayHintStyle.width(of: ": Double") && kern(37) == InlayHintStyle.width(of: ": Int"))

        document.setInlayHints([])
        #expect(shown().isEmpty && kern(8) == nil && kern(37) == nil)
    }
}

/// Counts calls from a notification observer (posted on the thread that edits: here, the main one).
final class Tally: @unchecked Sendable {
    var count = 0
}
