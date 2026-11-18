import AppKit
import Testing
@testable import Oh_My_Code

/// Compare Files and Folders.
@MainActor
struct CompareTests {
    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func compare(_ left: URL, _ right: URL) throws -> [String: FolderCompareStatus] {
        let entries = try FolderComparer.compare(left: left, right: right, isCancelled: { false })
        #expect(entries.map(\.path) == entries.map(\.path).sorted())
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.status) })
    }

    @Test func foldersByPathSizeAndContent() throws {
        let left = try makeFolder(["a.txt": "1", "b.txt": "xxxx", "same.txt": "s\n", "sub/c.txt": "c", "big.txt": "long one"])
        let right = try makeFolder(["b.txt": "yyyy", "same.txt": "s\n", "sub/d.txt": "d", "e.txt": "e", "big.txt": "short"])
        #expect(try compare(left, right) == [
            "a.txt": .onlyLeft, "b.txt": .different, "same.txt": .same, "sub/c.txt": .onlyLeft,
            "sub/d.txt": .onlyRight, "e.txt": .onlyRight, "big.txt": .different,
        ])
    }

    @Test func ignoresBuildFoldersAndGitignore() throws {
        let files = [
            ".git/HEAD": "ref", "node_modules/x/index.js": "x", ".build/debug/y": "y", "DerivedData/z": "z", ".DS_Store": "d",
            "app.log": "log", "out/o.txt": "o", "sub/out/kept.txt": "k", "sub/tmp/t.txt": "t", "src/main.swift": "m",
            ".gitignore": "# build output\n*.log\n/out/\ntmp/\n!keep.log\n",
        ]
        let left = try makeFolder(files)
        let right = try makeFolder([:])
        #expect(try Set(compare(left, right).keys) == [".gitignore", "sub/out/kept.txt", "src/main.swift"])

        let rules = FolderCompareIgnore(gitignore: "**/cache/\ndocs/*.md\n")
        #expect(rules.ignores("a/b/cache", isDirectory: true) && !rules.ignores("a/b/cache", isDirectory: false))
        #expect(rules.ignores("docs/readme.md", isDirectory: false) && !rules.ignores("other/docs/readme.md", isDirectory: false))
    }

    @Test func symbolicLinksAreNotFollowed() throws {
        let target = try makeFolder(["inside.txt": "i"])
        let left = try makeFolder(["f.txt": "f"])
        let right = try makeFolder(["f.txt": "f"])
        let manager = FileManager.default
        try manager.createSymbolicLink(atPath: left.appending(path: "linked").path, withDestinationPath: target.path)
        try manager.createSymbolicLink(atPath: right.appending(path: "linked").path, withDestinationPath: target.path)
        try manager.createSymbolicLink(atPath: left.appending(path: "other").path, withDestinationPath: target.path)
        try manager.createSymbolicLink(atPath: right.appending(path: "other").path, withDestinationPath: "/tmp")
        // A link and a regular file with the same bytes as its target path still differ.
        try manager.createSymbolicLink(atPath: left.appending(path: "mixed").path, withDestinationPath: "f.txt")
        try "f.txt".write(to: right.appending(path: "mixed"), atomically: true, encoding: .utf8)
        #expect(try compare(left, right) == ["f.txt": .same, "linked": .same, "other": .different, "mixed": .different])
    }

    @Test func cancellationStopsTheComparison() throws {
        let left = try makeFolder(["a.txt": "a", "b.txt": "b"])
        let right = try makeFolder(["a.txt": "a", "b.txt": "c"])
        #expect(throws: CancellationError.self) {
            try FolderComparer.compare(left: left, right: right, isCancelled: { true })
        }
        // Stopped while comparing contents (after the walks).
        var checks = 0
        #expect(throws: CancellationError.self) {
            try FolderComparer.compare(left: left, right: right, isCancelled: { checks += 1; return checks > 2 })
        }
        var reported: [Int] = []
        _ = try FolderComparer.compare(left: left, right: right, progress: { done, total in
            #expect(total == 2)
            reported.append(done)
        }, isCancelled: { false })
        #expect(reported == [0, 1, 2])
    }

    @Test func folderTabListsAndClosingCancels() async throws {
        let left = try makeFolder(["a.txt": "a", "same.txt": "s", "diff.txt": "1"])
        let right = try makeFolder(["b.txt": "b", "same.txt": "s", "diff.txt": "2"])
        let workspace = Workspace()
        let tab = try #require(workspace.comparisons.compareFolders(left, right))
        #expect(workspace.comparisons.compareFolders(left, right) === tab) // one tab per pair
        #expect(tab.isRunning)
        await tab.waitForCompletion()
        #expect(!tab.isRunning && tab.count(.same) == 1 && tab.count(.different) == 1)
        #expect(tab.visibleEntries.map(\.path) == ["a.txt", "b.txt", "diff.txt"]) // same hidden by default
        tab.showsSame = true
        tab.filter = "DIFF"
        #expect(tab.visibleEntries.map(\.path) == ["diff.txt"])
        #expect(workspace.tabInfo(tab.id)?.title == "\(left.lastPathComponent) ↔ \(right.lastPathComponent)")

        tab.refresh()
        #expect(tab.isRunning)
        workspace.closeTab(tab.id, in: workspace.activeGroup)
        #expect(!tab.isRunning && workspace.comparisons.folderTab(id: tab.id) == nil)
    }

    @Test func clipboardAndSavedSides() async throws {
        let root = try makeFolder(["a.txt": "one\ntwo\n"])
        let url = root.appending(path: "a.txt")
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: url)
        let document = try #require(workspace.activeDocument)

        let clip = try #require(workspace.compareWithClipboard(url, text: "one\nTWO\n"))
        #expect(clip.title == "a.txt (Clipboard)" && clip.sideLabels.base == "Clipboard" && clip.document === document)
        #expect(clip.baseLines?.joined(separator: "\n") == "one\nTWO\n" && clip.currentLines.joined(separator: "\n") == "one\ntwo\n")
        await clip.refreshCompare()
        #expect(clip.hunks.count == 1)
        // Again: the same tab, with the clipboard as it is now.
        #expect(workspace.compareWithClipboard(url, text: "one\ntwo\n") === clip)
        await clip.refreshCompare()
        #expect(clip.hunks.isEmpty)

        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "ONE")
        let saved = try #require(workspace.compareWithSaved(url))
        #expect(saved.title == "a.txt (Saved ↔ Edited)" && saved.sideLabels == ("Saved", "Edited"))
        #expect(saved.baseLines?.joined(separator: "\n") == "one\ntwo\n" && saved.currentLines.first == "ONE")
        await saved.refreshCompare()
        #expect(saved.hunks.count == 1)
    }

    @Test func filesTitlesSwapAndBinary() async throws {
        let left = try makeFolder(["a.txt": "a\n", "x/same.txt": "1\n", "bin.dat": "\u{0}\u{1}"])
        let right = try makeFolder(["b.txt": "b\n", "y/same.txt": "2\n", "bin.dat": "\u{0}\u{2}"])
        let a = left.appending(path: "a.txt"), b = right.appending(path: "b.txt")
        let workspace = Workspace()

        let session = try #require(workspace.compareFiles(a, b))
        #expect(session.title == "a.txt ↔ b.txt" && session.sideLabels == ("a.txt", "b.txt") && session.url == b && session.document != nil)
        #expect(session.baseLines?.first == "a" && session.currentLines.first == "b")
        #expect(workspace.compareFiles(a, b) === session)
        // The same name: the folders tell them apart.
        #expect(workspace.compareFiles(left.appending(path: "x/same.txt"), right.appending(path: "y/same.txt"))?.title == "x/same.txt ↔ y/same.txt")
        #expect(FileComparison.distinctNames(URL(filePath: "/p/a/src/m.swift"), URL(filePath: "/p/b/src/m.swift")) == ("a/…/m.swift", "b/…/m.swift"))

        workspace.activeGroup.show(session.id)
        workspace.swapSides(of: session)
        #expect(workspace.diffSession(id: session.id) == nil)
        let swapped = try #require(workspace.diffSession(id: workspace.activeGroup.activeDocumentID))
        #expect(swapped.mode == .files(.file(b)) && swapped.url == a && swapped.title == "b.txt ↔ a.txt")

        let binary = try #require(workspace.compareFiles(left.appending(path: "bin.dat"), right.appending(path: "bin.dat")))
        #expect(binary.binaryDifference == true && binary.document == nil)
        let identical = try #require(workspace.compareFiles(left.appending(path: "bin.dat"), left.appending(path: "bin.dat")))
        #expect(identical.binaryDifference == false)

        // Explorer: Select for Compare, then Compare with Selected on the same kind only.
        workspace.comparisons.selected = a
        #expect(workspace.canCompareWithSelected(b) && !workspace.canCompareWithSelected(a) && !workspace.canCompareWithSelected(right))
        workspace.comparisons.selected = left
        #expect(workspace.canCompareWithSelected(right))
    }
}
