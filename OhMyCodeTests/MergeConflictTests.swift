import AppKit
import Testing
@testable import Oh_My_Code

struct ConflictParserTests {
    private func parse(_ text: String) -> [MergeConflict] { ConflictParser.conflicts(in: text as NSString) }
    private func resolve(_ text: String, _ resolution: MergeConflict.Resolution) throws -> String {
        let string = text as NSString
        let edits = parse(text).map { TextReplacement(range: $0.range, text: $0.text(for: resolution, in: string)) }
        return try TextReplacement.apply(edits, to: text)
    }

    let twoWay = """
    keep
    <<<<<<< HEAD
    ours 1
    ours 2
    =======
    theirs
    >>>>>>> feature/x
    tail

    """

    @Test func readsTwoWayConflicts() throws {
        let conflicts = parse(twoWay)
        #expect(conflicts.count == 1)
        let conflict = try #require(conflicts.first)
        let text = twoWay as NSString
        #expect(conflict.currentLabel == "HEAD" && conflict.incomingLabel == "feature/x" && conflict.base == nil)
        #expect(text.substring(with: conflict.current) == "ours 1\nours 2\n")
        #expect(text.substring(with: conflict.incoming) == "theirs\n")
        #expect(text.substring(with: conflict.startMarker) == "<<<<<<< HEAD")
        #expect(try resolve(twoWay, .current) == "keep\nours 1\nours 2\ntail\n")
        #expect(try resolve(twoWay, .incoming) == "keep\ntheirs\ntail\n")
        #expect(try resolve(twoWay, .both) == "keep\nours 1\nours 2\ntheirs\ntail\n")
    }

    @Test func readsDiff3CRLFAndEndOfFile() throws {
        let diff3 = "<<<<<<< ours\r\na\r\n||||||| base\r\nb\r\n=======\r\nc\r\n>>>>>>> theirs" // no final newline
        let conflict = try #require(parse(diff3).first)
        let text = diff3 as NSString
        #expect(text.substring(with: try #require(conflict.base)) == "b\r\n")
        #expect(text.substring(with: conflict.startMarker) == "<<<<<<< ours")
        #expect(NSMaxRange(conflict.range) == text.length)
        #expect(try resolve(diff3, .incoming) == "c\r\n")
        // Empty sides (one branch deleted the lines).
        let empty = "<<<<<<< HEAD\n=======\nnew\n>>>>>>> b\n"
        #expect(try resolve(empty, .current) == "" && resolve(empty, .incoming) == "new\n")
    }

    @Test func ignoresMalformedAndLookalikeMarkers() {
        #expect(parse("no conflicts here\n").isEmpty)
        #expect(parse("<<<<<<< HEAD\nonly a start\n=======\nno end\n").isEmpty)
        #expect(parse("  <<<<<<< indented\n=======\n>>>>>>> x\n").isEmpty)
        #expect(parse("<<<<<<<< eight\n=======\n>>>>>>> x\n").isEmpty)                 // not a marker
        #expect(parse("<<<<<<< a\none\n======= not a separator\n>>>>>>> b\n").isEmpty) // separator must stand alone
        // An unfinished conflict followed by a complete one: only the complete one counts.
        let text = "<<<<<<< a\nbroken\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b\n"
        let conflicts = parse(text)
        #expect(conflicts.count == 1 && (text as NSString).substring(with: conflicts[0].current) == "x\n")
        // Two conflicts.
        #expect(parse(twoWay + twoWay).count == 2)
    }
}

@MainActor
struct MergeConflictEditorTests {
    private func show(_ document: EditorDocument) -> (EditorController, NSWindow) {
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.attach(controller)
        document.editor = controller
        return (controller, window)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func clickingAnActionResolvesAndUndoBringsItBack() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-conflict-\(UUID().uuidString).txt")
        let original = "a\n<<<<<<< HEAD\nmine\n=======\nyours\n>>>>>>> other\nb\n<<<<<<< HEAD\n1\n=======\n2\n>>>>>>> other\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        #expect(document.conflicts.count == 2) // found on open
        let (controller, window) = show(document)

        let actions = controller.conflictActionRects()
        #expect(actions.count == 8)
        #expect(controller.conflictBands().filter { $0.kind == .current }.count == 2)
        // Actions sit after the "<<<<<<<" line, left to right.
        let marker = try #require(controller.rect(for: document.conflicts[0].startMarker))
        #expect(actions[0].rect.minX > marker.maxX && abs(actions[0].rect.minY - marker.minY) < 1)
        #expect(actions.map(\.action).prefix(4) == [.accept(.current), .accept(.incoming), .accept(.both), .compare])

        let incoming = actions[1]
        #expect(controller.handleConflictClick(at: NSPoint(x: incoming.rect.midX, y: incoming.rect.midY)))
        #expect(document.textStorage.string == "a\nyours\nb\n<<<<<<< HEAD\n1\n=======\n2\n>>>>>>> other\n")
        #expect(document.undoManager.undoActionName == "Accept Incoming")
        #expect(try await eventually { document.conflicts.count == 1 })
        #expect(!controller.handleConflictClick(at: NSPoint(x: 1, y: 1))) // not on an action

        // Next/previous conflict and the palette's "at cursor" actions.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.revealConflict(forward: true)
        #expect(controller.textView.selectedRange().location == document.conflicts[0].range.location)
        controller.resolveConflictAtCursor(with: .both)
        #expect(document.textStorage.string == "a\nyours\nb\n1\n2\n")

        document.undoManager.undo()
        document.undoManager.undo()
        #expect(document.textStorage.string == original)
        #expect(try await eventually { document.conflicts.count == 2 })
        #expect(document.resolve(document.conflicts, with: .current))
        #expect(document.textStorage.string == "a\nmine\nb\n1\n")
        #expect(document.undoManager.undoActionName == "Accept Current (All)")
        withExtendedLifetime(window) {}
    }

    @Test func compareOpensBothSidesInADiffTab() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "Cart.swift")
        try "struct Cart {\n<<<<<<< HEAD\n    var total = 1\n    var tax = 0\n=======\n    var total = 2\n    var tax = 0\n>>>>>>> feature\n}\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: url)
        let document = try #require(workspace.activeDocument)
        let (controller, window) = show(document)

        let compare = try #require(controller.conflictActionRects().first { $0.action == .compare })
        #expect(controller.handleConflictClick(at: NSPoint(x: compare.rect.midX, y: compare.rect.midY)))
        let session = try #require(workspace.diffSession(id: workspace.activeGroup.activeDocumentID))
        #expect(workspace.tabInfo(session.id)?.title == "Cart.swift (Current ↔ Incoming)")
        #expect(session.sideLabels.base == "Current: HEAD" && session.sideLabels.current == "Incoming: feature")
        #expect(session.baseLines == ["    var total = 1", "    var tax = 0", ""])
        #expect(session.hunks == [DiffHunk(oldStart: 0, oldCount: 1, newStart: 0, newCount: 1)])
        #expect(document.textStorage.string.contains("<<<<<<<")) // comparing changes nothing

        // The same conflict again: the same tab.
        controller.textView.setSelectedRange(NSRange(location: document.conflicts[0].current.location, length: 0))
        controller.compareConflict()
        #expect(workspace.diffSessions.count == 1 && workspace.activeGroup.activeDocumentID == session.id)
        withExtendedLifetime((workspace, window)) {}
    }

    /// A conflict as git writes it.
    @Test func readsAConflictGitMade() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-gitconflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "user.name=A", "-c", "user.email=a@example.invalid",
                                 "-c", "commit.gpgsign=false", "-c", "merge.conflictStyle=diff3"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        let file = root.appending(path: "f.txt")
        try git(["init", "-q", "-b", "main"])
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-qm", "base"])
        try git(["switch", "-qc", "side"])
        try "one\nSIDE\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "side"])
        try git(["switch", "-q", "main"])
        try "one\nMAIN\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "main"])
        try git(["merge", "side"])

        let document = try EditorDocument(url: file)
        let conflict = try #require(document.conflicts.first)
        let text = document.textStorage.mutableString
        #expect(conflict.currentLabel == "HEAD" && conflict.incomingLabel == "side")
        #expect(text.substring(with: conflict.current) == "MAIN\n" && text.substring(with: conflict.incoming) == "SIDE\n")
        #expect(conflict.base.map { text.substring(with: $0) } == "two\n")
        #expect(document.resolve([conflict], with: .incoming))
        #expect(document.textStorage.string == "one\nSIDE\nthree\n")
    }
}
