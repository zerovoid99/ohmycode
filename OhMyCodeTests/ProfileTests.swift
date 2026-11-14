import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct ProfileTests {
    /// A Mac's worth of settings, all in scratch places.
    private func makeMac(syncFolder: URL? = nil) -> (ProfileManager, ProfileManager.Parts) {
        let id = UUID().uuidString
        let base = FileManager.default.temporaryDirectory.appending(path: "omc-profiles-\(id)")
        let settings = AppSettings(defaults: UserDefaults(suiteName: "omc-profile-settings-\(id)")!)
        let parts = ProfileManager.Parts(settings: settings, keybindings: Keybindings(file: base.appending(path: "keybindings.json")),
                                         snippets: SnippetLibrary(userDirectory: base.appending(path: "Snippets")),
                                         extensions: ExtensionStore(directory: base.appending(path: "Extensions"),
                                                                    defaults: UserDefaults(suiteName: "omc-profile-ext-\(id)")!))
        let manager = ProfileManager(defaults: UserDefaults(suiteName: "omc-profile-manager-\(id)")!, appFolder: base.appending(path: "Profiles"))
        if let syncFolder { manager.setSyncFolder(syncFolder) }
        manager.attach(parts)
        return (manager, parts)
    }

    @Test func switchingSwapsEverything() throws {
        let (manager, parts) = makeMac()
        #expect(manager.current == "Default" && manager.names == ["Default"])
        #expect(FileManager.default.fileExists(atPath: manager.url(for: "Default").path))

        // A new profile starts as a copy; changes to it stay in it.
        manager.switchTo("Presenting")
        #expect(manager.names == ["Default", "Presenting"] && parts.settings.editorFontSize == 13)
        parts.settings.editorFontSize = 22
        parts.settings.showsMinimap = false
        parts.keybindings.set(try KeyChord(parsing: "ctrl+alt+p"), for: "tasks.run")
        try parts.snippets.replaceUserFiles(["swift.json": #"{ "Big": { "prefix": "big", "body": "BIG" } }"#])
        parts.extensions.disabledIDs = ["noisy.ext"]

        manager.switchTo("Default")
        #expect(parts.settings.editorFontSize == 13 && parts.settings.showsMinimap)
        #expect(parts.keybindings.rules.isEmpty && parts.snippets.userFiles().isEmpty && parts.extensions.disabledIDs.isEmpty)

        manager.switchTo("Presenting")
        #expect(parts.settings.editorFontSize == 22 && !parts.settings.showsMinimap)
        #expect(parts.keybindings.display(for: "tasks.run") == "⌃⌥P" && parts.extensions.disabledIDs == ["noisy.ext"])
        #expect(parts.snippets.snippets(for: "swift", root: nil).contains { $0.prefixes == ["big"] })

        manager.rename("Presenting", to: "Talks")
        #expect(manager.current == "Talks" && manager.names == ["Default", "Talks"])
        #expect(try SettingsProfile.read(from: manager.url(for: "Talks")).name == "Talks")
        manager.delete("Talks") // the current one stays
        #expect(manager.names.contains("Talks"))
        manager.switchTo("Default")
        manager.delete("Talks")
        #expect(manager.names == ["Default"])
    }

    @Test func exportsImportsAndSyncsBetweenMacs() throws {
        let (first, firstParts) = makeMac()
        firstParts.settings.terminalFontSize = 16
        firstParts.settings.apply(["theme": .string("monokai"), "unknown": .bool(true), "showsMinimap": .string("wrong type")])
        #expect(firstParts.settings.themeID == "monokai" && firstParts.settings.showsMinimap) // the bad value is ignored
        let file = FileManager.default.temporaryDirectory.appending(path: "omc-export-\(UUID().uuidString).omcprofile")
        try first.export(to: file)

        let (second, secondParts) = makeMac()
        try second.importProfile(from: file)
        #expect(secondParts.settings.terminalFontSize == 16 && secondParts.settings.themeID == "monokai")
        #expect(try SettingsProfile.read(from: second.url(for: "Default")).settings["terminalFontSize"] == .number(16))

        // Two Macs syncing through one folder.
        let shared = FileManager.default.temporaryDirectory.appending(path: "omc-sync-\(UUID().uuidString)")
        let (macA, partsA) = makeMac(syncFolder: shared)
        let (macB, partsB) = makeMac(syncFolder: shared)
        #expect(macA.folder == shared && macB.folder == shared)
        partsA.settings.editorFontSize = 18
        macA.saveNow()
        // B comes back to the app: the newer file wins.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: macA.url(for: "Default").path)
        macB.pullIfChanged()
        #expect(partsB.settings.editorFontSize == 18)
        // Nothing newer: nothing changes.
        partsB.settings.editorFontSize = 14
        macB.pullIfChanged()
        #expect(partsB.settings.editorFontSize == 14)

        // Edited here since the last save (a snippet file): relaunching doesn't put the old profile back.
        try partsB.snippets.replaceUserFiles(["go.json": "{}"])
        let relaunched = ProfileManager(defaults: macB.defaultsForTesting, appFolder: FileManager.default.temporaryDirectory)
        relaunched.attach(partsB)
        #expect(partsB.snippets.userFiles().keys.sorted() == ["go.json"] && partsB.settings.editorFontSize == 14)

        // Back to this Mac's own folder.
        macB.setSyncFolder(nil)
        #expect(macB.syncFolder == nil && FileManager.default.fileExists(atPath: macB.url(for: "Default").path))
    }
}
