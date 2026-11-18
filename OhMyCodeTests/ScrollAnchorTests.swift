import AppKit
import Testing
@testable import Oh_My_Code

/// Scrolling up from a place jumped to, the lines coming into view have only estimated
/// heights; laying them out moved the lines already on screen (by tens of points with word
/// wrap: the view seemed to scroll by itself).
@MainActor
@Suite(.serialized)
struct ScrollAnchorTests {
    @Test(arguments: [true, false]) func linesInViewStayPutScrollingUp(wrap: Bool) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-anchor-\(UUID().uuidString).md")
        // Paragraphs of different lengths, so wrapped ones take one to eight rows.
        let words = ["the", "editor", "keeps", "what", "is", "on", "screen", "where", "it", "was"]
        let text = (0..<3000).map { paragraph in
            (0..<(5 + paragraph * 7 % 120)).map { words[($0 + paragraph) % words.count] }.joined(separator: " ")
        }.joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try EditorDocument(url: url)
        document.wordWrapOverride = wrap
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        let view = controller.textView!
        view.layoutSubtreeIfNeeded()
        document.attach(controller)

        controller.scrollLineToTop(document.lineIndex.lineCount * 2 / 3)
        view.layoutSubtreeIfNeeded()
        var jumps: [CGFloat] = []
        for _ in 0..<150 {
            let line = controller.topVisibleLine + 1
            let start = document.lineIndex.lineStarts[line]
            let before = try #require(controller.laidOutRect(ofCharacterAt: start)).minY - view.visibleRect.minY
            view.scroll(NSPoint(x: 0, y: view.visibleRect.minY - 60))
            view.layoutSubtreeIfNeeded()
            let after = try #require(controller.laidOutRect(ofCharacterAt: start)).minY - view.visibleRect.minY
            if abs(after - before - 60) > 1 { jumps.append(after - before - 60) }
        }
        // (TextKit itself can still nudge the view now and then.)
        #expect(jumps.count <= 3, "lines on screen moved by \(jumps) as the view scrolled 60 points at a time")
        withExtendedLifetime(window) {}
    }
}
