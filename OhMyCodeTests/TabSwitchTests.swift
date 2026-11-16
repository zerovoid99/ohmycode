import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

/// Switching tabs keeps each tab's editor (see `EditorCache`) and everything about it.
@MainActor
@Suite(.serialized)
struct TabSwitchTests {
    @Test func switchingBackShowsTheSameEditorAsItWasLeft() async throws {
        let fixture = try TabSwitchFixture(files: 3, bytes: 60_000)
        defer { fixture.tearDown() }
        let (a, b) = (fixture.ids[0], fixture.ids[1])
        await fixture.show(a)
        let editorA = try #require(fixture.editor(for: a))
        #expect(editorA.textView.window === fixture.window)
        #expect(fixture.window.firstResponder === editorA.textView)

        // A selection and a scroll position deep in the file, and a fold.
        let document = try #require(fixture.workspace.document(id: a))
        let line = document.lineIndex.lineCount / 2
        let location = document.lineIndex.lineStarts[line] + 3
        editorA.textView.setSelectedRange(NSRange(location: location, length: 5))
        editorA.textView.scrollRangeToVisible(editorA.textView.selectedRange())
        fixture.window.displayIfNeeded()
        let scroll = editorA.textView.visibleRect.origin
        #expect(scroll.y > 0)

        await fixture.show(b)
        let editorB = try #require(fixture.editor(for: b))
        #expect(editorA.containerView?.isHidden == true)
        #expect(editorA.textView.isHiddenOrHasHiddenAncestor)
        #expect(editorA.isParked)
        #expect(fixture.window.firstResponder === editorB.textView)
        #expect(document.viewState?.selection == NSRange(location: location, length: 5))

        await fixture.show(a)
        #expect(fixture.editor(for: a) === editorA, "the tab's editor was made again")
        #expect(!editorA.isParked)
        #expect(editorA.textView.window === fixture.window)
        #expect(fixture.window.firstResponder === editorA.textView)
        #expect(editorA.textView.selectedRange() == NSRange(location: location, length: 5))
        #expect(editorA.textView.visibleRect.origin == scroll)
        #expect(document.editor === editorA)
    }

    /// A hidden editor isn't resized with the window; shown at the new size, it's back at the
    /// line it showed (as a new editor would be: `restoreViewState`), and a hidden editor
    /// doesn't take the focus.
    @Test func aTabShownAtAnotherSizeKeepsItsPlace() async throws {
        let fixture = try TabSwitchFixture(files: 2, bytes: 60_000)
        defer { fixture.tearDown() }
        let (a, b) = (fixture.ids[0], fixture.ids[1])
        await fixture.show(a)
        let editorA = try #require(fixture.editor(for: a))
        editorA.reveal(line: 900)
        fixture.window.displayIfNeeded()
        let top = editorA.topVisibleLine
        let selection = editorA.textView.selectedRange()
        #expect(top > 0)

        await fixture.show(b)
        let editorB = try #require(fixture.editor(for: b))
        let size = try #require(editorA.containerView?.frame.size)
        fixture.window.setContentSize(NSSize(width: 700, height: 500))
        await fixture.show(b)
        #expect(editorA.containerView?.frame.size == size, "a hidden editor was resized")
        editorA.focus()
        #expect(fixture.window.firstResponder === editorB.textView)

        await fixture.show(a)
        #expect(editorA.containerView?.frame.size == editorA.containerView?.superview?.bounds.size)
        #expect(editorA.textView.selectedRange() == selection)
        #expect(abs(editorA.topVisibleLine - top) <= 1, "top \(top) now \(editorA.topVisibleLine), size \(size) now \(String(describing: editorA.containerView?.frame.size))")
    }

    /// A reveal (go to definition, search result) in a tab that's being switched to waits for
    /// its editor to be shown.
    @Test func revealInAHiddenTabHappensWhenItShows() async throws {
        let fixture = try TabSwitchFixture(files: 2, bytes: 60_000)
        defer { fixture.tearDown() }
        let (a, b) = (fixture.ids[0], fixture.ids[1])
        await fixture.show(a)
        await fixture.show(b)
        let editorA = try #require(fixture.editor(for: a))
        let document = try #require(fixture.workspace.document(id: a))
        let target = NSRange(location: document.lineIndex.lineStarts[document.lineIndex.lineCount - 10], length: 4)

        fixture.workspace.activeDocumentID = a
        document.reveal(target)
        #expect(editorA.textView.selectedRange() != target, "revealed while hidden")
        await fixture.show(a)
        #expect(editorA.textView.selectedRange() == target)
        #expect(editorA.textView.visibleRect.intersects(try #require(editorA.rect(for: target))))
        #expect(fixture.window.firstResponder === editorA.textView)
    }

    @Test func theFindBarStaysWithItsTab() async throws {
        let fixture = try TabSwitchFixture(files: 2, bytes: 20_000)
        defer { fixture.tearDown() }
        let (a, b) = (fixture.ids[0], fixture.ids[1])
        await fixture.show(a)
        let editorA = try #require(fixture.editor(for: a))
        editorA.showFindInterface()
        let scrollView = try #require(editorA.textView.enclosingScrollView)
        #expect(scrollView.isFindBarVisible)
        await fixture.show(b)
        #expect(fixture.editor(for: b)?.textView.enclosingScrollView?.isFindBarVisible == false)
        await fixture.show(a)
        #expect(scrollView.isFindBarVisible)
    }

    /// Each tab of a split has its own editor; a tab moved to another group leaves its old one.
    @Test func splitsKeepTheirOwnEditors() async throws {
        let fixture = try TabSwitchFixture(files: 2, bytes: 20_000)
        defer { fixture.tearDown() }
        let workspace = fixture.workspace
        let first = workspace.activeGroup
        await fixture.show(fixture.ids[0])
        workspace.splitEditor()
        let second = workspace.activeGroup
        #expect(second !== first)
        let host = NSHostingView(rootView: EditorGroupView(workspace: workspace, group: second))
        fixture.window.contentView?.addSubview(host)
        host.frame = NSRect(x: 600, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let document = try #require(workspace.document(id: fixture.ids[0]))
        let left = try #require(document.editor(inGroup: first))
        let right = try #require(document.editor(inGroup: second))
        #expect(left !== right)
        #expect(second.editorCache.controller(for: document.id) === right)
        #expect(first.editorCache.controller(for: document.id) === left)

        #expect(workspace.activeGroup === second)
        workspace.moveActiveEditor(by: -1) // back into the first group, which has it already
        #expect(!second.contains(document.id))
        #expect(!workspace.groups.contains { $0 === second })
        host.layoutSubtreeIfNeeded()
        #expect(second.editorCache.controller(for: document.id) == nil)
        host.removeFromSuperview()
    }

    /// Only the most recently shown editors are kept; an older tab gets a new editor, back
    /// where it was.
    @Test func theCacheIsBounded() async throws {
        let fixture = try TabSwitchFixture(files: 4, bytes: 60_000)
        defer { fixture.tearDown() }
        let cache = fixture.workspace.activeGroup.editorCache
        cache.capacity = 2
        weak var weakFirst: EditorController?
        await fixture.show(fixture.ids[0])
        let document = try #require(fixture.workspace.document(id: fixture.ids[0]))
        let location = document.lineIndex.lineStarts[document.lineIndex.lineCount / 2]
        autoreleasepool {
            weakFirst = fixture.editor(for: fixture.ids[0])
            weakFirst?.textView.setSelectedRange(NSRange(location: location, length: 0))
        }
        for id in fixture.ids.dropFirst() { await fixture.show(id) }
        #expect(cache.documentIDs == Array(fixture.ids.suffix(2)))
        #expect(weakFirst == nil, "an evicted editor was kept")

        await fixture.show(fixture.ids[0])
        #expect(fixture.editor(for: fixture.ids[0])?.textView.selectedRange().location == location)
    }

    /// Hidden editors of big files go beyond the memory budget; the last one hidden stays.
    @Test func hiddenEditorsStayWithinTheMemoryBudget() async throws {
        let fixture = try TabSwitchFixture(files: 4, bytes: 20_000)
        defer { fixture.tearDown() }
        let cache = fixture.workspace.activeGroup.editorCache
        let document = try #require(fixture.workspace.document(id: fixture.ids[0]))
        cache.parkedMemoryBudget = EditorCache.estimatedCost(of: document) * 2 + 1
        for id in fixture.ids { await fixture.show(id) }
        #expect(cache.documentIDs == Array(fixture.ids.suffix(3)))
        cache.parkedMemoryBudget = 0
        await fixture.show(fixture.ids[0])
        #expect(cache.documentIDs == [fixture.ids[3], fixture.ids[0]])
    }

    /// A closed tab's editor and document go, also from the editor cache.
    @Test func closedTabReleasesItsEditorAndDocument() async throws {
        let fixture = try TabSwitchFixture(files: 3, bytes: 20_000)
        defer { fixture.tearDown() }
        weak var weakDocument: EditorDocument?
        weak var weakEditor: EditorController?
        weak var weakLine: NSView?
        await {
            for id in fixture.ids { await fixture.show(id) }
            await fixture.show(fixture.ids[1])
            await fixture.show(fixture.ids[2]) // the closed tab is hidden, its editor parked
            let document = fixture.workspace.document(id: fixture.ids[1])
            weakDocument = document
            weakEditor = fixture.editor(for: fixture.ids[1])
            weakLine = weakEditor?.textView.subviews.flatMap(\.subviews).first
            if let document { fixture.workspace.close(document) }
            await fixture.show(fixture.ids[2])
        }()
        for step in 0..<60 where step < 5 || weakEditor != nil || weakDocument != nil || weakLine != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(weakEditor == nil, "the closed tab's editor was kept")
        #expect(weakDocument == nil, "the closed tab's document was kept")
        #expect(weakLine == nil, "a line's view outlived its editor")

        // Closing the shown tab too.
        weak var weakShown: EditorDocument?
        await {
            let document = fixture.workspace.document(id: fixture.ids[2])
            weakShown = document
            if let document { fixture.workspace.close(document) }
            await fixture.show(fixture.ids[0])
        }()
        for step in 0..<60 where step < 5 || weakShown != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(weakShown == nil, "the closed active tab's document was kept")
        #expect(fixture.workspace.activeGroup.editorCache.documentIDs == [fixture.ids[0]])
    }
}
