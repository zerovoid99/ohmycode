import AppKit
import Testing
@testable import Oh_My_Code

@discardableResult
private func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/git")
    // Local paths as submodule URLs need the file protocol (off by default since git 2.38.1).
    process.arguments = ["-C", directory.path, "-c", "user.name=A", "-c", "user.email=a@example.invalid",
                         "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"] + arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(8)
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}

private func temporaryFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "omc-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct WorktreeParsingTests {
    @Test func parsesWorktreeList() {
        let output = """
        worktree /repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /repo-feature
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/team/feature
        locked

        worktree /gone
        HEAD 3333333333333333333333333333333333333333
        detached
        prunable gitdir file points to non-existent location

        """
        let worktrees = GitWorktree.parse(Data(output.utf8))
        #expect(worktrees.map(\.path) == ["/repo", "/repo-feature", "/gone"])
        #expect(worktrees.map(\.branch) == ["main", "team/feature", nil])
        #expect(worktrees[1].isLocked && !worktrees[0].isLocked)
        #expect(worktrees[2].isPrunable && worktrees[2].head?.hasPrefix("333") == true)
    }
}

@MainActor
struct WorktreeTests {
    /// main with a commit, a local `feature` branch, and `origin/remote-only` fetched.
    private func makeRepository() throws -> (base: URL, root: URL) {
        let base = try temporaryFolder("worktrees")
        let root = base.appending(path: "app"), origin = base.appending(path: "origin.git"), other = base.appending(path: "other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", "-b", "main", origin.path], in: base)
        try git(["init", "-q", "-b", "main"], in: root)
        try "x\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "first"], in: root)
        try git(["branch", "feature"], in: root)
        try git(["remote", "add", "origin", origin.path], in: root)
        try git(["push", "-q", "origin", "main"], in: root)
        try git(["clone", "-q", origin.path, other.path], in: base)
        try git(["switch", "-qc", "remote-only"], in: other)
        try "r\n".write(to: other.appending(path: "r.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: other)
        try git(["commit", "-qm", "remote"], in: other)
        try git(["push", "-q", "origin", "remote-only"], in: other)
        try git(["fetch", "-q", "origin"], in: root)
        return (base, root)
    }

    @Test func createsOpensAndRemovesWorktrees() async throws {
        let (base, root) = try makeRepository()
        let workspace = Workspace()
        var opened: [URL] = []
        workspace.openInNewWindow = { opened.append($0) }
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus?.hasCommits == true })
        await workspace.loadWorktrees()
        await workspace.loadBranches()
        let main = try #require(workspace.worktrees?.first)
        #expect(workspace.worktrees?.count == 1 && workspace.isCurrent(main) && main.branch == "main")

        // An existing branch, in the suggested folder beside the repository.
        var suggestions: [String] = []
        workspace.worktreePrompt = { _, suggested in suggestions.append(suggested); return (suggested, nil) }
        let feature = try #require(workspace.branches?.first { $0.name == "feature" })
        await workspace.createWorktree(for: feature)
        let featureFolder = base.appending(path: "app-feature")
        #expect(suggestions == [featureFolder.path])
        #expect(opened.map(\.path) == [featureFolder.path])
        #expect(try git(["branch", "--show-current"], in: featureFolder) == "feature")
        #expect(workspace.worktrees?.count == 2)
        #expect(workspace.worktrees?.contains { $0.branch == "feature" && !workspace.isCurrent($0) } == true)

        // A remote branch: a local branch tracking it.
        let remote = try #require(workspace.branches?.first { $0.name == "origin/remote-only" })
        await workspace.createWorktree(for: remote)
        let remoteFolder = base.appending(path: "app-remote-only")
        #expect(try git(["branch", "--show-current"], in: remoteFolder) == "remote-only")
        #expect(try git(["rev-parse", "--abbrev-ref", "remote-only@{upstream}"], in: root) == "origin/remote-only")
        #expect(FileManager.default.fileExists(atPath: remoteFolder.appending(path: "r.txt").path))

        // A new branch from HEAD, in a folder of our choosing.
        let freshFolder = base.appending(path: "elsewhere")
        workspace.worktreePrompt = { _, _ in (freshFolder.path, "fresh") }
        await workspace.createWorktree(for: nil)
        #expect(try git(["branch", "--show-current"], in: freshFolder) == "fresh")
        #expect(workspace.worktrees?.count == 4 && opened.count == 3)

        // A branch checked out elsewhere can't be checked out again: git says so, nothing opens.
        workspace.worktreePrompt = { _, _ in (base.appending(path: "again").path, nil) }
        await workspace.createWorktree(for: feature)
        #expect(workspace.errorMessage != nil && opened.count == 3 && workspace.worktrees?.count == 4)
        workspace.errorMessage = nil

        // Removing: asked first; uncommitted changes are asked about again before forcing.
        let fresh = try #require(workspace.worktrees?.first { $0.branch == "fresh" })
        try "dirty\n".write(to: freshFolder.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        var questions: [String] = []
        workspace.confirmation = { questions.append($0); return questions.count == 1 }
        await workspace.removeWorktree(fresh)
        #expect(questions.count == 2 && questions[1].contains("aren't committed"))
        #expect(FileManager.default.fileExists(atPath: freshFolder.path) && workspace.worktrees?.count == 4)
        workspace.confirmation = { _ in true }
        await workspace.removeWorktree(fresh)
        #expect(try await eventually { workspace.worktrees?.count == 3 && !workspace.isRunningGitCommand })
        #expect(!FileManager.default.fileExists(atPath: freshFolder.path))
        #expect(try git(["branch", "--list", "fresh"], in: root).contains("fresh")) // the branch stays

        // A clean one goes after one question; this window's own can't be removed.
        let featureTree = try #require(workspace.worktrees?.first { $0.branch == "feature" })
        questions = []
        workspace.confirmation = { questions.append($0); return true }
        await workspace.removeWorktree(featureTree)
        #expect(questions.count == 1 && workspace.worktrees?.count == 2)
        await workspace.removeWorktree(main)
        #expect(questions.count == 1 && workspace.worktrees?.count == 2)

        // Opening one opens its folder.
        let remoteTree = try #require(workspace.worktrees?.first { $0.branch == "remote-only" })
        workspace.openWorktree(remoteTree)
        #expect(opened.last?.standardizedFileURL.path == remoteFolder.path)
        #expect(workspace.errorMessage == nil)
    }
}
