import AppKit
import Testing
@testable import Oh_My_Code

struct GitBranchParserTests {
    @Test func parsesBranchesAndSkipsRemoteHEAD() {
        let rows = [
            "refs/remotes/origin/HEAD\u{1f}origin\u{1f}\u{1f}\u{1f} \u{1f}1700000000\u{1f}x",
            "refs/remotes/origin/feature/x\u{1f}origin/feature/x\u{1f}\u{1f}\u{1f} \u{1f}1700000300\u{1f}Remote work",
            "refs/heads/main\u{1f}main\u{1f}origin/main\u{1f}ahead 1, behind 2\u{1f}*\u{1f}1700000200\u{1f}Tip",
            "refs/heads/old\u{1f}old\u{1f}origin/old\u{1f}gone\u{1f} \u{1f}1700000100\u{1f}Old: with \u{1f} in it",
        ].joined(separator: "\n")
        let branches = GitBranch.parse(Data(rows.utf8))
        #expect(branches.map(\.name) == ["main", "old", "origin/feature/x"]) // local first
        #expect(branches[0].isCurrent && branches[0].tracking == "ahead 1, behind 2" && branches[0].upstream == "origin/main")
        #expect(branches[1].tracking == "gone" && branches[1].subject == "Old: with \u{1f} in it")
        #expect(branches[2].isRemote && branches[2].localName == "feature/x" && branches[2].upstream == nil)
    }

    /// Nothing may wait for input nobody can type: no password prompt, no editor, no SSH questions.
    @Test func gitRunsNonInteractively() throws {
        let folder = FileManager.default.temporaryDirectory
        let output = try #require(Git.run(["-c", "alias.environment=!env", "environment"], in: folder))
        let environment = Set(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(environment.contains("GIT_TERMINAL_PROMPT=0"))
        #expect(environment.contains("GIT_EDITOR=true") && environment.contains("GIT_SEQUENCE_EDITOR=true"))
        #expect(environment.contains { $0.hasPrefix("GIT_SSH_COMMAND=") })
    }

    @Test func statusReadsTheUpstream() {
        let output = "# branch.oid abc\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
        let status = GitStatus.parse(Data(output.utf8), prefix: "")
        #expect(status.branch == "main" && status.upstream == "origin/main" && status.ahead == 2 && status.behind == 1)
        #expect(GitStatus.parse(Data("# branch.head main\0".utf8), prefix: "").upstream == nil)
    }
}

@MainActor
struct BranchOperationTests {
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

    /// A clone (with its own identity) of a fresh bare "origin".
    private func clone(_ remote: URL, as name: String, in base: URL) throws -> URL {
        let url = base.appending(path: name)
        try git(["clone", "-q", remote.path, url.path], in: base)
        for (key, value) in [("user.name", name), ("user.email", "\(name)@example.invalid"), ("commit.gpgsign", "false"),
                             ("pull.rebase", "false")] {
            try git(["config", key, value], in: url)
        }
        return url
    }

    private func write(_ text: String, _ file: String, in directory: URL) throws {
        try text.write(to: directory.appending(path: file), atomically: true, encoding: .utf8)
    }

    @Test func createsSwitchesMergesRebasesAndSyncs() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "omc-branches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let origin = base.appending(path: "origin.git")
        try git(["init", "-q", "--bare", "-b", "main", origin.path], in: base)
        let root = try clone(origin, as: "work", in: base)
        try write("one\ntwo\nthree\n", "f.txt", in: root)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "First"], in: root)
        try git(["push", "-q", "-u", "origin", "main"], in: root)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus?.upstream == "origin/main" })
        workspace.confirmation = { _ in true }

        // New branch from the current commit; the first push sets its upstream.
        workspace.textPrompt = { _ in " feature " }
        workspace.createBranchFromCurrent()
        #expect(try await eventually { workspace.gitStatus?.branch == "feature" })
        try write("one\nTWO\nthree\n", "f.txt", in: root)
        try git(["commit", "-qam", "Shout two"], in: root)
        workspace.push()
        #expect(try await eventually { workspace.gitStatus?.upstream == "origin/feature" })
        #expect(try git(["rev-parse", "feature"], in: origin) == git(["rev-parse", "HEAD"], in: root))

        // Back to main, merge feature (fast-forward).
        await workspace.loadBranches()
        let main = try #require(workspace.branches?.first { $0.name == "main" })
        workspace.switchBranch(main)
        #expect(try await eventually { workspace.gitStatus?.branch == "main" })
        await workspace.loadBranches()
        let feature = try #require(workspace.branches?.first { $0.name == "feature" })
        #expect(workspace.branches?.contains { $0.name == "origin/feature" && $0.isRemote } == true)
        workspace.mergeIntoCurrent(feature)
        #expect(try await eventually { (try? String(contentsOf: root.appending(path: "f.txt"), encoding: .utf8)) == "one\nTWO\nthree\n" })

        // A conflicting merge stops with a merge in progress; abort restores main.
        try git(["switch", "-qc", "left"], in: root)
        try write("one\nLEFT\nthree\n", "f.txt", in: root)
        try git(["commit", "-qam", "Left"], in: root)
        try git(["switch", "-q", "main"], in: root)
        try write("one\nMAIN\nthree\n", "f.txt", in: root)
        try git(["commit", "-qam", "Main"], in: root)
        await workspace.loadBranches()
        let left = try #require(workspace.branches?.first { $0.name == "left" })
        workspace.mergeIntoCurrent(left)
        #expect(try await eventually { workspace.gitStatus?.operation == .merge })
        #expect(workspace.errorMessage?.contains("CONFLICT") == true)
        #expect(workspace.gitStatus?.changes.filter(\.isConflicted).map(\.path) == ["f.txt"])
        workspace.resolveOperation(.abort)
        #expect(try await eventually { workspace.gitStatus?.operation == nil })
        #expect(try String(contentsOf: root.appending(path: "f.txt"), encoding: .utf8) == "one\nMAIN\nthree\n")

        // Same for a rebase.
        workspace.rebaseCurrent(onto: left)
        #expect(try await eventually { workspace.gitStatus?.operation == .rebase })
        workspace.resolveOperation(.abort)
        #expect(try await eventually { workspace.gitStatus?.operation == nil && workspace.gitStatus?.branch == "main" })

        // A branch only on the remote: checking it out makes a local branch tracking it.
        let other = try clone(origin, as: "other", in: base)
        try git(["switch", "-qc", "remote-only"], in: other)
        try write("other\n", "g.txt", in: other)
        try git(["add", "."], in: other)
        try git(["commit", "-qm", "Remote work"], in: other)
        try git(["push", "-q", "origin", "remote-only"], in: other)
        workspace.fetch()
        #expect(try await eventually { workspace.branches?.contains { $0.name == "origin/remote-only" } == true })
        let remoteOnly = try #require(workspace.branches?.first { $0.name == "origin/remote-only" })
        workspace.switchBranch(remoteOnly)
        #expect(try await eventually { workspace.gitStatus?.branch == "remote-only" && workspace.gitStatus?.upstream == "origin/remote-only" })

        // Pull what someone else pushed.
        try write("other\nmore\n", "g.txt", in: other)
        try git(["commit", "-qam", "More"], in: other)
        try git(["push", "-q", "origin", "remote-only"], in: other)
        workspace.errorMessage = nil
        workspace.pull()
        #expect(try await eventually { (try? String(contentsOf: root.appending(path: "g.txt"), encoding: .utf8)) == "other\nmore\n" },
                "\(workspace.errorMessage ?? "no error")")

        // Deleting a branch with unmerged commits needs a second yes.
        await workspace.loadBranches()
        let unmerged = try #require(workspace.branches?.first { $0.name == "left" })
        var asked: [String] = []
        workspace.confirmation = { asked.append($0); return false }
        workspace.deleteBranch(unmerged)
        #expect(try await eventually { asked.count == 1 && !workspace.isRunningGitCommand })
        #expect(try git(["branch", "--list", "left"], in: root).contains("left"))
        workspace.confirmation = { _ in true }
        workspace.deleteBranch(unmerged)
        #expect(try await eventually { workspace.branches?.contains { $0.name == "left" } == false })
        #expect(try git(["branch", "--list", "left"], in: root).isEmpty)

        // Unsaved edits: switching asks first, and "no" leaves everything as it is.
        workspace.open(fileAt: root.appending(path: "g.txt"))
        let document = try #require(workspace.activeDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "unsaved ")
        workspace.confirmation = { _ in false }
        workspace.switchBranch(main)
        try await Task.sleep(for: .milliseconds(300))
        #expect(workspace.gitStatus?.branch == "remote-only")
        withExtendedLifetime(workspace) {}
    }
}
