import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct InlayHintTests {
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func pairs(_ document: EditorDocument) -> [String] { document.shownInlayHints.map { "\($0.index)\($0.text)" } }

    @Test func hintsAreLayoutOnly() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-inlay-\(UUID().uuidString).swift")
        try "let total = 42\nfooBar(3)\n".write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller

        document.setInlayHints([
            InlayHint(position: LSPPosition(line: 0, character: 9), label: ": Int", kind: .type),
            InlayHint(position: LSPPosition(line: 1, character: 7), label: "count:", kind: .parameter, paddingRight: true),
            InlayHint(position: LSPPosition(line: 1, character: 0), label: "skipped", kind: nil), // line start
        ])
        #expect(pairs(document) == ["8: Int", "21count: "])
        // The text, its dirtiness and undo are untouched.
        #expect(document.textStorage.string == "let total = 42\nfooBar(3)\n" && !document.isDirty && !document.undoManager.canUndo)
        // A gap opens after the character: the next one moves right by the hint's width.
        controller.textView.layoutSubtreeIfNeeded()
        let rects = controller.inlayHintRects()
        #expect(rects.count == 2)
        let after = try #require(controller.rect(for: NSRange(location: 9, length: 1)))
        #expect(rects[0].rect.maxX <= after.minX + 0.5 && rects[0].rect.width > 10)

        // Typing right after a hinted character doesn't take its gap.
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        controller.textView.insertText("s", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(document.textStorage.attribute(.kern, at: 9, effectiveRange: nil) == nil)
        // Hints move with the text.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// a\n")
        #expect(pairs(document) == ["13: Int", "27count: "])

        document.setInlayHints([])
        #expect(document.shownInlayHints.isEmpty && document.textStorage.attribute(.kern, at: 13, effectiveRange: nil) == nil)
        withExtendedLifetime(window) {}
    }

    @Test func theServersHintsFollowEditsAndTheSetting() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(text: "let total = 42\nfooBar(3)\n")
        #expect(try await eventually { pairs(document) == ["8: Int", "21count: "] })
        // Typing a new declaration: its hint comes after the pause.
        controller.textView.setSelectedRange(NSRange(location: document.textStorage.length, length: 0))
        controller.textView.insertText("let more = 1\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(try await eventually { pairs(document).contains("32: Int") })

        AppSettings.shared.showsInlayHints = false
        defer { AppSettings.shared.showsInlayHints = true }
        #expect(try await eventually { document.shownInlayHints.isEmpty })
        AppSettings.shared.showsInlayHints = true
        #expect(try await eventually { document.shownInlayHints.count == 3 })
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func readsHints() {
        let hint = InlayHint(json: ["position": ["line": 2, "character": 4], "label": [["value": "na"], ["value": "me:"]],
                                    "kind": 2, "paddingLeft": true, "paddingRight": true])
        #expect(hint?.label == "name:" && hint?.kind == .parameter && hint?.text == " name: ")
        #expect(InlayHint(json: ["position": ["line": 0, "character": 0], "label": ""]) == nil)
    }
}
