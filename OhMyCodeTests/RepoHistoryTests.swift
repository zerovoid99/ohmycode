import AppKit
import Testing
@testable import Oh_My_Code

struct RepoLogParserTests {
    @Test func parsesCommitsRefsAndFiles() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let log = "\u{1e}\(b)\u{1f}\(a)\u{1f}Bob\u{1f}1700000100\u{1f}HEAD -> main, origin/main, tag: v2\u{1f}Second\n"
            + "\u{1e}\(a)\u{1f}\u{1f}Ann\u{1f}1700000000\u{1f}\u{1f}First, with a comma\n"
        let commits = RepoCommit.parseLog(Data(log.utf8))
        #expect(commits.map(\.summary) == ["Second", "First, with a comma"])
        #expect(commits[0].refs == ["HEAD -> main", "origin/main", "tag: v2"] && commits[1].refs.isEmpty)
        #expect(commits[1].parents.isEmpty && commits[0].parents == [a])

        let files = CommitFile.parse(Data("R087\0old/x.txt\0new/x.txt\0A\0n.txt\0D\0gone.txt\0M\0m.txt\0".utf8))
        #expect(files.map(\.change) == [.renamed, .added, .deleted, .modified])
        #expect(files[0].originalPath == "old/x.txt" && files[0].path == "new/x.txt" && files[0].directory == "new")

        // As a file-history entry: which paths to read on each side.
        let renamed = commits[0].change(to: files[0])
        #expect(renamed.path == "new/x.txt" && renamed.parentPath == "old/x.txt")
        #expect(commits[0].change(to: files[1]).parentPath == nil)   // added: nothing before
        #expect(commits[0].change(to: files[2]).path == nil)         // deleted: nothing after
        #expect(commits[1].change(to: files[3]).parentPath == nil)   // root commit
    }
}

@MainActor
struct RepoHistoryWorkspaceTests {
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=Alice", "-c", "user.email=a@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// The workspace is `sub/` inside the repository; one commit touches a file outside it.
    @Test func pagesTheLogListsFilesAndBranches() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "omc-repolog-\(UUID().uuidString)")
        let root = repo.appending(path: "sub")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["init", "-q", "-b", "main"], in: repo)
        try "one\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-qm", "First"], in: repo)
        _ = try git(["tag", "v1"], in: repo)
        try "readme\n".write(to: repo.appending(path: "README"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-qm", "Readme outside the folder"], in: repo)
        _ = try git(["mv", "sub/a.txt", "sub/b.txt"], in: repo)
        try "one\ntwo\n".write(to: root.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-qm", "Rename and grow"], in: repo)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitRepository != nil })
        #expect(workspace.repositoryRootURL?.standardizedFileURL.path == repo.standardizedFileURL.path)

        // Pages of two: then the rest.
        workspace.repoHistoryPageSize = 2
        workspace.loadRepoHistory()
        await workspace.waitForRepoHistory()
        #expect(workspace.repoHistory?.commits.map(\.summary) == ["Rename and grow", "Readme outside the folder"])
        #expect(workspace.repoHistory?.hasMore == true)
        workspace.loadRepoHistory(more: true)
        await workspace.waitForRepoHistory()
        let commits = try #require(workspace.repoHistory?.commits)
        #expect(commits.map(\.summary) == ["Rename and grow", "Readme outside the folder", "First"])
        #expect(workspace.repoHistory?.hasMore == false)
        #expect(commits[0].refs == ["HEAD -> main"] && commits[2].refs == ["tag: v1"])

        // A commit's files; the rename's diff reads the parent by the old name.
        await workspace.loadFiles(of: commits[0])
        let files = try #require(workspace.commitFiles[commits[0].sha])
        #expect(files.map(\.path) == ["sub/b.txt"] && files[0].change == .renamed && files[0].originalPath == "sub/a.txt")
        let rename = try #require(workspace.openCommit(commits[0], file: files[0]))
        #expect(try await eventually { rename.isLoaded })
        #expect(rename.baseLines == ["one", ""] && rename.hunks == [DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 1)])
        // A file outside the workspace folder opens too.
        await workspace.loadFiles(of: commits[1])
        let readme = try #require(workspace.commitFiles[commits[1].sha]?.first)
        let readmeDiff = try #require(workspace.openCommit(commits[1], file: readme))
        #expect(readmeDiff.url.lastPathComponent == "README")
        #expect(try await eventually { readmeDiff.isLoaded && readmeDiff.currentLines == ["readme", ""] })

        // Create a branch at the first commit (and switch to it); the log shows it on refresh,
        // and still lists main's newer commits.
        workspace.sidebarMode = .history
        workspace.historyScope = .repository
        workspace.branchNamePrompt = { _ in " feature/old " }
        workspace.createBranch(at: commits[2])
        #expect(try await eventually { workspace.repoHistory?.commits.last?.refs == ["HEAD -> feature/old", "tag: v1"] })
        #expect(workspace.repoHistory?.commits.map(\.sha) == commits.map(\.sha))
        #expect(workspace.repoHistory?.commits.first?.refs == ["main"])
        #expect(try git(["branch", "--show-current"], in: repo) == "feature/old")

        // Detached checkout: nothing unless confirmed.
        workspace.checkoutConfirmation = { _ in false }
        workspace.checkoutDetached(commits[1])
        try await Task.sleep(for: .milliseconds(200))
        #expect(try git(["rev-parse", "HEAD"], in: repo) == commits[2].sha)
        workspace.checkoutConfirmation = { _ in true }
        workspace.checkoutDetached(commits[1])
        #expect(try await eventually { (try? self.git(["rev-parse", "HEAD"], in: repo)) == commits[1].sha })
        #expect(try git(["branch", "--show-current"], in: repo).isEmpty)
        withExtendedLifetime(workspace) {}
    }
}
