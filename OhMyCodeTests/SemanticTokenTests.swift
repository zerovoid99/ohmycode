import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct SemanticTokenTests {
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func tokens(_ document: EditorDocument) -> [String] {
        let text = document.textStorage.mutableString
        return document.semanticTokens.map { "\(text.substring(with: $0.range)):\($0.type)" }
    }

    @Test func decodesRelativeNumbers() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-sem-\(UUID().uuidString).swift")
        try "let a = Foo()\n  bar(a)\n".write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        // "a" (variable) at 0:4, "Foo" (type) at 0:8, "bar" (function) at 1:2; an unknown type is skipped.
        let decoded = SemanticTokens.decode([0, 4, 1, 2, 0, 0, 4, 3, 0, 0, 1, 2, 3, 1, 0, 0, 5, 1, 9, 0],
                                            legend: ["type", "function", "variable"], in: document)
        #expect(decoded == [SemanticToken(range: NSRange(location: 4, length: 1), type: "variable"),
                            SemanticToken(range: NSRange(location: 8, length: 3), type: "type"),
                            SemanticToken(range: NSRange(location: 16, length: 3), type: "function")])
        #expect(SemanticTokens.capture(for: "struct") == "type" && SemanticTokens.capture(for: "keyword") == nil
                && SemanticTokens.capture(for: "parameter") == "")
    }

    @Test func editsMoveTokensUntilTheServerAnswers() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-sem-\(UUID().uuidString).swift")
        try "aa Bb cc Dd\n".write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        document.semanticTokens = [SemanticToken(range: NSRange(location: 3, length: 2), type: "type"),
                                   SemanticToken(range: NSRange(location: 9, length: 2), type: "type")]
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "xx")
        #expect(tokens(document) == ["Bb:type", "Dd:type"])
        // An edit inside a token drops it; the ones after move.
        document.textStorage.replaceCharacters(in: NSRange(location: 6, length: 0), with: "z")
        #expect(tokens(document) == ["Dd:type"])
        #expect(document.semanticTokens(in: NSRange(location: 0, length: 5)).isEmpty)
        #expect(document.semanticTokens(in: NSRange(location: 10, length: 3)).count == 1)
    }

    @Test func theServersTokensColorNames() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "let total = Counter()\nrun(total)\n")
        #expect(try await eventually { tokens(document) == ["total:variable", "Counter:type", "run:function"] })
        // The type is drawn in the theme's type color, over the syntax tree's.
        let typeColor = try #require(EditorTheme.color(forCapture: "type"))
        let counter = (document.textStorage.string as NSString).range(of: "Counter").location
        #expect(try await eventually { controller.renderedColor(at: counter) == typeColor })
        let run = (document.textStorage.string as NSString).range(of: "run").location
        #expect(try await eventually { controller.renderedColor(at: run) == EditorTheme.color(forCapture: "function") })

        // Typing: the server's new answer covers the new text.
        controller.textView.setSelectedRange(NSRange(location: document.textStorage.length, length: 0))
        controller.textView.insertText("let Other = 1\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(try await eventually { tokens(document).contains("Other:type") })

        AppSettings.shared.semanticHighlighting = false
        defer { AppSettings.shared.semanticHighlighting = true }
        #expect(try await eventually { document.semanticTokens.isEmpty })
        withExtendedLifetime((workspace, window)) {}
    }

    /// Against Xcode's real sourcekit-lsp.
    @Test(.timeLimit(.minutes(2)))
    func sourceKitClassifiesNames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-sem-skl-\(UUID().uuidString)")
        let sources = root.appending(path: "Sources/Demo")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [.executableTarget(name: "Demo")])
        """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "struct Point { var x = 0 }\nlet p = Point()\nprint(p.x)\n"
            .write(to: sources.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: sources.appending(path: "main.swift"))
        let document = try #require(workspace.activeDocument)
        let found = try await eventually(.seconds(90)) {
            tokens(document).contains { $0.hasPrefix("Point:") } && tokens(document).contains { $0.hasPrefix("x:") }
        }
        print("SEMANTIC \(tokens(document))")
        #expect(found)
        let point = document.semanticTokens.first { (document.textStorage.string as NSString).substring(with: $0.range) == "Point" }
        #expect(point.map { SemanticTokens.capture(for: $0.type) } == "type")
        withExtendedLifetime(workspace) {}
    }
}
