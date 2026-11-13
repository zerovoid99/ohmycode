import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct AmendUndoTests {
    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-amend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: root)
        for (key, value) in [("user.name", "A"), ("user.email", "a@example.invalid"), ("commit.gpgsign", "false")] {
            try git(["config", key, value], in: root)
        }
        return root
    }

    @Test func statusKnowsAnEmptyRepository() {
        #expect(!GitStatus.parse(Data("# branch.oid (initial)\0# branch.head main\0".utf8), prefix: "").hasCommits)
        #expect(GitStatus.parse(Data("# branch.oid 1234abcd\0# branch.head main\0".utf8), prefix: "").hasCommits)
    }

    @Test func amendsAndUndoesCommits() async throws {
        let root = try makeRepository()
        let a = root.appending(path: "a.txt"), b = root.appending(path: "b.txt")
        try "a\n".write(to: a, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "First"], in: root)
        try "b\n".write(to: b, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "Add b\n\nWith a body."], in: root)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus?.hasCommits == true })
        workspace.confirmation = { _ in true }
        #expect(await workspace.lastCommitMessage() == "Add b\n\nWith a body.")

        // Amend with an empty message: the staged change joins the commit, the message stays.
        try "b\nfix\n".write(to: b, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        workspace.refreshGit()
        #expect(try await eventually { workspace.gitStatus?.stagedChanges.count == 1 })
        #expect(await workspace.amend(message: "  "))
        #expect(try git(["rev-list", "--count", "HEAD"], in: root) == "2")
        #expect(try git(["log", "-1", "--format=%B"], in: root) == "Add b\n\nWith a body.")
        #expect(try git(["show", "HEAD:b.txt"], in: root) == "b\nfix")
        // With a message: just the message changes.
        #expect(await workspace.amend(message: "Add b (fixed)"))
        #expect(try git(["log", "-1", "--format=%s"], in: root) == "Add b (fixed)")

        // Undo: the commit goes, its changes are staged, its message comes back.
        #expect(try await eventually { workspace.gitStatus?.stagedChanges.isEmpty == true })
        let undone = await workspace.undoLastCommit()
        #expect(undone == "Add b (fixed)")
        #expect(try git(["rev-list", "--count", "HEAD"], in: root) == "1")
        #expect(try await eventually { workspace.gitStatus?.stagedChanges.map(\.path) == ["b.txt"] })
        #expect(try String(contentsOf: b, encoding: .utf8) == "b\nfix\n")

        // Saying no undoes nothing.
        workspace.confirmation = { _ in false }
        #expect(await workspace.undoLastCommit() == nil)
        #expect(try git(["rev-list", "--count", "HEAD"], in: root) == "1")

        // The very first commit: the branch is unborn again, everything staged.
        workspace.confirmation = { _ in true }
        #expect(await workspace.undoLastCommit() == "First")
        #expect(try await eventually { workspace.gitStatus?.hasCommits == false })
        #expect(workspace.gitStatus?.stagedChanges.map(\.path).sorted() == ["a.txt", "b.txt"])
        #expect(await workspace.undoLastCommit() == nil) // nothing left to undo
        withExtendedLifetime(workspace) {}
    }

    @Test func warnsBeforeRewritingAPushedCommit() async throws {
        let root = try makeRepository()
        let origin = root.deletingLastPathComponent().appending(path: "origin-\(UUID().uuidString).git")
        try git(["init", "-q", "--bare", "-b", "main", origin.path], in: root)
        try git(["remote", "add", "origin", origin.path], in: root)
        try "a\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "Pushed"], in: root)
        try git(["push", "-q", "-u", "origin", "main"], in: root)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus?.hasCommits == true })
        var questions: [String] = []
        workspace.confirmation = { questions.append($0); return false }
        #expect(!(await workspace.amend(message: "Rewritten")))
        #expect(await workspace.undoLastCommit() == nil)
        #expect(questions.count == 2 && questions.allSatisfy { $0.contains("force push") })
        #expect(try git(["log", "-1", "--format=%s"], in: root) == "Pushed")

        // A local commit on top isn't pushed: no warning for it.
        try "b\n".write(to: root.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "Local"], in: root)
        questions = []
        #expect(await workspace.amend(message: "Local, amended"))
        #expect(questions.isEmpty)
        withExtendedLifetime(workspace) {}
    }
}
