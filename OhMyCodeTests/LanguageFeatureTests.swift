import AppKit
import Foundation
import Testing
@testable import Oh_My_Code

/// Multi-edit application shared by rename, formatting and replace.
@MainActor
struct TextReplacementTests {
    private func makeDocument(_ text: String) throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-edits-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        document.undoManager.groupsByEvent = false
        return document
    }

    /// Random non-overlapping edit sets: the document matches applying them to a plain string,
    /// its line index stays exact, and undo/redo are single steps that restore each version.
    @Test func appliesEditsAsOneUndoStep() throws {
        let pieces = ["", "x", "\n", "é😀", "ab\ncd\n", "    "]
        for _ in 0..<60 {
            let original = (0..<Int.random(in: 1...6)).map { _ in pieces.randomElement()! + "line\n" }.joined()
            let document = try makeDocument(original)
            let length = (original as NSString).length
            var edits: [TextReplacement] = []
            var position = 0
            while position < length, edits.count < 8 {
                let start = Int.random(in: position...length)
                let end = Int.random(in: start...min(length, start + 4))
                edits.append(TextReplacement(range: NSRange(location: start, length: end - start), text: pieces.randomElement()!))
                position = end + 1
            }
            edits.shuffle()
            let expected = try TextReplacement.apply(edits, to: original)
            let changed = try document.apply(edits, actionName: "Test")
            #expect(document.textStorage.string == expected)
            #expect(changed == (expected != original))
            #expect(document.lineIndex == LineIndex(string: document.textStorage.mutableString))
            guard changed else { continue }

            document.undoManager.undo()
            #expect(document.textStorage.string == original)
            #expect(document.lineIndex == LineIndex(string: document.textStorage.mutableString))
            document.undoManager.redo()
            #expect(document.textStorage.string == expected)
        }
    }

    @Test func rejectsOverlappingEditsWithoutChangingAnything() throws {
        let document = try makeDocument("abcdef")
        #expect(throws: TextReplacementError.self) {
            try document.apply([TextReplacement(range: NSRange(location: 0, length: 3), text: "x"),
                                TextReplacement(range: NSRange(location: 2, length: 2), text: "y")], actionName: "Test")
        }
        #expect(throws: TextReplacementError.self) {
            try document.apply([TextReplacement(range: NSRange(location: 5, length: 3), text: "x")], actionName: "Test")
        }
        #expect(document.textStorage.string == "abcdef")
        #expect(!document.undoManager.canUndo)
    }

    @Test func previewGroupsEditsByLine() {
        let text = "a b a\nnone\nx\ny\nlast a"
        let edits = [
            TextReplacement(range: NSRange(location: 0, length: 1), text: "A"),
            TextReplacement(range: NSRange(location: 4, length: 1), text: "A"),
            TextReplacement(range: NSRange(location: 11, length: 3), text: "x+y"), // "x\ny" spans two lines
            TextReplacement(range: NSRange(location: 20, length: 1), text: "A"),
        ]
        let changes = EditPreview.LineChange.changes(edits, in: text)
        #expect(changes.map(\.line) == [0, 2, 4])
        #expect(changes.map(\.old) == ["a b a", "x\ny", "last a"])
        #expect(changes.map(\.new) == ["A b A", "x+y", "last A"])
    }

    @Test func detectsIndentation() throws {
        #expect(try makeDocument("a {\n    b\n        c\n}\n").indentation == (4, true))
        #expect(try makeDocument("a {\n  b\n    c\n  d\n}\n").indentation == (2, true))
        #expect(try makeDocument("a {\n\tb\n\t\tc\n}\n").indentation == (4, false))
    }
}

struct LSPParsingTests {
    @Test func parsesBothWorkspaceEditShapes() throws {
        let range: [String: Any] = ["start": ["line": 0, "character": 1], "end": ["line": 0, "character": 2]]
        let changes = try #require(WorkspaceEdit(json: ["changes": ["file:///a.swift": [["range": range, "newText": "x"]]]]))
        #expect(changes.changes[URL(string: "file:///a.swift")!]?.first?.newText == "x")
        let documentChanges = try #require(WorkspaceEdit(json: ["documentChanges": [
            ["textDocument": ["uri": "file:///b.swift", "version": 3], "edits": [["range": range, "newText": "y"]]],
            ["kind": "create", "uri": "file:///c.swift"], // file operations are skipped
        ]]))
        #expect(documentChanges.changes.keys.map(\.lastPathComponent) == ["b.swift"])
        #expect(documentChanges.editCount == 1)
    }

    @Test func normalizesHoverContents() {
        #expect(HoverContent.markdown(from: ["contents": ["kind": "markdown", "value": "**x**"]]) == "**x**")
        #expect(HoverContent.markdown(from: ["contents": ["language": "swift", "value": "let x"]]) == "```swift\nlet x\n```")
        #expect(HoverContent.markdown(from: ["contents": ["plain", ["language": "c", "value": "int x"]]])
                == "plain\n\n---\n\n```c\nint x\n```")
        #expect(HoverContent.markdown(from: ["contents": ""]) == nil)
        #expect(HoverContent.markdown(from: NSNull()) == nil)

        #expect(HoverContent.blocks("```swift\nlet x: Int\n```\n---\nDocs *here*.\n\nMore.") == [
            .code("let x: Int"), .rule, .text("Docs *here*.\n\nMore."),
        ])
        #expect(HoverContent.blocks("---\ntext\n---") == [.text("text")])
    }
}

/// Hover, references, rename and formatting against the fake server (Fixtures/fake_lsp.py).
@MainActor
struct LanguageFeatureTests {
    private func ready(_ document: EditorDocument) async throws -> LanguageClient {
        #expect(try await LanguageClientTests.eventually { document.languageClient?.state == .ready })
        return try #require(document.languageClient)
    }

    @Test func hoverShowsDocsAndDiagnostics() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "let value = 1\nlet BAD = 2\n")
        _ = try await ready(document)
        #expect(try await LanguageClientTests.eventually { document.diagnostics.count == 1 })
        controller.textView.layoutSubtreeIfNeeded()

        // The mouse maps to the character whose glyph it is over, and nothing past a line's end.
        let rect = try #require(controller.rect(for: NSRange(location: 5, length: 1)))
        #expect(controller.characterIndex(at: NSPoint(x: rect.midX, y: rect.midY)) == 5)
        #expect(controller.characterIndex(at: NSPoint(x: rect.midX + 400, y: rect.midY)) == nil)

        #expect(await controller.hover.show(at: 5))
        #expect(controller.hover.shownMarkdown?.contains("Docs for **value**") == true)
        #expect(controller.hover.shownDiagnostics.isEmpty)

        #expect(await controller.hover.show(at: 19)) // inside BAD
        #expect(controller.hover.shownDiagnostics.map(\.message) == ["BAD is not allowed"])
        #expect(controller.hover.shownMarkdown?.contains("**BAD**") == true)

        controller.hover.dismiss()
        #expect(await controller.hover.show(at: 10) == false) // "=": no symbol, no diagnostic
        #expect(controller.hover.shownMarkdown == nil)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func findReferencesListsUsesAcrossFiles() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "let target = 1\nprint(target)\n",
            files: ["Sources/b.swift": "func f() -> Int { target + target }\n"])
        _ = try await ready(document)
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        await workspace.findReferences()?.value

        let references = try #require(workspace.references)
        #expect(workspace.sidebarMode == .references)
        #expect(references.symbol == "target")
        #expect(references.count == 4)
        #expect(references.results.map(\.path) == ["main.swift", "Sources/b.swift"])
        #expect(references.results[1].matches.map(\.column) == [18, 27])
        let match = references.results[1].matches[0]
        #expect((match.preview as NSString).substring(with: match.previewRange) == "target")

        // Opening a reference selects it in its file.
        workspace.open(references.results[1], match)
        #expect(workspace.activeDocument?.fileName == "b.swift")
        withExtendedLifetime((workspace, window)) {}
    }

    /// Rename is reviewed first, then applied through documents: files that weren't open open as
    /// unsaved tabs, so every change can be undone and nothing is written to disk.
    @Test func renameIsReviewedThenAppliedUndoablyInTabs() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "let target = 1\nprint(target)\n",
            files: ["Sources/b.swift": "let x = target * 2 // target\n", "Sources/c.swift": "print(target)\n"])
        _ = try await ready(document)
        let root = try #require(workspace.rootURL)
        document.undoManager.groupsByEvent = false

        var prompted: [String] = []
        workspace.renamePrompt = { current in prompted.append(current); return "goal" }

        // A number can't be renamed: the server refuses before the prompt.
        controller.textView.setSelectedRange(NSRange(location: 13, length: 0))
        await workspace.renameSymbol()?.value
        #expect(prompted.isEmpty && workspace.pendingEdit == nil)

        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        await workspace.renameSymbol()?.value
        #expect(prompted == ["target"])

        // Nothing changes until the preview is applied.
        let preview = try #require(workspace.pendingEdit)
        #expect(preview.title == "Rename “target” to “goal”")
        #expect(preview.files.map(\.path) == ["main.swift", "Sources/b.swift", "Sources/c.swift"])
        #expect(preview.changeCount == 5)
        let bChanges = try #require(preview.files.first { $0.path == "Sources/b.swift" }?.changes)
        #expect(bChanges.map(\.old) == ["let x = target * 2 // target"])
        #expect(bChanges.map(\.new) == ["let x = goal * 2 // goal"])
        #expect(document.textStorage.string == "let target = 1\nprint(target)\n")

        // Leave c.swift out; b.swift changes on disk after the preview, so it's skipped too.
        preview.files[2].isIncluded = false
        try "let x = target * 3\n".write(to: root.appending(path: "Sources/b.swift"), atomically: true, encoding: .utf8)
        let skipped = workspace.applyPendingEdit()
        #expect(skipped == ["Sources/b.swift"])
        #expect(workspace.errorMessage?.contains("Sources/b.swift") == true)
        #expect(document.textStorage.string == "let goal = 1\nprint(goal)\n")
        #expect(workspace.activeDocument === document) // other files open in the background
        #expect(workspace.document(matching: root.appending(path: "Sources/c.swift")) == nil,
                "open: \(workspace.documents.map(\.fileName))")
        #expect(workspace.document(matching: root.appending(path: "Sources/b.swift")) == nil) // skipped: no tab

        // Files that weren't open: opened as unsaved tabs, disk untouched, undoable.
        workspace.errorMessage = nil
        controller.textView.setSelectedRange(NSRange(location: 21, length: 0)) // "goal" in print(goal)
        workspace.renamePrompt = { _ in "aim" }
        await workspace.renameSymbol()?.value
        workspace.applyPendingEdit()
        #expect(workspace.document(matching: root.appending(path: "Sources/c.swift")) == nil) // no "goal" in it
        #expect(document.textStorage.string == "let aim = 1\nprint(aim)\n")

        workspace.renamePrompt = { _ in "goal" }
        controller.textView.setSelectedRange(NSRange(location: 4, length: 0))
        document.undoManager.undo() // aim → goal
        #expect(document.textStorage.string == "let goal = 1\nprint(goal)\n")
        document.undoManager.undo() // goal → target
        #expect(document.textStorage.string == "let target = 1\nprint(target)\n")
        #expect(try String(contentsOf: document.url, encoding: .utf8) == "let target = 1\nprint(target)\n")

        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        await workspace.renameSymbol()?.value
        workspace.applyPendingEdit()
        let c = try #require(workspace.document(matching: root.appending(path: "Sources/c.swift")))
        #expect(c.textStorage.string == "print(goal)\n" && c.isDirty)
        #expect(workspace.documents(in: workspace.activeGroup).contains { $0 === c }) // has a tab
        #expect(try String(contentsOf: c.url, encoding: .utf8) == "print(target)\n")
        c.undoManager.undo()
        #expect(c.textStorage.string == "print(target)\n")
        withExtendedLifetime((workspace, window)) {}
    }

    /// sourcekit-lsp names a file both by its /var/… and /private/var/… path in one edit.
    @Test func previewMergesOneFileNamedByTwoURIs() throws {
        let (workspace, document, _, window) = try LanguageClientTests.makeWorkspace(text: "let target = 1\n")
        let url = document.url
        let resolved = URL(filePath: FileWatcher.canonicalPath(url))
        #expect(resolved.path != url.path) // the temporary directory is behind a symlink
        let rename = LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 4), end: LSPPosition(line: 0, character: 10)),
                                 newText: "goal")
        let preview = try workspace.preview(WorkspaceEdit(changes: [url: [rename], resolved: [rename]]),
                                            title: "Rename", actionName: "Rename")
        #expect(preview.files.count == 1 && preview.changeCount == 1)
        #expect(workspace.apply(preview).isEmpty)
        #expect(document.textStorage.string == "let goal = 1\n")
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func formatDocumentIsOneUndoStepAndKeepsServerInSync() async throws {
        let original = "struct A {\n  var a = 1  \n  var b = 2\n\tvar c = 3 \n}\n"
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(text: original)
        let client = try await ready(document)
        document.undoManager.groupsByEvent = false
        controller.textView.setSelectedRange(NSRange(location: 40, length: 0)) // in "var c"

        await workspace.formatDocument()?.value
        let formatted = "struct A {\n  var a = 1\n  var b = 2\n  var c = 3\n}\n"
        #expect(document.textStorage.string == formatted)
        #expect(controller.textView.selectedRange().location == 39) // moved with its text (−2 + 1)
        let serverText = try await client.request("omc/text", params: ["uri": document.url.absoluteString]) as? String
        #expect(serverText == formatted)

        document.undoManager.undo()
        #expect(document.textStorage.string == original)
        document.undoManager.redo()
        #expect(document.textStorage.string == formatted)

        // Typing while the request is in flight makes its edits stale: they are dropped.
        document.undoManager.undo()
        let task = workspace.formatDocument()
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// x\n")
        await task?.value
        #expect(document.textStorage.string == "// x\n" + original)
        withExtendedLifetime((workspace, window)) {}
    }
}

@MainActor
struct ReplaceInFilesTests {
    private func makeWorkspace(_ files: [String: String]) throws -> (Workspace, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-replace-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let workspace = Workspace()
        workspace.openFolder(root)
        return (workspace, root)
    }

    @Test func replacementsFollowSearchOptions() throws {
        func replace(_ text: String, _ options: SearchOptions, with replacement: String) throws -> String {
            let edits = TextSearch.replacements(in: text, regex: try TextSearch.replacementRegex(options),
                                                template: TextSearch.template(replacement, regex: options.regex))
            return try TextReplacement.apply(edits, to: text)
        }
        #expect(try replace("Foo foo food", SearchOptions(query: "foo"), with: "bar") == "bar bar bard")
        #expect(try replace("Foo foo food", SearchOptions(query: "foo", caseSensitive: true, wholeWord: true), with: "$1")
                == "Foo $1 food") // literal mode: no templates
        #expect(try replace("a.b a+b", SearchOptions(query: "a.b"), with: "x") == "x a+b")
        #expect(try replace("id = 42; id = 7", SearchOptions(query: #"id = (\d+)"#, regex: true), with: #"n($1)\n"#)
                == "n(42)\n; n(7)\n")
        #expect(try replace("a$b", SearchOptions(query: "a", regex: true), with: #"\$"#) == "$$b")
    }

    @Test func replaceAllIsReviewedAndUndoable() async throws {
        let (workspace, root) = try makeWorkspace([
            "open.txt": "foo and foo\n",
            "closed/x.txt": "food foo\n",
            "other.md": "nothing\n",
        ])
        let model = workspace.search
        workspace.open(fileAt: root.appending(path: "open.txt"))
        let document = try #require(workspace.activeDocument)
        document.undoManager.groupsByEvent = false
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "foo! ") // unsaved

        model.options = SearchOptions(query: "foo", wholeWord: true)
        await model.waitUntilDone()
        #expect(model.matchCount == 4)
        model.showsReplace = true
        model.replacement = "bar"
        let match = try #require(model.results.first { $0.path == "closed/x.txt" }?.matches.first)
        #expect(model.replacementPreview(for: match) == "bar")

        // Replace All shows a preview; cancelling changes nothing.
        await model.replaceAll()?.value
        let preview = try #require(workspace.pendingEdit)
        #expect(preview.title == "Replace 4 occurrences of “foo” with “bar”")
        #expect(preview.files.map(\.path) == ["closed/x.txt", "open.txt"])
        #expect(preview.files[1].changes.first?.new == "bar! bar and bar")
        workspace.cancelPendingEdit()
        #expect(document.textStorage.string == "foo! foo and foo\n")

        await model.replaceAll()?.value
        workspace.applyPendingEdit()
        await model.waitUntilDone()
        #expect(document.textStorage.string == "bar! bar and bar\n")
        // The closed file is now an unsaved tab; the file on disk is untouched.
        let closed = try #require(workspace.document(matching: root.appending(path: "closed/x.txt")))
        #expect(closed.textStorage.string == "food bar\n" && closed.isDirty)
        #expect(try String(contentsOf: closed.url, encoding: .utf8) == "food foo\n")
        #expect(model.results.isEmpty) // searched again afterwards

        document.undoManager.undo()
        #expect(document.textStorage.string == "foo! foo and foo\n")
        closed.undoManager.undo()
        #expect(closed.textStorage.string == "food foo\n")
        withExtendedLifetime(workspace) {}
    }

    @Test func replacesSingleMatchesAndFilesWithRegexGroups() async throws {
        let (workspace, root) = try makeWorkspace([
            "a.txt": "v1 v2\nv3\n",
            "b.txt": "v4\n",
        ])
        let model = workspace.search
        model.options = SearchOptions(query: #"v(\d)"#, regex: true)
        model.replacement = "w$1$1"
        await model.waitUntilDone()
        let a = try #require(model.results.first { $0.path == "a.txt" })
        #expect(model.replacementPreview(for: a.matches[1]) == "w22")

        // One match: only that occurrence changes, even though the file has three.
        // Applied right away (no review), still through an undoable tab.
        func text(_ name: String) -> String? { workspace.document(matching: root.appending(path: name))?.textStorage.string }
        await model.replace(a.matches[1], in: a)?.value
        #expect(workspace.pendingEdit == nil)
        #expect(text("a.txt") == "v1 w22\nv3\n")

        let b = try #require(model.results.first { $0.path == "b.txt" })
        await model.replace(in: b)?.value
        #expect(text("b.txt") == "w44\n")
        #expect(text("a.txt") == "v1 w22\nv3\n")
        #expect(try String(contentsOf: root.appending(path: "b.txt"), encoding: .utf8) == "v4\n")
        #expect(model.results.map(\.path) == ["a.txt"])
        #expect(model.matchCount == 2)
        withExtendedLifetime(workspace) {}
    }
}
