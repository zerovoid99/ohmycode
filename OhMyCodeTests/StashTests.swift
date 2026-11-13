import AppKit
import Testing
@testable import Oh_My_Code

struct StashParserTests {
    @Test func parsesEntriesBranchesAndMessages() {
        let w = String(repeating: "a", count: 40), base = String(repeating: "b", count: 40)
        let index = String(repeating: "c", count: 40), untracked = String(repeating: "d", count: 40)
        let list = "stash@{0}\u{1f}\(w)\u{1f}\(base) \(index)\u{1f}1700000000\u{1f}WIP on main: bbbbbbb Fix: the thing\n"
            + "stash@{1}\u{1f}\(w.replacingOccurrences(of: "a", with: "e"))\u{1f}\(base) \(index) \(untracked)\u{1f}1700000100\u{1f}On feature/x: my work: part 2\n"
        let stashes = GitStash.parse(Data(list.utf8))
        #expect(stashes.map(\.ref) == ["stash@{0}", "stash@{1}"])
        #expect(stashes[0].branch == "main" && stashes[0].message == "bbbbbbb Fix: the thing" && !stashes[0].hasUntrackedFiles)
        #expect(stashes[1].branch == "feature/x" && stashes[1].message == "my work: part 2" && stashes[1].untrackedCommit == untracked)
        #expect(stashes[1].trackedChanges.parents == [base])
        // Opening files: tracked ones against the base, untracked ones as new files.
        let tracked = stashes[1].change(to: StashFile(file: CommitFile(change: .modified, path: "a.txt", originalPath: nil), isUntracked: false))
        #expect(tracked.sha == stashes[1].sha && tracked.parents == [base] && tracked.parentPath == "a.txt")
        let new = stashes[1].change(to: StashFile(file: CommitFile(change: .added, path: "u.txt", originalPath: nil), isUntracked: true))
        #expect(new.sha == untracked && new.parentPath == nil && new.path == "u.txt")
    }
}

@MainActor
struct StashWorkspaceTests {
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
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func stashesAppliesPopsAndDrops() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-stash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appending(path: "a.txt"), b = root.appending(path: "b.txt"), u = root.appending(path: "u.txt")
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["config", "user.name", "A"], in: root)
        try git(["config", "user.email", "a@example.invalid"], in: root)
        try "a\n".write(to: a, atomically: true, encoding: .utf8)
        try "b\n".write(to: b, atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "init"], in: root)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus != nil })
        workspace.confirmation = { _ in true }

        // Stash a change and an untracked file, with a message.
        try "a\nmore\n".write(to: a, atomically: true, encoding: .utf8)
        try "new\n".write(to: u, atomically: true, encoding: .utf8)
        workspace.refreshGit()
        #expect(try await eventually { workspace.gitStatus?.changes.count == 2 })
        workspace.textPrompt = { _ in "  my work " }
        workspace.stash(.includingUntracked)
        #expect(try await eventually { workspace.stashes.count == 1 && workspace.gitStatus?.changes.isEmpty == true })
        let mine = try #require(workspace.stashes.first)
        #expect(mine.message == "my work" && mine.branch == "main" && mine.hasUntrackedFiles)
        #expect(read(a) == "a\n" && !FileManager.default.fileExists(atPath: u.path))

        // Its files, and their diffs.
        await workspace.loadFiles(of: mine)
        let files = try #require(workspace.stashFiles[mine.sha])
        #expect(files.map(\.file.path) == ["a.txt", "u.txt"] && files.map(\.isUntracked) == [false, true])
        let tracked = try #require(workspace.openStashFile(mine, files[0]))
        #expect(try await eventually { tracked.isLoaded })
        #expect(tracked.hunks == [DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 1)])
        let untracked = try #require(workspace.openStashFile(mine, files[1]))
        #expect(try await eventually { untracked.isLoaded && untracked.currentLines == ["new", ""] })

        // Cancelled: nothing happens. No message: git's "WIP on main: …".
        try "b\nchanged\n".write(to: b, atomically: true, encoding: .utf8)
        workspace.refreshGit()
        #expect(try await eventually { workspace.gitStatus?.changes.count == 1 })
        workspace.textPrompt = { _ in nil }
        workspace.stash(.all)
        try await Task.sleep(for: .milliseconds(300))
        #expect(workspace.stashes.count == 1)
        workspace.textPrompt = { _ in "" }
        workspace.stash(.all)
        #expect(try await eventually { workspace.stashes.count == 2 })
        #expect(workspace.stashes[0].subject.hasPrefix("WIP on main:") && read(b) == "b\n")

        // Apply keeps the stash; drop removes it (after asking).
        workspace.applyStash(workspace.stashes[0], pop: false)
        #expect(try await eventually { self.read(b) == "b\nchanged\n" })
        #expect(workspace.stashes.count == 2)
        try git(["checkout", "--", "b.txt"], in: root)
        workspace.confirmation = { _ in false }
        workspace.dropStash(workspace.stashes[0])
        try await Task.sleep(for: .milliseconds(300))
        #expect(workspace.stashes.count == 2)
        workspace.confirmation = { _ in true }
        workspace.dropStash(workspace.stashes[0])
        #expect(try await eventually { workspace.stashes.count == 1 })

        // Pop brings the work back and removes the stash.
        workspace.applyStash(workspace.stashes[0], pop: true)
        #expect(try await eventually { workspace.stashes.isEmpty })
        #expect(read(a) == "a\nmore\n" && read(u) == "new\n")

        // Only what's staged: the unstaged change stays.
        try git(["add", "a.txt"], in: root)
        try "b\nloose\n".write(to: b, atomically: true, encoding: .utf8)
        workspace.refreshGit()
        #expect(try await eventually { workspace.gitStatus?.stagedChanges.count == 1 })
        workspace.textPrompt = { _ in "staged only" }
        workspace.stash(.staged)
        #expect(try await eventually { workspace.stashes.count == 1 })
        #expect(read(a) == "a\n" && read(b) == "b\nloose\n")

        // A branch from the stash: made where it was stashed, with the stash applied and dropped.
        try git(["checkout", "--", "b.txt"], in: root)
        try FileManager.default.removeItem(at: u)
        workspace.textPrompt = { _ in "from-stash" }
        workspace.branchFromStash(workspace.stashes[0])
        #expect(try await eventually { workspace.gitStatus?.branch == "from-stash" && workspace.stashes.isEmpty })
        #expect(read(a) == "a\nmore\n")

        // Unsaved edits: asked first; "no" stashes nothing.
        workspace.open(fileAt: b)
        let document = try #require(workspace.activeDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "unsaved ")
        workspace.confirmation = { _ in false }
        workspace.stash(.all)
        try await Task.sleep(for: .milliseconds(300))
        #expect(workspace.stashes.isEmpty)
        withExtendedLifetime(workspace) {}
    }
}
