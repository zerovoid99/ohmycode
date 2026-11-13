import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

/// Every character of `characters` is inside a span whose capture starts with `capture`.
func covered(_ spans: [LineSpan], _ characters: Range<Int>, by capture: String) -> Bool {
    characters.allSatisfy { index in
        spans.contains { $0.capture.hasPrefix(capture) && NSLocationInRange(index, $0.range) }
    }
}

struct WordDiffTests {
    private func strings(_ ranges: [NSRange], _ text: String) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    @Test func marksOnlyTheChangedWords() {
        let old = "let total = price * 10", new = "let total = cost * 120 // tax"
        let changes = WordDiff.changes(old: old, new: new)
        #expect(strings(changes.old, old) == ["price", "10"])
        #expect(strings(changes.new, new) == ["cost", "120 // tax"]) // touching tokens merge
    }

    @Test func wholeRewritesAndOddCharactersAreSafe() {
        #expect(WordDiff.changes(old: "foo()", new: "bar()").old == [NSRange(location: 0, length: 3)]) // shares "(" and ")"
        #expect(WordDiff.changes(old: "alpha", new: "omega") == ([], []))          // no word in common: line tint only
        #expect(WordDiff.changes(old: "  ", new: "    ") == ([], []))              // whitespace alone isn't shared
        // Surrogate pairs stay inside one token, so ranges never split a character.
        let new = "x = \"a😀b\""
        let changes = WordDiff.changes(old: "x = \"ab\"", new: new)
        #expect(strings(changes.new, new) == ["a😀b"])
    }
}

@MainActor
struct DiffSyntaxTests {
    @Test func splitsHighlightsIntoLines() {
        let text = "a /* one\ntwo */ b\nc" as NSString
        let comment = text.range(of: "/* one\ntwo */")
        let lines = DiffSyntax.spansByLine([(comment, "comment"), (NSRange(location: 18, length: 1), "variable")], in: text)
        #expect(lines.count == 3)
        #expect(lines[0] == [LineSpan(range: NSRange(location: 2, length: 6), capture: "comment")])
        #expect(lines[1] == [LineSpan(range: NSRange(location: 0, length: 6), capture: "comment")])
        #expect(lines[2] == [LineSpan(range: NSRange(location: 0, length: 1), capture: "variable")])
    }

    @Test func highlightsSwiftPerLine() async throws {
        let spans = try #require(await DiffSyntax.highlight("let a = 1\nlet s = \"hi\"\n", language: .swift))
        #expect(spans.count == 3)
        #expect(spans[0].contains { $0.range == NSRange(location: 0, length: 3) && $0.capture.hasPrefix("keyword") })
        #expect(covered(spans[1], 8..<12, by: "string")) // the grammar captures quotes and content separately
        #expect(await DiffSyntax.highlight("plain", language: .plaintext) == nil)
    }

    @Test func stylesSyntaxAndChangedWords() throws {
        let line = "let total = 120"
        let keyword = try #require(EditorTheme.color(forCapture: "keyword"))
        let text = DiffLineStyle.attributed(line, spans: [LineSpan(range: NSRange(location: 0, length: 3), capture: "keyword")],
                                            words: [NSRange(location: 12, length: 3)], wordTint: .green)
        let runs = text.runs.map { (String(text[$0.range].characters), $0.foregroundColor, $0.backgroundColor) }
        #expect(runs.first?.0 == "let" && runs.first?.1 == Color(nsColor: keyword))
        #expect(runs.last?.0 == "120" && runs.last?.2 == .green)
        #expect(runs.filter { $0.2 != nil }.count == 1)
        // Spans that no longer fit the line (stale colors while typing) are skipped, not crashed on.
        _ = DiffLineStyle.attributed("ab", spans: [LineSpan(range: NSRange(location: 1, length: 5), capture: "keyword")],
                                     words: [NSRange(location: 3, length: 1)], wordTint: .red)
    }
}

@MainActor
struct DiffSessionHighlightTests {
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=A", "-c", "user.email=a@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func colorsBothSidesAndFollowsEditsInsideAChangedLine() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-diffhl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        try "let a = 1\nlet b = 2\n".write(to: root.appending(path: "f.swift"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "i"], in: root)
        try "let a = 1\nlet b = 3\n".write(to: root.appending(path: "f.swift"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitRepository != nil })
        let url = root.appending(path: "f.swift")

        // Staged: HEAD and index are both colored.
        let staged = try #require(workspace.openChanges(for: url, staged: true))
        #expect(try await eventually { staged.hunks.count == 1 })
        await staged.refreshHighlights()
        #expect(staged.baseSpans?[1].contains { $0.range.location == 0 && $0.capture.hasPrefix("keyword") } == true)
        #expect(staged.currentSpans?.count == 3)

        // Working tree: typing inside an already changed line keeps the same hunks, but the
        // text and colors still follow.
        workspace.open(fileAt: url)
        let document = try #require(workspace.activeDocument)
        let session = try #require(workspace.openChanges(for: url))
        #expect(try await eventually { document.diffBaseLines != nil })
        document.textStorage.replaceCharacters(in: NSRange(location: 18, length: 1), with: "\"x\"")
        await document.waitForDiff()
        let hunks = document.diffHunks
        let version = session.currentVersion
        #expect(session.currentLines[1] == "let b = \"x\"")
        document.textStorage.replaceCharacters(in: NSRange(location: 19, length: 1), with: "xyz")
        await document.waitForDiff()
        #expect(document.diffHunks == hunks)
        #expect(session.currentVersion > version)
        #expect(session.currentLines[1] == "let b = \"xyz\"")
        await session.refreshHighlights()
        #expect(covered(session.currentSpans?[1] ?? [], 8..<13, by: "string"))
        withExtendedLifetime(workspace) {}
    }
}
