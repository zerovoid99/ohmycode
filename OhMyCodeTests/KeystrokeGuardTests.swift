import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

/// Guards against per-keystroke work growing with what's in the file besides its text: blame,
/// diagnostics, semantic tokens, folds, cursors, and the text elements TextKit keeps of every
/// place the viewport has been. Each of these made a keystroke (or the redraw after it) take
/// tens to hundreds of milliseconds. Limits are generous: the old behavior was far over them.
@MainActor
@Suite(.serialized)
struct KeystrokeGuardTests {
    private let clock = ContinuousClock()

    private func open(bytes: Int) throws -> (EditorDocument, EditorController, NSWindow, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-keys-\(UUID().uuidString).swift")
        try PerformanceBenchmarks.code(bytes: bytes).write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        document.attach(controller)
        return (document, controller, window, url)
    }

    /// Median time of typing `count` characters at the cursor (each laid out).
    private func typing(_ controller: EditorController, count: Int = 15) -> Duration {
        var samples: [Duration] = []
        for _ in 0..<count {
            samples.append(clock.measure {
                controller.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
                controller.textView.layoutSubtreeIfNeeded()
            })
        }
        return samples.sorted()[samples.count / 2]
    }

    // MARK: Blame

    @Test func blameShiftsInPlace() {
        func line(_ name: String) -> BlameLine? { BlameLine(commit: String(repeating: "a", count: 40), author: name, date: Date(timeIntervalSince1970: 1), summary: "") }
        let blame = [line("0"), line("1"), nil, line("3")]
        func authors(_ lines: [BlameLine?]) -> [String?] { lines.map { $0.map { $0.isUncommitted ? "-" : $0.author } } }
        // Typing in a line; a line added; lines removed; a line added at the end.
        #expect(authors(BlameLine.shifted(blame, replacing: 1..<2, with: 1)) == ["0", "-", nil, "3"])
        #expect(authors(BlameLine.shifted(blame, replacing: 1..<2, with: 2)) == ["0", "-", "-", nil, "3"])
        #expect(authors(BlameLine.shifted(blame, replacing: 1..<3, with: 1)) == ["0", "-", "3"])
        #expect(authors(BlameLine.shifted(blame, replacing: 1..<3, with: 0)) == ["0", "3"])
        #expect(authors(BlameLine.shifted(blame, replacing: 4..<4, with: 1)) == ["0", "1", nil, "3", "-"])
        #expect(authors(BlameLine.shifted(blame, replacing: 3..<9, with: 1)) == ["0", "1", nil, "-"])
        #expect(authors(BlameLine.shifted(blame, replacing: 7..<8, with: 1)) == ["0", "1", nil, "3"])
        #expect(BlameLine.uncommitted().isUncommitted && line("x")?.isUncommitted == false)
    }

    /// Every keystroke used to copy the whole blame and read every line's date again: 55 ms in
    /// 40,000 lines, 270 ms in 200,000.
    @Test func typingWithBlameDoesntReadEveryLine() async throws {
        let (document, controller, window, url) = try open(bytes: 3_000_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = document.lineIndex.lineCount
        var entries: [BlameLine?] = (0..<lines).map { index in
            BlameLine(commit: String(format: "%040x", index % 300 + 1), author: "Author \(index % 20)",
                      date: Date(timeIntervalSince1970: 1_600_000_000 + Double(index % 300) * 86_400), summary: "Commit \(index % 300)")
        }
        document.blameProvider = { [entries] _ in entries }
        entries = []
        document.scheduleBlame(after: .zero)
        await document.waitForBlame()
        document.blameProvider = nil // not asked again while this types
        let dates = try #require(document.blameDates)
        #expect(dates.lowerBound == Date(timeIntervalSince1970: 1_600_000_000) && document.blame?.count == lines)

        let middle = document.lineIndex.lineStarts[lines / 2] + 4
        controller.textView.setSelectedRange(NSRange(location: middle, length: 0))
        let median = typing(controller)
        #expect(median < .milliseconds(25), "median keystroke with blame took \(median)")
        #expect(document.blame?.count == lines && document.blame?[lines / 2]?.isUncommitted == true)
        #expect(document.blame?[lines / 2 + 1]?.isUncommitted == false && document.blameDates == dates)
        controller.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(document.blame?.count == lines + 1 && document.blame?[lines / 2 + 1]?.isUncommitted == true)
        withExtendedLifetime(window) {}
    }

    // MARK: Semantic tokens

    /// Edits move the tokens after them in place: the same result as going through them all.
    @Test func semanticTokensShiftLikeBefore() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-keys-\(UUID().uuidString).swift")
        try String(repeating: "abcdefghij\n", count: 40).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try EditorDocument(url: url)
        func reference(_ tokens: [SemanticToken], _ oldRange: NSRange, _ newLength: Int) -> [SemanticToken] {
            let delta = newLength - oldRange.length, end = NSMaxRange(oldRange)
            return tokens.compactMap { token in
                if NSMaxRange(token.range) <= oldRange.location { return token }
                if token.range.location >= end, oldRange.length > 0 || token.range.location > oldRange.location {
                    var moved = token
                    moved.range.location += delta
                    return moved
                }
                return nil
            }
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            // Sorted, apart or touching, like a server's.
            var tokens: [SemanticToken] = []
            var location = Int.random(in: 0...3, using: &generator)
            while location < 300 {
                let length = Int.random(in: 1...6, using: &generator)
                tokens.append(SemanticToken(range: NSRange(location: location, length: length), type: ["type", "function", "variable"].randomElement()!))
                location += length + Int.random(in: 0...4, using: &generator)
            }
            let oldRange = NSRange(location: Int.random(in: 0...310, using: &generator), length: Int.random(in: 0...12, using: &generator))
            let newLength = Int.random(in: 0...12, using: &generator)
            document.semanticTokens = tokens
            document.shiftSemanticTokens(oldRange: oldRange, newLength: newLength)
            #expect(document.semanticTokens == reference(tokens, oldRange, newLength), "replacing \(oldRange) with \(newLength)")
        }
    }

    // MARK: Many edits at once

    /// Typing at many cursors (or Replace All) made one storage edit per place, and TextKit
    /// moves its text elements after every one: 25 s for 1,000 places in a 1 MB file.
    @Test func manyEditsAreOneStorageEdit() async throws {
        let (document, controller, window, url) = try open(bytes: 900_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = document.textStorage.string
        let index = document.lineIndex
        let step = (index.lineCount - 2) / 600
        let cursors = (0..<600).map { NSRange(location: index.lineStarts[$0 * step] + 2, length: 0) }
        controller.setSelections(main: cursors[0], extras: Array(cursors.dropFirst()))
        var expected = NSMutableString(string: original)
        for cursor in cursors.reversed() { expected.insert("x\ny", at: cursor.location) }

        let typed = clock.measure {
            controller.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.textView.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(typed < .seconds(2), "typing three times at 600 cursors took \(typed)")
        #expect(document.textStorage.string == expected as String)
        // The document saw each edit: its line index is the text's.
        #expect(document.lineIndex == LineIndex(string: document.textStorage.mutableString))
        #expect(controller.extraSelections.count == 599)

        let undone = clock.measure { for _ in 0..<3 { document.undoManager.undo() } }
        #expect(undone < .seconds(2), "undoing them took \(undone)")
        #expect(document.textStorage.string == original)
        #expect(document.lineIndex == LineIndex(string: document.textStorage.mutableString))
        expected = ""
        withExtendedLifetime(window) {}
    }
}
