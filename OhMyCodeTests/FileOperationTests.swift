import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct FileOperationTests {
    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-files-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func newFilesAndFolders() throws {
        let root = try makeFolder(["a.txt": "a"])
        let workspace = Workspace()
        workspace.openFolder(root)
        let file = try #require(workspace.newFile(in: root, named: "src/new.txt"))
        #expect(FileManager.default.fileExists(atPath: file.path) && workspace.activeDocument?.url.lastPathComponent == "new.txt")
        #expect(workspace.newFile(in: root, named: "a.txt") == nil && workspace.errorMessage?.contains("already exists") == true)
        workspace.errorMessage = nil
        #expect(workspace.newFile(in: root, named: "  ") == nil && workspace.errorMessage != nil)
        let folder = try #require(workspace.newFolder(in: root, named: "docs"))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        // New items go in the selected folder, or the selected file's folder.
        #expect(workspace.folder(for: file)?.standardizedFileURL.path == root.appending(path: "src").standardizedFileURL.path)
        #expect(workspace.folder(for: folder)?.lastPathComponent == "docs" && workspace.folder(for: nil) == root)
    }

    @Test func renameUpdatesReferencesAndTellsTheServer() async throws {
        let (workspace, document, _, window) = try LanguageClientTests.makeWorkspace(
            text: "// include \"other.swift\"\n", files: ["other.swift": "let x = 1\n"])
        #expect(try await LanguageClientTests.eventually { document.languageClient?.state == .ready })
        let root = try #require(workspace.rootURL)
        let renamed = await workspace.rename(root.appending(path: "other.swift"), to: "renamed.swift")
        #expect(renamed?.lastPathComponent == "renamed.swift")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "renamed.swift").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "other.swift").path))
        // The reference was updated (unsaved, to review).
        #expect(document.textStorage.string == "// include \"renamed.swift\"\n" && document.isDirty)
        let client = try #require(document.languageClient)
        let renames = try await client.request("omc/renamed", params: nil) as? [[String]]
        #expect(renames?.count == 1 && renames?.first?.last?.hasSuffix("renamed.swift") == true)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func openTabsFollowWithTheirUnsavedText() async throws {
        let root = try makeFolder(["lib/a.txt": "saved\n", "b.txt": "b"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "b.txt"))
        workspace.open(fileAt: root.appending(path: "lib/a.txt"))
        let document = try #require(workspace.activeDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "unsaved ")
        let tabIndex = try #require(workspace.activeGroup.documentIDs.firstIndex(of: document.id))

        // Move the folder: the tab now shows the file at its new path, in the same place.
        _ = workspace.newFolder(in: root, named: "pkg")
        let moved = await workspace.move(root.appending(path: "lib"), into: root.appending(path: "pkg"))
        #expect(moved?.path.hasSuffix("pkg/lib") == true)
        let following = try #require(workspace.activeDocument)
        #expect(following.url.path.hasSuffix("pkg/lib/a.txt") && following.textStorage.string == "unsaved saved\n" && following.isDirty)
        #expect(workspace.activeGroup.documentIDs[tabIndex] == following.id)
        #expect(!workspace.documents.contains { $0 === document })

        // Not into itself, not out of the folder, not over another file.
        #expect(await workspace.move(root.appending(path: "pkg"), into: root.appending(path: "pkg/lib")) == nil)
        #expect(await workspace.move(root.appending(path: "b.txt"), to: FileManager.default.temporaryDirectory.appending(path: "x-\(UUID()).txt")) == nil)
        try "c".write(to: root.appending(path: "c.txt"), atomically: true, encoding: .utf8)
        #expect(await workspace.rename(root.appending(path: "b.txt"), to: "c.txt") == nil)
    }

    @Test func trashClosesTabs() throws {
        let root = try makeFolder(["a.txt": "a", "b.txt": "b"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.txt"))
        var trashed: [URL] = []
        let savedTrash = Workspace.moveToTrash, savedConfirm = Workspace.confirmTrash
        nonisolated(unsafe) var sink: [URL] = []
        Workspace.moveToTrash = { url in sink.append(url); try FileManager.default.removeItem(at: url) }
        defer { Workspace.moveToTrash = savedTrash; Workspace.confirmTrash = savedConfirm }

        Workspace.confirmTrash = { _ in false }
        workspace.trash([root.appending(path: "a.txt")])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "a.txt").path))

        Workspace.confirmTrash = { _ in true }
        workspace.trash([root.appending(path: "a.txt")])
        trashed = sink
        #expect(trashed.map(\.lastPathComponent) == ["a.txt"] && workspace.documents.isEmpty)
    }
}
