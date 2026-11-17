import AppKit
import Testing
@testable import Oh_My_Code

struct BlameCommitParsingTests {
    @Test func blameKeepsThePathInTheCommit() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        let output = """
        \(a) 1 1 1
        author Alice
        author-time 1700000000
        summary First
        filename old/name.txt
        \tone
        \(b) 2 2 1
        author Bob
        author-time 1700000100
        summary Second
        filename new/name.txt
        \ttwo
        \(a) 3 3 1
        \tthree

        """
        let lines = BlameLine.parse(Data(output.utf8))
        #expect(lines.map { $0?.path } == ["old/name.txt", "new/name.txt", "old/name.txt"])
    }

    @Test func parsesCommitDetailsWithTheWholeMessage() throws {
        let sha = String(repeating: "c", count: 40), parent = String(repeating: "d", count: 40)
        let output = "\(sha)\u{1f}\(parent)\u{1f}Bob Builder\u{1f}bob@example.invalid\u{1f}1700000000\u{1f}Fix it\n\nBecause:\n- reasons\n\n"
        let details = try #require(CommitDetails.parse(Data(output.utf8)))
        #expect(details.sha == sha && details.parents == [parent] && details.shortSHA == "ccccccc")
        #expect(details.author == "Bob Builder" && details.email == "bob@example.invalid")
        #expect(details.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(details.message == "Fix it\n\nBecause:\n- reasons")
        #expect(CommitDetails.parse(Data("garbage".utf8)) == nil)
    }
}

@MainActor
struct BlameCommitTests {
    private func git(_ arguments: [String], author: String = "Alice", in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=\(author)", "-c", "user.email=\(author.lowercased())@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func output(_ arguments: [String], in directory: URL) throws -> String {
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

    private func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Alice writes f.txt, Bob changes its second line, Carol renames it to g.txt and edits
    /// another file. Returns the folder and Bob's commit.
    private func makeRepository() throws -> (URL, String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-blame-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        try "one\ntwo\nthree\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-q", "-m", "First lines"], in: root)
        try "one\nTWO\nthree\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try "y\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "Shout two\n\nIt matters more than the others."], author: "Bob", in: root)
        let bob = try output(["rev-parse", "HEAD"], in: root)
        try git(["mv", "f.txt", "g.txt"], in: root)
        try git(["commit", "-q", "-m", "Rename f to g"], author: "Carol", in: root)
        return (root, bob)
    }

    private func blamedDocument(in root: URL) async throws -> (Workspace, EditorDocument) {
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "g.txt"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually { document.blame?.count == 3 })
        return (workspace, document)
    }

    @Test func readsTheCommitAndOpensItsChangesUnderTheOldName() async throws {
        let (root, bob) = try makeRepository()
        let (workspace, document) = try await blamedDocument(in: root)
        let line = try #require(document.blame?[1])
        #expect(line.commit == bob && line.path == "f.txt")

        let details = try #require(await workspace.commitDetails(bob))
        #expect(details.author == "Bob" && details.email == "bob@example.invalid")
        #expect(details.message == "Shout two\n\nIt matters more than the others.")

        // Bob's change to the file, though it's called g.txt now.
        let session = try #require(await workspace.openBlameChanges(line))
        guard case .commit(let commit) = session.mode else { Issue.record("not a commit diff"); return }
        #expect(commit.sha == bob && commit.path == "f.txt" && commit.change == .modified)
        #expect(workspace.diffSessions.count == 1)

        // Lines not committed have no commit to open.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "new\n")
        #expect(try await eventually { document.blame?.count == 4 })
        #expect(await workspace.openBlameChanges(try #require(document.blame?[0])) == nil)
        #expect(workspace.diffSessions.count == 1)
    }

    @Test func hoveringShowsTheCommitAndClickingOpensIt() async throws {
        let (root, bob) = try makeRepository()
        let (workspace, document) = try await blamedDocument(in: root)
        BlameHoverController.delay = .zero
        defer { BlameHoverController.delay = .milliseconds(350) }

        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0)) // Bob's line
        let annotation = try #require(controller.blameAnnotation())
        #expect(annotation.blame.commit == bob && !annotation.isHovered)
        let inside = NSPoint(x: annotation.rect.midX, y: annotation.rect.midY)
        let besideText = NSPoint(x: annotation.rect.minX - 10, y: annotation.rect.midY)

        // Hover: underlined, then the popover with that commit.
        #expect(controller.blameHover.mouseMoved(to: inside))
        #expect(controller.blameAnnotation()?.isHovered == true)
        #expect(try await eventually { controller.blameHover.shownCommit == bob })
        // Moving off it closes the popover.
        #expect(!controller.blameHover.mouseMoved(to: besideText))
        #expect(controller.blameHover.shownCommit == nil && controller.blameAnnotation()?.isHovered == false)

        // A click beside the annotation isn't on it; a click on it opens Bob's change.
        #expect(!controller.handleBlameClick(at: besideText))
        #expect(controller.handleBlameClick(at: inside))
        #expect(try await eventually {
            if case .commit(let commit) = workspace.diffSessions.first?.mode { commit.sha == bob } else { false }
        })

        // Uncommitted lines: nothing to hover or click.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "new\n")
        #expect(try await eventually { document.blame?.count == 4 })
        controller.textView.setSelectedRange(NSRange(location: 1, length: 0))
        let uncommitted = try #require(controller.blameAnnotation())
        #expect(uncommitted.blame.isUncommitted)
        let point = NSPoint(x: uncommitted.rect.midX, y: uncommitted.rect.midY)
        #expect(!controller.blameHover.mouseMoved(to: point))
        #expect(!controller.handleBlameClick(at: point))
        withExtendedLifetime((workspace, window)) {}
    }

    /// Between the annotation and the popover above it, even off to the side of the annotation,
    /// the mouse is on its way to the popover; below the annotation, or past the popover, it isn't.
    @Test func theWayToThePopoverKeepsItOpen() {
        let anchor = NSRect(x: 400, y: 300, width: 300, height: 16)
        let popover = NSRect(x: 300, y: 330, width: 400, height: 120)
        let way = BlameHoverController.way(from: anchor, to: popover)
        #expect(way.contains(NSPoint(x: 550, y: 320)))  // straight up, in the gap
        #expect(way.contains(NSPoint(x: 320, y: 325)))  // diagonally, toward the popover's left end
        #expect(way.contains(NSPoint(x: 500, y: 400)))  // in it
        #expect(!way.contains(NSPoint(x: 550, y: 250))) // below the annotation
        #expect(!way.contains(NSPoint(x: 800, y: 400))) // past it
    }

    @Test func showInTimelineFindsTheCommitInTheRepositoryLog() async throws {
        let (root, bob) = try makeRepository()
        let (workspace, document) = try await blamedDocument(in: root)
        document.blameActions?.showInTimeline(try #require(document.blame?[1]))
        #expect(workspace.sidebarMode == .history && workspace.historyScope == .repository)
        #expect(workspace.repoHistoryFilter == LogFilter(kind: .message, text: bob))
        #expect(try await eventually { workspace.repoHistory?.isLoading == false && workspace.repoHistory?.commits.first?.sha == bob })
        #expect(workspace.repoHistory?.pinned?.sha == bob)
    }
}

struct BlameShiftTests {
    private func line(_ commit: Character) -> BlameLine {
        BlameLine(commit: String(repeating: commit, count: 40), author: String(commit), date: Date(timeIntervalSince1970: 0), summary: "")
    }

    @Test func editedLinesBecomeUncommittedAndLaterOnesMove() {
        let blame: [BlameLine?] = [line("a"), line("b"), line("c"), line("d")]
        // Line 1 replaced by three lines.
        let grown = BlameLine.shifted(blame, replacing: 1..<2, with: 3)
        #expect(grown.map { $0?.author } == ["a", "Not Committed Yet", "Not Committed Yet", "Not Committed Yet", "c", "d"])
        #expect(grown[1]?.isUncommitted == true)
        // Lines 1 to 2 joined into one.
        let joined = BlameLine.shifted(blame, replacing: 1..<3, with: 1)
        #expect(joined.map { $0?.author } == ["a", "Not Committed Yet", "d"])
        // A line added before line 2, and line 1 deleted.
        #expect(BlameLine.shifted(blame, replacing: 2..<2, with: 1).map { $0?.author } == ["a", "b", "Not Committed Yet", "c", "d"])
        #expect(BlameLine.shifted(blame, replacing: 1..<2, with: 0).map { $0?.author } == ["a", "c", "d"])
        // Typing at the end.
        #expect(BlameLine.shifted(blame, replacing: 3..<4, with: 1).map { $0?.author } == ["a", "b", "c", "Not Committed Yet"])
    }

    @Test func columnTextsAndRuns() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entry = BlameLine(commit: String(repeating: "a", count: 40), author: "Alice", date: now.addingTimeInterval(-3 * 86400), summary: "")
        let texts = BlameColumn.texts(entry, now: now)
        #expect(texts.author == "Alice" && texts.age.contains("3"))
        #expect(BlameColumn.texts(BlameLine.uncommitted(), now: now) == ("Not committed", ""))
    }
}

@MainActor
struct BlameColumnTests {
    private func git(_ arguments: [String], author: String = "Alice", date: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=\(author)", "-c", "user.email=\(author.lowercased())@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.environment = ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Alice writes four lines in 2020, Bob rewrites the middle two in 2024.
    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-blame-column-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"], date: "2020-01-01T00:00:00Z", in: root)
        try "a\nb\nc\nd\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], date: "2020-01-01T00:00:00Z", in: root)
        try git(["commit", "-q", "-m", "Letters"], date: "2020-01-01T00:00:00Z", in: root)
        try "a\nB\nC\nd\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "Capitals"], author: "Bob", date: "2024-01-01T00:00:00Z", in: root)
        return root
    }

    @Test func showsEveryLinesCommitInTheGutter() async throws {
        let root = try makeRepository()
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "f.txt"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually { document.blame?.count == 4 })
        BlameHoverController.delay = .zero
        defer { BlameHoverController.delay = .milliseconds(350) }

        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.editor = controller
        let gutter = controller.gutterView!
        let narrow = gutter.width
        #expect(gutter.blameWidth == 0)

        controller.toggleBlameColumn()
        #expect(document.showsBlameColumn && gutter.blameWidth > 100 && gutter.width == narrow + gutter.blameWidth)

        // Runs: Alice's line, Bob's two, Alice's last; Bob's are the newest.
        let column = BlameColumn(document: document, width: gutter.blameWidth)
        #expect((0..<4).map(column.startsRun) == [true, true, false, true])
        let bob = try #require(column.entry(1)), alice = try #require(column.entry(0))
        #expect(bob.author == "Bob" && column.recency(bob) == 1 && column.recency(alice) == 0)

        // Line 2 (Bob's) under the mouse in the column: hover shows Bob's commit, click opens it.
        let lineRect = try #require(controller.rect(for: NSRange(location: 2, length: 1)))
        let point = gutter.convert(NSPoint(x: 10, y: lineRect.midY), from: controller.textView)
        let (line, rect) = try #require(gutter.line(at: point))
        #expect(line == 1)
        controller.blameHover.gutterMouseMoved(line: line, rect: rect)
        #expect(try await eventually { controller.blameHover.shownCommit == bob.commit })
        // Moving within Bob's run keeps it; Alice's line shows hers.
        controller.blameHover.gutterMouseMoved(line: 2, rect: rect)
        #expect(controller.blameHover.shownCommit == bob.commit)
        controller.blameHover.gutterMouseMoved(line: 3, rect: rect)
        #expect(try await eventually { controller.blameHover.shownCommit == alice.commit })
        controller.blameHover.gutterMouseMoved(line: nil, rect: .zero)
        #expect(controller.blameHover.shownCommit == nil)

        controller.handleBlameColumnClick(line: 1)
        #expect(try await eventually {
            if case .commit(let commit) = workspace.diffSessions.first?.mode { commit.sha == bob.commit } else { false }
        })

        // The context menu toggles the column and offers the line's commit.
        let menu = try #require(controller.gutterMenu(line: 1))
        #expect(menu.items.map(\.title) == ["Hide Blame", "", "Open Changes of \(bob.commit.prefix(7))",
                                            "Show \(bob.commit.prefix(7)) in Timeline", "Copy Commit Hash"])

        // Typing keeps the column in step: the edited line isn't committed, later ones move.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "new\n")
        #expect(column.entry(0)?.author == "Alice") // the old snapshot
        let shifted = BlameColumn(document: document, width: gutter.blameWidth)
        // A whole line inserted: only it is new, "a" below it is still Alice's.
        #expect(shifted.entry(0)?.isUncommitted == true && shifted.entry(1)?.author == "Alice")
        #expect(shifted.entry(2)?.author == "Bob" && shifted.entry(4)?.author == "Alice")
        // Typing within a line marks just that line; deleting a whole line removes its entry.
        document.textStorage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "x") // "xa"
        #expect(BlameColumn(document: document, width: 1).entry(1)?.isUncommitted == true)
        #expect(BlameColumn(document: document, width: 1).entry(2)?.author == "Bob")
        document.textStorage.replaceCharacters(in: NSRange(location: 4, length: 3), with: "") // the "xa" line
        let afterDelete = BlameColumn(document: document, width: 1)
        #expect(afterDelete.entry(0)?.isUncommitted == true && afterDelete.entry(1)?.author == "Bob" && afterDelete.entry(3)?.author == "Alice")

        controller.toggleBlameColumn()
        #expect(!document.showsBlameColumn && gutter.width == narrow)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func filesOutsideGitHaveNoBlameColumn() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-no-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "x\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "f.txt"))
        let document = try #require(workspace.activeDocument)
        let controller = EditorController(document: document)
        _ = controller.makeView()
        controller.toggleBlameColumn()
        #expect(!document.showsBlameColumn && controller.gutterView.blameWidth == 0)
        #expect(controller.gutterMenu(line: 0) == nil)
        withExtendedLifetime(workspace) {}
    }
}
