import AppKit
import Testing
@testable import Oh_My_Code

struct LineMixingTests {
    let old = LineDiff.lines("a\nb\nc\nd\nx\ny\n")
    let new = LineDiff.lines("A\nB\nc\nd\ny\ne\n")

    @Test func picksSidesRowByRow() {
        let hunks = LineDiff.hunks(base: old, current: new)
        // a,b → A,B (changed pairs) · x removed · e added
        let rows = hunks.flatMap(LineDiff.pairs)
        #expect(rows == [DiffLinePair(old: 0, new: 0), DiffLinePair(old: 1, new: 1),
                         DiffLinePair(old: 4, new: nil), DiffLinePair(old: nil, new: 5)])
        #expect(LineDiff.mixing(old: old, new: new, hunks: hunks, useNew: { _ in false }) == old.joined(separator: "\n"))
        #expect(LineDiff.mixing(old: old, new: new, hunks: hunks, useNew: { _ in true }) == new.joined(separator: "\n"))
        // Only the second changed line: the first keeps its old text, in place.
        #expect(LineDiff.mixing(old: old, new: new, hunks: hunks, useNew: { $0 == rows[1] }) == "a\nB\nc\nd\nx\ny\n")
        // Only the removal, only the addition.
        #expect(LineDiff.mixing(old: old, new: new, hunks: hunks, useNew: { $0 == rows[2] }) == "a\nb\nc\nd\ny\n")
        #expect(LineDiff.mixing(old: old, new: new, hunks: hunks, useNew: { $0 == rows[3] }) == "a\nb\nc\nd\nx\ny\ne\n")
    }

    @Test func unevenHunksPairThenListTheRest() {
        let hunk = DiffHunk(oldStart: 2, oldCount: 3, newStart: 2, newCount: 1)
        #expect(LineDiff.pairs(in: hunk) == [DiffLinePair(old: 2, new: 2), DiffLinePair(old: 3, new: nil),
                                             DiffLinePair(old: 4, new: nil)])
    }

    @Test func selectionTouchesRowsAndNearbyDeletions() {
        let hunks = [DiffHunk(oldStart: 0, oldCount: 3, newStart: 0, newCount: 1),   // a,b,c → A
                     DiffHunk(oldStart: 6, oldCount: 1, newStart: 4, newCount: 0)]   // line removed above new line 4
        // Selecting the changed line takes the removed lines of its hunk too.
        #expect(LineDiff.rows(touching: [0], in: hunks) == [DiffLinePair(old: 0, new: 0), DiffLinePair(old: 1, new: nil),
                                                            DiffLinePair(old: 2, new: nil)])
        // A pure deletion counts from the line below it or the one above.
        #expect(LineDiff.rows(touching: [4], in: hunks) == [DiffLinePair(old: 6, new: nil)])
        #expect(LineDiff.rows(touching: [3], in: hunks) == [DiffLinePair(old: 6, new: nil)])
        #expect(LineDiff.rows(touching: [2], in: hunks).isEmpty)
    }
}

struct RevertLinesTests {
    /// For every subset of rows: the edits, applied to the current text, give the current text
    /// with exactly those rows taken from the old one.
    @Test(arguments: [
        ("a\nb\nc\nd\nx\ny\n", "A\nB\nc\nd\ny\ne\n"),     // changed pair, removal, addition at the end
        ("a\nb\nc", "a\nB\nc\nd"),                          // no final newline, addition at the very end
        ("a\nb\nc\nd\n", "a\nd\n"),                          // pure deletion in the middle
        ("a\nb\n", "x\ny\nz\na\nb\n"),                        // pure addition at the start
        ("a\nb\nc\n", "a\nb\n"),                              // deletion of the last line
        ("p\nq\nr\ns\n", "P\nr\nS\nT\nU\n"),                  // uneven hunks
    ])
    func revertingAnySubsetMatchesMixing(old oldText: String, new newText: String) throws {
        let old = LineDiff.lines(oldText), new = LineDiff.lines(newText)
        let hunks = LineDiff.hunks(base: old, current: new)
        let rows = hunks.flatMap(LineDiff.pairs)
        let text = newText as NSString
        let lineStarts = LineIndex(string: text).lineStarts
        for mask in 0..<(1 << rows.count) {
            let chosen = Set(rows.indices.filter { mask & (1 << $0) != 0 }.map { rows[$0] })
            let edits = LineDiff.revertEdits(rows: chosen, hunks: hunks, old: old, new: new, text: text, lineStarts: lineStarts)
            let result = try TextReplacement.apply(edits.map { TextReplacement(range: $0.range, text: $0.replacement) },
                                                   to: newText)
            let expected = LineDiff.mixing(old: old, new: new, hunks: hunks, useNew: { !chosen.contains($0) })
            #expect(result == expected, "rows \(chosen.map { "\($0.old.map(String.init) ?? "-")/\($0.new.map(String.init) ?? "-")" })")
        }
    }
}

@MainActor
struct LineStagingWorkspaceTests {
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=A", "-c", "user.email=a@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func index(_ path: String, in directory: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "show", ":" + path]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func stagesTheSelectedLinesAndUnstagesSingleRows() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-lines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        let original = "one\ntwo\nthree\nfour\nfive\n"
        try original.write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "i"], in: root)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitRepository != nil })
        workspace.open(fileAt: root.appending(path: "f.txt"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually { document.diffBaseLines != nil })
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.attach(controller)
        document.editor = controller

        // One change of three lines (two..four → TWO..FOUR); the selection covers only THREE,
        // and a second cursor sits on FOUR's line.
        let text = document.textStorage.mutableString
        document.textStorage.replaceCharacters(in: text.range(of: "two\nthree\nfour"), with: "TWO\nTHREE\nFOUR")
        await document.waitForDiff()
        #expect(document.diffHunks.count == 1)
        controller.textView.setSelectedRange(text.range(of: "HRE"))
        controller.extraSelections = [NSRange(location: text.range(of: "FOUR").location, length: 0)]
        workspace.stageSelectedLines()
        #expect(try await eventually { (try? index("f.txt", in: root)) == "one\ntwo\nTHREE\nFOUR\nfive\n" })
        #expect(try await eventually { document.diffHunks == [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)] })

        // The staged diff: unstage just FOUR's row.
        let session = try #require(workspace.openChanges(for: document.url, staged: true))
        #expect(try await eventually { session.hunks.count == 1 })
        workspace.unstageRows([DiffLinePair(old: 3, new: 3)], in: session)
        #expect(try await eventually { (try? index("f.txt", in: root)) == "one\ntwo\nTHREE\nfour\nfive\n" })
        #expect(try await eventually { session.hunks == [DiffHunk(oldStart: 2, oldCount: 1, newStart: 2, newCount: 1)] })

        // Rows picked from a diff that has changed since are refused, and nothing is staged.
        let picked = [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)] // the diff before unstaging
        #expect(try await eventually { document.diffHunks.count == 2 })
        let before = try index("f.txt", in: root)
        workspace.stageRows(of: document) { $0 == picked ? [DiffLinePair(old: 1, new: 1)] : nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try index("f.txt", in: root) == before)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func revertsTheSelectedLinesAsOneUndoableEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-revert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q"], in: root)
        try "one\ntwo\nthree\nfour\nfive\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually { workspace.gitRepository != nil })
        workspace.open(fileAt: root.appending(path: "f.txt"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually { document.diffBaseLines != nil })
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.attach(controller)
        document.editor = controller

        let text = document.textStorage.mutableString
        document.textStorage.replaceCharacters(in: text.range(of: "two\nthree\nfour"), with: "TWO\nTHREE\nFOUR")
        document.textStorage.replaceCharacters(in: NSRange(location: text.length, length: 0), with: "six\n")
        await document.waitForDiff()
        document.undoManager.removeAllActions()
        // The selection runs over THREE and FOUR; TWO and the added "six" stay.
        controller.textView.setSelectedRange(NSRange(location: text.range(of: "THREE").location,
                                                     length: NSMaxRange(text.range(of: "FO")) - text.range(of: "THREE").location))
        workspace.revertSelectedLines()
        #expect(document.textStorage.string == "one\nTWO\nthree\nfour\nfive\nsix\n")
        #expect(document.undoManager.undoActionName == "Revert Selected Lines")
        document.undoManager.undo()
        #expect(document.textStorage.string == "one\nTWO\nTHREE\nFOUR\nfive\nsix\n")

        // Nothing changed under the cursor: refused, text untouched.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        workspace.revertSelectedLines()
        #expect(document.textStorage.string == "one\nTWO\nTHREE\nFOUR\nfive\nsix\n")
        withExtendedLifetime((workspace, window)) {}
    }
}
