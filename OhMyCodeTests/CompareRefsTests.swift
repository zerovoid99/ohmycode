import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct CompareRefsTests {
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

    private func write(_ text: String, _ name: String, in root: URL) throws {
        try text.write(to: root.appending(path: name), atomically: true, encoding: .utf8)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// main: base commit, then one more changing m.txt. feature (from base): changes f.txt,
    /// adds n.txt, renames r.txt (two commits). An unrelated `orphan` branch too.
    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: root)
        try write("f1\n", "f.txt", in: root)
        try write("m1\n", "m.txt", in: root)
        try write("r\nr\nr\n", "r.txt", in: root)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "base"], in: root)
        try git(["switch", "-qc", "feature"], in: root)
        try write("f2\n", "f.txt", in: root)
        try write("n\n", "n.txt", in: root)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "feature one"], in: root)
        try git(["mv", "r.txt", "renamed.txt"], in: root)
        try git(["commit", "-qm", "feature two"], in: root)
        try git(["switch", "-q", "main"], in: root)
        try write("m2\n", "m.txt", in: root)
        try git(["commit", "-qam", "main moves on"], in: root)
        try git(["switch", "-q", "--orphan", "orphan"], in: root)
        try write("o\n", "o.txt", in: root)
        try git(["add", "o.txt"], in: root)
        try git(["commit", "-qm", "orphan"], in: root)
        try git(["switch", "-q", "main"], in: root)
        return root
    }

    @Test func comparesBranchesSinceTheirCommonAncestorOrDirectly() async throws {
        let root = try makeRepository()
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus?.hasCommits == true })

        await workspace.compare("main", with: "feature", sinceCommonAncestor: true)
        #expect(workspace.sidebarMode == .history && workspace.historyScope == .compare)
        let pr = try #require(workspace.comparison)
        #expect(pr.ahead == 2 && pr.behind == 1)
        #expect(pr.baseSHA == (try git(["merge-base", "main", "feature"], in: root)))
        #expect(pr.targetSHA == (try git(["rev-parse", "feature"], in: root)))
        // What feature changed since it left main: not main's own change to m.txt.
        #expect(pr.files.map(\.path).sorted() == ["f.txt", "n.txt", "renamed.txt"])
        #expect(pr.files.first { $0.path == "renamed.txt" }?.change == .renamed)
        #expect(pr.files.first { $0.path == "renamed.txt" }?.originalPath == "r.txt")

        // A file's diff: the common ancestor's version against feature's.
        let file = try #require(pr.files.first { $0.path == "f.txt" })
        let session = try #require(workspace.openComparison(file))
        #expect(try await eventually { session.loadedCurrent != nil })
        #expect(session.loadedBase == ["f1", ""] && session.loadedCurrent == ["f2", ""])
        // Opening it again shows the same tab.
        #expect(workspace.openComparison(file) === session)

        // Directly: main's m.txt change shows too (as feature's older version).
        await workspace.compare("main", with: "feature", sinceCommonAncestor: false)
        let direct = try #require(workspace.comparison)
        #expect(direct.baseSHA == (try git(["rev-parse", "main"], in: root)))
        #expect(direct.files.map(\.path).sorted() == ["f.txt", "m.txt", "n.txt", "renamed.txt"])

        // Same commit: nothing differs.
        await workspace.compare("main", with: "HEAD", sinceCommonAncestor: false)
        #expect(workspace.comparison?.files == [] && workspace.comparison?.ahead == 0)

        workspace.clearComparison()
        #expect(workspace.comparison == nil)
        withExtendedLifetime(workspace) {}
    }

    @Test func reportsUnknownRefsAndUnrelatedHistories() async throws {
        let root = try makeRepository()
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus?.hasCommits == true })

        await workspace.compare("main", with: "nope", sinceCommonAncestor: true)
        #expect(workspace.errorMessage?.contains("nope") == true && workspace.comparison == nil)
        workspace.errorMessage = nil

        // A name that looks like an option is a ref name, not a git flag.
        await workspace.compare("--all", with: "main", sinceCommonAncestor: false)
        #expect(workspace.errorMessage?.contains("--all") == true && workspace.comparison == nil)
        workspace.errorMessage = nil

        await workspace.compare("main", with: "orphan", sinceCommonAncestor: true)
        #expect(workspace.errorMessage?.contains("no commit in common") == true && workspace.comparison == nil)
        workspace.errorMessage = nil

        // Directly, unrelated histories still compare.
        await workspace.compare("main", with: "orphan", sinceCommonAncestor: false)
        #expect(workspace.errorMessage == nil)
        #expect(workspace.comparison?.files.map(\.path).sorted() == ["f.txt", "m.txt", "o.txt", "r.txt"])
        withExtendedLifetime(workspace) {}
    }
}
