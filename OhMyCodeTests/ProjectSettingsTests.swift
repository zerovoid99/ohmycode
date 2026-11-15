import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct ProjectSettingsTests {
    @Test func readsWithCommentsAndIgnoresWhatItDoesntKnow() throws {
        let json = """
        // Folder settings
        {
          "wordWrap": "on", // always
          /* block */ "formatOnSave": true,
          "autoSaveDelay": 500,
          "renderWhitespace": "sometimes",
          "showsCodeLens": "yes",
          "url": "http://example.com//not-a-comment",
          "colour": 1,
        }
        """
        let settings = try ProjectSettings(json: Data(json.utf8))
        #expect(settings.wordWrap == .on && settings.formatOnSave == true && settings.autoSaveDelay == 60)
        #expect(settings.renderWhitespace == nil && settings.showsCodeLens == nil)
        #expect(settings.unknownKeys == ["colour", "url"])
        #expect(throws: (any Error).self) { try ProjectSettings(json: Data("{ nope".utf8)) }
        // The template sets nothing (all commented out) and parses.
        let template = try ProjectSettings(json: Data(ProjectSettings.template.utf8))
        #expect(template == ProjectSettings())
    }

    @Test func folderSettingsOverrideTheApps() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".omc"), withIntermediateDirectories: true)
        try #"{ "wordWrap": "on", "autoSave": "afterDelay", "formatOnSave": true }"#
            .write(to: root.appending(path: ProjectSettings.file), atomically: true, encoding: .utf8)
        try "let x = 1\n".write(to: root.appending(path: "a.swift"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.swift"))
        let document = try #require(workspace.activeDocument)
        // The app's setting wraps only prose; the folder's wraps code too.
        #expect(AppSettings.shared.wordWrap == .prose && document.wrapsLines)
        #expect(workspace.effectiveAutoSave == .afterDelay && workspace.formatsOnSave)

        // Edited in the editor and saved: applied at once.
        workspace.open(fileAt: root.appending(path: ProjectSettings.file))
        let settingsFile = try #require(workspace.activeDocument)
        try settingsFile.apply([TextReplacement(range: NSRange(location: 0, length: settingsFile.textStorage.length),
                                                text: #"{ "wordWrap": "off" }"#)], actionName: "Edit")
        #expect(workspace.save(settingsFile))
        #expect(!document.wrapsLines && workspace.effectiveAutoSave == AppSettings.shared.autoSave)
    }

    @Test func openingTheSettingsWritesATemplate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace()
        workspace.notificationDuration = .seconds(1)
        workspace.openFolder(root)
        workspace.openProjectSettings()
        #expect(workspace.activeDocument?.url.path.hasSuffix(".omc/settings.json") == true)
        #expect(try String(contentsOf: root.appending(path: ProjectSettings.file), encoding: .utf8) == ProjectSettings.template)

        // Broken JSON: a warning, and the app's settings.
        try "{ broken".write(to: root.appending(path: ProjectSettings.file), atomically: true, encoding: .utf8)
        workspace.loadProjectSettings()
        let deadline = ContinuousClock.now + .seconds(2)
        while workspace.notifications.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.notifications.first?.message.contains("isn't valid JSON") == true)
        #expect(workspace.projectSettings == ProjectSettings())
    }
}
