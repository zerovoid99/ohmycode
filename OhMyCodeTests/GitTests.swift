import Foundation
import Testing
@testable import Oh_My_Code

struct GitStatusParserTests {
    private func porcelain(_ records: [String]) -> Data {
        Data(records.joined(separator: "\0").appending("\0").utf8)
    }

    @Test func parsesBranchAndEntries() {
        let output = porcelain([
            "# branch.oid abc123",
            "# branch.head feature/login",
            "# branch.upstream origin/feature/login",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa aaa Sources/App.swift",
            "1 A. N... 000000 100644 100644 000 bbb Sources/New File.swift",
            "1 D. N... 100644 000000 000000 ccc 000 Old.swift",
            "2 R. N... 100644 100644 100644 ddd ddd R100 Sources/Renamed.swift", "Sources/Before.swift",
            "u UU N... 100644 100644 100644 100644 e1 e2 e3 Conflict.txt",
            "? notes.md",
            "? scratch/",
        ])
        let status = GitStatus.parse(output, prefix: "")
        #expect(status.branch == "feature/login")
        #expect(status.ahead == 2 && status.behind == 1)
        #expect(status.status(forRelativePath: "Sources/App.swift", isDirectory: false) == .modified)
        #expect(status.status(forRelativePath: "Sources/New File.swift", isDirectory: false) == .added)
        #expect(status.status(forRelativePath: "Old.swift", isDirectory: false) == .deleted)
        #expect(status.status(forRelativePath: "Sources/Renamed.swift", isDirectory: false) == .renamed)
        #expect(status.status(forRelativePath: "Sources/Before.swift", isDirectory: false) == nil)
        #expect(status.status(forRelativePath: "Conflict.txt", isDirectory: false) == .conflicted)
        #expect(status.status(forRelativePath: "notes.md", isDirectory: false) == .untracked)
        // Untracked folder: itself and everything inside.
        #expect(status.status(forRelativePath: "scratch", isDirectory: true) == .untracked)
        #expect(status.status(forRelativePath: "scratch/a/b.txt", isDirectory: false) == .untracked)
        // Folders take their most important child's status.
        #expect(status.status(forRelativePath: "Sources", isDirectory: true) == .modified)
        #expect(status.status(forRelativePath: "Clean.swift", isDirectory: false) == nil)
    }

    @Test func detachedHeadAndSubfolderPrefix() {
        let output = porcelain([
            "# branch.head (detached)",
            "1 .M N... 100644 100644 100644 a a app/src/main.swift",
            "1 .M N... 100644 100644 100644 a a other/readme.md",
        ])
        let status = GitStatus.parse(output, prefix: "app/")
        #expect(status.branch == nil)
        #expect(status.status(forRelativePath: "src/main.swift", isDirectory: false) == .modified)
        #expect(status.changedFileCount == 1) // other/ is outside the opened folder
    }
}

struct LineDiffTests {
    private func markers(_ base: String, _ current: String) -> [Int: DiffMarker] {
        LineDiff.markers(base: LineDiff.lines(base), current: LineDiff.lines(current))
    }

    @Test func identicalHasNoMarkers() {
        #expect(markers("a\nb\nc\n", "a\nb\nc\n").isEmpty)
    }

    @Test func addedModifiedDeleted() {
        #expect(markers("a\nb\nc", "a\nb\nNEW\nc") == [2: .added])
        #expect(markers("a\nb\nc", "a\nB!\nc") == [1: .modified])
        #expect(markers("a\nb\nc\nd", "a\nd") == [1: .deletedAbove])
        #expect(markers("a\nb", "") == [0: .modified]) // emptied file: one (empty) line remains
    }

    @Test func multipleHunks() {
        let base = (1...10).map(String.init).joined(separator: "\n")
        var lines = base.split(separator: "\n").map(String.init)
        lines[1] = "two!"            // modified line 1
        lines.insert("inserted", at: 5) // added at line 5
        lines.remove(at: 9)          // removes "9" (now at index 9)
        let result = markers(base, lines.joined(separator: "\n"))
        #expect(result == [1: .modified, 5: .added, 9: .deletedAbove])
    }

    @Test func hugeRewriteFallsBackWithoutMyers() {
        let base = (0..<15_000).map { "old \($0)" }.joined(separator: "\n")
        let current = (0..<15_000).map { "new \($0)" }.joined(separator: "\n")
        let clock = ContinuousClock()
        var result: [Int: DiffMarker] = [:]
        let elapsed = clock.measure { result = markers(base, current) }
        #expect(result.count == 15_000 && result.values.allSatisfy { $0 == .modified })
        #expect(elapsed < .seconds(1))
    }
}

/// Against a real repository.
struct GitRepositoryTests {
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=OMC", "-c", "user.email=omc@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    static func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(to: root.appending(path: "src/main.txt"), atomically: true, encoding: .utf8)
        try "keep\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func statusAndIndexContent() throws {
        let root = try Self.makeRepository()
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["add", "."], in: root)
        try git(["commit", "-q", "-m", "init"], in: root)

        try "one\nTWO\nthree\n".write(to: root.appending(path: "src/main.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: root.appending(path: "added.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appending(path: "README.md"))

        let repository = try #require(Git.repository(at: root))
        #expect(repository.prefix == "")
        let status = try #require(Git.status(of: repository))
        #expect(status.branch == "main")
        #expect(status.status(forRelativePath: "src/main.txt", isDirectory: false) == .modified)
        #expect(status.status(forRelativePath: "added.txt", isDirectory: false) == .untracked)
        #expect(status.status(forRelativePath: "README.md", isDirectory: false) == .deleted)
        #expect(status.status(forRelativePath: "src", isDirectory: true) == .modified)

        #expect(Git.indexContent(ofRelativePath: "src/main.txt", in: repository) == "one\ntwo\nthree\n")
        #expect(Git.indexContent(ofRelativePath: "added.txt", in: repository) == nil)

        // A subfolder of the repository opened as the workspace.
        let sub = try #require(Git.repository(at: root.appending(path: "src")))
        #expect(sub.prefix == "src/")
        #expect(Git.status(of: sub)?.status(forRelativePath: "main.txt", isDirectory: false) == .modified)
        #expect(Git.indexContent(ofRelativePath: "main.txt", in: sub) == "one\ntwo\nthree\n")
    }

    @Test func notARepository() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(Git.repository(at: folder) == nil)
    }
}

@MainActor
struct GitWorkspaceTests {
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=OMC", "-c", "user.email=omc@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func eventually(timeout: Duration = .seconds(4), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    private func makeCommittedRepository() throws -> URL {
        let root = try GitRepositoryTests.makeRepository()
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["add", "."], in: root)
        try git(["commit", "-q", "-m", "init"], in: root)
        return root
    }

    @Test func statusFollowsChangesMadeOutsideTheApp() async throws {
        let root = try makeCommittedRepository()
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus?.branch == "main" })
        #expect(workspace.gitStatus?.changedFileCount == 0)

        try "x".write(to: root.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        #expect(try await eventually {
            workspace.gitStatus(for: root.appending(path: "new.txt"), isDirectory: false) == .untracked
        })

        try git(["add", "new.txt"], in: root) // only .git/ changes: must still refresh
        #expect(try await eventually {
            workspace.gitStatus(for: root.appending(path: "new.txt"), isDirectory: false) == .added
        })

        try git(["commit", "-q", "-m", "add"], in: root)
        #expect(try await eventually { workspace.gitStatus?.changedFileCount == 0 })
    }

    @Test func gutterMarkersTrackEditsAgainstTheIndex() async throws {
        let root = try makeCommittedRepository()
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "src/main.txt"))
        let document = try #require(workspace.activeDocument)
        try await Task.sleep(for: .milliseconds(300)) // diff base loads in the background

        // "one\ntwo\nthree\n": modify line 1, then add a line at the end.
        document.textStorage.replaceCharacters(in: NSRange(location: 4, length: 3), with: "TWO")
        #expect(try await eventually { document.diffMarkers == [1: .modified] })
        document.textStorage.replaceCharacters(in: NSRange(location: 14, length: 0), with: "four\n")
        #expect(try await eventually { document.diffMarkers == [1: .modified, 3: .added] })

        // Staging the change makes the index match: markers disappear.
        #expect(workspace.save(document))
        try git(["add", "src/main.txt"], in: root)
        #expect(try await eventually { document.diffMarkers.isEmpty })
    }

    @Test func untrackedFilesAndNonRepositoriesHaveNoMarkers() async throws {
        let root = try makeCommittedRepository()
        try "fresh\n".write(to: root.appending(path: "fresh.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "fresh.txt"))
        let document = try #require(workspace.activeDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "more\n")
        try await Task.sleep(for: .milliseconds(500))
        #expect(document.diffMarkers.isEmpty)

        let plain = FileManager.default.temporaryDirectory.appending(path: "omc-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let other = Workspace()
        other.openFolder(plain)
        try await Task.sleep(for: .milliseconds(300))
        #expect(other.gitStatus == nil)
    }
}
