import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct LocalHistoryTests {
    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-history-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func keepsVersionsWithinLimits() throws {
        let history = LocalHistory(directory: FileManager.default.temporaryDirectory.appending(path: "omc-lh-\(UUID().uuidString)"))
        let folder = URL(filePath: "/tmp/omc-lh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "a.txt")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let start = Date()
        #expect(history.record("one", for: url, reason: .saved, date: start) != nil)
        #expect(history.record("one", for: url, reason: .saved, date: start.addingTimeInterval(1)) == nil) // the same again
        let two = try #require(history.record("two", for: url, reason: .beforeReload, date: start.addingTimeInterval(2)))
        #expect(history.entries(for: url).map(\.reason) == [.beforeReload, .saved])
        #expect(history.text(of: two, for: url) == "two" && two.size == 3)
        // One file, however its path is spelled (/tmp is /private/tmp).
        #expect(history.folder(for: url) == history.folder(for: URL(filePath: "/private" + url.path)))

        // At most 50, none older than 30 days.
        for index in 0..<60 { history.record("v\(index)", for: url, reason: .saved, date: start.addingTimeInterval(Double(10 + index))) }
        var entries = history.entries(for: url)
        #expect(entries.count == LocalHistory.maxEntriesPerFile && history.text(of: entries[0], for: url) == "v59")
        let files = try FileManager.default.contentsOfDirectory(atPath: history.folder(for: url).path)
        #expect(files.count == LocalHistory.maxEntriesPerFile + 1) // and index.json
        history.record("later", for: url, reason: .saved, date: start.addingTimeInterval(31 * 24 * 3600))
        #expect(history.entries(for: url).map { history.text(of: $0, for: url) } == ["later"])

        // Too big, or the history's own files: not kept.
        #expect(history.record(String(repeating: "x", count: LocalHistory.maxFileSize + 1), for: url, reason: .saved) == nil)
        #expect(history.record("x", for: history.directory.appending(path: "f/1.txt"), reason: .saved) == nil)

        entries = history.entries(for: url)
        history.remove(entries[0], for: url)
        #expect(history.entries(for: url).isEmpty)
    }

    @Test func savingAndReloadingKeepVersions() throws {
        let root = try makeFolder(["a.txt": "original\n"])
        let url = root.appending(path: "a.txt")
        let document = try EditorDocument(url: url)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 8), with: "first")
        try document.save()
        // The version before this session's first save, then what was saved.
        var entries = LocalHistory.shared.entries(for: url)
        #expect(entries.map(\.reason) == [.saved, .beforeSave])
        #expect(entries.map { LocalHistory.shared.text(of: $0, for: url) } == ["first\n", "original\n"])

        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "second")
        try document.save()
        #expect(LocalHistory.shared.entries(for: url).count == 3) // the disk had the last saved version

        // Another program changes the file: what the editor had is kept first.
        try "outside\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        document.reloadFromDiskIfChanged()
        #expect(document.textStorage.string == "outside\n")
        entries = LocalHistory.shared.entries(for: url)
        #expect(entries.first?.reason == .saved) // "second" was already kept: not again
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        try "elsewhere\n".write(to: url, atomically: true, encoding: .utf8)
        try document.save() // replaces another program's version: kept first
        #expect(LocalHistory.shared.entries(for: url).prefix(2).map { LocalHistory.shared.text(of: $0, for: url) } == ["xoutside\n", "elsewhere\n"])
    }

    @Test func comparesAndRestores() async throws {
        let root = try makeFolder(["a.txt": "one\ntwo\n"])
        let url = root.appending(path: "a.txt")
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: url)
        let document = try #require(workspace.activeDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 4, length: 3), with: "TWO")
        _ = workspace.save(document)
        let original = try #require(LocalHistory.shared.entries(for: url).first { $0.reason == .beforeSave })

        let session = try #require(workspace.compare(original, with: url))
        #expect(session.mode == .history(original) && session.title.hasPrefix("a.txt (") && session.sideLabels.current == "Current")
        await session.refreshCompare()
        #expect(session.hunks.count == 1)
        #expect(workspace.compare(original, with: url) === session) // one tab per version

        // Unsaved edits are kept before restoring.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "draft ")
        workspace.restore(original, of: url)
        #expect(document.textStorage.string == "one\ntwo\n" && document.isDirty)
        let kept = try #require(LocalHistory.shared.entries(for: url).first)
        #expect(kept.reason == .beforeRestore && LocalHistory.shared.text(of: kept, for: url) == "draft one\nTWO\n")
        document.undoManager.undo()
        #expect(document.textStorage.string == "draft one\nTWO\n")
    }
}
