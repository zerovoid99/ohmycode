import AppKit
import Testing
@testable import Oh_My_Code

struct RemoteParsingTests {
    @Test func parsesRemotesWithTheirURLs() {
        let output = """
        origin\tgit@github.com:me/app.git (fetch)
        origin\tgit@github.com:me/app.git (push)
        upstream\thttps://example.com/team/app.git (fetch)
        upstream\tno_push (push)

        """
        let remotes = GitRemote.parse(Data(output.utf8))
        #expect(remotes.map(\.name) == ["origin", "upstream"])
        #expect(remotes[0].fetchURL == "git@github.com:me/app.git" && remotes[0].pushURL == remotes[0].fetchURL)
        #expect(remotes[1].fetchURL == "https://example.com/team/app.git" && remotes[1].pushURL == "no_push")
    }

    @Test func hidesPasswordsInURLs() {
        #expect(GitRemote.display("https://me:s3cret@example.com/app.git") == "https://me:•••@example.com/app.git")
        #expect(GitRemote.display("https://example.com/app.git") == "https://example.com/app.git")
        #expect(GitRemote.display("git@github.com:me/app.git") == "git@github.com:me/app.git")
        #expect(GitRemote.display("/path/to/repo.git") == "/path/to/repo.git")
    }
}

@MainActor
struct RemoteTests {
    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=A", "-c", "user.email=a@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
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

    /// A working repository without remotes, and two bare repositories: "team" has a
    /// `feature` branch (pushed from a seed clone), "mirror" is empty.
    private func makeRepositories() throws -> (work: URL, seed: URL, team: URL, mirror: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "omc-remotes-\(UUID().uuidString)")
        let work = base.appending(path: "work"), seed = base.appending(path: "seed")
        let team = base.appending(path: "team.git"), mirror = base.appending(path: "mirror.git")
        for directory in [work, seed] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try git(["init", "-q", "--bare", "-b", "main", team.path], in: base)
        try git(["init", "-q", "--bare", "-b", "main", mirror.path], in: base)
        try git(["init", "-q", "-b", "main"], in: work)
        try "w\n".write(to: work.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: work)
        try git(["commit", "-qm", "work"], in: work)
        try git(["init", "-q", "-b", "feature"], in: seed)
        try "s\n".write(to: seed.appending(path: "s.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: seed)
        try git(["commit", "-qm", "seed"], in: seed)
        try git(["push", "-q", team.path, "feature"], in: seed)
        return (work, seed, team, mirror)
    }

    private func remoteBranches(_ workspace: Workspace) async -> [String] {
        await workspace.loadBranches()
        return (workspace.branches ?? []).filter(\.isRemote).map(\.name).sorted()
    }

    @Test func addsEditsRenamesFetchesAndRemovesRemotes() async throws {
        let (work, seed, team, mirror) = try makeRepositories()
        let workspace = Workspace()
        workspace.openFolder(work)
        #expect(try await eventually { workspace.gitStatus?.hasCommits == true })
        await workspace.loadRemotes()
        #expect(workspace.remotes == [])

        // Add: fetched right away, so its branches are there.
        workspace.remotePrompt = { remote in remote == nil ? (" team ", " \(team.path) ") : nil }
        workspace.addRemote()
        #expect(try await eventually { workspace.remotes?.map(\.name) == ["team"] && !workspace.isRunningGitCommand })
        #expect(workspace.remotes?.first?.fetchURL == team.path)
        #expect(await remoteBranches(workspace) == ["team/feature"])

        // Fetch one remote: a branch pushed there since shows up.
        try git(["push", "-q", team.path, "feature:second"], in: seed)
        workspace.fetch(from: try #require(workspace.remotes?.first))
        #expect(try await eventually { !workspace.isRunningGitCommand })
        #expect(await remoteBranches(workspace) == ["team/feature", "team/second"])

        // Edit its URL.
        workspace.remotePrompt = { remote in remote.map { ($0.name, mirror.path) } }
        workspace.editRemoteURL(try #require(workspace.remotes?.first))
        #expect(try await eventually { workspace.remotes?.first?.fetchURL == mirror.path && !workspace.isRunningGitCommand })
        #expect(try git(["remote", "get-url", "--push", "team"], in: work) == mirror.path)

        // Rename: remote branches follow.
        workspace.textPrompt = { _ in "upstream" }
        workspace.renameRemote(try #require(workspace.remotes?.first))
        #expect(try await eventually { workspace.remotes?.map(\.name) == ["upstream"] && !workspace.isRunningGitCommand })
        #expect(await remoteBranches(workspace) == ["upstream/feature", "upstream/second"])

        // An invalid name is git's to refuse: the error shows, nothing is added.
        workspace.remotePrompt = { _ in ("bad name", team.path) }
        workspace.addRemote()
        #expect(try await eventually { workspace.errorMessage != nil && !workspace.isRunningGitCommand })
        #expect(workspace.remotes?.map(\.name) == ["upstream"])
        workspace.errorMessage = nil

        // Remove: asked first; its branches go too.
        workspace.confirmation = { _ in false }
        workspace.removeRemote(try #require(workspace.remotes?.first))
        #expect(workspace.remotes?.map(\.name) == ["upstream"] && !workspace.isRunningGitCommand)
        workspace.confirmation = { _ in true }
        workspace.removeRemote(try #require(workspace.remotes?.first))
        #expect(try await eventually { workspace.remotes == [] && !workspace.isRunningGitCommand })
        #expect(await remoteBranches(workspace) == [])
        #expect(workspace.errorMessage == nil)
    }

    @Test func cancellingOrUnchangedAnswersDoNothing() async throws {
        let (work, _, team, _) = try makeRepositories()
        try git(["remote", "add", "origin", team.path], in: work)
        let workspace = Workspace()
        workspace.openFolder(work)
        #expect(try await eventually { workspace.gitStatus?.hasCommits == true })
        await workspace.loadRemotes()
        let origin = try #require(workspace.remotes?.first)
        #expect(origin.name == "origin")

        workspace.remotePrompt = { _ in nil }
        workspace.addRemote()
        workspace.editRemoteURL(origin)
        workspace.textPrompt = { _ in nil }
        workspace.renameRemote(origin)
        workspace.textPrompt = { _ in "origin" }
        workspace.renameRemote(origin)
        workspace.remotePrompt = { _ in ("origin", team.path) }
        workspace.editRemoteURL(origin)
        #expect(!workspace.isRunningGitCommand)
        #expect(workspace.remotes == [origin])
    }
}
