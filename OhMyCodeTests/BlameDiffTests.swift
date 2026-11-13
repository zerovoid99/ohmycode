import AppKit
import Testing
@testable import Oh_My_Code

struct BlameParserTests {
    @Test func parsesPorcelainWithRepeatedCommits() {
        let a = String(repeating: "a", count: 40), z = String(repeating: "0", count: 40)
        let output = """
        \(a) 1 1 2
        author Alice
        author-mail <alice@example.com>
        author-time 1700000000
        author-tz +0000
        summary First commit
        filename f.txt
        \tline one
        \(a) 2 2
        \tline two
        \(z) 3 3 1
        author Not Committed Yet
        author-time 1800000000
        summary Version of f.txt from f.txt
        filename f.txt
        \tnew line

        """
        let lines = BlameLine.parse(Data(output.utf8))
        #expect(lines.count == 3)
        #expect(lines[0]?.author == "Alice" && lines[1]?.author == "Alice")   // metadata given once per commit
        #expect(lines[1]?.summary == "First commit")
        #expect(lines[1]?.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(lines[2]?.isUncommitted == true && lines[0]?.isUncommitted == false)
    }

    @Test func describesTheChange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 3 * 86_400)
        let blame = BlameLine(commit: String(repeating: "a", count: 40), author: "Alice",
                              date: Date(timeIntervalSince1970: 1_700_000_000), summary: "Fix it")
        #expect(EditorController.describe(blame, now: now) == "Alice, 3 days ago • Fix it")
        let uncommitted = BlameLine(commit: String(repeating: "0", count: 40), author: "x", date: now, summary: "")
        #expect(EditorController.describe(uncommitted) == "Not committed yet")
    }
}

struct DiffRowTests {
    @Test func pairsChangesAndCollapsesUnchangedRuns() {
        // 20 lines; line 10 changed, a line added after 15, line 18 removed (old numbering).
        let hunks = [DiffHunk(oldStart: 10, oldCount: 1, newStart: 10, newCount: 1),
                     DiffHunk(oldStart: 16, oldCount: 0, newStart: 16, newCount: 1),
                     DiffHunk(oldStart: 18, oldCount: 1, newStart: 19, newCount: 0)]
        let rows = DiffRow.rows(hunks: hunks, oldCount: 20, newCount: 20)
        // The leading run keeps 3 lines of context before the change, collapsing 0…6.
        #expect(rows.first?.kind == .skipped(7))
        let changed = rows.filter { $0.kind != .same && !$0.isSkipped }
        #expect(changed.map(\.kind) == [.changed, .added, .removed])
        #expect(changed.map(\.old) == [10, nil, 18] && changed.map(\.new) == [10, 16, nil])
        // Every line appears once on each side (counting collapsed ones).
        let oldLines = rows.reduce(0) { total, row in
            if case .skipped(let n) = row.kind { return total + n }
            return total + (row.old == nil ? 0 : 1)
        }
        #expect(oldLines == 20)

        let expanded = DiffRow.rows(hunks: hunks, oldCount: 20, newCount: 20, expanded: [0])
        #expect(!expanded.contains { $0.isSkipped })
    }
}

struct HunkPatchTests {
    @Test func appliesAndRevertsOneHunkKeepingTheOthers() {
        let old = LineDiff.lines("a\nb\nc\nd\ne\n")
        let new = LineDiff.lines("a\nB\nc\nd\ne\nf\n")
        let hunks = LineDiff.hunks(base: old, current: new)
        #expect(hunks.count == 2)
        // Staging only the first change; then only the second (an addition at the end of the file).
        #expect(LineDiff.applying(hunks[0], old: old, new: new) == "a\nB\nc\nd\ne\n")
        #expect(LineDiff.applying(hunks[1], old: old, new: new) == "a\nb\nc\nd\ne\nf\n")
        // Unstaging takes the change back out of the new side only.
        #expect(LineDiff.reverting(hunks[0], old: old, new: new) == "a\nb\nc\nd\ne\nf\n")
        #expect(LineDiff.reverting(hunks[1], old: old, new: new) == "a\nB\nc\nd\ne\n")

        // A deletion, and a missing final newline, round-trip exactly.
        let noNewline = LineDiff.lines("a\nc")
        let deletion = LineDiff.hunks(base: old, current: noNewline)
        var staged = old
        for hunk in deletion.reversed() { staged = LineDiff.lines(LineDiff.applying(hunk, old: staged, new: noNewline)) }
        #expect(staged.joined(separator: "\n") == "a\nc")
    }
}

@MainActor
struct BlameDiffWorkspaceTests {
    private func git(_ arguments: [String], author: String = "Alice", in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=\(author)", "-c", "user.email=\(author.lowercased())@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func output(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Alice commits three lines, Bob changes the second.
    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-blame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        try "one\ntwo\nthree\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-q", "-m", "First lines"], in: root)
        try "one\nTWO\nthree\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "Shout two"], author: "Bob", in: root)
        return root
    }

    @Test func blamesTheBufferAndShowsTheCursorLine() async throws {
        let root = try makeRepository()
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "f.txt"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually { document.blame?.count == 3 })
        #expect(document.blame?.map { $0?.author } == ["Alice", "Bob", "Alice"])
        #expect(document.blame?[1]?.summary == "Shout two")

        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0)) // line 2
        let annotation = try #require(controller.blameAnnotation())
        #expect(annotation.text.hasPrefix("Bob, ") && annotation.text.hasSuffix("• Shout two"))
        let lineEnd = try #require(controller.rect(for: NSRange(location: 6, length: 1)))
        #expect(annotation.origin.x > lineEnd.maxX && abs(annotation.origin.y - lineEnd.minY) < 1)

        // Unsaved edits are blamed as not committed, with line numbers matching the buffer.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "zero\n")
        #expect(document.blame == nil) // hidden while the numbers are stale
        #expect(try await eventually { document.blame?.count == 4 })
        #expect(document.blame?[0]?.isUncommitted == true && document.blame?[2]?.author == "Bob")

        AppSettings.shared.showsLineBlame = false
        defer { AppSettings.shared.showsLineBlame = true }
        #expect(controller.blameAnnotation() == nil)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func openChangesShowsADiffTabThatFollowsEdits() async throws {
        let root = try makeRepository()
        try "one\nTWO\nthree\nfour\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try "keep\n".write(to: root.appending(path: "other.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitRepository != nil })
        workspace.open(fileAt: root.appending(path: "other.txt"))
        let group = workspace.activeGroup

        // The file isn't open: it gets opened for the diff only, without a tab of its own.
        let session = try #require(workspace.openChanges(for: root.appending(path: "f.txt")))
        #expect(group.activeDocumentID == session.id)
        #expect(workspace.tabInfo(session.id)?.title == "f.txt (Changes)")
        #expect(workspace.activeDocument == nil) // a diff tab, not an editor
        let document = try #require(session.document)
        #expect(!group.contains(document.id))
        #expect(try await eventually { document.diffHunks == [DiffHunk(oldStart: 3, oldCount: 0, newStart: 3, newCount: 1)] })

        // Live: editing the document updates the hunks the view renders.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "ONE")
        await document.waitForDiff()
        #expect(document.diffHunks.count == 2)
        #expect(workspace.openChanges(for: root.appending(path: "f.txt")) === session) // reused

        // Closing the diff closes the document it opened (unchanged: undo the edit first).
        document.undoManager.removeAllActions()
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "one")
        try document.save()
        workspace.closeTab(session.id, in: group)
        #expect(workspace.diffSessions.isEmpty)
        #expect(!workspace.documents.contains { $0 === document })
        #expect(workspace.activeDocument?.fileName == "other.txt")

        // A document that has a tab stays open when its diff closes; Close All closes diff tabs too.
        workspace.open(fileAt: root.appending(path: "f.txt"))
        let opened = try #require(workspace.activeDocument)
        let second = try #require(workspace.openChanges(for: opened.url))
        workspace.closeTab(second.id, in: workspace.activeGroup)
        #expect(workspace.documents.contains { $0 === opened })
        workspace.openChanges(for: opened.url)
        workspace.closeAll()
        #expect(workspace.diffSessions.isEmpty && workspace.documents.isEmpty)
        withExtendedLifetime(workspace) {}
    }

    /// The workspace is a folder inside the repository, so index paths need its prefix.
    @Test func stagesAndUnstagesSingleHunks() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "omc-hunks-\(UUID().uuidString)")
        let root = repo.appending(path: "sub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try original.write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "Lines"], in: repo)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitRepository != nil })
        workspace.open(fileAt: root.appending(path: "f.txt"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually { document.diffBaseLines != nil })

        // Two unsaved changes in the buffer: line 2 and line 19.
        let text = document.textStorage.mutableString
        document.textStorage.replaceCharacters(in: text.range(of: "line 19"), with: "LINE 19")
        document.textStorage.replaceCharacters(in: text.range(of: "line 2\n"), with: "LINE 2\n")
        await document.waitForDiff()
        #expect(document.diffHunks.count == 2)

        // Stage only the second: the index gets it, the first stays an unstaged change.
        workspace.stageHunk(document.diffHunks[1], of: document)
        #expect(try await eventually { document.diffHunks.count == 1 })
        #expect(document.diffHunks.first?.newStart == 1)
        let staged = try output(["show", ":sub/f.txt"], in: repo)
        #expect(staged == original.replacingOccurrences(of: "line 19", with: "LINE 19"))
        #expect(try String(contentsOf: root.appending(path: "f.txt"), encoding: .utf8) == original) // disk untouched

        // The staged diff shows it (HEAD ↔ index); unstaging it restores the index to HEAD.
        let session = try #require(workspace.openChanges(for: document.url, staged: true))
        #expect(workspace.tabInfo(session.id)?.title == "f.txt (Staged)")
        #expect(try await eventually { session.hunks == [DiffHunk(oldStart: 18, oldCount: 1, newStart: 18, newCount: 1)] })
        #expect(workspace.openChanges(for: document.url, staged: true) === session)
        #expect(workspace.openChanges(for: document.url) !== session) // the working-tree diff is a separate tab
        workspace.unstageHunk(session.hunks[0], in: session)
        #expect(try await eventually { session.isLoaded && session.hunks.isEmpty })
        #expect(try output(["show", ":sub/f.txt"], in: repo) == original)
        #expect(try await eventually { document.diffHunks.count == 2 }) // both unstaged again

        // A hunk computed against an index that changed since is refused, not misapplied.
        let stale = document.diffHunks[0]
        // (Changed in the index only, as another tool would; the file on disk stays as it is.)
        let elsewhere = FileManager.default.temporaryDirectory.appending(path: "omc-blob-\(UUID().uuidString)")
        try original.replacingOccurrences(of: "line 5", with: "x").write(to: elsewhere, atomically: true, encoding: .utf8)
        let blob = try output(["hash-object", "-w", elsewhere.path], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["update-index", "--cacheinfo", "100644,\(blob),sub/f.txt"], in: repo)
        workspace.errorMessage = nil
        workspace.stageHunk(stale, of: document)
        #expect(try await eventually { workspace.errorMessage != nil })
        #expect(workspace.errorMessage?.contains("changed") == true)
        #expect(try output(["show", ":sub/f.txt"], in: repo).contains("\nx\n"))
        withExtendedLifetime(workspace) {}
    }

    @Test func unstagingAllOfANewFileRemovesItFromTheIndex() async throws {
        let root = try makeRepository()
        try "fresh\n".write(to: root.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        try git(["add", "new.txt"], in: root)
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitRepository != nil })
        let session = try #require(workspace.openChanges(for: root.appending(path: "new.txt"), staged: true))
        #expect(try await eventually { session.hunks.count == 1 })
        #expect(session.isNewFile && session.title == "new.txt (Staged)")
        workspace.unstageHunk(session.hunks[0], in: session)
        #expect(try await eventually { session.isLoaded && session.indexLines == nil })
        #expect(try output(["status", "--porcelain"], in: root) == "?? new.txt\n")
        withExtendedLifetime(workspace) {}
    }
}
