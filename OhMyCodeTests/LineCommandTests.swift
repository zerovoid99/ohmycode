import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct LineCommandTests {
    private func makeEditor(_ text: String, ext: String = "swift") throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-lines-\(UUID().uuidString).\(ext)")
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

    private func run(_ text: String, select: NSRange, _ command: LineCommand, ext: String = "swift") throws -> (String, NSRange) {
        let (document, controller, window) = try makeEditor(text, ext: ext)
        controller.textView.setSelectedRange(select)
        controller.perform(command)
        defer { withExtendedLifetime(window) {} }
        return (document.textStorage.string, controller.textView.selectedRange())
    }

    @Test func togglesLineComments() throws {
        let code = "func f() {\n    let a = 1\n\n  let b = 2\n}\n"
        // Lines 2–4: markers at the least indented column; the blank line is left alone.
        var (text, selection) = try run(code, select: NSRange(location: 15, length: 20), .toggleComment)
        #expect(text == "func f() {\n  //   let a = 1\n\n  // let b = 2\n}\n")
        #expect(selection.location == 18)
        // Again: back as it was.
        let (document, controller, window) = try makeEditor(text)
        controller.textView.setSelectedRange(NSRange(location: 15, length: 25))
        controller.perform(.toggleComment)
        #expect(document.textStorage.string == code)
        document.undoManager.undo()
        #expect(document.textStorage.string == text)
        withExtendedLifetime(window) {}

        (text, selection) = try run("x = 1\n", select: NSRange(location: 2, length: 0), .toggleComment, ext: "py")
        #expect(text == "# x = 1\n" && selection.location == 4)
        // No line comments (CSS): a block comment.
        (text, _) = try run("a { color: red; }\n", select: NSRange(location: 0, length: 0), .toggleComment, ext: "css")
        #expect(text == "/* a { color: red; } */\n")
        (text, _) = try run(text, select: NSRange(location: 0, length: 0), .toggleComment, ext: "css")
        #expect(text == "a { color: red; }\n")
    }

    @Test func movesAndCopiesLines() throws {
        var (text, selection) = try run("a\nb\nc\n", select: NSRange(location: 2, length: 0), .moveUp)
        #expect(text == "b\na\nc\n" && selection.location == 0)
        (text, selection) = try run("a\nb\nc\n", select: NSRange(location: 2, length: 0), .moveDown)
        #expect(text == "a\nc\nb\n" && selection.location == 4)
        // The last line has no line break: it's kept right.
        (text, selection) = try run("a\nb", select: NSRange(location: 3, length: 0), .moveUp)
        #expect(text == "b\na" && selection.location == 1)
        (text, _) = try run("a\nb", select: NSRange(location: 0, length: 0), .moveDown)
        #expect(text == "b\na")
        // Nowhere to go.
        (text, _) = try run("a\nb\n", select: NSRange(location: 2, length: 0), .moveDown)
        #expect(text == "a\nb\n")
        // Several lines move together, the selection with them.
        (text, selection) = try run("1\n2\n3\n4\n", select: NSRange(location: 2, length: 3), .moveDown)
        #expect(text == "1\n4\n2\n3\n" && selection == NSRange(location: 4, length: 3))

        (text, selection) = try run("a\nb\n", select: NSRange(location: 1, length: 0), .copyDown)
        #expect(text == "a\na\nb\n" && selection.location == 3)
        (text, selection) = try run("a\nb\n", select: NSRange(location: 1, length: 0), .copyUp)
        #expect(text == "a\na\nb\n" && selection.location == 1)
        (text, selection) = try run("a\nlast", select: NSRange(location: 3, length: 0), .copyDown)
        #expect(text == "a\nlast\nlast" && selection.location == 8)
    }

    @Test func deletesIndentsAndInsertsLines() throws {
        var (text, selection) = try run("one\ntwo\nthree\n", select: NSRange(location: 5, length: 0), .delete)
        #expect(text == "one\nthree\n" && selection.location == 5)
        (text, selection) = try run("one\ntwo", select: NSRange(location: 5, length: 0), .delete)
        #expect(text == "one" && selection.location == 1)

        (text, selection) = try run("a\n\nb\n", select: NSRange(location: 0, length: 4), .indent)
        #expect(text == "    a\n\n    b\n" && selection == NSRange(location: 4, length: 8))
        (text, selection) = try run("    a\n    b\n\tc\nd\n", select: NSRange(location: 0, length: 15), .outdent)
        #expect(text == "a\nb\nc\nd\n" && selection == NSRange(location: 0, length: 6))

        (text, selection) = try run("    let x = 1\nnext\n", select: NSRange(location: 6, length: 0), .insertBelow)
        #expect(text == "    let x = 1\n    \nnext\n" && selection.location == 18)
        (text, selection) = try run("    let x = 1\n", select: NSRange(location: 6, length: 0), .insertAbove)
        #expect(text == "    \n    let x = 1\n" && selection.location == 4)
    }

    @Test func joinsSortsAndTransforms() throws {
        var (text, selection) = try run("call(  \n    a,\n    b\n)\n", select: NSRange(location: 0, length: 0), .join)
        #expect(text == "call( a,\n    b\n)\n" && selection.location == 5)
        (text, _) = try run("f(\n  a\n)\n", select: NSRange(location: 0, length: 9), .join)
        #expect(text == "f( a)\n")

        (text, _) = try run("item10\nItem2\nitem1\n", select: NSRange(location: 0, length: 0), .sortAscending)
        #expect(text == "item1\nItem2\nitem10\n")
        (text, _) = try run("b\na\nc\n", select: NSRange(location: 0, length: 0), .sortDescending)
        #expect(text == "c\nb\na\n")
        // Only the selected lines.
        (text, _) = try run("z\nb\na\ny\n", select: NSRange(location: 2, length: 3), .sortAscending)
        #expect(text == "z\na\nb\ny\n")
        (text, _) = try run("a\nb\na\nc\nb\n", select: NSRange(location: 0, length: 0), .deleteDuplicates)
        #expect(text == "a\nb\nc\n")

        (text, selection) = try run("hello world", select: NSRange(location: 1, length: 0), .upperCase)
        #expect(text == "HELLO world" && selection == NSRange(location: 0, length: 5))
        (text, _) = try run("hello world", select: NSRange(location: 0, length: 11), .titleCase)
        #expect(text == "Hello World")
        (text, _) = try run("a  \nb\t\nc\n", select: NSRange(location: 0, length: 0), .trimTrailingWhitespace)
        #expect(text == "a\nb\nc\n")
    }

    @Test func keysRunThemInTheEditorOnly() throws {
        let (document, controller, window) = try makeEditor("a\nb\n")
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        let up = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .numericPad, .function],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                                               isARepeat: false, keyCode: 126))
        controller.textView.keyDown(with: up)
        #expect(document.textStorage.string == "b\na\n")
        let slash = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "/",
                                                  charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
        #expect(controller.textView.performKeyEquivalent(with: slash))
        #expect(document.textStorage.string == "// b\na\n")
        // Plain typing isn't looked up.
        let letter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "x",
                                                   charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        #expect(!controller.handleLineCommandKey(letter))
        // Every line command is in the palette with its default key.
        #expect(PaletteCommand.all.filter { $0.id.hasPrefix("edit.line.") }.count == LineCommand.allCases.count)
        #expect(Keybindings.shared.defaultSpec(for: "edit.line.moveUp") == "alt+up")
        withExtendedLifetime(window) {}
    }
}
