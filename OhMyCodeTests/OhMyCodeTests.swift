import AppKit
import Foundation
import Testing
@testable import Oh_My_Code

struct LineIndexTests {
    /// Apply a random sequence of edits incrementally and compare with a full rebuild.
    @Test func incrementalEditsMatchFullRebuild() {
        let storage = NSMutableString(string: "line one\nline two\n\nline four")
        var index = LineIndex(string: storage)
        var rng = SystemRandomNumberGenerator()
        let samples = ["", "a", "\n", "foo\nbar", "\n\n", "x\ny\nz\n", "\r\n"]

        for _ in 0..<2_000 {
            let location = Int.random(in: 0...storage.length, using: &rng)
            let length = Int.random(in: 0...min(6, storage.length - location), using: &rng)
            let replacement = samples.randomElement(using: &rng)!
            storage.replaceCharacters(in: NSRange(location: location, length: length), with: replacement)
            let newLength = (replacement as NSString).length
            index.apply(editedRange: NSRange(location: location, length: newLength),
                        changeInLength: newLength - length, in: storage)
            #expect(index == LineIndex(string: storage))
        }
    }

    @Test func lineLookup() {
        let index = LineIndex(string: "ab\ncd\n")
        #expect(index.lineCount == 3)
        #expect(index.line(containing: 0) == 0)
        #expect(index.line(containing: 2) == 0)
        #expect(index.line(containing: 3) == 1)
        #expect(index.line(containing: 6) == 2)
    }
}

@MainActor
struct EditorDocumentTests {
    private func makeFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func editsTrackLinesDirtyAndSave() throws {
        let url = try makeFile("let a = 1\n")
        let document = try EditorDocument(url: url)
        #expect(document.lineCount == 2)
        #expect(!document.isDirty)
        #expect(document.language == .swift)

        document.textStorage.replaceCharacters(in: NSRange(location: 10, length: 0), with: "let b = 2\n")
        #expect(document.lineCount == 3)
        #expect(document.isDirty)

        try document.save()
        #expect(!document.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "let a = 1\nlet b = 2\n")
    }

    @Test func attributeOnlyEditsDoNotDirty() throws {
        let document = try EditorDocument(url: try makeFile("hello"))
        document.textStorage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 5))
        #expect(!document.isDirty)
    }

    @Test func rejectsBinaryFiles() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: url)
        #expect(throws: EditorDocumentError.self) { try EditorDocument(url: url) }
    }

    /// The editor must stay on TextKit 2 (viewport layout). Any access to
    /// `NSTextView.layoutManager` silently downgrades to TextKit 1.
    @Test func editorStaysOnTextKit2() throws {
        nonisolated(unsafe) var didFallBack = false
        let token = NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: nil, queue: nil
        ) { _ in didFallBack = true }
        defer { NotificationCenter.default.removeObserver(token) }

        let text = (1...5_000).map { "line \($0)" }.joined(separator: "\n")
        let document = try EditorDocument(url: try makeFile(text))
        let controller = EditorController(document: document)
        let scrollView = controller.makeScrollView()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        scrollView.frame = window.contentView!.bounds
        window.layoutIfNeeded()
        controller.rulerView.display()

        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.textView.insertText("// hi\n", replacementRange: NSRange(location: 0, length: 0))
        controller.rulerView.display()

        #expect(!didFallBack)
        #expect(controller.textView.textLayoutManager != nil)
        #expect(document.lineCount == 5_001)
        #expect(document.cursorLine == 2)
        #expect(document.undoManager.canUndo)
    }
}
