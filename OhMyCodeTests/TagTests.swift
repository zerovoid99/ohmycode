import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct TagTests {
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

    @Test func readsTagsFromRefs() {
        let commit = RepoCommit(sha: String(repeating: "a", count: 40), parents: [], author: "", date: Date(), summary: "",
                                refs: ["HEAD -> main", "tag: v1.0", "origin/main", "tag: release/2"])
        #expect(commit.tags == ["v1.0", "release/2"])
    }

    @Test func createsPushesAndDeletesTags() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "omc-tags-\(UUID().uuidString)")
        let root = base.appending(path: "work"), origin = base.appending(path: "origin.git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare", "-b", "main", origin.path], in: base)
        try git(["init", "-q", "-b", "main"], in: root)
        for (key, value) in [("user.name", "A"), ("user.email", "a@example.invalid"), ("commit.gpgsign", "false"),
                             ("tag.gpgsign", "false")] {
            try git(["config", key, value], in: root)
        }
        try git(["remote", "add", "origin", origin.path], in: root)
        for index in 1...2 {
            try "\(index)\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
            try git(["add", "."], in: root)
            try git(["commit", "-qm", "c\(index)"], in: root)
        }
        try git(["push", "-q", "-u", "origin", "main"], in: root)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus?.hasCommits == true })
        workspace.confirmation = { _ in true }
        workspace.sidebarMode = .history
        workspace.historyScope = .repository
        workspace.loadRepoHistory()
        await workspace.waitForRepoHistory()
        let c1 = try #require(workspace.repoHistory?.commits.first { $0.summary == "c1" })

        // Annotated at a commit, lightweight at HEAD; the Timeline shows them.
        workspace.tagPrompt = { _ in (" v1.0 ", " First release ") }
        workspace.createTag(at: c1)
        #expect(try await eventually { workspace.repoHistory?.commits.first { $0.summary == "c1" }?.tags == ["v1.0"] })
        #expect(try git(["cat-file", "-t", "v1.0"], in: root) == "tag")
        #expect(try git(["tag", "-l", "--format=%(contents)", "v1.0"], in: root) == "First release")
        workspace.tagPrompt = { _ in ("nightly", "") }
        workspace.createTag(at: nil)
        #expect(try await eventually { workspace.repoHistory?.commits.first?.tags == ["nightly"] })
        #expect(try git(["cat-file", "-t", "nightly"], in: root) == "commit") // lightweight
        workspace.tagPrompt = { _ in nil }                                 // cancelled
        workspace.createTag(at: nil)

        // Push one, then all; delete from the remote; delete here.
        workspace.pushTag("v1.0")
        #expect(try await eventually { (try? self.git(["tag", "-l"], in: origin)) == "v1.0" })
        workspace.pushTag(nil)
        #expect(try await eventually { (try? self.git(["tag", "-l"], in: origin)) == "nightly\nv1.0" })
        workspace.deleteRemoteTag("nightly")
        #expect(try await eventually { (try? self.git(["tag", "-l"], in: origin)) == "v1.0" })
        workspace.confirmation = { _ in false }
        workspace.deleteTag("v1.0")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try git(["tag", "-l"], in: root) == "nightly\nv1.0")
        workspace.confirmation = { _ in true }
        workspace.deleteTag("v1.0")
        #expect(try await eventually { (try? self.git(["tag", "-l"], in: root)) == "nightly" })
        #expect(try await eventually { workspace.repoHistory?.commits.contains { $0.tags.contains("v1.0") } == false })
        // A clash is git's to report.
        workspace.errorMessage = nil
        workspace.tagPrompt = { _ in ("nightly", "") }
        workspace.createTag(at: c1)
        #expect(try await eventually { workspace.errorMessage?.contains("already exists") == true })
        withExtendedLifetime(workspace) {}
    }
}
