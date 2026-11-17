import AppKit
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

    /// `git add -N` leaves a file "added" in the worktree only (".A").
    @Test func intentToAddIsAdded() {
        let status = GitStatus.parse(porcelain(["1 .A N... 000000 000000 100644 0 0 later.swift"]), prefix: "")
        #expect(status.status(forRelativePath: "later.swift", isDirectory: false) == .added)
        #expect(status.changes.first?.unstagedStatus == .added)
    }

    /// A rename's original path is relative to the folder too, and gone when it was outside it.
    @Test func renameOriginalPathOutsideTheFolder() {
        let status = GitStatus.parse(porcelain([
            "2 R. N... 100644 100644 100644 a a R100 app/inside.txt", "app/before.txt",
            "2 R. N... 100644 100644 100644 a a R100 app/moved-in.txt", "other/before.txt",
        ]), prefix: "app/")
        #expect(status.changes.map(\.originalPath) == ["before.txt", nil])
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

    /// Lines split on "\n" alone, as the editor numbers them: "\r\n" is one Character, so a
    /// split on Characters made a CRLF file one line.
    @Test func crlfFilesSplitIntoLines() {
        let base = "one\r\ntwo\r\nthree\r\n", current = "one\r\nTWO\r\nthree\r\nfour\r\n"
        #expect(LineDiff.lines(base) == ["one\r", "two\r", "three\r", ""])
        #expect(LineDiff.lines("a\nb\r\nc") == ["a", "b\r", "c"])
        #expect(LineDiff.lines("") == [""])
        #expect(markers(base, current) == [1: .modified, 3: .added])

        // Staging one change and reverting both give back CRLF text, line for line.
        let old = LineDiff.lines(base), new = LineDiff.lines(current)
        let hunks = LineDiff.hunks(base: old, current: new)
        #expect(hunks.count == 2)
        #expect(LineDiff.applying(hunks[0], old: old, new: new) == "one\r\nTWO\r\nthree\r\n")
        let text = NSMutableString(string: current)
        for hunk in hunks.reversed() {
            let edit = LineDiff.revertEdit(for: hunk, base: old, text: text, lineStarts: LineIndex(string: text).lineStarts.array)
            text.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        #expect(text as String == base)
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

struct GitStageTwoTests {
    @Test func stagedAndUnstagedAreSeparated() {
        let output = Data([
            "# branch.head main",
            "1 M. N... 100644 100644 100644 a b staged.swift",
            "1 .M N... 100644 100644 100644 a a unstaged.swift",
            "1 MM N... 100644 100644 100644 a b both.swift",
            "1 A. N... 000000 100644 100644 0 b new.swift",
            "u UU N... 100644 100644 100644 100644 a b c conflict.swift",
            "? untracked.swift",
        ].joined(separator: "\0").appending("\0").utf8)
        let status = GitStatus.parse(output, prefix: "")
        #expect(status.stagedChanges.map(\.path) == ["staged.swift", "both.swift", "new.swift"])
        #expect(status.unstagedChanges.map(\.path) == ["unstaged.swift", "both.swift", "conflict.swift", "untracked.swift"])
        #expect(status.changes.first { $0.path == "new.swift" }?.stagedStatus == .added)
        #expect(status.changes.first { $0.path == "untracked.swift" }?.unstagedStatus == .untracked)
        #expect(status.changes.first { $0.path == "conflict.swift" }?.unstagedStatus == .conflicted)
    }

    /// Reverting every hunk (bottom-up) must reproduce the base exactly, for any edit.
    @Test func revertingAllHunksRestoresBase() {
        var rng = SystemRandomNumberGenerator()
        let vocabulary = ["a", "b", "c", "dd", "", "x y"]
        for _ in 0..<500 {
            let baseLines = (0..<Int.random(in: 0...8, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }
            var currentLines = baseLines
            for _ in 0..<Int.random(in: 0...4, using: &rng) {
                let operation = currentLines.isEmpty ? 0 : Int.random(in: 0..<3, using: &rng)
                switch operation {
                case 0: currentLines.insert(vocabulary.randomElement(using: &rng)!, at: Int.random(in: 0...currentLines.count, using: &rng))
                case 1: currentLines.remove(at: Int.random(in: 0..<currentLines.count, using: &rng))
                default: currentLines[Int.random(in: 0..<currentLines.count, using: &rng)] = "CHANGED"
                }
            }
            let baseText = baseLines.joined(separator: "\n") + (Bool.random(using: &rng) ? "\n" : "")
            let currentText = currentLines.joined(separator: "\n") + (Bool.random(using: &rng) ? "\n" : "")
            let base = LineDiff.lines(baseText)

            let text = NSMutableString(string: currentText)
            for hunk in LineDiff.hunks(base: base, current: LineDiff.lines(currentText)).reversed() {
                let starts = LineIndex(string: text).lineStarts.array
                let edit = LineDiff.revertEdit(for: hunk, base: base, text: text, lineStarts: starts)
                text.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            #expect(text as String == baseText, "base=\(baseText.debugDescription) current=\(currentText.debugDescription)")
            if text as String != baseText { return }
        }
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test func stageUnstageDiscardCommit() throws {
        let root = try GitRepositoryTests.makeRepository()
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["config", "user.name", "OMC Test"], in: root)
        try git(["config", "user.email", "omc@example.invalid"], in: root)
        try git(["config", "commit.gpgsign", "false"], in: root)
        let repository = try #require(Git.repository(at: root))

        // Unstage works before the first commit too.
        try Git.stage(["README.md"], in: repository)
        #expect(Git.status(of: repository)?.stagedChanges.map(\.path) == ["README.md"])
        try Git.unstage(["README.md"], in: repository)
        #expect(Git.status(of: repository)?.stagedChanges.isEmpty == true)

        try Git.stage(["README.md", "src/main.txt"], in: repository)
        try Git.commit(message: "first", in: repository)
        #expect(Git.status(of: repository)?.changes.isEmpty == true)

        try "changed\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try Git.discard(["README.md"], in: repository)
        #expect(try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8) == "keep\n")

        #expect(throws: Git.CommandError.self) { try Git.commit(message: "nothing staged", in: repository) }
    }

    private func output(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    private func makeRepository() throws -> (URL, Git.Repository) {
        let root = try GitRepositoryTests.makeRepository()
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["config", "user.name", "OMC Test"], in: root)
        try git(["config", "user.email", "omc@example.invalid"], in: root)
        try git(["config", "commit.gpgsign", "false"], in: root)
        return (root, try #require(Git.repository(at: root)))
    }

    /// Paths are matched as they are: "[id]" isn't a glob matching "d".
    @Test func pathsWithGlobCharactersMatchOnlyThemselves() throws {
        let (root, repository) = try makeRepository()
        try FileManager.default.createDirectory(at: root.appending(path: "app"), withIntermediateDirectories: true)
        try "a\n".write(to: root.appending(path: "app/[id].tsx"), atomically: true, encoding: .utf8)
        try "d\n".write(to: root.appending(path: "app/d.tsx"), atomically: true, encoding: .utf8)

        try Git.stage(["app/[id].tsx"], in: repository)
        #expect(Git.status(of: repository)?.stagedChanges.map(\.path) == ["app/[id].tsx"])
        try Git.unstage(["app/[id].tsx"], in: repository) // no commit yet: `rm --cached`
        #expect(Git.status(of: repository)?.stagedChanges.isEmpty == true)
        try Git.stage(["app/[id].tsx", "app/d.tsx", "README.md", "src/main.txt"], in: repository)
        try Git.commit(message: "first", in: repository)

        try "a2\n".write(to: root.appending(path: "app/[id].tsx"), atomically: true, encoding: .utf8)
        try "d2\n".write(to: root.appending(path: "app/d.tsx"), atomically: true, encoding: .utf8)
        try Git.stage(["app/[id].tsx"], in: repository)
        #expect(Git.status(of: repository)?.stagedChanges.map(\.path) == ["app/[id].tsx"])
        try Git.unstage(["app/[id].tsx"], in: repository)
        #expect(Git.status(of: repository)?.stagedChanges.isEmpty == true)
        try Git.discard(["app/[id].tsx"], in: repository)
        #expect(try String(contentsOf: root.appending(path: "app/[id].tsx"), encoding: .utf8) == "a\n")
        #expect(try String(contentsOf: root.appending(path: "app/d.tsx"), encoding: .utf8) == "d2\n")

        try Git.setIndexContent("a3\n", expected: "a\n", relativePath: "app/[id].tsx", in: repository)
        #expect(Git.indexContent(ofRelativePath: "app/[id].tsx", in: repository) == "a3\n")
        try Git.stage(["app/d.tsx"], in: repository)
        try Git.commit(message: "second", in: repository)
        try "d3\n".write(to: root.appending(path: "app/d.tsx"), atomically: true, encoding: .utf8)
        try Git.stage(["app/d.tsx"], in: repository)
        try Git.commit(message: "only d", in: repository)
        #expect(Git.history(ofRelativePath: "app/[id].tsx", in: repository)?.map(\.summary) == ["second", "first"])
    }

    @Test func intentToAddShowsAsAdded() throws {
        let (root, repository) = try makeRepository()
        try "later\n".write(to: root.appending(path: "later.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-N", "later.txt"], in: root)
        let change = try #require(Git.status(of: repository)?.changes.first { $0.path == "later.txt" })
        #expect(change.unstagedStatus == .added && !change.isStaged)
    }

    /// Staging part of a file that starts with a byte order mark keeps the mark.
    @Test func partialStagingKeepsTheByteOrderMark() throws {
        let (root, repository) = try makeRepository()
        try Data([0xEF, 0xBB, 0xBF] + Array("one\ntwo\n".utf8)).write(to: root.appending(path: "bom.txt"))
        try Git.stage(["bom.txt"], in: repository)
        let staged = try #require(Git.indexContent(ofRelativePath: "bom.txt", in: repository))
        #expect(staged == "one\ntwo\n") // read without the mark, like the editor
        try Git.setIndexContent("one\nTWO\n", expected: staged, relativePath: "bom.txt", in: repository)
        #expect(try output(["show", ":bom.txt"], in: root) == Data([0xEF, 0xBB, 0xBF] + Array("one\nTWO\n".utf8)))
    }

    @Test func removesARemoteWhoseNameLooksLikeAnOption() throws {
        let (root, repository) = try makeRepository()
        try git(["remote", "add", "--", "-x", "https://example.invalid/x.git"], in: root)
        #expect(Git.remotes(in: repository) == ["-x"])
        try Git.removeRemote("-x", in: repository)
        #expect(Git.remotes(in: repository).isEmpty)
    }

    /// A repository's config can name an fsmonitor hook; the app's own status refreshes don't
    /// run it.
    @Test func statusDoesNotRunAnFsmonitorHook() throws {
        let (root, repository) = try makeRepository()
        let marker = root.appending(path: "fsmonitor-ran")
        let hook = root.appending(path: "hook.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try git(["config", "core.fsmonitor", hook.path], in: root)
        try git(["add", "README.md"], in: root) // an index for the hook to be asked about

        // Plain git runs it (else this test proves nothing).
        _ = try output(["status", "--porcelain"], in: root)
        try #require(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)

        #expect(Git.status(of: repository) != nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

@MainActor
struct GitStageTwoWorkspaceTests {
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    private func makeRepository() throws -> URL {
        let root = try GitRepositoryTests.makeRepository()
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["config", "user.name", "OMC Test"], in: root)
        try git(["config", "user.email", "omc@example.invalid"], in: root)
        try git(["config", "commit.gpgsign", "false"], in: root)
        try git(["add", "."], in: root)
        try git(["commit", "-q", "-m", "init"], in: root)
        return root
    }

    @Test func stageCommitAndDiscardFromTheWorkspace() async throws {
        let root = try makeRepository()
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitStatus != nil })

        try "keep\nmore\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "scratch".write(to: root.appending(path: "scratch.txt"), atomically: true, encoding: .utf8)
        #expect(try await eventually { workspace.gitStatus?.unstagedChanges.count == 2 })

        workspace.stage(["README.md"])
        #expect(try await eventually { workspace.gitStatus?.stagedChanges.map(\.path) == ["README.md"] })

        #expect(await workspace.commit(message: "  update readme  "))
        #expect(try await eventually { workspace.gitStatus?.stagedChanges.isEmpty == true })
        #expect(await workspace.commit(message: "nothing staged") == false)
        #expect(workspace.errorMessage != nil)
        workspace.errorMessage = nil

        // Discard: untracked file goes to the (test) Trash, tracked edits are restored.
        try "edited".write(to: root.appending(path: "src/main.txt"), atomically: true, encoding: .utf8)
        #expect(try await eventually { workspace.gitStatus?.unstagedChanges.count == 2 })
        let trashed = TrashRecorder()
        Workspace.confirmDiscard = { _ in true }
        Workspace.moveToTrash = { url in trashed.add(url); try FileManager.default.removeItem(at: url) }
        defer {
            Workspace.confirmDiscard = nil
            Workspace.moveToTrash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        }
        workspace.discard(workspace.gitStatus?.unstagedChanges ?? [])
        #expect(try await eventually { workspace.gitStatus?.changes.isEmpty == true })
        #expect(trashed.names == ["scratch.txt"])
        #expect(try String(contentsOf: root.appending(path: "src/main.txt"), encoding: .utf8) == "one\ntwo\nthree\n")
    }

    @Test func revertHunkFromTheGutterIsUndoable() async throws {
        let root = try makeRepository()
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "src/main.txt"))
        let document = try #require(workspace.activeDocument)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.makeFirstResponder(controller.textView)
        try await Task.sleep(for: .milliseconds(300)) // diff base loads

        let undo = document.undoManager
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        controller.textView.insertText("TWO", replacementRange: NSRange(location: 4, length: 3))
        undo.endUndoGrouping()
        #expect(try await eventually { document.diffMarkers == [1: .modified] })

        let hunk = try #require(document.hunk(atLine: 1))
        #expect(document.lines(of: hunk).old == ["two"])
        #expect(document.lines(of: hunk).new == ["TWO"])
        undo.beginUndoGrouping()
        controller.revert(hunk)
        undo.endUndoGrouping()
        #expect(document.textStorage.string == "one\ntwo\nthree\n")
        #expect(try await eventually { document.diffMarkers.isEmpty })

        undo.undo()
        #expect(document.textStorage.string == "one\nTWO\nthree\n")
        withExtendedLifetime((workspace, window)) {}
    }
}

private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    var names: [String] { lock.withLock { urls.map(\.lastPathComponent) } }
}
