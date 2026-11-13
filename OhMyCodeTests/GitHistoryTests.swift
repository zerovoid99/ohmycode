import AppKit
import Testing
@testable import Oh_My_Code

struct GitLogParserTests {
    @Test func followsRenamesBackwards() {
        let sha = { (c: Character) in String(repeating: c, count: 40) }
        let log = """
        \u{1e}\(sha("d"))\u{1f}\(sha("m"))\u{1f}Dee\u{1f}1700000400\u{1f}Edit after merge

        M\tsub/new.txt
        \u{1e}\(sha("m"))\u{1f}\(sha("c")) \(sha("x"))\u{1f}Em\u{1f}1700000300\u{1f}Merge branch
        \u{1e}\(sha("c"))\u{1f}\(sha("b"))\u{1f}Cee\u{1f}1700000200\u{1f}Rename

        R087\tsub/old.txt\tsub/new.txt
        \u{1e}\(sha("b"))\u{1f}\(sha("a"))\u{1f}Bee\u{1f}1700000100\u{1f}Tweak: a\u{1f}b in subject

        M\tsub/old.txt
        \u{1e}\(sha("a"))\u{1f}\u{1f}Ay\u{1f}1700000000\u{1f}First

        A\tsub/old.txt

        """
        let commits = GitCommit.parseLog(Data(log.utf8), currentPath: "sub/new.txt")
        #expect(commits.map(\.author) == ["Dee", "Em", "Cee", "Bee", "Ay"])
        #expect(commits.map(\.change) == [.modified, .modified, .renamed, .modified, .added])
        // A merge has no status line: it keeps the path of the commit above it.
        #expect(commits[1].path == "sub/new.txt" && commits[1].parents.count == 2)
        #expect(commits[2].path == "sub/new.txt" && commits[2].parentPath == "sub/old.txt")
        #expect(commits[3].path == "sub/old.txt" && commits[3].summary == "Tweak: a\u{1f}b in subject")
        #expect(commits[4].parentPath == nil && commits[4].parents.isEmpty) // root commit
        #expect(commits[4].date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(commits[0].shortSHA == "ddddddd" && commits[0].fileName == "new.txt")
    }
}

@MainActor
struct GitHistoryWorkspaceTests {
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=Alice", "-c", "user.email=a@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// The workspace is a folder inside the repository; the file was renamed along the way.
    @Test func showsHistoryCommitsAndComparesWithTheBuffer() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "omc-history-\(UUID().uuidString)")
        let root = repo.appending(path: "sub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        try "a\nb\nc\n".write(to: root.appending(path: "old.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-qm", "First"], in: repo)
        try "a\nB\nc\n".write(to: root.appending(path: "old.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "Shout b"], in: repo)
        try git(["mv", "sub/old.txt", "sub/new.txt"], in: repo)
        try git(["commit", "-qm", "Rename"], in: repo)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitRepository != nil })
        let url = root.appending(path: "new.txt")
        workspace.open(fileAt: url)
        workspace.showFileHistory()
        #expect(workspace.sidebarMode == .history)
        await workspace.waitForHistory()
        let commits = try #require(workspace.fileHistory?.commits)
        #expect(commits.map(\.summary) == ["Rename", "Shout b", "First"])
        #expect(commits.map(\.change) == [.renamed, .modified, .added])

        // What "Shout b" changed, read from the old name.
        let shout = workspace.openCommit(commits[1], for: url)
        #expect(workspace.tabInfo(shout.id)?.title == "new.txt (\(commits[1].shortSHA))")
        #expect(try await eventually { shout.isLoaded })
        #expect(shout.hunks == [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)])
        #expect(shout.baseLines?[1] == "b" && shout.currentLines[1] == "B")
        #expect(shout.sideLabels.current == commits[1].shortSHA)
        #expect(workspace.openCommit(commits[1], for: url) === shout)
        // The rename moved the file without changing it: the parent's side is read by the old name.
        let rename = workspace.openCommit(commits[0], for: url)
        #expect(try await eventually { rename.isLoaded })
        #expect(rename.baseLines == ["a", "B", "c", ""] && rename.hunks.isEmpty && !rename.isNewFile)
        // The first commit added the file: everything is new.
        let first = workspace.openCommit(commits[2], for: url)
        #expect(try await eventually { first.isLoaded })
        #expect(first.isNewFile && first.hunks == [DiffHunk(oldStart: 0, oldCount: 0, newStart: 0, newCount: 3)])

        // Against the buffer, live: unsaved edits count.
        let document = try #require(workspace.document(matching: url))
        let compare = try #require(workspace.compare(commits[2], with: url))
        #expect(compare.document === document && compare.title == "new.txt (\(commits[2].shortSHA) ↔ Current)")
        #expect(try await eventually { compare.isLoaded })
        await compare.refreshCompare()
        #expect(compare.hunks == [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)])
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "A")
        await document.waitForDiff()
        await compare.refreshCompare()
        #expect(compare.hunks == [DiffHunk(oldStart: 0, oldCount: 2, newStart: 0, newCount: 2)])

        // A new commit shows up in the Timeline.
        try document.save()
        try git(["commit", "-qam", "Capital A"], in: repo)
        workspace.refreshGit()
        #expect(try await eventually { workspace.fileHistory?.commits?.first?.summary == "Capital A" })
        withExtendedLifetime(workspace) {}
    }
}
