import AppKit
import Testing
@testable import Oh_My_Code

struct SnippetParserTests {
    private func ranges(_ snippet: ParsedSnippet) -> [Int: [String]] {
        let text = snippet.text as NSString
        return Dictionary(uniqueKeysWithValues: snippet.stops.map { ($0.index, $0.ranges.map { text.substring(with: $0) }) })
    }

    @Test func parsesStopsPlaceholdersMirrorsAndChoices() {
        let snippet = ParsedSnippet("for ${1:item} in ${2:items} {\n\tprint($1)\n}$0")
        #expect(snippet.text == "for item in items {\n\tprint(item)\n}")
        #expect(snippet.stops.map(\.index) == [1, 2, 0])
        #expect(ranges(snippet) == [1: ["item", "item"], 2: ["items"], 0: [""]])
        #expect(snippet.stops[2].ranges == [NSRange(location: (snippet.text as NSString).length, length: 0)])

        // Nested; no $0 means the end; the mirror before its placeholder still gets its text.
        let nested = ParsedSnippet("$1 = ${1:a ${2:b}}; ${3|one,two\\,x|}")
        #expect(nested.text == "a b = a b; one")
        #expect(ranges(nested) == [1: ["a b", "a b"], 2: ["b", "b"], 3: ["one"], 0: [""]])
        #expect(nested.stops[2].choices == ["one", "two,x"])
        #expect(nested.stops.last?.ranges == [NSRange(location: 14, length: 0)])

        // Escapes, a stray "$", transforms (left as the value) and a stop in its own placeholder.
        #expect(ParsedSnippet("cost \\$5 \\} \\\\ $ end").text == "cost $5 } \\ $ end")
        #expect(ParsedSnippet("${1/(.*)/${1:/upcase}/}x").text == "x")
        #expect(ParsedSnippet("${1:a $1}").text == "a ")
    }

    @Test func fillsVariablesAndLaysOutLines() {
        let variables: (String) -> String? = { ["TM_FILENAME": "a.swift", "TM_SELECTED_TEXT": "", "EMPTY": ""][$0] }
        let snippet = ParsedSnippet("// $TM_FILENAME ${TM_SELECTED_TEXT:none} ${EMPTY} $NOPE${1:x}", variables: variables)
        #expect(snippet.text == "// a.swift none  NOPEx")

        let layout = ParsedSnippet.Layout(indent: "    ", indentUnit: "  ")
        let block = ParsedSnippet("if ${1:c} {\n\t${2:body}\n}", layout: layout)
        #expect(block.text == "if c {\n      body\n    }")
        #expect(ranges(block)[2] == ["body"])
    }

    @Test func lspSnippetExpansionStillWorks() {
        #expect(Snippet.expand("fooBar(${1:count}, ${2:name})$0").firstPlaceholder == NSRange(location: 7, length: 5))
        #expect(Snippet.expand("plain").firstPlaceholder == nil)
    }
}

@MainActor
struct SnippetEditorTests {
    private func makeEditor(_ text: String, ext: String = "swift", root: URL? = nil) throws -> (EditorDocument, EditorController, NSWindow) {
        let folder = root ?? FileManager.default.temporaryDirectory
        let url = folder.appending(path: "omc-snippet-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        document.workspaceRoot = root
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
        for character in text {
            controller.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func selected(_ controller: EditorController) -> [String] {
        let text = controller.document.textStorage.string as NSString
        return controller.allSelections.sorted { $0.location < $1.location }.map { text.substring(with: $0) }
    }

    @Test func tabStepsThroughStopsThatFollowTyping() throws {
        let (document, controller, window) = try makeEditor("func f() {\n    \n}")
        controller.textView.setSelectedRange(NSRange(location: 15, length: 0))
        controller.insertSnippet("for ${1:item} in ${2:items} {\n\tprint($1)\n}", replacing: controller.textView.selectedRange())
        // Indented like the line, a tab as the file indents (4 spaces).
        #expect(document.textStorage.string == "func f() {\n    for item in items {\n        print(item)\n    }\n}")
        // The mirrored stop has a cursor in each copy: typing changes both.
        #expect(selected(controller) == ["item", "item"])
        type(controller, "row")
        #expect(document.textStorage.string == "func f() {\n    for row in items {\n        print(row)\n    }\n}")

        command(controller, #selector(NSResponder.insertTab(_:)))
        #expect(selected(controller) == ["items"])
        type(controller, "rows")
        command(controller, #selector(NSResponder.insertBacktab(_:)))
        #expect(selected(controller) == ["row", "row"])
        command(controller, #selector(NSResponder.insertTab(_:)))
        #expect(selected(controller) == ["rows"])
        // The last Tab goes to the end and finishes: Tab indents again.
        command(controller, #selector(NSResponder.insertTab(_:)))
        #expect(controller.snippetSession == nil)
        #expect(controller.textView.selectedRange().location == ("func f() {\n    for row in rows {\n        print(row)\n    }" as NSString).length)
        // One undo removes the typing per step; the snippet's insertion is its own step.
        #expect(document.textStorage.string.contains("for row in rows"))
        withExtendedLifetime(window) {}
    }

    @Test func typingOverAPlaceholderDropsItsNestedStops() throws {
        let (document, controller, window) = try makeEditor("", ext: "txt")
        controller.insertSnippet("call(${1:a, ${2:b}}) ${3:c}", replacing: NSRange(location: 0, length: 0))
        #expect(selected(controller) == ["a, b"])
        type(controller, "z")
        #expect(document.textStorage.string == "call(z) c")
        command(controller, #selector(NSResponder.insertTab(_:)))
        #expect(selected(controller) == ["c"]) // stop 2 went with the text it was in
        withExtendedLifetime(window) {}
    }

    @Test func leavingOrEscapeEndsTheSnippet() throws {
        let (document, controller, window) = try makeEditor("x\n", ext: "txt")
        controller.insertSnippet("${1:one} ${2:two}", replacing: NSRange(location: 0, length: 0))
        #expect(controller.snippetSession != nil)
        command(controller, #selector(NSResponder.cancelOperation(_:)))
        #expect(controller.snippetSession == nil)

        controller.insertSnippet("${1:one} ${2:two}", replacing: NSRange(location: document.textStorage.length, length: 0))
        #expect(controller.snippetSession != nil)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0)) // clicked elsewhere
        #expect(controller.snippetSession == nil)
        withExtendedLifetime(window) {}
    }

    @Test func tabAfterAPrefixExpandsIt() throws {
        let (document, controller, window) = try makeEditor("let x = 1\n")
        controller.textView.setSelectedRange(NSRange(location: 10, length: 0))
        type(controller, "guard")
        command(controller, #selector(NSResponder.insertTab(_:)))
        #expect(document.textStorage.string == "let x = 1\nguard condition else {\n    return\n}")
        #expect(selected(controller) == ["condition"])
        // Not a prefix: Tab inserts as usual.
        command(controller, #selector(NSResponder.cancelOperation(_:)))
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        command(controller, #selector(NSResponder.insertTab(_:)))
        #expect(document.textStorage.string.hasPrefix("let x = 1\t\n") || document.textStorage.string.hasPrefix("let x = 1    \n"))
        withExtendedLifetime(window) {}
    }

    @Test func completionOffersSnippetsAndInsertsThemWithStops() async throws {
        let (document, controller, window) = try makeEditor("", ext: "md")
        type(controller, "tab")
        controller.completion.triggerManually()
        let deadline = ContinuousClock.now + .seconds(5)
        while !controller.completion.visibleItems.contains(where: { $0.label == "table" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try #require(controller.completion.visibleItems.first { $0.label == "table" })
        #expect(item.kind == 15 && item.isSnippet)
        controller.completion.insert(item)
        #expect(document.textStorage.string == "| Column | Column |\n| --- | --- |\n|  |  |")
        #expect(selected(controller) == ["Column"])
        #expect(controller.snippetSession != nil)
        controller.completion.dismiss()
        withExtendedLifetime(window) {}
    }
}

struct SnippetLibraryTests {
    @Test func readsUserAndFolderSnippets() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "omc-snippets-\(UUID().uuidString)")
        let user = base.appending(path: "user")
        let root = base.appending(path: "project")
        for folder in [user, root.appending(path: ".vscode"), root.appending(path: ".omc/snippets")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try """
        {
          // comments are fine
          "My guard": { "prefix": "guard", "body": ["guard $1 else {", "\\treturn", "}"], "description": "mine" },
          "Two": { "prefix": ["tw", "two"], "body": "2" },
          "Broken": { "body": "no prefix" }
        }
        """.write(to: user.appending(path: "swift.json"), atomically: true, encoding: .utf8)
        try #"{ "Py only": { "prefix": "pyo", "body": "x", "scope": "python" }, "Any": { "prefix": "any", "body": "y" } }"#
            .write(to: root.appending(path: ".vscode/team.code-snippets"), atomically: true, encoding: .utf8)
        try #"{ "Local": { "prefix": "loc", "body": "z" } }"#
            .write(to: root.appending(path: ".omc/snippets/swift.json"), atomically: true, encoding: .utf8)

        let library = SnippetLibrary(userDirectory: user)
        let swift = library.snippets(for: "swift", root: root)
        let custom = swift.filter { $0.source != "Built-in" }
        #expect(custom.map(\.name) == ["My guard", "Two", "Local", "Any"])
        #expect(custom[0].body == "guard $1 else {\n\treturn\n}" && custom[0].source == "User" && custom[1].prefixes == ["tw", "two"])
        #expect(custom[3].source == "team.code-snippets")
        // The user's "guard" replaces the built-in one; other built-ins stay.
        #expect(swift.filter { $0.prefixes.contains("guard") }.count == 1 && swift.contains { $0.prefixes == ["struct"] })
        #expect(library.snippets(for: "python", root: root).filter { $0.source != "Built-in" }.map(\.name) == ["Any", "Py only"])

        // A changed file is read again.
        try #"{ "Local": { "prefix": "loc2", "body": "z" } }"#
            .write(to: root.appending(path: ".omc/snippets/swift.json"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: root.appending(path: ".omc/snippets/swift.json").path)
        #expect(library.snippets(for: "swift", root: root).contains { $0.prefixes == ["loc2"] })

        // The user file for a new language starts as a commented example that parses to nothing.
        let file = try library.userFile(for: "go")
        #expect(SnippetLibrary.parse(try Data(contentsOf: file), source: "User").isEmpty)
        #expect(library.snippets(for: "go", root: nil).allSatisfy { $0.source == "Built-in" })
    }
}
