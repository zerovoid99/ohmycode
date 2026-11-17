import AppKit
import SwiftUI
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

    /// Regression: reading dropped a UTF-8 byte order mark, and saving didn't write it back.
    @Test func savingKeepsTheByteOrderMark() throws {
        let url = try makeFile("")
        try Data([0xEF, 0xBB, 0xBF] + Array("a\n".utf8)).write(to: url)
        let document = try EditorDocument(url: url)
        #expect(document.textStorage.string == "a\n" && document.hasBOM)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "b")
        try document.save()
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF] + Array("b\n".utf8)))

        let plain = try EditorDocument(url: try makeFile("c\n"))
        plain.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "d")
        try plain.save()
        #expect(try Data(contentsOf: plain.url) == Data("d\n".utf8))
    }

    /// Regression: the atomic save replaced a symlink with a regular file of its own.
    @Test func savingWritesThroughASymlinkAndKeepsPermissions() throws {
        let target = try makeFile("one\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link) }

        let document = try EditorDocument(url: link)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "two")
        try document.save()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "two\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        #expect(permissions == 0o755)
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
        let editorView = controller.makeView()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editorView
        window.layoutIfNeeded()
        controller.gutterView.display()

        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.textView.insertText("// hi\n", replacementRange: NSRange(location: 0, length: 0))
        controller.gutterView.display()

        #expect(!didFallBack)
        #expect(controller.textView.textLayoutManager != nil)
        #expect(document.lineCount == 5_001)
        #expect(document.cursorLine == 2)
        #expect(document.undoManager.canUndo)
    }
}

@MainActor
struct WorkspaceLayoutTests {
    /// Regression: with no file open, VSplitView collapsed the empty editor area, leaving large
    /// undrawn (transparent) regions and the status bar floating mid-window.
    @Test func emptyEditorAreaFillsTheWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        let host = NSHostingView(rootView: WorkspaceView(workspace: workspace).frame(width: 700, height: 360))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(600))
        window.layoutIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)

        var undrawn = 0, total = 0
        for x in stride(from: 300, to: bitmap.pixelsWide, by: 4) { // editor side of the window
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if color.alphaComponent < 0.5 { undrawn += 1 }
            }
        }
        #expect(Double(undrawn) / Double(total) < 0.05, "\(undrawn) of \(total) sampled pixels are undrawn")
        withExtendedLifetime(workspace) {}
    }
}
