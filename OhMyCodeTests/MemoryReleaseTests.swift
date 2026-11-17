import AppKit
import Testing
@testable import Oh_My_Code

/// A closed file must leave memory: its text, line index and syntax tree go with it.
@MainActor
@Suite(.serialized)
struct MemoryReleaseTests {
    /// Opens `url` in an editor in a window (synchronously, so autoreleased objects drain).
    private func showEditor(for document: EditorDocument) -> (EditorController, NSWindow) {
        autoreleasepool {
            let controller = EditorController(document: document)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = controller.makeView()
            window.layoutIfNeeded()
            controller.textView.displayIfNeeded()
            document.editor = controller
            return (controller, window)
        }
    }

    /// Lets AppKit let go (a closed text view lingers for a moment), up to a few seconds.
    private func settle(until released: () -> Bool = { false }) async throws {
        for step in 0..<60 where step < 5 || !released() { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func closedEditorReleasesItsDocument() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-release-\(UUID().uuidString).swift")
        try "struct A {\n    let a = 1\n}\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        weak var weakDocument: EditorDocument?
        weak var weakOverlay: NSView?
        weak var weakLine: NSView?
        var hadLine = false
        try await {
            let document = try EditorDocument(url: url)
            weakDocument = document
            var (controller, window): (EditorController?, NSWindow?) = showEditor(for: document)
            await document.highlighter?.waitUntilIdle()
            autoreleasepool {
                weakOverlay = controller?.diagnosticsOverlay
                // One of TextKit's views of a line (in a view of its own in the text view).
                weakLine = controller?.textView.subviews.flatMap(\.subviews).first
                hadLine = weakLine != nil
                window?.contentView = nil
                window?.close()
                (controller, window) = (nil, nil)
            }
        }()
        try await settle { weakOverlay == nil && weakLine == nil && weakDocument == nil }
        #expect(weakOverlay == nil, "the overlay outlived its editor")
        #expect(hadLine)
        #expect(weakLine == nil, "a line's view outlived its editor")
        #expect(weakDocument == nil, "the document outlived its editor")
    }

    @Test func closedTabReleasesItsDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let a = 1\n".write(to: root.appending(path: "a.swift"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        weak var weakDocument: EditorDocument?
        try await {
            workspace.open(fileAt: root.appending(path: "a.swift"))
            let document = try #require(workspace.activeDocument)
            weakDocument = document
            var (controller, window): (EditorController?, NSWindow?) = showEditor(for: document)
            await document.highlighter?.waitUntilIdle()
            #expect(controller != nil)
            autoreleasepool {
                workspace.close(document)
                window?.contentView = nil
                window?.close()
                (controller, window) = (nil, nil)
            }
        }()
        try await settle()
        #expect(weakDocument == nil, "the workspace kept a closed file")
        withExtendedLifetime(workspace) {}
    }
}
