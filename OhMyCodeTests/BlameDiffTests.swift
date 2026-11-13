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
        let document = session.document
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
}
