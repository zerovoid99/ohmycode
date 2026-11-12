import AppKit
import Foundation
import Testing
@testable import Oh_My_Code

@MainActor
struct FileWatchingTests {
    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-watch-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// FSEvents delivers on the main queue; sleeping on the main actor lets it run.
    private func eventually(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func names(_ node: FileNode?) -> [String] { node?.children?.map(\.name) ?? [] }

    @Test func treeAndIndexFollowCreatesAndDeletes() async throws {
        let root = try makeFolder(["a.txt": "a", "src/main.swift": "x"])
        let workspace = Workspace()
        workspace.openFolder(root)
        let tree = try #require(workspace.rootNode)
        let src = try #require(tree.children?.first { $0.name == "src" })
        #expect(names(src) == ["main.swift"]) // load the subfolder, as if expanded
        #expect(try await eventually { workspace.fileIndex != nil })

        try "y".write(to: root.appending(path: "src/util.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
        #expect(try await eventually { names(src) == ["main.swift", "util.swift"] })
        #expect(try await eventually { names(tree) == ["docs", "src", "a.txt"] })
        #expect(try await eventually {
            workspace.fileIndex?.files.contains { $0.text == "src/util.swift" } == true
        })
        // The loaded subtree was reused, not rebuilt.
        #expect(tree.children?.first { $0.name == "src" } === src)

        try FileManager.default.removeItem(at: root.appending(path: "a.txt"))
        #expect(try await eventually { names(tree) == ["docs", "src"] })
        #expect(try await eventually { workspace.fileIndex?.files.contains { $0.text == "a.txt" } == false })
    }

    @Test func cleanDocumentReloadsExternalEdits() async throws {
        let root = try makeFolder(["note.txt": "one\n"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "note.txt"))
        let document = try #require(workspace.activeDocument)

        try await Task.sleep(for: .milliseconds(1100)) // ensure a distinct mtime
        try "one\ntwo\nthree\n".write(to: root.appending(path: "note.txt"), atomically: false, encoding: .utf8)

        #expect(try await eventually { document.textStorage.string == "one\ntwo\nthree\n" })
        #expect(!document.isDirty)
        #expect(document.lineCount == 4)
        #expect(!document.undoManager.canUndo)
    }

    @Test func dirtyDocumentKeepsUserEdits() async throws {
        let root = try makeFolder(["note.txt": "one\n"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "note.txt"))
        let document = try #require(workspace.activeDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")

        try await Task.sleep(for: .milliseconds(1100))
        try "theirs\n".write(to: root.appending(path: "note.txt"), atomically: false, encoding: .utf8)

        #expect(try await eventually { document.hasExternalChanges })
        #expect(document.textStorage.string == "mine one\n")
        #expect(document.isDirty)
    }

    @Test func ownSaveDoesNotReload() async throws {
        let root = try makeFolder(["note.txt": "one\n"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "note.txt"))
        let document = try #require(workspace.activeDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        workspace.saveActive()
        document.undoManager.registerUndo(withTarget: document) { _ in } // a reload would clear this

        try await Task.sleep(for: .milliseconds(600))
        #expect(document.undoManager.canUndo)
        #expect(!document.hasExternalChanges)
        #expect(document.textStorage.string == "xone\n")
    }
}

@MainActor
struct ViewStateTests {
    @Test func scrollPositionAndSelectionSurviveTabSwitch() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).swift")
        try (1...5_000).map { "let line\($0) = \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)

        func show() -> (EditorController, NSWindow) {
            let controller = EditorController(document: document)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = controller.makeView()
            window.layoutIfNeeded()
            controller.textView.layoutSubtreeIfNeeded()
            return (controller, window)
        }

        let (first, firstWindow) = show()
        let target = document.lineIndex.lineStarts[3_000]
        first.reveal(NSRange(location: target, length: 0))
        first.textView.layoutSubtreeIfNeeded()
        let topLine = first.topVisibleLine
        #expect(topLine > 2_900)
        first.saveViewState()
        firstWindow.contentView = nil

        let (second, _) = show()
        #expect(second.topVisibleLine == 0)
        second.restoreViewState()
        second.textView.layoutSubtreeIfNeeded()
        #expect(second.topVisibleLine == topLine)
        #expect(second.textView.selectedRange() == NSRange(location: target, length: 0))
    }
}
