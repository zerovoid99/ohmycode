import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct MultiCursorTests {

    private func makeEditor(_ text: String) throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-multi-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        document.undoManager.groupsByEvent = false
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.attach(controller)
        document.editor = controller
        return (document, controller, window)
    }

    private func command(_ controller: EditorController, _ selector: Selector) {
        if controller.textView.delegate?.textView?(controller.textView, doCommandBy: selector) != true {
            controller.textView.doCommand(by: selector)
        }
    }

    private func type(_ controller: EditorController, _ text: String) {
        controller.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func carets(_ controller: EditorController) -> [Int] {
        controller.allSelections.map(\.location).sorted()
    }

    @Test func typingAndDeletingAtEveryCursorIsOneUndoStep() throws {
        let (document, controller, window) = try makeEditor("foo\nfoo\nfoo")
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0))
        controller.toggleCursor(at: 7)   // ⌥-click
        controller.toggleCursor(at: 11)
        #expect(carets(controller) == [3, 7, 11])

        type(controller, "X")
        #expect(document.textStorage.string == "fooX\nfooX\nfooX")
        #expect(carets(controller) == [4, 9, 14])
        type(controller, "é😀")
        #expect(document.textStorage.string == "fooXé😀\nfooXé😀\nfooXé😀")
        command(controller, #selector(NSResponder.deleteBackward(_:))) // the emoji is one character to delete
        #expect(document.textStorage.string == "fooXé\nfooXé\nfooXé")

        document.undoManager.undo()
        #expect(document.textStorage.string == "fooXé😀\nfooXé😀\nfooXé😀")
        document.undoManager.undo()
        document.undoManager.undo()
        #expect(document.textStorage.string == "foo\nfoo\nfoo")

        // ⌥-clicking an extra cursor again removes it; Esc drops the rest.
        controller.setSelections(main: NSRange(location: 3, length: 0), extras: [NSRange(location: 7, length: 0)])
        controller.toggleCursor(at: 7)
        #expect(!controller.hasExtraCursors)
        controller.toggleCursor(at: 7)
        command(controller, #selector(NSResponder.cancelOperation(_:)))
        #expect(!controller.hasExtraCursors)
        withExtendedLifetime(window) {}
    }

    @Test func cursorsThatMeetMerge() throws {
        let (document, controller, window) = try makeEditor("abc")
        controller.setSelections(main: NSRange(location: 2, length: 0), extras: [NSRange(location: 1, length: 0)])
        command(controller, #selector(NSResponder.deleteBackward(_:)))
        #expect(document.textStorage.string == "c")
        #expect(carets(controller) == [0])
        #expect(!controller.hasExtraCursors)
        withExtendedLifetime(window) {}
    }

    @Test func addNextAndAllOccurrences() throws {
        let text = "value = value + other.value"
        let (document, controller, window) = try makeEditor(text)
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        controller.addNextOccurrence() // selects the word
        #expect(controller.textView.selectedRange() == NSRange(location: 0, length: 5))
        #expect(!controller.hasExtraCursors)
        controller.addNextOccurrence()
        controller.addNextOccurrence()
        #expect(controller.allSelections.map(\.location).sorted() == [0, 8, 22])
        controller.addNextOccurrence() // all taken: nothing more
        #expect(controller.extraSelections.count == 2)

        type(controller, "x")
        #expect(document.textStorage.string == "x = x + other.x")

        document.undoManager.undo()
        controller.setSelections(main: NSRange(location: 9, length: 0), extras: [])
        controller.selectAllOccurrences() // ⇧⌘L from a cursor in the second "value"
        #expect(controller.allSelections.count == 3)
        #expect(controller.allSelections.allSatisfy { $0.length == 5 })
        withExtendedLifetime(window) {}
    }

    @Test func cursorsAboveAndBelowAndMovement() throws {
        let (document, controller, window) = try makeEditor("abcd\nab\nabcd\nx")
        controller.textView.setSelectedRange(NSRange(location: 3, length: 0)) // line 0, column 3
        controller.addCursorVertically(1)  // line 1 is shorter: its end
        controller.addCursorVertically(1)  // line 2, column 2 (from the cursor above it)
        #expect(carets(controller) == [3, 7, 10])
        controller.addCursorVertically(-1) // nothing above line 0's cursor's line? line -1: ignored
        #expect(carets(controller) == [3, 7, 10])

        command(controller, #selector(NSResponder.moveRight(_:)))
        #expect(carets(controller) == [4, 8, 11]) // the end of "ab" moves to the next line
        command(controller, #selector(NSResponder.moveLeft(_:)))
        #expect(carets(controller) == [3, 7, 10])
        command(controller, #selector(NSResponder.moveToBeginningOfLine(_:)))
        #expect(carets(controller) == [0, 5, 8])
        command(controller, #selector(NSResponder.moveToEndOfLine(_:)))
        #expect(carets(controller) == [4, 7, 12])
        command(controller, #selector(NSResponder.moveDown(_:))) // columns clamp to shorter lines
        #expect(carets(controller) == [7, 10, 14])

        // The overlay draws a caret per extra cursor.
        controller.textView.layoutSubtreeIfNeeded()
        #expect(controller.extraCursorShapes().carets.count == 2)

        // A command that doesn't apply to several cursors drops the extras first.
        command(controller, #selector(NSResponder.moveWordLeft(_:)))
        #expect(!controller.hasExtraCursors)
        #expect(document.textStorage.string == "abcd\nab\nabcd\nx")
        withExtendedLifetime(window) {}
    }

    /// Regression: an edit that bypasses the cursors (paste, completion inserting at a range)
    /// left extra cursors pointing past the text.
    @Test func editsElsewhereDropExtraCursors() throws {
        let (document, controller, window) = try makeEditor("one two three four")
        controller.setSelections(main: NSRange(location: 0, length: 18), extras: [NSRange(location: 17, length: 0)])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("x", forType: .string)
        // Text view edits register undo; with event grouping off (see makeEditor) they need a
        // group, or AppKit throws through Swift frames and the process crashes later.
        let undo = document.undoManager
        undo.beginUndoGrouping()
        controller.textView.paste(nil) // replaces the whole selection
        undo.endUndoGrouping()
        #expect(document.textStorage.string == "x")
        #expect(!controller.hasExtraCursors)

        controller.setSelections(main: NSRange(location: 0, length: 1), extras: [NSRange(location: 1, length: 0)])
        undo.beginUndoGrouping()
        controller.textView.insertText("longer", replacementRange: NSRange(location: 0, length: 1))
        undo.endUndoGrouping()
        #expect(document.textStorage.string == "longer" && !controller.hasExtraCursors)
        withExtendedLifetime(window) {}
    }

}
