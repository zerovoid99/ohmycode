import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct WhitespaceTests {
    private func makeEditor(_ text: String, in folder: URL? = nil, name: String = "a.txt") throws -> (EditorDocument, EditorController, NSWindow) {
        let folder = folder ?? FileManager.default.temporaryDirectory.appending(path: "omc-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        controller.textView.layoutSubtreeIfNeeded()
        return (document, controller, window)
    }

    private var space: CGFloat { (" " as NSString).size(withAttributes: [.font: EditorTheme.font]).width }

    @Test func tabsAreAsWideAsTheTabWidth() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-ws-\(UUID().uuidString)")
        let (document, controller, window) = try makeEditor("\tx\n\ty\n    z\n", in: folder)
        #expect(document.displayTabWidth == 4)
        let lineStart = try #require(controller.rect(for: NSRange(location: 0, length: 1))).minX
        let x = try #require(controller.rect(for: NSRange(location: 1, length: 1))).minX
        let z = try #require(controller.rect(for: NSRange(location: 10, length: 1))).minX
        // A tab lines up with four spaces.
        #expect(abs((x - lineStart) - 4 * space) < 1 && abs(x - z) < 1)
        #expect(!document.isDirty && !document.undoManager.canUndo)

        // .editorconfig's tab_width.
        try "root = true\n[*]\ntab_width = 2\n".write(to: folder.appending(path: ".editorconfig"), atomically: true, encoding: .utf8)
        document.reloadEditorConfig()
        controller.textView.layoutSubtreeIfNeeded()
        #expect(document.displayTabWidth == 2)
        let narrower = try #require(controller.rect(for: NSRange(location: 1, length: 1))).minX
        #expect(abs((narrower - lineStart) - 2 * space) < 1)
        #expect(!document.isDirty && !document.undoManager.canUndo)
        withExtendedLifetime(window) {}
    }

    @Test func marksFollowTheSetting() throws {
        let (_, controller, window) = try makeEditor("  a b  c  \n\tx\n")
        let settings = AppSettings.shared
        defer { settings.renderWhitespace = .selection }

        settings.renderWhitespace = .all
        var marks = controller.whitespaceMarks()
        #expect(marks.filter { !$0.isTab }.count == 7 && marks.filter(\.isTab).count == 1)
        // Each space gets its own mark, side by side.
        let spaces = marks.filter { !$0.isTab }.map(\.rect)
        #expect(abs(spaces[1].minX - spaces[0].maxX) < 0.5)

        // Not the single space between words.
        settings.renderWhitespace = .boundary
        marks = controller.whitespaceMarks()
        #expect(marks.filter { !$0.isTab }.count == 6 && marks.filter(\.isTab).count == 1)

        settings.renderWhitespace = .selection
        #expect(controller.whitespaceMarks().isEmpty)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 5)) // "  a b"
        #expect(controller.whitespaceMarks().count == 3)

        settings.renderWhitespace = .none
        #expect(controller.whitespaceMarks().isEmpty)
        withExtendedLifetime(window) {}
    }
}
