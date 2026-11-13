import AppKit

/// A color theme for the editor and terminal.
struct EditorThemeDefinition: Identifiable {
    let id: String
    let name: String
    /// nil: follows the app's light/dark appearance (colors are dynamic).
    let isDark: Bool?
    let background: NSColor
    let foreground: NSColor
    let selection: NSColor
    let cursor: NSColor
    let lineNumber: NSColor
    let currentLineNumber: NSColor
    /// Colors per syntax role: keyword, string, comment, number, type, function, property, attribute.
    let syntax: [String: NSColor]
    /// Window chrome around the editor; nil keeps the system's materials.
    var chrome: ChromeColors? = nil
    /// The 16 ANSI terminal colors (black…white, then bright); nil keeps Ghostty's defaults.
    var ansi: [UInt32]? = nil

    struct ChromeColors {
        let sidebar: NSColor
        let tabBar: NSColor
        let statusBar: NSColor
        /// Header strip of the terminal panel.
        let panel: NSColor
    }

    /// The terminal's 256-color palette: the theme's 16 colors, then the standard xterm 6×6×6
    /// color cube and grayscale ramp.
    var terminalPalette: [UInt32]? {
        guard let ansi, ansi.count == 16 else { return nil }
        var palette = ansi
        let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
        for r in levels { for g in levels { for b in levels { palette.append(r << 16 | g << 8 | b) } } }
        for i in 0..<24 {
            let v = UInt32(8 + i * 10)
            palette.append(v << 16 | v << 8 | v)
        }
        return palette
    }

    /// The appearance editors using this theme should draw with (nil: inherit the window's).
    var appearance: NSAppearance? {
        isDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
    }
}

@MainActor
enum EditorTheme {
    // MARK: Current settings

    private static var cachedFont: NSFont?
    private static var cachedTheme: EditorThemeDefinition?
    private static var resolvedColors: [String: NSColor?] = [:]

    static var font: NSFont {
        if let cachedFont { return cachedFont }
        let font = AppSettings.shared.editorFont
        cachedFont = font
        return font
    }

    static var gutterFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
    }

    static var current: EditorThemeDefinition {
        if let cachedTheme { return cachedTheme }
        let theme = themes.first { $0.id == AppSettings.shared.themeID } ?? defaultTheme
        cachedTheme = theme
        return theme
    }

    /// Bumped on every settings change, so documents restyle lazily (see `EditorDocument`).
    private(set) static var generation = 0

    /// Settings changed: recompute on next use.
    static func invalidate() {
        generation += 1
        cachedFont = nil
        cachedTheme = nil
        resolvedColors.removeAll()
    }

    /// `current`, read so SwiftUI views re-render when the theme changes (the cache itself
    /// isn't observable).
    static var observed: EditorThemeDefinition {
        _ = AppSettings.shared.themeID
        return current
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: current.foreground]
    }

    // MARK: Syntax colors

    /// tree-sitter capture → syntax role.
    private static let captureRoles: [String: String] = [
        "keyword": "keyword", "include": "keyword", "conditional": "keyword", "repeat": "keyword",
        "exception": "keyword", "storageclass": "keyword", "variable.builtin": "keyword",
        "string": "string", "character": "string", "string.special": "string", "escape": "number",
        "comment": "comment",
        "number": "number", "float": "number", "boolean": "keyword", "constant": "number",
        "constant.builtin": "keyword",
        "type": "type", "constructor": "type", "module": "type", "namespace": "type",
        "function": "function", "method": "function",
        "property": "property", "field": "property", "variable.member": "property",
        "attribute": "attribute", "tag": "keyword", "label": "attribute",
    ]

    /// Color for a capture like `keyword.function`, falling back to `keyword`.
    static func color(forCapture name: String) -> NSColor? {
        if let resolved = resolvedColors[name] { return resolved }
        var components = name.split(separator: ".")
        var result: NSColor?
        while !components.isEmpty {
            if let role = captureRoles[components.joined(separator: ".")] {
                result = current.syntax[role]
                break
            }
            components.removeLast()
        }
        resolvedColors[name] = result
        return result
    }

    // MARK: Themes

    static let themes: [EditorThemeDefinition] = [defaultTheme, solarizedLight, solarizedDark, monokai]

    /// Xcode-like colors that follow the system's light/dark appearance.
    static let defaultTheme = EditorThemeDefinition(
        id: "default", name: "Default (Light & Dark)", isDark: nil,
        background: .textBackgroundColor, foreground: .textColor, selection: .selectedTextBackgroundColor,
        cursor: .textColor, lineNumber: .tertiaryLabelColor, currentLineNumber: .labelColor,
        syntax: [
            "keyword": adaptive(light: 0xAD3DA4, dark: 0xFF7AB2),
            "string": adaptive(light: 0xC41A16, dark: 0xFF8170),
            "comment": adaptive(light: 0x5D6C79, dark: 0x7F8C98),
            "number": adaptive(light: 0x1C00CF, dark: 0xD9C97C),
            "type": adaptive(light: 0x0B4F79, dark: 0x5DD8FF),
            "function": adaptive(light: 0x326D74, dark: 0x67B7A4),
            "property": adaptive(light: 0x3E8087, dark: 0x4EB0CC),
            "attribute": adaptive(light: 0x947100, dark: 0xCC9768),
        ])

    // Solarized by Ethan Schoonover (MIT).
    private static let solarizedAccents: [String: NSColor] = [
        "keyword": hex(0x859900), "string": hex(0x2AA198), "number": hex(0xD33682), "type": hex(0xB58900),
        "function": hex(0x268BD2), "property": hex(0x6C71C4), "attribute": hex(0xCB4B16),
    ]

    static let solarizedLight = EditorThemeDefinition(
        id: "solarized-light", name: "Solarized Light", isDark: false,
        background: hex(0xFDF6E3), foreground: hex(0x657B83), selection: hex(0xEEE8D5), cursor: hex(0x586E75),
        lineNumber: hex(0x93A1A1), currentLineNumber: hex(0x586E75),
        syntax: solarizedAccents.merging(["comment": hex(0x93A1A1)]) { $1 },
        chrome: .init(sidebar: hex(0xEEE8D5), tabBar: hex(0xDDD6C1), statusBar: hex(0xEEE8D5), panel: hex(0xEEE8D5)),
        ansi: solarizedANSI)

    static let solarizedDark = EditorThemeDefinition(
        id: "solarized-dark", name: "Solarized Dark", isDark: true,
        background: hex(0x002B36), foreground: hex(0x839496), selection: hex(0x073642), cursor: hex(0x93A1A1),
        lineNumber: hex(0x586E75), currentLineNumber: hex(0x93A1A1),
        syntax: solarizedAccents.merging(["comment": hex(0x586E75)]) { $1 },
        chrome: .init(sidebar: hex(0x00212B), tabBar: hex(0x004052), statusBar: hex(0x00212B), panel: hex(0x00212B)),
        ansi: solarizedANSI)

    private static let solarizedANSI: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]

    static let monokai = EditorThemeDefinition(
        id: "monokai", name: "Monokai", isDark: true,
        background: hex(0x272822), foreground: hex(0xF8F8F2), selection: hex(0x49483E), cursor: hex(0xF8F8F0),
        lineNumber: hex(0x90908A), currentLineNumber: hex(0xF8F8F2),
        syntax: [
            "keyword": hex(0xF92672), "string": hex(0xE6DB74), "comment": hex(0x75715E), "number": hex(0xAE81FF),
            "type": hex(0x66D9EF), "function": hex(0xA6E22E), "property": hex(0xFD971F), "attribute": hex(0xA6E22E),
        ],
        chrome: .init(sidebar: hex(0x1E1F1C), tabBar: hex(0x1E1F1C), statusBar: hex(0x414339), panel: hex(0x1E1F1C)),
        ansi: [
            0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
            0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5,
        ])

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            hex(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
}
