import AppKit
import SwiftTreeSitter
import Testing
@testable import Oh_My_Code

/// Long files are parsed a window at a time; within it, colors match a parse of the whole file.
@MainActor
@Suite(.serialized)
struct WindowedHighlightingTests {
    final class Client: SyntaxHighlighterClient {
        var highlightRange: NSRange?
        init(_ range: NSRange) { highlightRange = range }
        func applyHighlights(_ highlights: [NamedRange], in range: NSRange) {}
    }

    private func makeDocument(_ text: String) throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try EditorDocument(url: url)
    }

    /// Highlights from parsing all of `text`.
    private func fullParse(_ text: NSString, in range: NSRange) async throws -> [NamedRange] {
        let grammar = try #require(GrammarRegistry.grammar(for: .swift))
        let engine = try #require(SyntaxEngine(grammar: grammar))
        return try #require(await engine.process(snapshot: TextSnapshot(string: text.copy() as! NSString), edits: [], highlightRange: range))
    }

    private func lineRange(_ document: EditorDocument, from line: Int, count: Int) -> NSRange {
        let starts = document.lineIndex.lineStarts
        return NSRange(location: starts[line], length: starts[line + count] - starts[line])
    }

    @Test func smallFilesParseWhole() throws {
        let document = try makeDocument("let a = 1\n")
        #expect(document.highlighter?.isWindowed == false)
    }

    @Test func windowMatchesWholeParse() async throws {
        let document = try makeDocument(PerformanceBenchmarks.code(bytes: 1_500_000))
        let highlighter = try #require(document.highlighter)
        #expect(highlighter.isWindowed)
        let lines = document.lineIndex.lineCount
        let client = Client(lineRange(document, from: lines / 2, count: 120))
        highlighter.addClient(client)
        await highlighter.waitUntilIdle()

        let window = try #require(highlighter.window)
        let range = try #require(client.highlightRange)
        #expect(NSIntersectionRange(window, range) == range)
        #expect(window.length < 2 * SyntaxHighlighter.windowMargin + range.length + 2 * SyntaxHighlighter.boundarySearchLimit)
        let windowed = await highlighter.highlights(in: range)
        #expect(!windowed.isEmpty)
        #expect(windowed == (try await fullParse(document.textStorage.mutableString, in: range)))

        // Typing inside the window reparses it incrementally.
        let at = document.lineIndex.lineStarts[lines / 2 + 10]
        document.textStorage.replaceCharacters(in: NSRange(location: at, length: 0), with: "let added = \"text\" // note\n")
        await highlighter.waitUntilIdle()
        #expect(highlighter.window?.length == window.length + 27)
        #expect(await highlighter.highlights(in: range) == (try await fullParse(document.textStorage.mutableString, in: range)))

        // Typing before it moves it along.
        document.textStorage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "x")
        await highlighter.waitUntilIdle()
        #expect(highlighter.window?.location == window.location + 1)

        // Scrolling far away parses a new window there.
        client.highlightRange = lineRange(document, from: lines - 200, count: 120)
        highlighter.requestHighlights(for: client)
        await highlighter.waitUntilIdle()
        let far = try #require(client.highlightRange)
        #expect(NSIntersectionRange(try #require(highlighter.window), far) == far)
        #expect(await highlighter.highlights(in: far) == (try await fullParse(document.textStorage.mutableString, in: far)))

        // Sticky scroll works in the window; the outline and folds don't come from a part of the file.
        let line = lines - 150
        let scopes = await highlighter.enclosingScopeLines(line: line, lineStart: document.lineIndex.lineStarts[line])
        #expect(!scopes.isEmpty)
        #expect(await highlighter.outline(for: .swift).isEmpty)
        #expect(await highlighter.foldRegions().isEmpty)
        withExtendedLifetime(client) {}
    }

    /// An edit across the window's edge starts a new window.
    @Test func editAcrossTheEdge() async throws {
        let document = try makeDocument(PerformanceBenchmarks.code(bytes: 1_200_000))
        let highlighter = try #require(document.highlighter)
        let lines = document.lineIndex.lineCount
        let client = Client(lineRange(document, from: lines / 2, count: 100))
        highlighter.addClient(client)
        await highlighter.waitUntilIdle()
        let window = try #require(highlighter.window)
        document.textStorage.replaceCharacters(in: NSRange(location: window.location - 5, length: 10), with: "")
        client.highlightRange = lineRange(document, from: lines / 2, count: 100)
        await highlighter.waitUntilIdle()
        let range = try #require(client.highlightRange)
        #expect(NSIntersectionRange(try #require(highlighter.window), range) == range)
        #expect(await highlighter.highlights(in: range) == (try await fullParse(document.textStorage.mutableString, in: range)))
        withExtendedLifetime(client) {}
    }

    @Test func boundariesPreferTopLevelLines() {
        let text = "struct A {\n    let a = 1\n    let b = 2\n}\nstruct B {}\n" as NSString
        let inside = text.range(of: "let b").location
        #expect(SyntaxHighlighter.boundary(in: text, near: inside, backward: true) == 0)
        #expect(SyntaxHighlighter.boundary(in: text, near: inside, backward: false) == text.range(of: "struct B").location)
        #expect(SyntaxHighlighter.boundary(in: text, near: 0, backward: true) == 0)
        #expect(SyntaxHighlighter.boundary(in: text, near: text.length, backward: false) == text.length)
    }
}
