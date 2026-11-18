import AppKit

/// Converts a VS Code color theme (`.json`, JSON with comments) into an editor theme.
/// UI colors come from `colors`, syntax colors from `tokenColors` TextMate scopes, mapped to
/// the roles our tree-sitter highlighting uses.
enum VSCodeTheme {
    enum ImportError: LocalizedError {
        case notJSON(String)
        case notATheme

        var errorDescription: String? {
            switch self {
            case .notJSON(let detail): "The file isn't valid JSON: \(detail)"
            case .notATheme: "The file isn't a VS Code color theme (no \"colors\" or \"tokenColors\")."
            }
        }
    }

    /// Reads a theme file and merges its `include` chain (VS Code's own themes build on base
    /// themes: Dark Modern → Dark+ → Dark VS). The result no longer depends on other files.
    static func load(_ url: URL, depth: Int = 0) throws -> [String: Any] {
        let object = try jsonObject(Data(contentsOf: url))
        guard let include = object["include"] as? String, depth < 8 else { return object }
        let base = try load(url.deletingLastPathComponent().appending(path: include).standardizedFileURL, depth: depth + 1)
        var merged = base.merging(object) { $1 }
        merged["include"] = nil
        merged["colors"] = (base["colors"] as? [String: Any] ?? [:]).merging(object["colors"] as? [String: Any] ?? [:]) { $1 }
        merged["tokenColors"] = (base["tokenColors"] as? [Any] ?? []) + (object["tokenColors"] as? [Any] ?? [])
        return merged
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: Data(stripJSONC(String(decoding: data, as: UTF8.self)).utf8))
        } catch {
            throw ImportError.notJSON((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)
        }
        guard let object = json as? [String: Any] else { throw ImportError.notATheme }
        return object
    }

    static func parse(_ data: Data, fallbackName: String) throws -> EditorThemeDefinition {
        try parse(jsonObject(data), fallbackName: fallbackName)
    }

    static func parse(_ object: [String: Any], fallbackName: String) throws -> EditorThemeDefinition {
        guard object["colors"] != nil || object["tokenColors"] != nil else { throw ImportError.notATheme }

        let colors = (object["colors"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? String).flatMap(color) }
        let tokens = tokenRules(object["tokenColors"])

        let type = (object["type"] as? String)?.lowercased()
        let fallbackDark = type.map { $0 != "light" && $0 != "hclight" } ?? true
        let background = colors["editor.background"] ?? (fallbackDark ? EditorTheme.hex(0x1E1E1E) : .white)
        let isDark = type.map { $0 != "light" && $0 != "hclight" } ?? (luminance(background) < 0.5)
        let foreground = colors["editor.foreground"] ?? colors["foreground"] ?? tokens.defaultForeground
            ?? (isDark ? EditorTheme.hex(0xD4D4D4) : EditorTheme.hex(0x333333))

        var syntax: [String: NSColor] = [:]
        for (role, scopes) in roleScopes {
            if let color = tokens.color(forAnyOf: scopes) { syntax[role] = color }
        }

        let sidebar = colors["sideBar.background"] ?? background
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let ansiKeys = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        let ansi = (ansiKeys.map { "terminal.ansi\($0)" } + ansiKeys.map { "terminal.ansiBright\($0)" })
            .compactMap { colors[$0].map(rgb) }

        return EditorThemeDefinition(
            id: "vscode-" + slug(name), name: name, isDark: isDark,
            background: background, foreground: foreground,
            // Selections are often translucent: blend them over the background (the terminal needs opaque).
            selection: blend(colors["editor.selectionBackground"] ?? (isDark ? EditorTheme.hex(0x264F78) : EditorTheme.hex(0xADD6FF)),
                             over: background),
            cursor: colors["editorCursor.foreground"] ?? foreground,
            lineNumber: colors["editorLineNumber.foreground"] ?? blend(foreground.withAlphaComponent(0.45), over: background),
            currentLineNumber: colors["editorLineNumber.activeForeground"] ?? foreground,
            syntax: syntax,
            chrome: .init(sidebar: sidebar,
                          tabBar: colors["editorGroupHeader.tabsBackground"] ?? colors["tab.inactiveBackground"] ?? sidebar,
                          statusBar: colors["statusBar.background"] ?? sidebar,
                          panel: colors["panel.background"] ?? colors["terminal.background"] ?? sidebar),
            ansi: ansi.count == 16 ? ansi : nil,
            textMateRules: tokens.textMate.isEmpty ? nil : tokens.textMate)
    }

    // MARK: Token colors

    /// TextMate scopes to look for, per syntax role, most typical first.
    static let roleScopes: [(String, [String])] = [
        ("keyword", ["keyword.control", "keyword", "storage.modifier", "storage"]),
        ("string", ["string.quoted", "string"]),
        ("comment", ["comment.line", "comment"]),
        ("number", ["constant.numeric", "constant.language", "constant"]),
        ("type", ["entity.name.type", "support.type", "entity.name.class", "storage.type"]),
        ("function", ["entity.name.function", "support.function", "meta.function-call"]),
        ("property", ["variable.other.property", "variable.other.member", "support.type.property-name", "variable.other.object.property"]),
        ("attribute", ["entity.other.attribute-name", "storage.type.annotation", "meta.attribute", "entity.name.tag"]),
    ]

    struct TokenRules {
        /// (selector, color), only simple selectors like "keyword.control" (no descendants).
        var rules: [(String, NSColor)] = []
        var defaultForeground: NSColor?
        /// Every rule, descendant selectors too: what TextMate grammars' scopes are colored by.
        var textMate = TextMateThemeRules()

        /// The color of the most specific rule matching any of `scopes` (earlier scopes win ties).
        func color(forAnyOf scopes: [String]) -> NSColor? {
            for scope in scopes {
                var best: (length: Int, color: NSColor)?
                for (selector, color) in rules where scope == selector || scope.hasPrefix(selector + ".") {
                    // Later rules override earlier ones with the same specificity, as in VS Code.
                    if best == nil || selector.count >= best!.length { best = (selector.count, color) }
                }
                if let best { return best.color }
            }
            return nil
        }
    }

    static func tokenRules(_ json: Any?) -> TokenRules {
        var result = TokenRules()
        for entry in json as? [Any] ?? [] {
            guard let entry = entry as? [String: Any], let settings = entry["settings"] as? [String: Any],
                  let foreground = (settings["foreground"] as? String).flatMap(color) else { continue }
            let selectors: [String]
            switch entry["scope"] {
            case let scope as String: selectors = scope.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            case let scopes as [String]: selectors = scopes.map { $0.trimmingCharacters(in: .whitespaces) }
            default:
                result.defaultForeground = foreground // a rule without scope sets the default text color
                continue
            }
            for selector in selectors where !selector.isEmpty {
                result.textMate.add(selector: selector, color: foreground)
                if !selector.contains(" ") { result.rules.append((selector, foreground)) }
            }
        }
        return result
    }

    // MARK: Helpers

    /// `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`.
    static func color(_ string: String) -> NSColor? {
        var hex = string.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? value << 8 | 0xFF : value
        return NSColor(srgbRed: CGFloat(rgba >> 24 & 0xFF) / 255, green: CGFloat(rgba >> 16 & 0xFF) / 255,
                       blue: CGFloat(rgba >> 8 & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    static func rgb(_ color: NSColor) -> UInt32 {
        let c = color.usingColorSpace(.sRGB) ?? .black
        return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8
            | UInt32((c.blueComponent * 255).rounded())
    }

    static func blend(_ color: NSColor, over background: NSColor) -> NSColor {
        let top = color.usingColorSpace(.sRGB) ?? color, bottom = background.usingColorSpace(.sRGB) ?? background
        let a = top.alphaComponent
        return NSColor(srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
                       green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                       blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    static func slug(_ name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return slug.isEmpty ? "theme" : slug
    }

    /// Removes `//` and `/* */` comments and trailing commas, leaving strings intact.
    static func stripJSONC(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        let chars = Array(text.unicodeScalars)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                output.unicodeScalars.append(c)
                if c == "\\", i + 1 < chars.count { output.unicodeScalars.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; output.unicodeScalars.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "," {
                // Drop a comma followed only by whitespace/comments and a closing bracket.
                var j = i + 1
                while j < chars.count {
                    if chars[j].properties.isWhitespace {
                        j += 1
                    } else if chars[j] == "/", j + 1 < chars.count, chars[j + 1] == "/" {
                        while j < chars.count, chars[j] != "\n" { j += 1 }
                    } else if chars[j] == "/", j + 1 < chars.count, chars[j + 1] == "*" {
                        j += 2
                        while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                        j += 2
                    } else {
                        break
                    }
                }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            output.unicodeScalars.append(c)
            i += 1
        }
        return output
    }
}

/// Imported themes, stored in Application Support as `.json` (with includes merged in).
@MainActor
@Observable
final class ThemeLibrary {
    static let shared = ThemeLibrary(directory: AppSettings.isRunningTests
        ? FileManager.default.temporaryDirectory.appending(path: "omc-themes-\(ProcessInfo.processInfo.processIdentifier)")
        : URL.omcApplicationSupport.appending(path: "Oh My Code/Themes"))

    let directory: URL
    private(set) var themes: [EditorThemeDefinition] = []

    init(directory: URL) {
        self.directory = directory
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        themes = files.filter { $0.pathExtension == "json" }
            .compactMap { url in try? VSCodeTheme.parse(Data(contentsOf: url), fallbackName: url.deletingPathExtension().lastPathComponent) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        EditorTheme.invalidate()
    }

    /// Copies a VS Code theme into the library and returns it (re-importing replaces it).
    @discardableResult
    func importTheme(from url: URL) throws -> EditorThemeDefinition {
        let object = try VSCodeTheme.load(url)
        let theme = try VSCodeTheme.parse(object, fallbackName: url.deletingPathExtension().lastPathComponent)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: theme.id), options: .atomic)
        reload()
        // Re-importing the theme in use restyles open editors.
        NotificationCenter.default.post(name: AppSettings.didChange, object: nil)
        return theme
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        reload()
        if AppSettings.shared.themeID == id { AppSettings.shared.themeID = EditorTheme.defaultTheme.id }
    }

    func isImported(_ id: String) -> Bool { themes.contains { $0.id == id } }

    private func fileURL(for id: String) -> URL { directory.appending(path: "\(id).json") }
}
