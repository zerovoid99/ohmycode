import AppKit

/// A shortcut written as in extension.json: "cmd+shift+k", "ctrl+alt+f5", "cmd+.". Keys are
/// matched by position on an ANSI keyboard (like the built-in shortcuts), so "cmd+shift+1"
/// works whatever character shift+1 types.
struct KeyChord: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    let keyCode: UInt16
    /// How the key shows ("K", "F5", "↩").
    let keyName: String

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    enum ParseError: LocalizedError, Equatable {
        case unknownKey(String)
        case unknownModifier(String)
        case needsModifier(String)

        var errorDescription: String? {
            switch self {
            case .unknownKey(let key): "“\(key)” isn't a key this editor knows."
            case .unknownModifier(let modifier): "“\(modifier)” isn't a modifier (use cmd, ctrl, alt or shift)."
            case .needsModifier(let chord): "“\(chord)” needs cmd, ctrl or alt (or a function key): it would take over typing."
            }
        }
    }

    init(modifiers: NSEvent.ModifierFlags, keyCode: UInt16, keyName: String) {
        self.modifiers = modifiers.intersection(Self.relevantModifiers)
        self.keyCode = keyCode
        self.keyName = keyName
    }

    /// Parses "cmd+shift+k"; the last part is the key.
    init(parsing text: String) throws {
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.popLast() else { throw ParseError.unknownKey(text) }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "meta": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "alt", "option", "opt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: throw ParseError.unknownModifier(part)
            }
        }
        let name = key.trimmingCharacters(in: .whitespaces)
        guard let code = Self.keyCodes[name] else { throw ParseError.unknownKey(name) }
        let isFunctionKey = name.hasPrefix("f") && name.count > 1 && Int(name.dropFirst()) != nil
        guard isFunctionKey || !modifiers.intersection([.command, .control, .option]).isEmpty else {
            throw ParseError.needsModifier(text)
        }
        self.init(modifiers: modifiers, keyCode: code, keyName: Self.displayNames[name] ?? name.uppercased())
    }

    func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == keyCode
            && event.modifierFlags.intersection(Self.relevantModifiers) == modifiers
    }

    /// "⌃⌥⇧⌘K", as menus show shortcuts.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keyName
    }

    /// The same key in the main menu, if a menu item has it (built-in shortcuts win).
    func menuItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if let submenu = item.submenu, let found = menuItem(in: submenu) { return found }
            guard !item.keyEquivalent.isEmpty else { continue }
            var itemModifiers = item.keyEquivalentModifierMask.intersection(Self.relevantModifiers)
            var key = item.keyEquivalent.lowercased()
            if item.keyEquivalent != key { itemModifiers.insert(.shift) } // "K" means shift+k
            if let special = Self.menuKeys[item.keyEquivalent] { key = special }
            if itemModifiers == modifiers, Self.keyCodes[key] == keyCode { return item }
        }
        return nil
    }

    /// ANSI key codes.
    private static let keyCodes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
            "enter": 36, "return": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "esc": 53,
            "delete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80]
        for (index, code) in functionKeys.enumerated() { codes["f\(index + 1)"] = code }
        return codes
    }()

    private static let displayNames: [String: String] = [
        "enter": "↩", "return": "↩", "tab": "⇥", "space": "Space", "backspace": "⌫", "escape": "⎋", "esc": "⎋",
        "delete": "⌦", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
        "left": "←", "right": "→", "down": "↓", "up": "↑",
    ]

    /// Menu key equivalents for special keys.
    private static let menuKeys: [String: String] = [
        "\r": "enter", "\t": "tab", " ": "space", "\u{8}": "backspace", "\u{1b}": "escape",
        String(UnicodeScalar(NSUpArrowFunctionKey)!): "up", String(UnicodeScalar(NSDownArrowFunctionKey)!): "down",
        String(UnicodeScalar(NSLeftArrowFunctionKey)!): "left", String(UnicodeScalar(NSRightArrowFunctionKey)!): "right",
    ]
}
