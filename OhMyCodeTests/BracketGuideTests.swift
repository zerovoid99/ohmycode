import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct BracketGuideTests {
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func makeEditor(_ text: String, ext: String = "swift") throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-brackets-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        return (document, controller, window)
    }

    @Test func matchesBracketsOutsideStrings() async throws {
        let code = "func f() {\n    let s = \"(}\"\n    if a { g(1) }\n}\n"
        let (document, controller, window) = try makeEditor(code)
        let text = code as NSString
        // Wait for the syntax colors: they tell where the string is.
        #expect(try await eventually { controller.nonCodeVersion == document.editVersion && !controller.nonCodeRanges.isEmpty })

        let open = text.range(of: "{").location
        let close = text.length - 2
        controller.textView.setSelectedRange(NSRange(location: open + 1, length: 0)) // after "{"
        // The "}" in the string doesn't count.
        #expect(controller.bracketPairAtCursor().map { [$0.0, $0.1] } == [open, close])
        let inString = text.range(of: "(}").location
        #expect(controller.matchingBracket(at: inString) == nil)
        let call = text.range(of: "g(").location + 1
        controller.textView.setSelectedRange(NSRange(location: call, length: 0)) // before "("
        #expect(controller.bracketPairAtCursor().map { [$0.0, $0.1] } == [call, call + 2])
        controller.textView.layoutSubtreeIfNeeded()
        #expect(controller.bracketRects().count == 2)

        // Go to Bracket: from a bracket to its match; inside a pair, to its closing bracket.
        controller.jumpToBracket()
        #expect(controller.textView.selectedRange().location == call + 2)
        controller.textView.setSelectedRange(NSRange(location: text.range(of: "a {").location, length: 0)) // in f's body
        controller.jumpToBracket()
        #expect(controller.textView.selectedRange().location == close)

        AppSettings.shared.highlightsMatchingBrackets = false
        defer { AppSettings.shared.highlightsMatchingBrackets = true }
        controller.textView.setSelectedRange(NSRange(location: open + 1, length: 0))
        #expect(controller.bracketPairAtCursor() == nil)
        withExtendedLifetime(window) {}
    }

    @Test func unmatchedBracketsMatchNothing() throws {
        let (_, controller, window) = try makeEditor("x = (1, [2\n", ext: "txt")
        #expect(controller.matchingBracket(at: 4) == nil && controller.matchingBracket(at: 8) == nil)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.jumpToBracket() // beeps, stays
        #expect(controller.textView.selectedRange().location == 0)
        withExtendedLifetime(window) {}
    }

    @Test func indentGuides() throws {
        let (document, controller, window) = try makeEditor("a\n    b\n        c\n\n    d\ne\n", ext: "txt")
        #expect(document.indentation.tabSize == 4)
        #expect((0..<6).map { controller.indentLevel(ofLine: $0, tabSize: 4) } == [0, 1, 2, 1, 1, 0])
        let start = document.lineIndex.lineStarts

        controller.textView.setSelectedRange(NSRange(location: start[2] + 9, length: 0)) // on "c"
        #expect(controller.activeIndentGuide(tabSize: 4).map { [$0.level, $0.lines.lowerBound, $0.lines.upperBound] } == [1, 2, 2])
        // A line that opens a block: that block's guide.
        controller.textView.setSelectedRange(NSRange(location: start[1] + 4, length: 0))
        #expect(controller.activeIndentGuide(tabSize: 4).map { [$0.level, $0.lines.lowerBound, $0.lines.upperBound] } == [1, 2, 2])
        controller.textView.setSelectedRange(NSRange(location: start[4] + 4, length: 0)) // on "d"
        #expect(controller.activeIndentGuide(tabSize: 4).map { [$0.level, $0.lines.lowerBound, $0.lines.upperBound] } == [0, 1, 4])
        // "a" opens the block below it.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(controller.activeIndentGuide(tabSize: 4).map { [$0.level, $0.lines.lowerBound, $0.lines.upperBound] } == [0, 1, 4])
        controller.textView.setSelectedRange(NSRange(location: start[5], length: 0)) // on "e"
        #expect(controller.activeIndentGuide(tabSize: 4) == nil)

        controller.textView.setSelectedRange(NSRange(location: start[4] + 4, length: 0))
        controller.textView.layoutSubtreeIfNeeded()
        let rects = controller.indentGuideRects()
        #expect(rects.count == 5)
        #expect(rects.filter(\.isActive).count == 4)
        // Level 1 guides sit four spaces right of level 0's.
        let xs = Set(rects.map(\.rect.minX)).sorted()
        #expect(xs.count == 2 && xs[1] - xs[0] > 10)

        AppSettings.shared.showsIndentGuides = false
        defer { AppSettings.shared.showsIndentGuides = true }
        #expect(controller.indentGuideRects().isEmpty)
        withExtendedLifetime(window) {}
    }
}
