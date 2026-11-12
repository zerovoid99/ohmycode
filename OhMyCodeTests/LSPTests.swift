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

    private func makeWorkspace(text: String) throws -> (Workspace, EditorDocument, EditorController, NSWindow) {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-lsp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.languageServerOverrides[.swift] = Self.fakeServer
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
    private func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws -> Bool {
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

    @Test func diagnosticsAreShownAndCleared() async throws {
        let (workspace, document, controller, window) = try makeWorkspace(text: "let ok = 1\nlet BAD = 2\n")
        #expect(try await eventually { document.diagnostics.count == 1 })
        let diagnostic = try #require(document.diagnostics.first)
        #expect(document.range(for: diagnostic.range) == NSRange(location: 15, length: 3))

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
}
