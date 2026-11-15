import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct WordWrapTests {
    private func makeEditor(_ text: String, ext: String) throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-wrap-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        controller.textView.layoutSubtreeIfNeeded()
        return (document, controller, window)
    }

    /// Rows the first line is laid out in.
    private func rows(_ controller: EditorController) -> Int {
        guard let layoutManager = controller.textView.textLayoutManager,
              let fragment = layoutManager.textLayoutFragment(for: layoutManager.documentRange.location) else { return 0 }
        layoutManager.ensureLayout(for: fragment.rangeInElement)
        return fragment.textLineFragments.count
    }

    private static let long = String(repeating: "word ", count: 80)

    @Test func settingChoosesByLanguage() {
        #expect(WordWrap.prose.wraps(.markdown) && WordWrap.prose.wraps(.plaintext) && !WordWrap.prose.wraps(.swift))
        #expect(WordWrap.on.wraps(.swift) && !WordWrap.off.wraps(.markdown))
    }

    @Test func markdownWrapsAndTheGutterFollows() throws {
        let (document, controller, window) = try makeEditor(Self.long + "\nshort\n", ext: "md")
        #expect(document.wrapsLines && controller.textView.textContainer?.widthTracksTextView == true)
        #expect(controller.textView.enclosingScrollView?.hasHorizontalScroller == false)
        #expect(rows(controller) > 2)

        // A point on the long line's second row is still line 0, whose rect covers all its rows.
        let gutter = controller.gutterView!
        let first = try #require(controller.rect(for: NSRange(location: 0, length: 1)))
        let secondRow = gutter.convert(NSPoint(x: 5, y: first.maxY + 3), from: controller.textView)
        let (line, rect) = try #require(gutter.line(at: secondRow))
        #expect(line == 0 && rect.height > first.height * 2)
        // The next line's row is line 1.
        let short = try #require(controller.rect(for: NSRange(location: (Self.long as NSString).length + 1, length: 1)))
        #expect(gutter.line(at: gutter.convert(NSPoint(x: 5, y: short.midY), from: controller.textView))?.0 == 1)

        // ⌥Z for this file: one row, scrolling sideways.
        controller.toggleWordWrap()
        controller.textView.layoutSubtreeIfNeeded()
        #expect(!document.wrapsLines && rows(controller) == 1)
        #expect(controller.textView.enclosingScrollView?.hasHorizontalScroller == true)
        controller.toggleWordWrap()
        controller.textView.layoutSubtreeIfNeeded()
        #expect(rows(controller) > 2)
        withExtendedLifetime(window) {}
    }

    @Test func codeWrapsWhenTheSettingSaysSo() throws {
        let (document, controller, window) = try makeEditor("let x = \"\(Self.long)\"\ny\n", ext: "swift")
        #expect(!document.wrapsLines && rows(controller) == 1)
        AppSettings.shared.wordWrap = .on
        defer { AppSettings.shared.wordWrap = .prose }
        controller.textView.layoutSubtreeIfNeeded()
        #expect(document.wrapsLines && rows(controller) > 2)
        // Still three lines (numbers and marks count lines, not rows).
        #expect(document.lineIndex.lineCount == 3)
        AppSettings.shared.wordWrap = .off
        controller.textView.layoutSubtreeIfNeeded()
        #expect(rows(controller) == 1)
        withExtendedLifetime(window) {}
    }
}
