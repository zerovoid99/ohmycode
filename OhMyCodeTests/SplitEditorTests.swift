import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct SplitEditorTests {
    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-split-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// An editor view in a window, as a group's pane would show it.
    private func show(_ document: EditorDocument, in group: EditorGroup?, x: CGFloat = 0) -> (EditorController, NSWindow) {
        let controller = EditorController(document: document, group: group)
        let window = NSWindow(contentRect: NSRect(x: x, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.attach(controller)
        return (controller, window)
    }

    @Test func twoEditorsShareOneBuffer() async throws {
        let root = try makeFolder(["a.swift": (1...100).map { "let value\($0) = \($0)" }.joined(separator: "\n")])
        let document = try EditorDocument(url: root.appending(path: "a.swift"))
        let (left, leftWindow) = show(document, in: nil)
        let (right, rightWindow) = show(document, in: nil, x: 600)
        #expect(document.textContentStorage.textLayoutManagers.count == 2)

        // The right editor has its cursor further down; the left one edits above it.
        right.textView.setSelectedRange(NSRange(location: 500, length: 0))
        let rightCharacter = (document.textStorage.string as NSString).substring(with: NSRange(location: 500, length: 1))
        left.textView.setSelectedRange(NSRange(location: 0, length: 0))
        leftWindow.makeFirstResponder(left.textView)
        left.textView.insertText("// header\n", replacementRange: left.textView.selectedRange())
        #expect(document.textStorage.string.hasPrefix("// header\nlet value1"))

        // Both views lay out the new text, and the other view's cursor stays on its character.
        for controller in [left, right] {
            controller.textView.layoutSubtreeIfNeeded()
            let rect = try #require(controller.rect(for: NSRange(location: 0, length: 9)))
            #expect(rect.width > 30, "the edit isn't laid out in one of the editors")
        }
        let rightSelection = right.textView.selectedRange()
        #expect(rightSelection.location <= document.textStorage.length)
        #expect((document.textStorage.string as NSString).substring(with: NSRange(location: rightSelection.location, length: 1)) == rightCharacter)

        // Typing in the right editor works too, and each gets syntax highlights for its own viewport.
        rightWindow.makeFirstResponder(right.textView)
        right.textView.insertText("x", replacementRange: NSRange(location: document.textStorage.length, length: 0))
        #expect(document.textStorage.string.hasSuffix("= 100x"))
        #expect(document.editor === right)

        let highlighter = try #require(document.highlighter)
        highlighter.addClient(left)
        highlighter.addClient(right)
        right.textView.scrollRangeToVisible(NSRange(location: document.textStorage.length, length: 0))
        right.textView.layoutSubtreeIfNeeded()
        await highlighter.waitUntilIdle()
        let leftRange = try #require(left.highlightRange)
        let rightRange = try #require(right.highlightRange)
        #expect(leftRange.location == 0)
        #expect(NSMaxRange(rightRange) == document.textStorage.length)
        #expect(left.highlightedRange == leftRange, "left editor wasn't highlighted")
        #expect(right.highlightedRange == rightRange, "right editor wasn't highlighted")
        withExtendedLifetime((leftWindow, rightWindow)) {}
    }

    @Test func closingAnEditorDetachesItsLayoutManager() throws {
        let root = try makeFolder(["a.txt": "hello\n"])
        let document = try EditorDocument(url: root.appending(path: "a.txt"))
        let (kept, keptWindow) = show(document, in: nil)
        autoreleasepool {
            var (closing, window): (EditorController?, NSWindow?) = show(document, in: nil)
            #expect(document.textContentStorage.textLayoutManagers.count == 2)
            window?.contentView = nil
            window = nil
            closing = nil
            _ = closing
        }
        #expect(document.textContentStorage.textLayoutManagers.count == 1)
        #expect(document.editors.count == 1)
        withExtendedLifetime((kept, keptWindow)) {}
    }

    @Test func groupsHaveTheirOwnTabsAndCloseIndependently() throws {
        let root = try makeFolder(["a.txt": "a\n", "b.txt": "b\n", "c.txt": "c\n"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.txt"))
        workspace.open(fileAt: root.appending(path: "b.txt"))
        let first = workspace.activeGroup
        let b = try #require(workspace.activeDocument)

        workspace.splitEditor()
        #expect(workspace.groups.count == 2)
        let second = workspace.activeGroup
        #expect(second !== first)
        #expect(second.documentIDs == [b.id])
        #expect(first.documentIDs.count == 2)

        // Opening a file goes to the active group only.
        workspace.open(fileAt: root.appending(path: "c.txt"))
        #expect(workspace.activeDocument?.fileName == "c.txt")
        #expect(second.documentIDs.count == 2 && first.documentIDs.count == 2)
        #expect(workspace.documents.count == 3) // b is one document in two groups

        // Closing b in one group keeps it open in the other.
        workspace.close(b, in: second)
        #expect(workspace.documents.contains { $0 === b })
        #expect(first.contains(b.id) && !second.contains(b.id))

        // Closing the last tab of a group removes the group.
        let c = try #require(workspace.activeDocument)
        workspace.close(c, in: second)
        #expect(workspace.groups.map(\.id) == [first.id])
        #expect(workspace.activeGroupID == first.id)
        #expect(!workspace.documents.contains { $0 === c })

        // Moving a tab creates a group at the edge, and the source keeps its other tab.
        workspace.activeDocumentID = b.id
        workspace.moveActiveEditor(by: 1)
        #expect(workspace.groups.count == 2)
        #expect(workspace.activeGroup.documentIDs == [b.id])
        #expect(!first.contains(b.id) && first.documentIDs.count == 1)
        workspace.moveActiveEditor(by: -1) // moving its only tab back closes the group
        #expect(workspace.groups.count == 1 && first.contains(b.id))

        workspace.splitEditor()
        workspace.splitEditor()
        workspace.splitEditor()
        workspace.splitEditor() // over the limit: ignored
        #expect(workspace.groups.count == Workspace.maxGroups)
        workspace.focusGroup(at: 0)
        #expect(workspace.activeGroupID == first.id)
        workspace.closeAll()
        #expect(workspace.documents.isEmpty && workspace.groups.count == 1)
        withExtendedLifetime(workspace) {}
    }

    /// Search results and go-to-definition land in the active group's editor, not in another
    /// split that happens to show the same file.
    @Test func revealUsesTheActiveGroupsEditor() throws {
        let root = try makeFolder(["a.txt": (1...50).map { "line \($0)" }.joined(separator: "\n")])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.txt"))
        let document = try #require(workspace.activeDocument)
        let first = workspace.activeGroup
        let (leftEditor, leftWindow) = show(document, in: first)
        workspace.splitEditor()
        let second = workspace.activeGroup
        let (rightEditor, rightWindow) = show(document, in: second, x: 600)

        workspace.focusGroup(at: 0)
        workspace.focusGroup(at: 1)
        #expect(document.editor === rightEditor)
        document.revealLine(40)
        let line40 = document.lineIndex.lineStarts[39]
        #expect(rightEditor.textView.selectedRange().location == line40)
        #expect(leftEditor.textView.selectedRange().location != line40)

        workspace.focusGroup(at: 0)
        #expect(document.editor === leftEditor)
        withExtendedLifetime((workspace, leftWindow, rightWindow)) {}
    }

    @Test func draggingTabsReordersAndMovesBetweenGroups() throws {
        let root = try makeFolder(["a.txt": "a\n", "b.txt": "b\n", "c.txt": "c\n", "d.txt": "d\n"])
        let workspace = Workspace()
        workspace.openFolder(root)
        for name in ["a", "b", "c"] { workspace.open(fileAt: root.appending(path: "\(name).txt")) }
        let first = workspace.activeGroup
        func names(_ group: EditorGroup) -> [String] { workspace.documents(in: group).map(\.fileName) }
        let a = try #require(workspace.documents.first { $0.fileName == "a.txt" })
        let c = try #require(workspace.documents.first { $0.fileName == "c.txt" })

        // Reorder: drop index is a position between tabs (before the tab at that index).
        workspace.moveTab(a.id, from: first, to: first, at: 3)      // after the last tab
        #expect(names(first) == ["b.txt", "c.txt", "a.txt"])
        workspace.moveTab(a.id, from: first, to: first, at: 0)
        #expect(names(first) == ["a.txt", "b.txt", "c.txt"])
        workspace.moveTab(a.id, from: first, to: first, at: 1)      // its own slot: no change
        #expect(names(first) == ["a.txt", "b.txt", "c.txt"])
        #expect(workspace.activeDocumentID == a.id)

        // Into another group at a position; the moved tab becomes active there.
        workspace.open(fileAt: root.appending(path: "d.txt"))
        workspace.splitEditor()
        let second = workspace.activeGroup
        #expect(names(second) == ["d.txt"])
        workspace.moveTab(c.id, from: first, to: second, at: 0)
        #expect(names(second) == ["c.txt", "d.txt"] && names(first) == ["a.txt", "b.txt", "d.txt"])
        #expect(workspace.activeGroupID == second.id && workspace.activeDocumentID == c.id)

        // Dropping a tab on a group that already shows it just moves the existing tab.
        let d = try #require(workspace.documents.first { $0.fileName == "d.txt" })
        workspace.moveTab(d.id, from: first, to: second, at: 0)
        #expect(names(second) == ["d.txt", "c.txt"] && names(first) == ["a.txt", "b.txt"])

        // Moving a group's only tab away closes that group.
        for document in workspace.documents(in: second) { workspace.moveTab(document.id, from: second, to: first, at: 99) }
        #expect(workspace.groups.map(\.id) == [first.id])
        #expect(names(first) == ["a.txt", "b.txt", "d.txt", "c.txt"])
        #expect(workspace.documents.count == 4)
        withExtendedLifetime(workspace) {}
    }

    @Test func tabDragPayloadRoundTripsAndIgnoresOtherText() {
        let payload = TabDragPayload(documentID: UUID(), groupID: UUID())
        #expect(TabDragPayload(payload.string) == payload)
        #expect(TabDragPayload("some dragged text") == nil)
        #expect(TabDragPayload("omc-tab:not-a-uuid:x") == nil)
    }
}
