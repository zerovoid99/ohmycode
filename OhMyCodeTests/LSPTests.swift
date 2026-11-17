import AppKit
import Foundation
import Testing
@testable import Oh_My_Code

struct SnippetTests {
    @Test func expandsPlaceholders() {
        let (text, first) = Snippet.expand("fooBar(${1:count}, ${2:name})$0")
        #expect(text == "fooBar(count, name)")
        #expect(first == NSRange(location: 7, length: 5))
        #expect(Snippet.expand("plain").text == "plain")
        #expect(Snippet.expand("a($1)").firstPlaceholder == NSRange(location: 2, length: 0))
        #expect(Snippet.expand("cost \\$5").text == "cost $5")
    }
}

/// Uses a fake server (Fixtures/fake_lsp.py) for deterministic protocol tests.
@MainActor
struct LanguageClientTests {
    static var fakeServer: LanguageServerConfig {
        let script = Bundle(for: BundleToken.self).url(forResource: "fake_lsp", withExtension: "py", subdirectory: "Fixtures")!
        return LanguageServerConfig(name: "Fake LSP", command: ["/usr/bin/python3", script.path], languages: [.swift])
    }

    /// The fake server asking for the whole text on every change (`textDocumentSync` 1).
    static var fullSyncServer: LanguageServerConfig {
        let server = fakeServer
        return LanguageServerConfig(name: server.name, command: server.command + ["--full-sync"], languages: server.languages)
    }

    func makeWorkspace(text: String, files: [String: String] = [:]) throws -> (Workspace, EditorDocument, EditorController, NSWindow) {
        try Self.makeWorkspace(text: text, files: files)
    }

    /// Writing to a server that exited fails quietly (SIGPIPE would kill the app).
    @Test func writingToAnExitedServerDoesNotKillTheApp() async throws {
        var action = sigaction()
        sigaction(SIGPIPE, nil, &action)
        #expect(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self))
        let connection = try LanguageServerConnection(command: ["/usr/bin/true"], directory: FileManager.default.temporaryDirectory,
                                                      environment: [:])
        var exited = false
        connection.onExit = { _ in exited = true }
        let deadline = ContinuousClock.now + .seconds(10)
        while !exited, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(exited)
        for _ in 0..<5 { connection.send(Data(String(repeating: "x", count: 100_000).utf8)) }
        // Past the writes above (they're in order on one queue).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send { continuation.resume(); return nil }
        }
        #expect(!connection.isRunning)
    }

    /// A folder with main.swift (opened in an editor in a window) plus `files`.
    static func makeWorkspace(text: String, files: [String: String] = [:],
                              server: LanguageServerConfig = fakeServer) throws -> (Workspace, EditorDocument, EditorController, NSWindow) {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-lsp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let workspace = Workspace()
        workspace.languageServerOverrides[.swift] = server
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "main.swift"))
        let document = workspace.activeDocument!
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        // Typing happens in the focused editor; unfocused text views end editing on every change.
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        return (workspace, document, controller, window)
    }

    // Tests keep the returned workspace and window alive until they finish. Dropped with `_`,
    // the window is freed at once (no first responder, no completion panel) and the workspace
    // soon after, silently detaching its language server: in the app, the window owns both.
    /// Generous: the first server start waits for the login-shell PATH, which can take seconds.
    func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws -> Bool {
        try await Self.eventually(timeout: timeout, condition)
    }

    static func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func incrementalSyncKeepsServerTextIdentical() async throws {
        let (workspace, document, _, window) = try makeWorkspace(text: "let a = 1\nlet b = 2\n")
        #expect(try await eventually { document.languageClient?.state == .ready })
        let client = try #require(document.languageClient)

        let pieces = ["x", "\n", "é", "😀", "ab\ncd", "", "  ", "日本"]
        for _ in 0..<150 {
            let length = document.textStorage.length
            let location = Int.random(in: 0...length)
            var removeLength = Int.random(in: 0...min(3, length - location))
            // Never split a surrogate pair (the text view wouldn't either).
            let text = document.textStorage.mutableString
            if removeLength > 0, CFStringIsSurrogateHighCharacter(text.character(at: location + removeLength - 1)) {
                removeLength += location + removeLength < length ? 1 : -1
            }
            if location > 0, location < length, CFStringIsSurrogateLowCharacter(text.character(at: location)) { continue }
            document.textStorage.replaceCharacters(in: NSRange(location: location, length: removeLength),
                                                   with: pieces.randomElement()!)
        }
        let serverText = try await client.request("omc/text", params: ["uri": document.url.absoluteString]) as? String
        #expect(serverText == document.textStorage.string)
        withExtendedLifetime((workspace, window)) {}
    }

    /// A full-sync server gets the whole text at most every so often, not per keystroke, but
    /// always before a request: it never answers about an older text.
    @Test func fullSyncSendsTheCurrentTextBeforeEachRequest() async throws {
        let (workspace, document, _, window) = try Self.makeWorkspace(text: "let a = 1\nlet b = 2\n", server: Self.fullSyncServer)
        #expect(try await eventually { document.languageClient?.state == .ready })
        let client = try #require(document.languageClient)
        #expect(!client.incrementalSync)
        client.fullSyncInterval = .seconds(3600) // only requests send it
        func changes() async throws -> [Int] {
            try #require(try await client.request("omc/stats", params: nil) as? [String: Any])["changes"] as? [Int] ?? []
        }
        func serverText() async throws -> String? {
            try await client.request("omc/text", params: ["uri": document.url.absoluteString]) as? String
        }

        let pieces = ["x", "\n", "é", "😀", "ab\ncd", "", "  ", "日本"]
        for round in 0..<3 {
            for _ in 0..<40 {
                let length = document.textStorage.length
                let location = Int.random(in: 0...length)
                let text = document.textStorage.mutableString
                if location > 0, location < length, CFStringIsSurrogateLowCharacter(text.character(at: location)) { continue }
                document.textStorage.replaceCharacters(in: NSRange(location: location, length: 0), with: pieces.randomElement()!)
            }
            // A feature's request (not just the test's own) goes after the text.
            _ = try await client.hover(url: document.url, position: LSPPosition(line: 0, character: 1))
            #expect(try await serverText() == document.textStorage.string)
            let sent = try await changes()
            #expect(sent.count == round + 1, "one change per burst of typing, not one per keystroke")
            #expect(sent == sent.sorted() && Set(sent).count == sent.count, "versions only go up")
        }

        // Without a request, it goes out after a pause: the diagnostic comes.
        client.fullSyncInterval = .milliseconds(50)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "BAD ")
        #expect(try await eventually { document.diagnostics.count == 1 })
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func diagnosticsAreShownAndCleared() async throws {
        let (workspace, document, controller, window) = try makeWorkspace(text: "let ok = 1\nlet BAD = 2\n")
        #expect(try await eventually { document.diagnostics.count == 1 })
        let diagnostic = try #require(document.diagnostics.first)
        #expect(document.range(for: diagnostic.range) == NSRange(location: 15, length: 3))
        #expect(workspace.problems.files().map(\.url.lastPathComponent) == [document.url.lastPathComponent])

        // A red squiggle is actually drawn under exactly that word (not just attributed).
        controller.textView.layoutSubtreeIfNeeded()
        let overlay = try #require(controller.diagnosticsOverlay)
        let segments = overlay.segments()
        #expect(segments.count == 1)
        let underline = try #require(segments.first?.rect)
        let bitmap = try #require(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
        overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
        var redBelowWord = 0, redElsewhere = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<min(bitmap.pixelsHigh, 80) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.3,
                      c.redComponent > 0.6, c.greenComponent < 0.5 else { continue }
                let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                if underline.insetBy(dx: -1, dy: -3).contains(point) { redBelowWord += 1 } else { redElsewhere += 1 }
            }
        }
        #expect(redBelowWord > 10, "no squiggle drawn under the diagnostic")
        #expect(redElsewhere == 0)

        document.textStorage.replaceCharacters(in: NSRange(location: 15, length: 3), with: "fine")
        #expect(try await eventually { document.diagnostics.isEmpty })
        #expect(workspace.problems.totalCount == 0)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func completionFiltersAndInsertsSnippet() async throws {
        let (workspace, document, controller, window) = try makeWorkspace(text: "let x = ")
        #expect(try await eventually { document.languageClient?.state == .ready })
        let textView = controller.textView!
        textView.setSelectedRange(NSRange(location: 8, length: 0))

        // In the app each key press is one event, and the undo manager groups per event. Tests have
        // no event loop between steps, so group explicitly, one group per simulated key press.
        let undo = document.undoManager
        undo.groupsByEvent = false
        func event(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }

        for character in "foo" { event { textView.insertText(String(character), replacementRange: textView.selectedRange()) } }
        #expect(try await eventually { controller.completion.isVisible })
        #expect(controller.completion.visibleItems.map(\.label) == ["fooBar", "fooBaz"])

        for character in "Bar" { event { textView.insertText(String(character), replacementRange: textView.selectedRange()) } }
        #expect(try await eventually { controller.completion.visibleItems.map(\.label) == ["fooBar"] })
        #expect(controller.completion.isVisible) // an exact match stays: its snippet adds arguments

        var handled = false
        event { handled = controller.completion.handle(#selector(NSResponder.insertNewline(_:))) }
        #expect(handled)
        #expect(document.textStorage.string == "let x = fooBar(count)")
        #expect(textView.selectedRange() == NSRange(location: 15, length: 5)) // placeholder selected
        #expect(!controller.completion.isVisible)

        undo.undo() // only the completion, not the typing before it
        #expect(document.textStorage.string == "let x = fooBar")
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func escapeDismissesAndTriggersManually() async throws {
        let (workspace, document, controller, window) = try makeWorkspace(text: "let x = f")
        #expect(try await eventually { document.languageClient?.state == .ready })
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        #expect(controller.textView.delegate?.textView?(controller.textView, doCommandBy: #selector(NSResponder.complete(_:))) == true)
        #expect(try await eventually { controller.completion.isVisible })
        #expect(controller.completion.handle(#selector(NSResponder.cancelOperation(_:))))
        #expect(!controller.completion.isVisible)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func goToDefinitionMovesTheCursor() async throws {
        let (workspace, document, controller, window) = try makeWorkspace(text: "let target = 1\nprint(target)\n")
        #expect(try await eventually { document.languageClient?.state == .ready })
        controller.textView.setSelectedRange(NSRange(location: 20, length: 0))
        workspace.goToDefinition()
        #expect(try await eventually { controller.textView.selectedRange() == NSRange(location: 4, length: 6) })
        withExtendedLifetime((workspace, window)) {}
    }

    /// A server that crashes comes back with the open files (as they are now); one that keeps
    /// crashing is left alone after a few tries.
    @Test func crashedServerRestartsWithTheOpenFiles() async throws {
        let (workspace, document, _, window) = try makeWorkspace(text: "let a = 1\n")
        workspace.languageServerRestartDelay = .milliseconds(10)
        #expect(try await eventually { document.languageClient?.state == .ready })
        var client = try #require(document.languageClient)
        for crash in 1...4 {
            let crashed = client
            Task { _ = try? await crashed.request("omc/crash", params: nil) }
            #expect(try await eventually { if case .failed = crashed.state { true } else { false } })
            // Typed while it's down: the new server gets this text, not the old one.
            document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// \(crash)\n")
            if crash == 4 {
                try await Task.sleep(for: .milliseconds(300))
                #expect(document.languageClient === crashed, "restarted more than 3 times")
                break
            }
            #expect(try await eventually { document.languageClient !== crashed && document.languageClient?.state == .ready })
            client = try #require(document.languageClient)
            #expect(workspace.languageClients["Fake LSP"] === client)
            let text = try await client.request("omc/text", params: ["uri": document.url.absoluteString]) as? String
            #expect(text == document.textStorage.string)
        }
        withExtendedLifetime((workspace, window)) {}
    }

    /// Requests sent while the server starts wait for it, and end with its error when it can't
    /// start; nothing is queued after that.
    @Test func requestsEndWhenInitializeFails() async throws {
        let server = Self.fakeServer
        let root = FileManager.default.temporaryDirectory
        let client = try LanguageClient(name: "Failing", command: server.command + ["--fail-initialize"], rootURL: root, environment: [:])
        // Sent while it starts: queued, then ended with initialize's error (it used to wait forever).
        let early = Task { () -> String in
            do { _ = try await client.request("omc/text", params: ["uri": "file:///x"]); return "answered" } catch { return error.localizedDescription }
        }
        #expect(client.state == .starting)
        #expect(await early.value == "fake can't start")
        #expect(try await eventually { if case .failed = client.state { true } else { false } })
        await #expect(throws: LanguageServerError.self) { _ = try await client.request("omc/text", params: nil) }
        client.shutdown()
        #expect(client.state == .stopped)
        await #expect(throws: LanguageServerError.self) { _ = try await client.request("omc/text", params: nil) }
    }

    /// Edits for another version of an open file than the one open are refused.
    @Test func editsForAnotherVersionAreStale() async throws {
        let (workspace, document, _, window) = try makeWorkspace(text: "let a = 1\n")
        #expect(try await eventually { document.languageClient?.state == .ready })
        let client = try #require(document.languageClient)
        func edit(_ version: Any) -> WorkspaceEdit? {
            WorkspaceEdit(json: ["documentChanges": [["textDocument": ["uri": document.url.absoluteString, "version": version],
                                                      "edits": [["range": ["start": ["line": 0, "character": 0],
                                                                           "end": ["line": 0, "character": 0]], "newText": "x"]]]]])
        }
        #expect(client.staleFile(in: try #require(edit(1))) == nil)
        #expect(client.staleFile(in: try #require(edit(NSNull()))) == nil)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// hi\n")
        #expect(client.staleFile(in: try #require(edit(1))) == document.url)
        #expect(client.staleFile(in: try #require(edit(2))) == nil)
        withExtendedLifetime((workspace, window)) {}
    }

    /// A completion's import comes along with it: given with the item, or when it's resolved.
    @Test func completionMakesItsAdditionalEdits() async throws {
        let (workspace, document, controller, window) = try makeWorkspace(text: "// WITH_IMPORTS\nlet x = ")
        #expect(try await eventually { document.languageClient?.state == .ready })
        let textView = controller.textView!
        let undo = document.undoManager
        undo.groupsByEvent = false
        func event(_ action: () -> Void) { undo.beginUndoGrouping(); action(); undo.endUndoGrouping() }
        func type(_ text: String) { for character in text { event { textView.insertText(String(character), replacementRange: textView.selectedRange()) } } }

        textView.setSelectedRange(NSRange(location: document.textStorage.length, length: 0))
        type("fooImp")
        #expect(try await eventually { controller.completion.visibleItems.map(\.label) == ["fooImported"] })
        event { _ = controller.completion.handle(#selector(NSResponder.insertNewline(_:))) }
        #expect(document.textStorage.string == "import Foo\n// WITH_IMPORTS\nlet x = fooImported")

        event { textView.insertText("\nlet y = ", replacementRange: textView.selectedRange()) }
        type("fooLa")
        #expect(try await eventually { controller.completion.visibleItems.map(\.label) == ["fooLazy"] })
        event { _ = controller.completion.handle(#selector(NSResponder.insertNewline(_:))) }
        #expect(try await eventually { document.textStorage.string.hasPrefix("import Lazy\nimport Foo\n") })
        #expect(document.textStorage.string.hasSuffix("let y = fooLazy"))
        withExtendedLifetime((workspace, window)) {}
    }

    /// A server's edit range is used whole (what's after the cursor too), its end moved by what
    /// was typed since the request.
    @Test func completionReplacesTheWholeEditRange() {
        // "foo|Tail": asked at 3, the server replaces 0..<7; two more letters typed since.
        #expect(CompletionController.replacementRange(NSRange(location: 0, length: 7), requestedAt: 3, cursor: 5, length: 9)
                == NSRange(location: 0, length: 9))
        // An insert-only range (ending at the request) still covers what was typed.
        #expect(CompletionController.replacementRange(NSRange(location: 0, length: 3), requestedAt: 3, cursor: 5, length: 9)
                == NSRange(location: 0, length: 5))
        // Never past the text.
        #expect(CompletionController.replacementRange(NSRange(location: 0, length: 40), requestedAt: 3, cursor: 5, length: 9)
                == NSRange(location: 0, length: 9))
    }

    /// Signature label offsets out of range (or backwards) are clamped, as is the active signature.
    @Test func parsesServerValuesSafely() throws {
        let help = try #require(SignatureHelp(json: ["activeSignature": -3, "signatures": [[
            "label": "f(a)", "parameters": [["label": [3, 1]], ["label": [2, 99]], ["label": [-5, 2]]],
        ]]]))
        #expect(help.activeSignature == 0)
        #expect(help.signatures[0].parameters.map(\.range) == [NSRange(location: 3, length: 0), NSRange(location: 2, length: 2),
                                                               NSRange(location: 0, length: 2)])
    }
}

private final class BundleToken {}

/// Against Xcode's real sourcekit-lsp with a SwiftPM package.
@MainActor
struct SourceKitLSPTests {
    @Test(.timeLimit(.minutes(2)))
    func reportsTypeErrorsAndCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-skl-\(UUID().uuidString)")
        let sources = root.appending(path: "Sources/Demo")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [.executableTarget(name: "Demo")])
        """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "let count: Int = \"not a number\"\nprint(count)\n"
            .write(to: sources.appending(path: "main.swift"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: sources.appending(path: "main.swift"))
        let document = try #require(workspace.activeDocument)

        let deadline = ContinuousClock.now + .seconds(90)
        while document.diagnostics.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        print("SKLSP state=\(String(describing: document.languageClient?.state)) diagnostics=\(document.diagnostics.map(\.message))")
        #expect(document.languageClient?.name == "SourceKit-LSP")
        #expect(document.diagnostics.contains { $0.severity == .error && $0.range.start.line == 0 })

        let client = try #require(document.languageClient)
        let completion = try await client.completion(url: document.url, position: LSPPosition(line: 1, character: 6),
                                                     triggerCharacter: nil)
        print("SKLSP completions=\(completion.items.count) e.g. \(completion.items.prefix(5).map(\.label))")
        #expect(completion.items.contains { $0.label.hasPrefix("count") })
    }

    /// The real server's fix-its as quick fixes, applied; parameter hints for a real call.
    @Test(.timeLimit(.minutes(3))) func fixItsAndParameterHints() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-skl3-\(UUID().uuidString)")
        let sources = root.appending(path: "Sources/Demo")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [.executableTarget(name: "Demo")])
        """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "func greet(name: String, times: Int) {\n    var count = times\n    print(name, count)\n}\ngreet(\n"
            .write(to: sources.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: sources.appending(path: "main.swift"))
        let document = try #require(workspace.activeDocument)
        let deadline = ContinuousClock.now + .seconds(90)
        while !document.diagnostics.contains(where: { $0.message.contains("never mutated") }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        let client = try #require(document.languageClient)
        #expect(client.supports(.codeAction) && client.supports(.signatureHelp))
        let actions = await workspace.codeActions(for: document, range: NSRange(location: 44, length: 0)) // on "var"
        print("SKLSP actions=\(actions.map { "\($0.kind): \($0.title)" })")
        let fix = try #require(actions.first { $0.isQuickFix && $0.title.contains("let") })
        await workspace.run(fix, in: document)
        #expect(document.textStorage.string.contains("    let count = times"))

        // Inside greet( at the end: the signature, its first parameter current.
        let help = try await client.signatureHelp(url: document.url, position: LSPPosition(line: 4, character: 6), trigger: "(", isRetrigger: false)
        print("SKLSP signature=\(help?.signatures.first?.label ?? "none")")
        #expect(help?.signatures.first?.label.contains("name: String") == true)
        #expect(help?.highlighted.map { (help!.signatures[help!.activeSignature].label as NSString).substring(with: $0) }?.contains("name") == true)

        // Types the server infers, shown inside the code.
        #expect(client.supports(.inlayHint))
        document.refreshInlayHints()
        await document.waitForInlayHints()
        print("SKLSP hints=\(document.shownInlayHints)")
        #expect(document.shownInlayHints.contains { $0.text.contains("Int") })
        withExtendedLifetime(workspace) {}
    }

    @Test(.timeLimit(.minutes(3))) func hoverReferencesRenameAndFormat() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-skl2-\(UUID().uuidString)")
        let sources = root.appending(path: "Sources/Demo")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [.executableTarget(name: "Demo")])
        """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "/// Number of apples.\nlet count: Int = 3\nprint(count)\nfunc   f( ) {print(count) }\n"
            .write(to: sources.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        try "func other() { print(count) }\n".write(to: sources.appending(path: "other.swift"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: sources.appending(path: "main.swift"))
        let document = try #require(workspace.activeDocument)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.editor = controller
        document.undoManager.groupsByEvent = false
        let deadline = ContinuousClock.now + .seconds(60)
        while document.languageClient?.state != .ready && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let client = try #require(document.languageClient)
        #expect(client.supports(.hover) && client.supports(.references) && client.supports(.rename) && client.supports(.formatting))
        let hover = try await client.hover(url: document.url, position: LSPPosition(line: 2, character: 7))
        #expect(hover?.contains("let count: Int") == true)
        #expect(hover?.contains("Number of apples.") == true)
        controller.textView.setSelectedRange(NSRange(location: 47, length: 0)) // "count" in print(count)
        for _ in 0..<30 { // cross-file results need the background index
            await workspace.findReferences()?.value
            await workspace.findReferences()?.value
            if (workspace.references?.count ?? 0) >= 4 { break }
            try await Task.sleep(for: .seconds(1))
        }
        #expect(workspace.references?.results.map(\.path) == ["Sources/Demo/main.swift", "Sources/Demo/other.swift"])
        #expect(workspace.references?.count == 4)

        workspace.renamePrompt = { _ in "total" }
        await workspace.renameSymbol()?.value
        #expect(workspace.pendingEdit?.files.count == 2)
        workspace.applyPendingEdit()
        #expect(document.textStorage.string == "/// Number of apples.\nlet total: Int = 3\nprint(total)\nfunc   f( ) {print(total) }\n")
        #expect(workspace.document(matching: sources.appending(path: "other.swift"))?.textStorage.string
                == "func other() { print(total) }\n")

        await workspace.formatDocument()?.value
        #expect(document.textStorage.string == "/// Number of apples.\nlet total: Int = 3\nprint(total)\nfunc f() { print(total) }\n")
        #expect(workspace.errorMessage == nil)
        withExtendedLifetime((workspace, window)) {}
    }
}
