import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct SessionTests {
    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-session-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func unsavedChangesAndTabsComeBackWithTheFolder() async throws {
        let root = try makeFolder(["a.txt": "a\n", "b.txt": "b\n"])
        let first = Workspace()
        first.openFolder(root)
        first.open(fileAt: root.appending(path: "a.txt"))
        first.open(fileAt: root.appending(path: "b.txt"))
        let a = try #require(first.document(matching: root.appending(path: "a.txt")))
        a.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "unsaved ")
        first.open(fileAt: root.appending(path: "a.txt"))
        first.keepSession(wasOpen: true, force: true)
        let stored = try #require(SessionStore.shared.read(first.sessionKey))
        #expect(stored.files.count == 2 && stored.unsaved.count == 1 && stored.wasOpen)
        // The file on disk is untouched.
        #expect(try String(contentsOf: root.appending(path: "a.txt"), encoding: .utf8) == "a\n")

        // Another window (or the next launch) opening the folder gets it all back.
        let second = Workspace()
        second.notificationDuration = .seconds(1)
        second.openFolder(root)
        #expect(second.documents.count == 2)
        let restored = try #require(second.document(matching: root.appending(path: "a.txt")))
        #expect(restored.textStorage.string == "unsaved a\n" && restored.isDirty)
        #expect(second.activeDocument === restored)
        let deadline = ContinuousClock.now + .seconds(2)
        while second.notifications.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let message = second.notifications.first?.message ?? ""
        #expect(message.contains("Restored unsaved changes in 1 file") && !message.contains("changed on disk"))
        SessionStore.shared.remove(first.sessionKey)
    }

    @Test func closingAWindowKeepsOnlyUnsavedWork() throws {
        let root = try makeFolder(["a.txt": "a"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.txt"))
        workspace.windowClosed()
        #expect(SessionStore.shared.read(workspace.sessionKey) == nil)
        workspace.activeDocument?.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        workspace.windowClosed()
        let kept = try #require(SessionStore.shared.read(workspace.sessionKey))
        #expect(!kept.wasOpen && kept.unsaved.count == 1)
        SessionStore.shared.remove(workspace.sessionKey)
    }

    @Test func quittingKeepsSessionsAndLaunchReopensThem() throws {
        let root = try makeFolder(["a.txt": "a"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.txt"))
        defer { SessionStore.shared.isTerminating = false; SessionStore.shared.remove(workspace.sessionKey) }
        #expect(Workspace.prepareToQuit([workspace]))
        #expect(SessionStore.shared.read(workspace.sessionKey)?.wasOpen == true)
        // Closing windows while quitting doesn't mark them closed.
        workspace.windowClosed()
        #expect(SessionStore.shared.read(workspace.sessionKey)?.wasOpen == true)

        var opened: [URL] = []
        Workspace.reopenLastSessions { opened.append($0.url) }
        #expect(opened.contains { $0.standardizedFileURL.path == root.standardizedFileURL.path })
        // A folder that's gone isn't reopened, and its session goes.
        let gone = try makeFolder(["x.txt": "x"])
        let goneWorkspace = Workspace()
        goneWorkspace.openFolder(gone)
        goneWorkspace.keepSession(wasOpen: true, force: true)
        try FileManager.default.removeItem(at: gone)
        opened = []
        Workspace.reopenLastSessions { opened.append($0.url) }
        #expect(!opened.contains { $0.lastPathComponent == gone.lastPathComponent })
        #expect(SessionStore.shared.read(goneWorkspace.sessionKey) == nil)
    }

    @Test func autoSaveAfterADelay() throws {
        let root = try makeFolder(["a.txt": "a"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.txt"))
        let document = try #require(workspace.activeDocument)
        let settings = AppSettings.shared
        settings.autoSaveDelay = 1
        defer { settings.autoSave = .off; settings.autoSaveDelay = 1 }

        document.textStorage.replaceCharacters(in: NSRange(location: 1, length: 0), with: "b")
        let start = Date()
        workspace.autoSaveTick(now: start)
        workspace.autoSaveTick(now: start.addingTimeInterval(2))
        #expect(document.isDirty) // off

        settings.autoSave = .afterDelay
        workspace.autoSaveTick(now: start)
        workspace.autoSaveTick(now: start.addingTimeInterval(0.5))
        #expect(document.isDirty)
        // Typing again restarts the wait.
        document.textStorage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "c")
        workspace.autoSaveTick(now: start.addingTimeInterval(1.2))
        #expect(document.isDirty)
        workspace.autoSaveTick(now: start.addingTimeInterval(2.3))
        #expect(try !document.isDirty && String(contentsOf: document.url, encoding: .utf8) == "abc")
    }

    @Test func autoSaveOnFocusChange() async throws {
        let root = try makeFolder(["a.txt": "a", "b.txt": "b"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.txt"))
        let a = try #require(workspace.activeDocument)
        AppSettings.shared.autoSave = .onFocusChange
        defer { AppSettings.shared.autoSave = .off }
        a.textStorage.replaceCharacters(in: NSRange(location: 1, length: 0), with: "!")
        // Switching tabs saves it.
        workspace.open(fileAt: root.appending(path: "b.txt"))
        let deadline = ContinuousClock.now + .seconds(5)
        while a.isDirty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try !a.isDirty && String(contentsOf: a.url, encoding: .utf8) == "a!")
    }
}

@MainActor
struct SessionDiskChangeTests {
    @Test func warnsWhenTheFileChangedOnDiskSince() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "a\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let first = Workspace()
        first.openFolder(root)
        first.open(fileAt: root.appending(path: "a.txt"))
        first.activeDocument?.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")
        first.keepSession(wasOpen: true, force: true)
        defer { SessionStore.shared.remove(first.sessionKey) }
        try await Task.sleep(for: .milliseconds(50))
        try "theirs\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)

        let second = Workspace()
        second.openFolder(root)
        // Unsaved text wins (it's what you were working on), with a warning to compare.
        #expect(second.activeDocument?.textStorage.string == "mine a\n")
        let deadline = ContinuousClock.now + .seconds(2)
        while second.notifications.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(second.notifications.first?.message.contains("changed on disk") == true)
    }
}
