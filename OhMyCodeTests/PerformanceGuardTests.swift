import AppKit
import Testing
@testable import Oh_My_Code

/// Cheap guards against the editor going O(file size) per keystroke again (it did: TextKit 2
/// with a container wider than its view updates every paragraph after an edit). Generous
/// limits: a debug build on a busy machine stays well under them; the old behavior didn't.
@MainActor
struct PerformanceGuardTests {
    @Test func typingInABigFileStaysFast() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-guard-\(UUID().uuidString).swift")
        try PerformanceBenchmarks.code(bytes: 2_000_000).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let clock = ContinuousClock()
        let layout = clock.measure {
            window.contentView = controller.makeView()
            window.layoutIfNeeded()
            controller.textView.displayIfNeeded()
        }
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        #expect(layout < .milliseconds(1_500), "first layout took \(layout)")
        // Lines don't wrap (code), and the view is as wide as the widest line.
        #expect(controller.textView.textContainer?.widthTracksTextView == true)
        #expect(controller.textView.frame.width >= controller.textView.enclosingScrollView!.contentSize.width)

        let middle = document.lineIndex.lineStarts[document.lineIndex.lineCount / 2] + 4
        controller.textView.setSelectedRange(NSRange(location: middle, length: 0))
        var samples: [Duration] = []
        for _ in 0..<30 {
            samples.append(clock.measure {
                controller.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
                controller.textView.displayIfNeeded()
            })
        }
        samples.sort()
        #expect(samples[samples.count / 2] < .milliseconds(25), "median keystroke took \(samples[samples.count / 2])")
        withExtendedLifetime(window) {}
    }

    /// Nothing may keep a copy of the line index across an edit: the edit would then copy all
    /// the line starts (sticky scroll's pending update did, 1.6 MB a keystroke in a 5 MB file).
    @Test func editsDontCopyTheLineIndex() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-guard-\(UUID().uuidString).swift")
        try PerformanceBenchmarks.code(bytes: 200_000).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.attach(controller)
        let sticky = try #require(controller.stickyView)
        let middle = document.lineIndex.lineStarts[document.lineIndex.lineCount / 2] + 4
        controller.textView.setSelectedRange(NSRange(location: middle, length: 0))
        let storage = document.lineIndex.storageAddress
        for _ in 0..<5 {
            sticky.update() // as scrolling does; its work runs later
            controller.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(document.lineIndex.storageAddress == storage)
        withExtendedLifetime(window) {}
    }

    /// A file of code in an editor in a window, laid out.
    private func openEditor(bytes: Int) throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-guard-\(UUID().uuidString).swift")
        try PerformanceBenchmarks.code(bytes: bytes).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()
        document.attach(controller)
        return (document, controller, window)
    }

    /// An edit changes the blame in place: making the array again for every keystroke took
    /// time in proportion to the file's lines (a second, in a 20 MB file).
    @Test func editsDontCopyTheBlame() async throws {
        let (document, controller, window) = try openEditor(bytes: 200_000)
        let lineCount = document.lineIndex.lineCount
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        document.blameProvider = { _ in
            (0..<lineCount).map { BlameLine(commit: String(format: "%040x", $0 % 50 + 1), author: "a", date: date.addingTimeInterval(Double($0)), summary: "s") }
        }
        document.scheduleBlame(after: .zero)
        await document.waitForBlame()
        #expect(document.blameDates == date...date.addingTimeInterval(Double(lineCount - 1)))
        func storage() -> UnsafeRawPointer? { document.blame?.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }
        let before = storage()
        let line = lineCount / 2
        controller.textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[line] + 4, length: 0))
        for _ in 0..<5 { controller.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        #expect(storage() == before)
        #expect(document.blame?[line]?.isUncommitted == true)
        #expect(document.blame?[line - 1]?.isUncommitted == false && document.blame?[line + 1]?.isUncommitted == false)
        #expect(document.blame?.count == lineCount)
        withExtendedLifetime(window) {}
    }

    /// The widest line, measured in one pass on open: tabs to the next stop, wide characters two
    /// columns, a surrogate pair one, the last line without its newline too.
    @Test func longestLineCountsColumns() throws {
        func longest(_ text: String) throws -> (Int, Int) {
            let url = FileManager.default.temporaryDirectory.appending(path: "omc-guard-\(UUID().uuidString).txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let document = try EditorDocument(url: url)
            return (document.longestLineColumns, document.displayTabWidth)
        }
        #expect(try longest("ab\n日本語日本語\r\n😀😀\nabcdefghij").0 == 12)
        #expect(try longest("a\nabcdefghijk").0 == 11)
        let (tabs, width) = try longest("x\n\t\t\tx\n")
        #expect(tabs == 3 * width + 1)
        #expect(try longest("").0 == 0)
    }

    @Test func longLinesDontWrapWithoutWordWrap() throws {
        let long = String(repeating: "let value = 1; ", count: 400) // ~6000 columns
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-guard-\(UUID().uuidString).swift")
        try "short\n\(long)\nend\n".write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.attach(controller) // as the app does once the view is up
        controller.textView.layoutSubtreeIfNeeded()
        // One row for the long line: its last character is on the same row as its first.
        let first = try #require(controller.rect(for: NSRange(location: 6, length: 1)))
        let last = try #require(controller.rect(for: NSRange(location: 6 + (long as NSString).length - 1, length: 1)))
        #expect(abs(first.minY - last.minY) < 1 && last.minX > 10_000)
        // Typing a longer line widens the view.
        let before = controller.textView.frame.width
        controller.textView.setSelectedRange(NSRange(location: 6 + (long as NSString).length, length: 0))
        controller.textView.insertText(String(repeating: "x", count: 200), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(controller.textView.frame.width > before)
        withExtendedLifetime(window) {}
    }
}
