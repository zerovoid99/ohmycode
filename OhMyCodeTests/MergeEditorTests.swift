import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

@MainActor
struct MergeEditorTests {
    private static let text = """
    top
    <<<<<<< HEAD
    mine 1
    =======
    theirs 1
    >>>>>>> feature
    middle
    <<<<<<< HEAD
    mine 2
    ||||||| base
    original 2
    =======
    theirs 2
    >>>>>>> feature
    end

    """

    private func makeDocument() async throws -> (Workspace, EditorDocument) {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.text.write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.txt"))
        let document = try #require(workspace.activeDocument)
        let deadline = ContinuousClock.now + .seconds(5)
        while document.conflicts.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return (workspace, document)
    }

    @Test func choosesSidesAndAppliesThemAsOneStep() async throws {
        let (workspace, document) = try await makeDocument()
        workspace.openMergeEditor()
        let session = try #require(workspace.pendingMerge)
        #expect(session.conflicts.count == 2 && session.unresolvedCount == 2)
        #expect(session.conflicts[0].current == "mine 1\n" && session.conflicts[0].base == nil)
        #expect(session.conflicts[1].base == "original 2\n" && session.conflicts[1].line == 8)
        #expect(session.conflicts[0].currentLabel == "HEAD" && session.conflicts[0].incomingLabel == "feature")

        session.choices[0] = .incoming
        session.choices[1] = .bothIncomingFirst
        #expect(session.result == "top\ntheirs 1\nmiddle\ntheirs 2\nmine 2\nend\n" && session.unresolvedCount == 0)
        #expect(workspace.applyMerge(session))
        #expect(workspace.pendingMerge == nil && document.textStorage.string == session.result && document.isDirty)
        document.undoManager.undo()
        #expect(document.textStorage.string == Self.text)
    }

    @Test func unresolvedConflictsKeepTheirMarkers() async throws {
        let (workspace, document) = try await makeDocument()
        workspace.openMergeEditor()
        let session = try #require(workspace.pendingMerge)
        session.choices[1] = .current
        workspace.applyMerge(session)
        #expect(document.textStorage.string.contains("<<<<<<< HEAD\nmine 1") && document.textStorage.string.contains("middle\nmine 2\nend"))
        #expect(ConflictParser.conflicts(in: document.textStorage.mutableString).count == 1)
        // Accept All.
        workspace.openMergeEditor()
        let again = try #require(workspace.pendingMerge)
        again.chooseAll(.current)
        workspace.applyMerge(again)
        #expect(ConflictParser.conflicts(in: document.textStorage.mutableString).isEmpty)
    }

    @Test func aFileChangedMeanwhileIsntTouched() async throws {
        let (workspace, document) = try await makeDocument()
        workspace.openMergeEditor()
        let session = try #require(workspace.pendingMerge)
        session.chooseAll(.incoming)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        #expect(!workspace.applyMerge(session))
        #expect(document.textStorage.string == "x" + Self.text && workspace.errorMessage?.contains("changed while merging") == true)
        // No conflicts: nothing to open.
        let plain = Workspace()
        plain.openMergeEditor()
        #expect(plain.pendingMerge == nil)
    }

    @Test func theEditorOffersIt() throws {
        #expect(MergeConflict.Action.allCases.map(\.title).last == "Merge Editor")
    }
}
