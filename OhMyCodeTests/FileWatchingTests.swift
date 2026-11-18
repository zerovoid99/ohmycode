import AppKit
import CoreServices
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

    /// Regression: saving a file another program had changed overwrote its version silently.
    /// Saving now asks: cancel keeps both, revert takes the disk's, overwrite takes ours.
    @Test func savingOverExternalChangesAsks() throws {
        let root = try makeFolder(["note.txt": "one\n"])
        let url = root.appending(path: "note.txt")
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: url)
        let document = try #require(workspace.activeDocument)
        let original = Workspace.confirmOverwrite
        defer { Workspace.confirmOverwrite = original }
        func changeOnDisk(_ text: String) throws {
            try text.write(to: url, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(.random(in: 10...1000))],
                                                  ofItemAtPath: url.path)
            document.reloadFromDiskIfChanged()
        }

        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")
        try changeOnDisk("theirs\n")
        #expect(document.hasExternalChanges)
        var asked = 0
        Workspace.confirmOverwrite = { _ in asked += 1; return .cancel }
        #expect(!workspace.save(document))
        #expect(asked == 1 && document.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n")

        Workspace.confirmOverwrite = { _ in .overwrite }
        #expect(workspace.save(document))
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine one\n")
        #expect(!document.isDirty && !document.hasExternalChanges)

        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "more ")
        try changeOnDisk("again\n")
        Workspace.confirmOverwrite = { _ in .revert }
        #expect(workspace.save(document))
        #expect(document.textStorage.string == "again\n")
        #expect(!document.isDirty && !document.hasExternalChanges)

        // Without changes on disk, nothing is asked.
        Workspace.confirmOverwrite = { _ in Issue.record("asked"); return .cancel }
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        #expect(workspace.save(document))
    }

    /// Regression: a file opened through a symlink read the link's own date, so changes to the target
    /// were never noticed and the next save overwrote them silently.
    @Test func changesToASymlinksTargetAreNoticed() throws {
        let root = try makeFolder(["target.txt": "one\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "target.txt")
        let link = root.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        func changeTarget(_ text: String, minutesAhead: Double) throws {
            try text.write(to: target, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(minutesAhead * 60)],
                                                  ofItemAtPath: target.path)
        }

        let dirty = try EditorDocument(url: link)
        dirty.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")
        try changeTarget("theirs\n", minutesAhead: 1)
        dirty.reloadFromDiskIfChanged()
        #expect(dirty.hasExternalChanges)

        let clean = try EditorDocument(url: link)
        try changeTarget("newer\n", minutesAhead: 2)
        clean.reloadFromDiskIfChanged()
        #expect(clean.textStorage.string == "newer\n")
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

    @Test func reloadKeepsNodesAndPutsNewOnesInOrder() throws {
        let root = try makeFolder(["a10.txt": "", "a2.txt": "", "B.txt": "", "sub/x.txt": "", "zeta/y.txt": ""])
        let node = FileNode(url: root, isDirectory: true)
        #expect(names(node) == ["sub", "zeta", "a2.txt", "a10.txt", "B.txt"])
        let kept = try #require(node.children?.first { $0.name == "a10.txt" })
        let sub = try #require(node.children?.first { $0.name == "sub" })
        _ = sub.children

        // Nothing changed: the same list, not a new one.
        let before = try #require(node.children)
        node.reloadChildren()
        #expect(try #require(node.children).elementsEqual(before) { $0 === $1 })

        try FileManager.default.removeItem(at: root.appending(path: "a2.txt"))
        for name in ["a1.txt", "a3.txt", "c.txt"] { try "".write(to: root.appending(path: name), atomically: true, encoding: .utf8) }
        try FileManager.default.createDirectory(at: root.appending(path: "alpha"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "tools"), withIntermediateDirectories: true)
        node.reloadChildren()
        // As a fresh listing orders them, with the nodes that were there kept (loaded folders too).
        #expect(names(node) == names(FileNode(url: root, isDirectory: true)))
        #expect(names(node) == ["alpha", "sub", "tools", "zeta", "a1.txt", "a3.txt", "a10.txt", "B.txt", "c.txt"])
        #expect(node.children?.first { $0.name == "a10.txt" } === kept)
        #expect(node.children?.first { $0.name == "sub" } === sub && sub.isLoaded)
        #expect(node.children?.allSatisfy { $0.url == root.appending(path: $0.name, directoryHint: $0.isDirectory ? .isDirectory : .notDirectory) } == true)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=OMC", "-c", "user.email=omc@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// A build writing ignored files sets nothing off; an edit re-reads git status but leaves
    /// open files' diff bases and blame alone; a commit reloads them.
    @Test func fileEventsSetOffOnlyWhatTheyNeed() async throws {
        let root = try makeFolder(["a.txt": "a\n", "b.txt": "b\n", "c.txt": "c\n", ".gitignore": "build/\n"])
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["add", "."], in: root)
        try git(["commit", "-q", "-m", "init"], in: root)
        let workspace = Workspace()
        workspace.openFolder(root)
        for name in ["a.txt", "b.txt", "c.txt"] { workspace.open(fileAt: root.appending(path: name)) }
        #expect(try await eventually { workspace.gitStatus != nil && workspace.fileIndex != nil })
        // Let the events of the setup above pass.
        try await Task.sleep(for: .milliseconds(800))
        await workspace.waitForFileEvents()

        let canonical = FileWatcher.canonicalPath(root)
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        var before = workspace.backgroundWork
        workspace.handleFileEvents((0..<50).map { FileWatcher.Event(path: canonical + "/build/out\($0).o", flags: created) })
        await workspace.waitForFileEvents()
        #expect(workspace.backgroundWork == before)

        // A file that counts, among the ignored ones.
        workspace.handleFileEvents([FileWatcher.Event(path: canonical + "/build/out.o", flags: created),
                                    FileWatcher.Event(path: canonical + "/new.txt", flags: created)])
        await workspace.waitForFileEvents()
        #expect(workspace.backgroundWork.indexBuilds == before.indexBuilds + 1)
        #expect(workspace.backgroundWork.gitRefreshes == before.gitRefreshes + 1)
        #expect(workspace.backgroundWork.diffBaseLoads == before.diffBaseLoads)

        // Something in .git changed: the open files are compared and blamed again.
        before = workspace.backgroundWork
        workspace.handleFileEvents([FileWatcher.Event(path: canonical + "/.git/index", flags: created)])
        await workspace.waitForFileEvents()
        #expect(workspace.backgroundWork.diffBaseLoads == before.diffBaseLoads + 3)
        #expect(workspace.backgroundWork.indexBuilds == before.indexBuilds)
    }

    @Test func changedTestFilesAreReadTogether() async throws {
        let test = { (name: String) in "import Testing\n\n@Test func \(name)() {}\n" }
        let root = try makeFolder(["Package.swift": "", "Tests/LibTests/ATests.swift": test("first")])
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.testing.allTests.count == 1 })

        try test("second").write(to: root.appending(path: "Tests/LibTests/BTests.swift"), atomically: true, encoding: .utf8)
        try (test("first") + "@Test func third() {}\n").write(to: root.appending(path: "Tests/LibTests/ATests.swift"), atomically: true, encoding: .utf8)
        let canonical = FileWatcher.canonicalPath(root)
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        workspace.handleFileEvents(["ATests.swift", "BTests.swift", "Gone.swift"].map {
            FileWatcher.Event(path: canonical + "/Tests/LibTests/" + $0, flags: modified)
        })
        await workspace.testing.waitForFileChanges()
        #expect(workspace.testing.files.map(\.label) == ["ATests.swift", "BTests.swift"])
        #expect(workspace.testing.allTests.count == 3)

        try FileManager.default.removeItem(at: root.appending(path: "Tests/LibTests/ATests.swift"))
        workspace.handleFileEvents([FileWatcher.Event(path: canonical + "/Tests/LibTests/ATests.swift", flags: modified)])
        await workspace.testing.waitForFileChanges()
        #expect(workspace.testing.files.map(\.label) == ["BTests.swift"])
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
