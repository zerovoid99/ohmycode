import AppKit
import simd
import Testing
@testable import Oh_My_Code

@MainActor
struct SettingsTests {
    private func scratch() -> UserDefaults {
        let name = "omc-settings-\(UUID().uuidString)"
        return ScratchDefaults.named(name)
    }

    /// Started with OMC_SUPPORT_DIR, the app's defaults (recent folders, settings, agents) live in
    /// that folder, not the user's.
    @Test func supportFolderKeepsItsOwnDefaults() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults.store(environment: ["OMC_SUPPORT_DIR": folder.path])
        #expect(defaults !== UserDefaults.standard)
        defaults.set(["/x"], forKey: "recentFolders")
        defaults.synchronize()
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "OhMyCode/Defaults.plist").path))
        #expect(UserDefaults.store(environment: ["OMC_SUPPORT_DIR": folder.path]).stringArray(forKey: "recentFolders") == ["/x"])
        #expect(UserDefaults.store(environment: [:]) === UserDefaults.standard)
    }

    @Test func persistsAndClamps() {
        let defaults = scratch()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.themeID == EditorTheme.defaultTheme.id)
        #expect(settings.editorFontSize == AppSettings.defaultEditorFontSize)

        settings.themeID = "monokai"
        settings.appearance = .dark
        settings.editorFontFamily = "Menlo"
        settings.editorFontSize = 99 // clamped
        settings.zoom(by: -40)       // clamped at the other end
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.themeID == "monokai")
        #expect(reloaded.appearance == .dark)
        #expect(reloaded.editorFontFamily == "Menlo")
        #expect(reloaded.editorFontSize == AppSettings.fontSizes.lowerBound)
        #expect(reloaded.terminalFontSize == AppSettings.fontSizes.lowerBound)

        defaults.set(1000.0, forKey: "terminalFontSize") // bad stored value
        #expect(AppSettings(defaults: defaults).terminalFontSize == AppSettings.fontSizes.upperBound)

        reloaded.restoreDefaults()
        let restored = AppSettings(defaults: defaults)
        #expect(restored.themeID == EditorTheme.defaultTheme.id && restored.editorFontFamily == ""
                && restored.editorFontSize == AppSettings.defaultEditorFontSize && restored.appearance == .system)
    }

    @Test func fixedThemesSetTheAppearance() {
        let settings = AppSettings(defaults: scratch())
        settings.appearance = .light
        #expect(settings.effectiveAppearance?.name == .aqua)
        #expect(!settings.themeSetsAppearance)
        settings.themeID = "monokai" // dark theme wins over the Light setting
        #expect(settings.themeSetsAppearance)
        #expect(settings.effectiveAppearance?.name == .darkAqua)
        settings.themeID = "solarized-light"
        settings.appearance = .dark
        #expect(settings.effectiveAppearance?.name == .aqua)
        settings.themeID = EditorTheme.defaultTheme.id
        settings.appearance = .system
        #expect(settings.effectiveAppearance == nil)
    }

    @Test func terminalPaletteExtendsTheThemeColors() throws {
        let palette = try #require(EditorTheme.monokai.terminalPalette)
        #expect(palette.count == 256)
        #expect(Array(palette.prefix(16)) == EditorTheme.monokai.ansi)
        #expect(palette[16] == 0x000000 && palette[21] == 0x0000FF && palette[231] == 0xFFFFFF)
        #expect(palette[232] == 0x080808 && palette[255] == 0xEEEEEE)
        #expect(EditorTheme.defaultTheme.terminalPalette == nil)
        for theme in EditorTheme.themes where theme.isDark != nil {
            #expect(theme.chrome != nil && theme.ansi?.count == 16, "\(theme.name) lacks UI or terminal colors")
        }
    }

    @Test func fontsFallBackToSystemMonospaced() {
        #expect(AppSettings.font(family: "", size: 14).isFixedPitch)
        #expect(AppSettings.font(family: "No Such Font", size: 14).pointSize == 14)
        if AppSettings.monospacedFamilies.contains("Menlo") {
            #expect(AppSettings.font(family: "Menlo", size: 15).familyName == "Menlo")
            #expect(AppSettings.font(family: "Menlo", size: 15, bold: true).fontDescriptor.symbolicTraits.contains(.bold))
        }
        #expect(!AppSettings.monospacedFamilies.isEmpty)
    }

    /// Changing the theme and font restyles open editors and terminals immediately. Synchronous
    /// on the main actor, and restored before returning, so other tests never see it.
    @Test func changesApplyLiveToEditorsAndTerminals() throws {
        let settings = AppSettings.shared
        let original = (settings.themeID, settings.editorFontSize, settings.terminalFontSize, settings.editorFontFamily)
        defer {
            settings.themeID = original.0
            settings.editorFontSize = original.1
            settings.terminalFontSize = original.2
            settings.editorFontFamily = original.3
            #expect(NSApp.appearance == nil)
        }

        let url = FileManager.default.temporaryDirectory.appending(path: "omc-theme-\(UUID().uuidString).swift")
        try (1...2000).map { "let value\($0) = \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()

        let session = try TerminalSession(directory: FileManager.default.temporaryDirectory, command: ["/bin/cat"])
        defer { session.terminate() }
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let terminalWindow = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        terminalWindow.contentView = terminal
        terminal.session = session

        session.feed(Data("\u{1b}[31mRED\u{1b}[0m\r\n".utf8))
        let red = SIMD3<Float>(Float(0xF9) / 255, Float(0x26) / 255, Float(0x72) / 255) // Monokai's red
        func hasRed(_ frame: TerminalFrame) -> Bool {
            frame.glyphs.contains { simd_distance(SIMD3($0.color.x, $0.color.y, $0.color.z), red) < 0.02 }
        }
        #expect(!hasRed(terminal.makeFrame(scale: 2)))
        let gutterWidth = controller.gutterView.width
        let columns = session.columns
        let cellWidth = terminal.cellWidth

        settings.themeID = "monokai"
        settings.editorFontSize = 20
        settings.terminalFontSize = 18

        let monokai = EditorTheme.monokai
        #expect(controller.textView.backgroundColor == monokai.background)
        #expect(controller.textView.insertionPointColor == monokai.cursor)
        #expect(EditorTheme.color(forCapture: "keyword.function") == monokai.syntax["keyword"])
        // The whole text is restyled, as an attribute-only change: not dirty, nothing to undo.
        let lastFont = document.textStorage.attribute(.font, at: document.textStorage.length - 1, effectiveRange: nil) as? NSFont
        #expect(lastFont?.pointSize == 20)
        #expect(document.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == monokai.foreground)
        #expect(!document.isDirty && !document.undoManager.canUndo)
        #expect(controller.gutterView.width > gutterWidth)
        #expect(controller.textView.enclosingScrollView?.superview?.appearance?.name == .darkAqua)

        // The terminal re-measures its cells and the shell gets the new grid size.
        #expect(terminal.cellWidth > cellWidth)
        #expect(session.columns < columns)
        let frame = terminal.makeFrame(scale: 2)
        #expect(hasRed(frame), "ANSI red doesn't use the theme's palette")
        #expect(NSApp.appearance?.name == .darkAqua, "a dark theme sets the app's appearance")
        let background = try #require(monokai.background.usingColorSpace(.sRGB))
        #expect(abs(Double(frame.clearColor.x) - background.redComponent) < 0.01)
        #expect(abs(Double(frame.clearColor.z) - background.blueComponent) < 0.01)

        // A document opened later is styled when an editor shows it.
        let other = try EditorDocument(url: url)
        let laterController = EditorController(document: other)
        _ = laterController.makeView()
        #expect((other.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 20)
        withExtendedLifetime((window, terminalWindow)) {}
    }
}
