import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct DocumentLinkTests {
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func makeEditor(_ text: String) throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-link-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        return (document, controller, window)
    }

    @Test func findsURLsInTheText() throws {
        let text = "see https://example.com/a_(b). and (http://x.org/p), file:///tmp/a.txt#L3 then\n"
            + "`https://q.com/x?y=1&z=2` notaurl://x https:// [doc](https://d.io/page)\n"
        let (document, _, window) = try makeEditor(text)
        let found = document.urls(in: NSRange(location: 0, length: document.textStorage.length)).map { $0.target!.absoluteString }
        #expect(found == ["https://example.com/a_(b)", "http://x.org/p", "file:///tmp/a.txt#L3", "https://q.com/x?y=1&z=2", "https://d.io/page"])
        let index = (text as NSString).range(of: "x.org").location
        #expect(document.link(at: index)?.target?.host() == "x.org")
        #expect(document.link(at: 1) == nil)
        withExtendedLifetime(window) {}
    }

    @Test func commandHoverUnderlinesAndClickOpens() throws {
        let (document, controller, window) = try makeEditor("go to https://example.com/docs now\n")
        var opened: [URL] = []
        let saved = EditorController.openExternal
        EditorController.openExternal = { opened.append($0) }
        defer { EditorController.openExternal = saved }

        controller.textView.layoutSubtreeIfNeeded()
        let range = (document.textStorage.string as NSString).range(of: "example")
        let rect = try #require(controller.rect(for: range))
        let point = NSPoint(x: rect.midX, y: rect.midY)
        controller.updateLinkHover(at: point, modifiers: [])
        #expect(controller.hoveredLink == nil && controller.linkUnderlineRect() == nil)
        controller.updateLinkHover(at: point, modifiers: .command)
        #expect(controller.hoveredLink?.target?.absoluteString == "https://example.com/docs")
        #expect(controller.linkUnderlineRect() != nil)
        // ⌘ let go.
        controller.updateLinkHover(at: point, modifiers: [])
        #expect(controller.hoveredLink == nil)

        #expect(controller.followLink(at: point))
        #expect(opened == [URL(string: "https://example.com/docs")!])
        // Not on a link: ⌘-click is Go to Definition.
        let plain = try #require(controller.rect(for: NSRange(location: 0, length: 2)))
        #expect(!controller.followLink(at: NSPoint(x: plain.midX, y: plain.midY)))
        // The context menu offers it.
        #expect(controller.linkMenuItems(at: range.location).map(\.title).prefix(2) == ["Open Link", "Copy Link Address"])
        #expect(controller.linkMenuItems(at: 0).isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func theServersLinksResolveAndOpenFiles() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "// include \"other.swift\"\n// goto \"other.swift\"\nlet x = 1\n", files: ["other.swift": "a\nb\nc\n"])
        #expect(try await eventually { document.languageClient?.state == .ready })
        document.refreshLinks()
        await document.waitForLinks()
        let text = document.textStorage.string as NSString
        let include = try #require(document.link(at: text.range(of: "other").location))
        #expect(include.serverIndex == 0 && include.target == nil)
        let target = await document.target(of: include)
        #expect(target?.lastPathComponent == "other.swift")

        controller.open(include)
        #expect(try await eventually { workspace.activeDocument?.url.lastPathComponent == "other.swift" })

        let gotoIndex = text.range(of: "other", options: [], range: NSRange(location: 26, length: text.length - 26)).location
        let goto = try #require(document.link(at: gotoIndex))
        #expect(goto.tooltip == "Open other.swift" && goto.target?.fragment == "L2")
        workspace.open(fileAt: document.url)
        let other = try #require(workspace.documents.first { $0.url.lastPathComponent == "other.swift" })
        controller.openLinkTarget(goto.target!)
        #expect(workspace.activeDocument === other)
        #expect(other.pendingReveal == NSRange(location: 2, length: 0) || other.cursorLine == 2)

        // After an edit the server's links are stale until asked again.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(document.link(at: text.range(of: "other").location + 1) == nil)
        withExtendedLifetime((workspace, window)) {}
    }
}
