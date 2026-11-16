import AppKit
import Testing
@testable import Oh_My_Code

/// Guards for the cost of language-server traffic: what's decoded where, what a keystroke
/// touches, and what's left alone when an answer changes nothing.
@MainActor
struct LSPPipelineTests {
    private func document(_ text: String) throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-pipeline-\(UUID().uuidString).swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try EditorDocument(url: url)
    }

    /// Squiggles are drawn for the diagnostics in view only. Asking TextKit where far-away ones
    /// are lays out the text there: with problems all over a long file, the whole file, on
    /// every redraw (and typing in a fully laid-out file is slow from then on).
    @Test func farAwayDiagnosticsAreNotLaidOut() throws {
        let lines = 6000
        let document = try document((0..<lines).map { "let value\($0) = \($0)\n" }.joined())
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()
        document.editor = controller

        func diagnostic(_ start: Int, _ end: Int, _ severity: Diagnostic.Severity = .error) -> Diagnostic {
            Diagnostic(range: LSPRange(start: LSPPosition(line: start, character: 4), end: LSPPosition(line: end, character: 9)),
                       severity: severity, message: "problem", source: "test")
        }
        // One per ten lines down the whole file, and one over all of it.
        document.setDiagnostics(stride(from: 1, to: lines, by: 10).map { diagnostic($0, $0) } + [diagnostic(0, lines - 1, .warning)])
        let overlay = try #require(controller.diagnosticsOverlay)
        let segments = overlay.segments()
        // The ones in view are there: line 1's, and the long one's lines.
        #expect(segments.contains { $0.color == NSColor.systemRed })
        #expect(segments.count { $0.color == NSColor.systemYellow } > 5)

        let layoutManager = try #require(controller.textView.textLayoutManager)
        var laidOut = 0
        layoutManager.enumerateTextLayoutFragments(from: nil, options: []) { fragment in
            if fragment.state == .layoutAvailable { laidOut += 1 }
            return true
        }
        #expect(laidOut < lines / 4, "\(laidOut) of \(lines) lines were laid out to draw the squiggles in view")
        withExtendedLifetime(window) {}
    }

    /// The same hints again (every pause in typing asks for them) leave the text alone: writing
    /// attributes makes TextKit lay the text out again. Only what changed is written.
    @Test func unchangedInlayHintsAreNotRewritten() throws {
        let document = try document("let total = 42\nlet other = 7\nlet third = 9\n")
        func mark(_ index: Int) -> InlayHintMark? { document.textStorage.attribute(.omcInlayHint, at: index, effectiveRange: nil) as? InlayHintMark }
        func kern(_ index: Int) -> CGFloat? { document.textStorage.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat }
        func shown() -> [String] { document.shownInlayHints.map { "\($0.index)\($0.text)" } }
        var hints = [InlayHint(position: LSPPosition(line: 0, character: 9), label: ": Int", kind: .type),
                     InlayHint(position: LSPPosition(line: 1, character: 9), label: ": Int", kind: .type),
                     InlayHint(position: LSPPosition(line: 2, character: 9), label: ": Int", kind: .type)]
        document.setInlayHints(hints)
        #expect(shown() == ["8: Int", "23: Int", "37: Int"])
        let first = try #require(mark(8)), second = try #require(mark(23)), third = try #require(mark(37))

        var edits = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: document.textStorage, queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        document.setInlayHints(hints)
        #expect(edits == 0)
        #expect(mark(8) === first && mark(23) === second && mark(37) === third)

        // One changes, one goes: the third stays as it was.
        hints[0].label = ": Double"
        hints.remove(at: 1)
        document.setInlayHints(hints)
        #expect(edits == 1)
        #expect(shown() == ["8: Double", "37: Int"])
        #expect(mark(8) !== first && mark(37) === third)
        #expect(mark(23) == nil && kern(23) == nil)
        #expect(kern(8) == InlayHintStyle.width(of: ": Double") && kern(37) == InlayHintStyle.width(of: ": Int"))

        document.setInlayHints([])
        #expect(shown().isEmpty && kern(8) == nil && kern(37) == nil)
    }
}
