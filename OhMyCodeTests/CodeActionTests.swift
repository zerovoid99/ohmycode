import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct CodeActionTests {
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func type(_ controller: EditorController, _ text: String) {
        for character in text {
            controller.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    @Test func listsAndRunsFixesAndRefactorings() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(text: "let ok = 1\nlet BAD = 2\n")
        #expect(try await eventually { document.diagnostics.count == 1 && document.languageClient?.state == .ready })
        let line = NSRange(location: 15, length: 0) // in BAD
        var actions = await workspace.codeActions(for: document, range: line)
        // The fix for the problem (offered because its own JSON went back), then refactorings, then source actions.
        #expect(actions.map(\.title) == ["Replace BAD with good", "Add a comment above", "Upper-case the line", "Not now", "Organize imports"])
        #expect(actions[0].isPreferred && actions[3].disabledReason == "fake says no")

        // An edit: one undo step.
        await workspace.run(actions[0], in: document)
        #expect(document.textStorage.string == "let ok = 1\nlet good = 2\n")
        document.undoManager.undo()
        #expect(document.textStorage.string == "let ok = 1\nlet BAD = 2\n")

        // A command: the server changes the file through workspace/applyEdit.
        actions = await workspace.codeActions(for: document, range: line)
        await workspace.run(actions[1], in: document)
        #expect(try await eventually { document.textStorage.string == "let ok = 1\n// added\nlet BAD = 2\n" })

        // Resolved first: its edit comes when asked.
        actions = await workspace.codeActions(for: document, range: NSRange(location: 0, length: 0))
        await workspace.run(try #require(actions.first { $0.title == "Upper-case the line" }), in: document)
        #expect(document.textStorage.string.hasPrefix("LET OK = 1\n"))

        // Disabled: says why, changes nothing.
        let text = document.textStorage.string
        await workspace.run(try #require(actions.first { $0.title == "Not now" }), in: document)
        #expect(workspace.errorMessage?.contains("fake says no") == true && document.textStorage.string == text)
        workspace.errorMessage = nil

        await workspace.organizeImports(in: document)?.value
        #expect(document.textStorage.string.hasPrefix("import Sorted\nLET OK"))
        withExtendedLifetime((workspace, window, controller)) {}
    }

    @Test func menusGroupActions() throws {
        let actions = [
            ["title": "Extract", "kind": "refactor.extract"], ["title": "Fix it", "kind": "quickfix", "isPreferred": true],
            ["title": "Sort imports", "kind": "source.organizeImports"], ["title": "Nope", "kind": "refactor", "disabled": ["reason": "no"]],
            ["title": "Run thing", "command": "x.run"],
        ].compactMap { CodeAction(json: $0) }
        var ran: [String] = []
        let menu = EditorController.codeActionMenu(actions) { ran.append($0.title) }
        let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == ["Quick Fix", "Fix it", "-", "Refactor", "Extract", "Nope", "-", "Source", "Sort imports", "-", "More Actions", "Run thing"])
        #expect(menu.items[1].attributedTitle != nil && menu.items[5].isEnabled == false && menu.items[5].toolTip == "no")
        menu.performActionForItem(at: 4)
        #expect(ran == ["Extract"])
    }

    @Test func aLightbulbOffersFixesOnTheCursorsLine() async throws {
        LightbulbController.delay = .milliseconds(10)
        defer { LightbulbController.delay = .milliseconds(300) }
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(text: "let ok = 1\nlet BAD = 2\n")
        #expect(try await eventually { document.diagnostics.count == 1 && document.languageClient?.state == .ready })
        controller.textView.setSelectedRange(NSRange(location: 15, length: 0))
        #expect(try await eventually { controller.lightbulb.isShown })
        #expect(controller.lightbulb.line == 1 && controller.lightbulb.actions.first?.title == "Replace BAD with good")
        // A line without problems: no bulb.
        controller.textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(!controller.lightbulb.isShown)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func parameterHintsFollowTheCall() async throws {
        SignatureHelpController.updateDelay = .milliseconds(5)
        defer { SignatureHelpController.updateDelay = .milliseconds(60) }
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(text: "\n")
        #expect(try await eventually { document.languageClient?.state == .ready })
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let hints = controller.signatureHelp
        type(controller, "fooBar(")
        #expect(try await eventually { hints.help != nil })
        #expect(hints.help?.highlighted == NSRange(location: 7, length: 10)) // count: Int
        type(controller, "3, ")
        #expect(try await eventually { hints.help?.highlighted == NSRange(location: 19, length: 12) }) // name: String
        let label = SignatureHelpView.label(try #require(hints.help))
        #expect(String(label.characters) == "fooBar(count: Int, name: String) -> Int")
        // The call closed: the hint goes.
        type(controller, "\"x\")")
        #expect(try await eventually { hints.help == nil })

        // By hand, and Esc.
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        hints.trigger()
        #expect(try await eventually { hints.help != nil })
        #expect(hints.handle(#selector(NSResponder.cancelOperation(_:))) && hints.help == nil)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func readsSignatureHelp() throws {
        let help = try #require(SignatureHelp(json: [
            "activeSignature": 5, "activeParameter": 1,
            "signatures": [["label": "f(a: Int, b: Int)", "parameters": [["label": "a: Int"], ["label": [10, 16]]]],
                           ["label": "f()", "parameters": [], "activeParameter": 0]],
        ]))
        #expect(help.activeSignature == 1) // clamped
        #expect(help.highlighted == nil)    // f() has no parameters
        var first = help
        first.activeSignature = 0
        #expect(first.highlighted == NSRange(location: 10, length: 6))
        #expect(first.signatures[0].parameters[0].range == NSRange(location: 2, length: 6))
        #expect(SignatureHelp(json: ["signatures": []]) == nil)
    }
}
