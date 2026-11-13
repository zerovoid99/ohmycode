import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct AutoEditTests {
    private func makeEditor(_ text: String, ext: String = "swift") throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-auto-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
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

    /// One key press, as AppKit sends it (typing goes through insertText, keys through commands).
    private func key(_ controller: EditorController, _ text: String) {
        let undo = controller.document.undoManager
        undo.beginUndoGrouping()
        if text == "\n" {
            if controller.textView.delegate?.textView?(controller.textView, doCommandBy: #selector(NSResponder.insertNewline(_:))) != true {
                controller.textView.insertNewline(nil)
            }
        } else if text == "⌫" {
            if controller.textView.delegate?.textView?(controller.textView, doCommandBy: #selector(NSResponder.deleteBackward(_:))) != true {
                controller.textView.deleteBackward(nil)
            }
        } else {
            controller.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        undo.endUndoGrouping()
    }

    private func type(_ controller: EditorController, _ keys: String) {
        for character in keys { key(controller, character == "⌫" ? "⌫" : String(character)) }
    }

    private func state(_ controller: EditorController) -> String {
        let text = controller.document.textStorage.string as NSString
        let cursor = controller.textView.selectedRange().location
        return text.replacingCharacters(in: NSRange(location: cursor, length: 0), with: "|")
    }

    @Test func enterKeepsAndDeepensIndentation() throws {
        let (_, controller, window) = try makeEditor("    let x = 1")
        controller.textView.setSelectedRange(NSRange(location: 13, length: 0))
        type(controller, "\n")
        #expect(state(controller) == "    let x = 1\n    |")

        type(controller, "if x {\n") // "{" closed itself; Enter puts "}" on its own line, indented
        #expect(state(controller) == "    let x = 1\n    if x {\n        |\n    }")
        withExtendedLifetime(window) {}
    }

    @Test func enterBetweenBracketsPutsTheCloserOnItsOwnLine() throws {
        let (_, controller, window) = try makeEditor("func f() ")
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        type(controller, "{")
        #expect(state(controller) == "func f() {|}")
        type(controller, "\n")
        #expect(state(controller) == "func f() {\n    |\n}")
        type(controller, "}") // already there below: typed on a blank line it outdents instead
        #expect(state(controller) == "func f() {\n}|\n}")
        withExtendedLifetime(window) {}
    }

    @Test func indentationFollowsTheFileAndLanguage() throws {
        let (_, tabs, tabWindow) = try makeEditor("struct A {\n\tvar a = 1\n\tfunc f() {")
        tabs.textView.setSelectedRange(NSRange(location: tabs.document.textStorage.length, length: 0))
        type(tabs, "\n")
        #expect(state(tabs) == "struct A {\n\tvar a = 1\n\tfunc f() {\n\t\t|")

        let (_, python, pythonWindow) = try makeEditor("def f():", ext: "py")
        python.textView.setSelectedRange(NSRange(location: 8, length: 0))
        type(python, "\n")
        #expect(state(python) == "def f():\n    |")
        withExtendedLifetime((tabWindow, pythonWindow)) {}
    }

    @Test func bracketsAndQuotesCloseThemselves() throws {
        let (document, controller, window) = try makeEditor("")
        type(controller, "print(")
        #expect(state(controller) == "print(|)")
        type(controller, "\"hi")
        #expect(state(controller) == "print(\"hi|\")")
        type(controller, "\")")      // steps over the closers already there
        #expect(state(controller) == "print(\"hi\")|")

        type(controller, " [⌫")      // Backspace in an empty pair deletes both
        #expect(state(controller) == "print(\"hi\") |")

        type(controller, "don't")   // no pair for an apostrophe in a word
        #expect(state(controller) == "print(\"hi\") don't|")
        type(controller, " x")
        controller.textView.setSelectedRange(NSRange(location: 1, length: 4)) // "rint"
        type(controller, "(")       // wraps the selection
        #expect(document.textStorage.string == "p(rint)(\"hi\") don't x")
        #expect(controller.textView.selectedRange() == NSRange(location: 2, length: 4))

        // Before a word, an opening bracket doesn't pair.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type(controller, "(")
        #expect(document.textStorage.string.hasPrefix("(p(rint)"))
        withExtendedLifetime(window) {}
    }

    @Test func autoCloseCanBeTurnedOff() throws {
        let settings = AppSettings.shared
        settings.autoClosePairs = false
        defer { settings.autoClosePairs = true }
        let (_, controller, window) = try makeEditor("")
        type(controller, "f(\"")
        #expect(state(controller) == "f(\"|")
        withExtendedLifetime(window) {}
    }

    @Test func undoRemovesTheAutoInsertedText() throws {
        let (document, controller, window) = try makeEditor("x")
        controller.textView.setSelectedRange(NSRange(location: 1, length: 0))
        document.undoManager.groupsByEvent = false
        type(controller, "(")
        #expect(document.textStorage.string == "x()")
        document.undoManager.undo()
        #expect(document.textStorage.string == "x")
        withExtendedLifetime(window) {}
    }
}

@MainActor
struct FormatOnSaveTests {
    @Test func formatsThenSaves() async throws {
        let (workspace, document, _, window) = try LanguageClientTests.makeWorkspace(text: "let a = 1   \nlet b = 2\t\n")
        #expect(try await LanguageClientTests.eventually { document.languageClient?.state == .ready })
        workspace.formatOnSave = true
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// edited \n")
        #expect(await workspace.saveActive()?.value == true)
        #expect(try String(contentsOf: document.url, encoding: .utf8) == "// edited\nlet a = 1\nlet b = 2\n")
        #expect(!document.isDirty)

        // Off: saved as typed.
        workspace.formatOnSave = false
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x  \n")
        await workspace.saveActive()?.value
        #expect(try String(contentsOf: document.url, encoding: .utf8).hasPrefix("x  \n"))
        withExtendedLifetime((workspace, window)) {}
    }

    /// A slow formatter doesn't hold up saving, and its late edits don't touch the saved file.
    @Test func slowFormatterTimesOutAndIsIgnored() async throws {
        let (workspace, document, _, window) = try LanguageClientTests.makeWorkspace(text: "// SLOW   \nlet a = 1\n")
        #expect(try await LanguageClientTests.eventually { document.languageClient?.state == .ready })
        workspace.formatOnSave = true
        workspace.formatOnSaveTimeout = .milliseconds(200)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n")
        let clock = ContinuousClock()
        let elapsed = await clock.measure { #expect(await workspace.saveActive()?.value == true) }
        #expect(elapsed < .milliseconds(800))
        #expect(try String(contentsOf: document.url, encoding: .utf8) == "\n// SLOW   \nlet a = 1\n")
        try await Task.sleep(for: .milliseconds(1200)) // the server answers after 1 s
        #expect(document.textStorage.string == "\n// SLOW   \nlet a = 1\n" && !document.isDirty)
        withExtendedLifetime((workspace, window)) {}
    }
}
