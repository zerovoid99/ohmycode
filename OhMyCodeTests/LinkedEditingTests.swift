import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct LinkedEditingTests {
    private func makeEditor(_ text: String, ext: String = "html") throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-linked-\(UUID().uuidString).\(ext)")
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

    private func type(_ controller: EditorController, _ text: String) {
        controller.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func typingInAnOpeningTagRenamesItsClosingTag() throws {
        let html = "<div class=\"a\">\n  <div>x</div>\n</div>\n"
        let (document, controller, window) = try makeEditor(html)
        controller.textView.setSelectedRange(NSRange(location: 4, length: 0)) // after "<div"
        type(controller, "x")
        // The outer pair, not the inner one.
        #expect(document.textStorage.string == "<divx class=\"a\">\n  <div>x</div>\n</divx>\n")
        #expect(controller.textView.selectedRange() == NSRange(location: 5, length: 0))
        document.undoManager.undo()
        #expect(document.textStorage.string == html)
        withExtendedLifetime(window) {}
    }

    @Test func editingAClosingTagRenamesItsOpeningTag() throws {
        let (document, controller, window) = try makeEditor("<p>\n  <span>a</span>\n</p>\n")
        let text = document.textStorage.string as NSString
        let closing = text.range(of: "</span>").location + 2
        controller.textView.setSelectedRange(NSRange(location: closing + 4, length: 0)) // after "</span"
        _ = controller.textView(controller.textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        #expect(document.textStorage.string == "<p>\n  <spa>a</spa>\n</p>\n")
        // The cursor stays where it was typing, moved by the edit before it.
        #expect(controller.textView.selectedRange().location == closing + 2)
        withExtendedLifetime(window) {}
    }

    @Test func notLinked() throws {
        // Self-closing, a tag still being typed, mismatched names, and the setting off.
        let (document, controller, window) = try makeEditor("<br/>\n<div>\n<sp\n</div>\n<a></b>\n")
        let text = document.textStorage.string as NSString
        #expect(controller.linkedTagNames(for: NSRange(location: 2, length: 0)) == nil)
        #expect(controller.linkedTagNames(for: NSRange(location: text.range(of: "<sp").location + 3, length: 0)) == nil)
        #expect(controller.linkedTagNames(for: NSRange(location: text.range(of: "<a>").location + 2, length: 0)) == nil)
        let div = NSRange(location: text.range(of: "<div>").location + 4, length: 0)
        #expect(controller.linkedTagNames(for: div) != nil)
        AppSettings.shared.linkedEditing = false
        defer { AppSettings.shared.linkedEditing = true }
        #expect(controller.linkedTagNames(for: div) == nil)
        withExtendedLifetime(window) {}
    }

    @Test func jsxComponentsWithDots() throws {
        let (document, controller, window) = try makeEditor("const x = <Foo.Bar a={1}><Foo.Bar/></Foo.Bar>\n", ext: "tsx")
        controller.textView.setSelectedRange(NSRange(location: 18, length: 0)) // after "<Foo.Bar"
        type(controller, "z")
        #expect(document.textStorage.string == "const x = <Foo.Barz a={1}><Foo.Bar/></Foo.Barz>\n")
        withExtendedLifetime(window) {}
    }
}
