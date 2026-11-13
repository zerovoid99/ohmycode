import AppKit
import Testing
@testable import Oh_My_Code

struct RebasePlanTests {
    private func commit(_ sha: Character, parents: Int = 1) -> RepoCommit {
        RepoCommit(sha: String(repeating: sha, count: 40), parents: Array(repeating: String(repeating: "0", count: 40), count: parents),
                   author: "A", date: Date(), summary: "commit \(sha)", refs: [])
    }

    @Test func validatesSteps() {
        let steps = [RebaseStep(commit: commit("a")), RebaseStep(commit: commit("b")), RebaseStep(commit: commit("c"))]
        #expect(RebaseStep.problem(with: steps) == nil)
        var plan = steps
        plan[0].action = .squash
        #expect(RebaseStep.problem(with: plan)?.contains("first commit") == true)
        plan[0].action = .drop
        plan[1].action = .fixup // the first one kept can't meld either
        #expect(RebaseStep.problem(with: plan)?.contains("first commit") == true)
        #expect(RebaseStep.problem(with: steps.map { var s = $0; s.action = .drop; return s }) == "Every commit would be dropped.")
        plan = steps
        plan[2].action = .reword
        plan[2].message = "  "
        #expect(RebaseStep.problem(with: plan) == "A reworded commit needs a message.")
        #expect(RebaseStep.problem(with: steps + [RebaseStep(commit: commit("m", parents: 2))])?.contains("merge") == true)
    }

    @Test func knowsWhenNothingChanges() {
        var plan = RebasePlan(base: commit("a"), steps: [RebaseStep(commit: commit("a")), RebaseStep(commit: commit("b"))])
        #expect(!plan.changesSomething)
        plan.steps[1].action = .reword               // same message: still nothing
        #expect(!plan.changesSomething)
        plan.steps[1].message = "better"
        #expect(plan.changesSomething)
        plan.steps = plan.original
        plan.steps.swapAt(0, 1)
        #expect(plan.changesSomething)
    }
}

@MainActor
struct InteractiveRebaseTests {
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

    /// c1…c5, each adding its own file (so any order applies cleanly).
    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-rebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: root)
        for (key, value) in [("user.name", "A"), ("user.email", "a@example.invalid"), ("commit.gpgsign", "false")] {
            try git(["config", key, value], in: root)
        }
        for index in 1...5 {
            try "\(index)\n".write(to: root.appending(path: "f\(index).txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: root)
            try git(["commit", "-qm", "c\(index)", "-m", "body of c\(index)"], in: root)
        }
        return root
    }

    private func subjects(_ root: URL) throws -> [String] {
        try git(["log", "--reverse", "--format=%s"], in: root).split(separator: "\n").map(String.init)
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

    @Test func rewordsReordersSquashesAndDrops() async throws {
        let root = try makeRepository()
        try "1\nlocal edit\n".write(to: root.appending(path: "f1.txt"), atomically: true, encoding: .utf8) // uncommitted
        let workspace = try await open(root)
        let c2 = try #require(workspace.repoHistory?.commits.first { $0.summary == "c2" })

        await workspace.planInteractiveRebase(from: c2)
        var plan = try #require(workspace.pendingRebase)
        #expect(plan.steps.map(\.commit.summary) == ["c2", "c3", "c4", "c5"])
        #expect(plan.steps[0].message == "c2\n\nbody of c2") // rewording starts from the whole message

        plan.steps[0].action = .reword
        plan.steps[0].message = "c2, reworded\n\nwith a new body"
        plan.steps.move(fromOffsets: [3], toOffset: 1)      // c2 c5 c3 c4
        plan.steps[2].action = .drop                          // c3
        plan.steps[3].action = .squash                        // c4 into c5
        workspace.startRebase(plan)
        #expect(try await eventually { (try? self.subjects(root)) == ["c1", "c2, reworded", "c5"] })
        #expect(workspace.pendingRebase == nil)
        #expect(try git(["log", "-1", "--skip=1", "--format=%b"], in: root) == "with a new body")
        // Squash keeps both messages (git's comment lines stripped).
        let squashed = try git(["log", "-1", "--format=%B"], in: root)
        #expect(squashed.contains("c5") && squashed.contains("c4") && !squashed.contains("#"))
        let files = try git(["ls-files"], in: root).split(separator: "\n")
        #expect(files == ["f1.txt", "f2.txt", "f4.txt", "f5.txt"])  // c3's file went with it
        // The uncommitted edit came back after the rebase.
        #expect(try await eventually { workspace.gitStatus?.operation == nil })
        #expect(try String(contentsOf: root.appending(path: "f1.txt"), encoding: .utf8) == "1\nlocal edit\n")
        withExtendedLifetime(workspace) {}
    }

    @Test func rebasesFromTheRootCommitWithFixup() async throws {
        let root = try makeRepository()
        let workspace = try await open(root)
        let c1 = try #require(workspace.repoHistory?.commits.last)
        await workspace.planInteractiveRebase(from: c1)
        var plan = try #require(workspace.pendingRebase)
        #expect(plan.steps.count == 5)
        plan.steps[1].action = .fixup // c2 into c1, keeping c1's message
        workspace.startRebase(plan)
        #expect(try await eventually { (try? self.subjects(root)) == ["c1", "c3", "c4", "c5"] })
        #expect(try git(["log", "--reverse", "-1", "--format=%B", "--max-parents=0"], in: root) == "c1\n\nbody of c1")
        withExtendedLifetime(workspace) {}
    }

    @Test func asksBeforeRewritingPushedCommitsAndStopsOnConflicts() async throws {
        let root = try makeRepository()
        let origin = root.deletingLastPathComponent().appending(path: "origin-\(UUID().uuidString).git")
        try git(["init", "-q", "--bare", "-b", "main", origin.path], in: root)
        try git(["remote", "add", "origin", origin.path], in: root)
        try git(["push", "-q", "-u", "origin", "main"], in: root)
        // Two more commits touching the same line: swapping them conflicts.
        for text in ["x\n", "y\n"] {
            try text.write(to: root.appending(path: "f5.txt"), atomically: true, encoding: .utf8)
            try git(["commit", "-qam", "edit \(text.prefix(1))"], in: root)
        }
        let workspace = try await open(root)
        let commits = try #require(workspace.repoHistory?.commits)

        // Pushed: asked, and "no" changes nothing.
        let c4 = try #require(commits.first { $0.summary == "c4" })
        await workspace.planInteractiveRebase(from: c4)
        var plan = try #require(workspace.pendingRebase)
        plan.steps[0].action = .drop
        var questions: [String] = []
        workspace.confirmation = { questions.append($0); return false }
        workspace.startRebase(plan)
        try await Task.sleep(for: .milliseconds(300))
        #expect(questions.count == 1 && questions[0].contains("force push"))
        #expect(try subjects(root).contains("c4"))

        // Local commits only, reordered into a conflict: the rebase stops and can be aborted.
        workspace.confirmation = { _ in true }
        let editX = try #require(commits.first { $0.summary == "edit x" })
        await workspace.planInteractiveRebase(from: editX)
        plan = try #require(workspace.pendingRebase)
        plan.steps.swapAt(0, 1)
        questions = []
        workspace.startRebase(plan)
        #expect(try await eventually { workspace.gitStatus?.operation == .rebase })
        #expect(questions.isEmpty) // nothing pushed in this range
        workspace.resolveOperation(.abort)
        #expect(try await eventually { workspace.gitStatus?.operation == nil })
        #expect(try subjects(root).suffix(2) == ["edit x", "edit y"])
        withExtendedLifetime(workspace) {}
    }
}
