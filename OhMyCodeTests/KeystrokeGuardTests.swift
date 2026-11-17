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

    // MARK: Diagnostics

    /// The overlay asked TextKit where every diagnostic in the file is, on every redraw: 30 ms
    /// with 1,000 of them, and each one laid out a line somewhere.
    @Test func onlyDiagnosticsInViewAreMeasured() throws {
        let (document, controller, window, url) = try open(bytes: 900_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = document.lineIndex.lineCount
        document.setDiagnostics((0..<lines / 4).map { index in
            Diagnostic(range: LSPRange(start: LSPPosition(line: index * 4, character: 0), end: LSPPosition(line: index * 4, character: 3)),
                       severity: .warning, message: "warning \(index)", source: "test")
        } + [Diagnostic(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: lines - 1, character: 0)),
                        severity: .hint, message: "the whole file", source: "test")])
        controller.reveal(NSRange(location: document.lineIndex.lineStarts[lines / 2], length: 0))
        controller.textView.layoutSubtreeIfNeeded()
        let overlay = try #require(controller.diagnosticsOverlay)
        let visible = controller.textView.visibleRect
        let segments = overlay.segments()
        // The ones on the lines in view (one every four lines), and the long one's lines there.
        let warnings = segments.filter { $0.color == DiagnosticsOverlayView.color(for: .warning) }
        let visibleLines = Int(visible.height / controller.lineHeight)
        #expect(warnings.count >= visibleLines / 4 - 1 && warnings.count <= visibleLines / 4 + 26, "\(warnings.count) of \(visibleLines) lines")
        #expect(segments.contains { $0.color == DiagnosticsOverlayView.color(for: .hint) })
        #expect(segments.allSatisfy { $0.rect.intersects(visible.insetBy(dx: 0, dy: -50)) })
        let draws = clock.measure { for _ in 0..<10 { overlay.display() } }
        #expect(draws < .milliseconds(400), "10 redraws with \(lines / 4) diagnostics took \(draws)")
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

        let redraw = clock.measure { for _ in 0..<5 { controller.diagnosticsOverlay?.display() } }
        #expect(redraw < .milliseconds(500), "5 redraws with 600 cursors took \(redraw)")
        let undone = clock.measure { for _ in 0..<3 { document.undoManager.undo() } }
        #expect(undone < .seconds(2), "undoing them took \(undone)")
        #expect(document.textStorage.string == original)
        #expect(document.lineIndex == LineIndex(string: document.textStorage.mutableString))
        expected = ""
        withExtendedLifetime(window) {}
    }

    // MARK: Folds

    @Test func hiddenRangesAreTheFoldsJoined() {
        let folds = [NSRange(location: 10, length: 50), NSRange(location: 20, length: 10), NSRange(location: 35, length: 30),
                     NSRange(location: 80, length: 5), NSRange(location: 85, length: 5), NSRange(location: 100, length: 1)]
        let merged = FoldRanges.merged(folds)
        #expect(merged == [NSRange(location: 10, length: 55), NSRange(location: 80, length: 10), NSRange(location: 100, length: 1)])
        for offset in 0..<110 {
            #expect(FoldRanges.contains(merged, offset) == folds.contains { NSLocationInRange(offset, $0) }, "\(offset)")
        }
        #expect(!FoldRanges.contains([], 3))
        #expect(FoldRanges.firstIndex(in: folds, startingAtOrAfter: 0) == 0 && FoldRanges.firstIndex(in: folds, startingAtOrAfter: 21) == 2
                && FoldRanges.firstIndex(in: folds, startingAtOrAfter: 85) == 4 && FoldRanges.firstIndex(in: folds, startingAtOrAfter: 101) == 6)
    }

    /// Each redraw asked TextKit where every fold in the file is (laying a line out at each),
    /// and every paragraph laid out was looked for in every fold: with everything folded in a
    /// 0.9 MB file a redraw took 4.6 s.
    @Test func manyFoldsStayCheapToDraw() async throws {
        let (document, controller, window, url) = try open(bytes: 900_000)
        defer { try? FileManager.default.removeItem(at: url) }
        await document.highlighter?.waitUntilIdle()
        await document.waitForFoldRegions()
        document.foldAll()
        controller.textView.layoutSubtreeIfNeeded()
        #expect(document.folds.count > 5_000)
        // What's hidden is what the folds say.
        for line in stride(from: 0, to: document.lineIndex.lineCount, by: 97) {
            let offset = document.lineIndex.lineStarts[line]
            #expect(document.isHidden(offset) == document.folds.contains { NSLocationInRange(offset, $0) }, "line \(line)")
        }
        let placeholders = controller.foldPlaceholderRects()
        #expect(!placeholders.isEmpty && placeholders.count < 200)
        #expect(placeholders.allSatisfy { $0.rect.intersects(controller.textView.visibleRect) && document.isFolded(line: $0.header) })
        let redraw = clock.measure { for _ in 0..<5 { controller.diagnosticsOverlay?.display() } }
        #expect(redraw < .seconds(2), "5 redraws with \(document.folds.count) folds took \(redraw)")
        withExtendedLifetime(window) {}
    }

    // MARK: Outline

    /// The outline was made again on every cursor move, and with a `ForEach` per symbol's
    /// children SwiftUI took 0.8 s to find what changed among 1,200 symbols whenever one row
    /// did: on each move to another symbol, and after each edit (the symbols' ranges move).
    @Test func theOutlineFollowsTheCursorCheaply() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(text: PerformanceBenchmarks.code(bytes: 100_000))
        document.attach(controller)
        await document.highlighter?.waitUntilIdle()
        document.refreshSymbols()
        #expect(try await LanguageClientTests.eventually { document.symbols.count > 200 })
        let lines = document.lineIndex.lineCount

        // The cursor's symbol is kept as it moves: a struct's method, then the struct after it.
        controller.textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[15 * 4 + 7] + 8, length: 0))
        let first = try #require(document.symbolIDAtCursor)
        #expect(first == document.symbolPathAtCursor.last?.id && document.symbolPathAtCursor.count == 2)
        controller.textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[15 * 4 + 7] + 12, length: 0))
        #expect(document.symbolIDAtCursor == first)
        controller.textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[15 * 5 + 1] + 3, length: 0))
        #expect(document.symbolIDAtCursor != first && document.symbolIDAtCursor == document.symbolPathAtCursor.last?.id)

        let outline = NSHostingView(rootView: OutlineView(workspace: workspace))
        let outlineWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        outlineWindow.contentView = outline
        outlineWindow.layoutIfNeeded()
        let moves = clock.measure {
            for index in 0..<10 {
                controller.textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[lines / 2 + index * 3] + 2, length: 0))
                outline.layoutSubtreeIfNeeded()
            }
        }
        #expect(moves < .seconds(1), "10 moves to other symbols took \(moves) with the outline shown")
        controller.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        document.refreshSymbols()
        await document.waitForSymbols()
        let refresh = clock.measure { outline.layoutSubtreeIfNeeded() }
        #expect(refresh < .milliseconds(400), "the outline took \(refresh) to show an edit's symbols")
        withExtendedLifetime(window) {}
        withExtendedLifetime(outlineWindow) {}
        withExtendedLifetime(workspace) {}
    }

    // MARK: Text elements

    /// TextKit keeps the text element of every line a viewport has laid out and moves the ones
    /// after an edit on every edit: after the viewport had been to 400 places, a keystroke at
    /// the top took 77 ms. The ones away from the viewport are dropped once scrolling stops.
    @Test func textElementsLeftBehindAreDropped() async throws {
        let (document, controller, window, url) = try open(bytes: 3_000_000)
        defer { try? FileManager.default.removeItem(at: url) }
        // Not while this measures the difference it makes.
        let delay = EditorController.textElementTrimDelay
        EditorController.textElementTrimDelay = .seconds(3600)
        defer { EditorController.textElementTrimDelay = delay }
        let view = controller.textView!
        let lines = document.lineIndex.lineCount
        for place in 0..<300 {
            controller.reveal(NSRange(location: document.lineIndex.lineStarts[place * (lines - 1) / 300], length: 0))
            view.layoutSubtreeIfNeeded()
        }
        controller.reveal(NSRange(location: 4, length: 0))
        view.layoutSubtreeIfNeeded()
        let before = typing(controller)
        document.trimTextElements()
        let after = typing(controller)
        #expect(after * 2 < before, "a keystroke took \(before) before dropping the text elements, \(after) after")

        // In the middle, colored: dropping them moves nothing, and what's in view keeps its colors.
        for place in 0..<20 {
            controller.reveal(NSRange(location: document.lineIndex.lineStarts[place * (lines - 1) / 20], length: 0))
            view.layoutSubtreeIfNeeded()
        }
        controller.reveal(NSRange(location: document.lineIndex.lineStarts[lines / 2], length: 0))
        view.layoutSubtreeIfNeeded()
        var keyword = NSNotFound
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            view.layoutSubtreeIfNeeded()
            if let visible = controller.visibleCharacterRange() {
                keyword = document.textStorage.mutableString.range(of: "struct", options: [], range: visible).location
                if keyword != NSNotFound, let color = controller.renderedColor(at: keyword), color != EditorTheme.current.foreground { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let color = try #require(controller.renderedColor(at: keyword))
        #expect(color != EditorTheme.current.foreground)
        let top = controller.topVisibleLine
        document.trimTextElements()
        view.layoutSubtreeIfNeeded()
        // (The scroller may move: TextKit's estimate of the height above changes.)
        #expect(controller.topVisibleLine == top, "top line \(top) -> \(controller.topVisibleLine)")
        #expect(controller.renderedColor(at: keyword) == color)
        // The text is all there, wherever one goes next.
        controller.reveal(NSRange(location: document.lineIndex.lineStarts[lines / 3], length: 0))
        view.layoutSubtreeIfNeeded()
        #expect(abs(controller.topVisibleLine - lines / 3) < 100)
        withExtendedLifetime(window) {}
    }

    /// A split: typing in one half, above where the other half has been. The other half keeps
    /// its top line (TextKit would keep its position in points, and revise its estimate of the
    /// height above: it showed lines 5,000 away), and once the text elements between them are
    /// dropped, a keystroke stops moving those (307 ms each, in a 3 MB file).
    @Test func typingAboveTheOtherHalfOfASplit() async throws {
        let (document, top, topWindow, url) = try open(bytes: 3_000_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let delay = EditorController.textElementTrimDelay
        EditorController.textElementTrimDelay = .seconds(3600)
        defer { EditorController.textElementTrimDelay = delay }
        let other = EditorController(document: document)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.contentView = other.makeView()
        otherWindow.layoutIfNeeded()
        document.attach(other)
        let view = other.textView!
        let lines = document.lineIndex.lineCount
        for place in 0..<300 {
            other.reveal(NSRange(location: document.lineIndex.lineStarts[place * (lines - 1) / 300], length: 0))
            view.layoutSubtreeIfNeeded()
        }
        other.scrollLineToTop(lines * 2 / 3)
        view.layoutSubtreeIfNeeded()
        top.textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[5] + 4, length: 0))
        top.textView.layoutSubtreeIfNeeded()

        func type(_ text: String) -> Duration {
            clock.measure {
                top.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                top.textView.layoutSubtreeIfNeeded()
                view.layoutSubtreeIfNeeded()
            }
        }
        let first = other.topVisibleLine
        var before: [Duration] = []
        for _ in 0..<5 { before.append(type("a")) }
        _ = type("\n")
        #expect(other.topVisibleLine == first + 1, "the other half's top line \(first) -> \(other.topVisibleLine), not \(first + 1)")

        let kept = other.topVisibleLine
        document.trimTextElements()
        view.layoutSubtreeIfNeeded()
        top.textView.layoutSubtreeIfNeeded()
        #expect(other.topVisibleLine == kept, "dropping the text elements moved the other half: \(kept) -> \(other.topVisibleLine)")
        var after: [Duration] = []
        for _ in 0..<5 { after.append(type("a")) }
        let slow = before.sorted()[2], fast = after.sorted()[2]
        #expect(fast * 4 < slow, "a keystroke took \(slow) before dropping the text elements between them, \(fast) after")
        #expect(other.topVisibleLine == kept)
        withExtendedLifetime((topWindow, otherWindow)) {}
    }

    /// Scrolling schedules it.
    @Test func scrollingDropsTextElementsAfterAPause() async throws {
        let (document, controller, window, url) = try open(bytes: 2_000_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let delay = EditorController.textElementTrimDelay
        EditorController.textElementTrimDelay = .milliseconds(20)
        defer { EditorController.textElementTrimDelay = delay }
        let view = controller.textView!
        let lines = document.lineIndex.lineCount
        for place in 0..<300 {
            controller.reveal(NSRange(location: document.lineIndex.lineStarts[place * (lines - 1) / 300], length: 0))
            view.layoutSubtreeIfNeeded()
        }
        controller.reveal(NSRange(location: 4, length: 0))
        view.layoutSubtreeIfNeeded()
        EditorController.textElementTrimDelay = .seconds(3600)
        let before = typing(controller)
        EditorController.textElementTrimDelay = .milliseconds(20)
        view.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 40))
        view.enclosingScrollView.map { $0.reflectScrolledClipView($0.contentView) }
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        let after = typing(controller)
        #expect(after * 2 < before, "a keystroke took \(before) before the pause, \(after) after")
        withExtendedLifetime(window) {}
    }
}
