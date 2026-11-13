import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct CherryPickRevertTests {
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
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func write(_ text: String, _ name: String, in root: URL) throws {
        try text.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String, in root: URL) -> String? {
        try? String(contentsOf: root.appending(path: name), encoding: .utf8)
    }

    /// main: base; feature: adds x.txt, then changes f.txt; main then changes f.txt too.
    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: root)
        for (key, value) in [("user.name", "A"), ("user.email", "a@example.invalid"), ("commit.gpgsign", "false")] {
            try git(["config", key, value], in: root)
        }
        try write("base\n", "f.txt", in: root)
        try git(["add", "."], in: root); try git(["commit", "-qm", "Base"], in: root)
        try git(["switch", "-qc", "feature"], in: root)
        try write("x\n", "x.txt", in: root)
        try git(["add", "."], in: root); try git(["commit", "-qm", "Add x"], in: root)
        try write("feature\n", "f.txt", in: root)
        try git(["commit", "-qam", "Feature f"], in: root)
        try git(["switch", "-q", "main"], in: root)
        try write("main\n", "f.txt", in: root)
        try git(["commit", "-qam", "Main f"], in: root)
        return root
    }

    private func open(_ root: URL) async throws -> Workspace {
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus?.hasCommits == true })
        workspace.confirmation = { _ in true }
        workspace.loadRepoHistory()
        await workspace.waitForRepoHistory()
        return workspace
    }

    private func commit(_ summary: String, in workspace: Workspace) throws -> RepoCommit {
        try #require(workspace.repoHistory?.commits.first { $0.summary == summary })
    }

    @Test func cherryPicksCleanlyAndThroughAConflict() async throws {
        let root = try makeRepository()
        let workspace = try await open(root)

        workspace.cherryPick(try commit("Add x", in: workspace))
        #expect(try await eventually { self.read("x.txt", in: root) == "x\n" })
        #expect(try git(["log", "-1", "--format=%s"], in: root) == "Add x")
        #expect(try git(["branch", "--show-current"], in: root) == "main")

        // Conflicting: a cherry-pick stays in progress; resolve, stage, continue.
        workspace.cherryPick(try commit("Feature f", in: workspace))
        #expect(try await eventually { workspace.gitStatus?.operation == .cherryPick })
        #expect(workspace.gitStatus?.changes.first { $0.path == "f.txt" }?.isConflicted == true)
        try write("both\n", "f.txt", in: root)
        workspace.stage(["f.txt"])
        #expect(try await eventually { workspace.gitStatus?.changes.contains { $0.isConflicted } == false })
        workspace.resolveOperation(.continue)
        #expect(try await eventually { workspace.gitStatus?.operation == nil })
        #expect(try git(["log", "-1", "--format=%s"], in: root) == "Feature f")
        #expect(try git(["show", "HEAD:f.txt"], in: root) == "both")
        withExtendedLifetime(workspace) {}
    }

    @Test func revertsAfterAskingAndAbortsAConflict() async throws {
        let root = try makeRepository()
        let workspace = try await open(root)
        let main = try commit("Main f", in: workspace)

        // "No": nothing.
        var asked: [String] = []
        workspace.confirmation = { asked.append($0); return false }
        workspace.revertCommit(main)
        try await Task.sleep(for: .milliseconds(300))
        #expect(asked.count == 1 && asked[0].contains("Main f"))
        #expect(try git(["rev-list", "--count", "HEAD"], in: root) == "2")

        // "Yes": a new commit puts f.txt back.
        workspace.confirmation = { _ in true }
        workspace.revertCommit(main)
        #expect(try await eventually { (try? self.git(["rev-list", "--count", "HEAD"], in: root)) == "3" })
        #expect(try git(["log", "-1", "--format=%s"], in: root) == "Revert \"Main f\"")
        #expect(read("f.txt", in: root) == "base\n")

        // Reverting the base now conflicts (f.txt changed since): a revert in progress, then abort.
        try write("later\n", "f.txt", in: root)
        try git(["commit", "-qam", "Later"], in: root)
        workspace.loadRepoHistory()
        await workspace.waitForRepoHistory()
        workspace.revertCommit(try commit("Base", in: workspace))
        #expect(try await eventually { workspace.gitStatus?.operation == .revert })
        workspace.resolveOperation(.abort)
        #expect(try await eventually { workspace.gitStatus?.operation == nil })
        #expect(read("f.txt", in: root) == "later\n")
        withExtendedLifetime(workspace) {}
    }

    @Test func revertsAMergeAgainstItsFirstParent() async throws {
        let root = try makeRepository()
        try git(["merge", "-q", "--no-ff", "-X", "theirs", "-m", "Merge feature", "feature"], in: root)
        #expect(read("x.txt", in: root) == "x\n")
        let workspace = try await open(root)
        let merge = try commit("Merge feature", in: workspace)
        #expect(merge.parents.count == 2)
        workspace.revertCommit(merge)
        #expect(try await eventually { self.read("x.txt", in: root) == nil }) // the feature's file is gone again
        #expect(read("f.txt", in: root) == "main\n")
        withExtendedLifetime(workspace) {}
    }
}
