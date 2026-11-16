import AppKit
import Testing
@testable import Oh_My_Code

/// Folds moved in place by edits, fold marks placed from the laid-out lines, and text checking
/// skipped when nothing is checked: what a keystroke with everything folded cost on top of
/// TextKit's own work.
@MainActor
@Suite(.serialized)
struct BigEditTests {
    private func open(_ text: String, width: CGFloat = 1000) throws -> (EditorDocument, EditorController, NSWindow, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-big-\(UUID().uuidString).swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        document.attach(controller)
        return (document, controller, window, url)
    }

    /// An edit that touches no fold moves the ones after it in place (and the hidden ranges);
    /// one that touches a fold unfolds it: the same as going through them all.
    @Test func foldsMoveWithEditsLikeBefore() async throws {
        let (document, _, window, url) = try open(PerformanceBenchmarks.code(bytes: 20_000))
        defer { try? FileManager.default.removeItem(at: url) }
        await document.highlighter?.waitUntilIdle()
        await document.waitForFoldRegions()
        func reference(_ folds: [NSRange], start: Int, oldEnd: Int, delta: Int) -> [NSRange] {
            folds.compactMap { fold in
                if oldEnd < fold.location { return NSRange(location: fold.location + delta, length: fold.length) }
                return start >= NSMaxRange(fold) ? fold : nil
            }
        }
        var generator = SeededGenerator(seed: 11)
        let length = document.textStorage.length
        for round in 0..<300 {
            if round % 30 == 0 { document.foldAll() } // nested folds, everywhere
            let before = document.folds
            #expect(before.count > 10)
            let start = Int.random(in: 0..<length, using: &generator)
            let oldEnd = min(length, start + (round % 3 == 0 ? 0 : Int.random(in: 0...40, using: &generator)))
            let delta = Int.random(in: -5...5, using: &generator)
            document.adjustFolds(editStart: start, oldEnd: oldEnd, delta: delta)
            let expected = reference(before, start: start, oldEnd: oldEnd, delta: delta)
            #expect(document.folds == expected, "edit \(start)..<\(oldEnd) by \(delta)")
            #expect(document.hiddenRanges == FoldRanges.merged(expected))
        }
        withExtendedLifetime(window) {}
    }

    /// A character's place read from its laid-out line (fold marks are drawn there) is where
    /// `rect(for:)` says it is: in view, with tabs, and on fold headers with everything folded.
    @Test func laidOutRectsMatchTheLayoutPass() async throws {
        let text = PerformanceBenchmarks.code(bytes: 40_000).replacingOccurrences(of: "\n    var", with: "\n\tvar")
        let (document, controller, window, url) = try open(text)
        defer { try? FileManager.default.removeItem(at: url) }
        await document.highlighter?.waitUntilIdle()
        await document.waitForFoldRegions()
        func compare(_ step: String) throws {
            controller.textView.layoutSubtreeIfNeeded()
            let visible = try #require(controller.visibleCharacterRange())
            var checked = 0
            for offset in stride(from: visible.location, to: min(NSMaxRange(visible), document.textStorage.length), by: 7)
            where !document.isHidden(offset) && document.textStorage.mutableString.character(at: offset) != 0x0A {
                guard let laidOut = controller.laidOutRect(ofCharacterAt: offset) else { continue }
                let expected = try #require(controller.rect(for: NSRange(location: offset, length: 1)))
                #expect(abs(laidOut.minX - expected.minX) < 0.5 && abs(laidOut.maxX - expected.maxX) < 0.5
                        && abs(laidOut.minY - expected.minY) < 0.5 && abs(laidOut.height - expected.height) < 0.5,
                        "\(step): \(offset) at \(laidOut), laid out at \(expected)")
                checked += 1
            }
            #expect(checked > 100, "\(step)")
        }
        try compare("unfolded")
        document.foldAll()
        try compare("folded")
        #expect(!controller.foldPlaceholderRects().isEmpty)
        withExtendedLifetime(window) {}
    }

    /// After each layout pass the text view's checker asks for the text of the whole viewport
    /// (with everything folded, the folded text too): none is given while nothing is checked,
    /// and it is once something is.
    @Test func textIsReadForCheckingOnlyWhenSomethingIsChecked() throws {
        let (document, controller, window, url) = try open(PerformanceBenchmarks.code(bytes: 5_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let view = try #require(controller.textView)
        let range = NSRange(location: 0, length: document.textStorage.length)
        var actual = NSRange(location: 0, length: 0)
        #expect(!view.isAutomaticTextCompletionEnabled)
        #expect(view.annotatedSubstringForChecking(proposedRange: range, actualRange: &actual) == nil && actual.location == NSNotFound)
        view.isContinuousSpellCheckingEnabled = true
        defer { view.isContinuousSpellCheckingEnabled = false }
        let text = view.annotatedSubstringForChecking(proposedRange: range, actualRange: &actual)
        #expect(text != nil && actual.location != NSNotFound && actual.length > 0)
        #expect(text.map { document.textStorage.mutableString.substring(with: actual) == $0.string } == true)
        withExtendedLifetime(window) {}
    }
}
