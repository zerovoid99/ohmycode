import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct VSCodeThemeTests {
    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle(for: ThemeBundleToken.self).url(forResource: name, withExtension: "json",
                                                           subdirectory: "Fixtures/themes"))
    }

    private func hex(_ color: NSColor?) -> UInt32? { color.map(VSCodeTheme.rgb) }

    @Test func stripsCommentsAndTrailingCommasButNotStrings() throws {
        let text = """
        {
          // line comment
          "url": "http://example.com/*not a comment*/", /* block */
          "list": [1, 2, ],
          "quote": "a \\" // still a string",
        }
        """
        let object = try VSCodeTheme.jsonObject(Data(text.utf8))
        #expect(object["url"] as? String == "http://example.com/*not a comment*/")
        #expect(object["list"] as? [Int] == [1, 2])
        #expect(object["quote"] as? String == "a \" // still a string")
    }

    @Test func parsesColorFormats() {
        #expect(hex(VSCodeTheme.color("#abc")) == 0xAABBCC)
        #expect(hex(VSCodeTheme.color("#1E1E1E")) == 0x1E1E1E)
        #expect(VSCodeTheme.color("#264F7880")?.alphaComponent ?? 0 > 0.49)
        #expect(VSCodeTheme.color("#264F7880")?.alphaComponent ?? 1 < 0.51)
        #expect(VSCodeTheme.color("red") == nil)
        #expect(VSCodeTheme.color("#12345") == nil)
    }

    @Test func mergesIncludesAndMapsScopes() throws {
        let theme = try VSCodeTheme.parse(VSCodeTheme.load(fixture("child_theme")), fallbackName: "x")
        #expect(theme.name == "Child Modern")
        #expect(theme.id == "vscode-child-modern")
        #expect(theme.isDark == true)
        #expect(hex(theme.background) == 0x1F1F1F)  // child overrides base
        #expect(hex(theme.foreground) == 0xD4D4D4)  // inherited from base
        #expect(hex(theme.cursor) == 0xAEAFAD)
        #expect(hex(theme.lineNumber) == 0x6E7681 && hex(theme.currentLineNumber) == 0xCCCCCC)
        // #264F78 at alpha 0x80 over #1F1F1F, made opaque for the terminal: (0x26·a + 0x1F·(1−a)) …
        let selection = try #require(hex(theme.selection))
        let alpha = 128.0 / 255
        for (shift, top, bottom) in [(16, 0x26, 0x1F), (8, 0x4F, 0x1F), (0, 0x78, 0x1F)] {
            let expected = Double(top) * alpha + Double(bottom) * (1 - alpha)
            #expect(abs(Double(selection >> UInt32(shift) & 0xFF) - expected) <= 1)
        }

        #expect(hex(theme.syntax["keyword"]) == 0xC586C0)  // keyword.control (child) is more specific
        #expect(hex(theme.syntax["string"]) == 0xCE9178)
        #expect(hex(theme.syntax["comment"]) == 0x6A9955)
        #expect(hex(theme.syntax["number"]) == 0xB5CEA8)   // "constant.numeric, constant.language"
        #expect(hex(theme.syntax["type"]) == 0x4EC9B0)
        #expect(hex(theme.syntax["function"]) == 0xDCDCAA)
        // "variable.other.property" only sets a font style; "support.type.property-name" (JSON keys)
        // then matches the "support.type" rule, as TextMate selectors do in VS Code.
        #expect(hex(theme.syntax["property"]) == 0x4EC9B0)

        #expect(hex(theme.chrome?.sidebar) == 0x252526 && hex(theme.chrome?.tabBar) == 0x181818)
        #expect(hex(theme.chrome?.statusBar) == 0x007ACC && hex(theme.chrome?.panel) == 0x181818)
        #expect(theme.ansi?.count == 16 && theme.ansi?[1] == 0xF14C4C)
    }

    @Test func rejectsFilesThatAreNotThemes() {
        #expect(throws: VSCodeTheme.ImportError.self) { try VSCodeTheme.parse(Data("{\"name\": \"x\"}".utf8), fallbackName: "x") }
        #expect(throws: VSCodeTheme.ImportError.self) { try VSCodeTheme.parse(Data("{ nope".utf8), fallbackName: "x") }
        // A minimal light theme still works: missing colors get sensible defaults.
        let light = try? VSCodeTheme.parse(Data(##"{"type": "light", "colors": {"editor.background": "#FFFFFF"}}"##.utf8),
                                           fallbackName: "My Light")
        #expect(light?.name == "My Light" && light?.isDark == false && light?.ansi == nil)
    }

    @Test func libraryImportsPersistsAndRemoves() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "omc-themelib-\(UUID().uuidString)")
        let library = ThemeLibrary(directory: directory)
        #expect(library.themes.isEmpty)
        let theme = try library.importTheme(from: fixture("child_theme"))
        #expect(library.themes.map(\.id) == [theme.id])

        // Stored self-contained (include merged), so it loads again without the base file.
        let stored = try String(contentsOf: directory.appending(path: "\(theme.id).json"), encoding: .utf8)
        #expect(!stored.contains("\"include\""))
        let reloaded = ThemeLibrary(directory: directory)
        #expect(hex(reloaded.themes.first?.foreground) == 0xD4D4D4)
        #expect(hex(reloaded.themes.first?.syntax["comment"]) == 0x6A9955)

        try library.importTheme(from: fixture("child_theme")) // re-import replaces
        #expect(library.themes.count == 1)
        library.remove(theme.id)
        #expect(library.themes.isEmpty && ThemeLibrary(directory: directory).themes.isEmpty)
    }
}

private final class ThemeBundleToken {}
