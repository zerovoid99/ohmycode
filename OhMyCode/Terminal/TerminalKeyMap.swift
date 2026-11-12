import AppKit
import Carbon.HIToolbox
import GhosttyVt

/// Translates AppKit key events into libghostty-vt key events. Keys are identified by
/// physical key code (layout independent), text comes from AppKit's layout translation.
enum TerminalKeyMap {
    @MainActor
    static func input(for event: NSEvent, action: GhosttyKeyAction) -> TerminalSession.KeyInput {
        let mods = ghosttyMods(event.modifierFlags)
        let text = printableText(event)
        var consumed: GhosttyMods = 0
        if text != nil {
            // Shift/Option produced the text (e.g. "A", "é"), so they shouldn't be encoded again.
            consumed = mods & GhosttyMods(GHOSTTY_MODS_SHIFT | GHOSTTY_MODS_ALT)
        }
        let unshifted = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value
            ?? event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first?.value ?? 0
        return TerminalSession.KeyInput(
            key: keys[Int(event.keyCode)] ?? GHOSTTY_KEY_UNIDENTIFIED,
            mods: mods, consumedMods: consumed, text: text,
            unshiftedCodepoint: isPrivateUse(unshifted) ? 0 : unshifted,
            action: action
        )
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: Int32 = 0
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS_LOCK }
        return GhosttyMods(mods)
    }

    /// The event's text unless it's a control character or one of AppKit's private-use
    /// function-key characters (arrows, F-keys…), which the encoder derives from the key.
    private static func printableText(_ event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else { return nil }
        for scalar in characters.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || isPrivateUse(scalar.value) { return nil }
        }
        return characters
    }

    private static func isPrivateUse(_ value: UInt32) -> Bool { (0xF700...0xF8FF).contains(value) }

    private static let keys: [Int: GhosttyKey] = [
        kVK_ANSI_A: GHOSTTY_KEY_A, kVK_ANSI_B: GHOSTTY_KEY_B, kVK_ANSI_C: GHOSTTY_KEY_C, kVK_ANSI_D: GHOSTTY_KEY_D,
        kVK_ANSI_E: GHOSTTY_KEY_E, kVK_ANSI_F: GHOSTTY_KEY_F, kVK_ANSI_G: GHOSTTY_KEY_G, kVK_ANSI_H: GHOSTTY_KEY_H,
        kVK_ANSI_I: GHOSTTY_KEY_I, kVK_ANSI_J: GHOSTTY_KEY_J, kVK_ANSI_K: GHOSTTY_KEY_K, kVK_ANSI_L: GHOSTTY_KEY_L,
        kVK_ANSI_M: GHOSTTY_KEY_M, kVK_ANSI_N: GHOSTTY_KEY_N, kVK_ANSI_O: GHOSTTY_KEY_O, kVK_ANSI_P: GHOSTTY_KEY_P,
        kVK_ANSI_Q: GHOSTTY_KEY_Q, kVK_ANSI_R: GHOSTTY_KEY_R, kVK_ANSI_S: GHOSTTY_KEY_S, kVK_ANSI_T: GHOSTTY_KEY_T,
        kVK_ANSI_U: GHOSTTY_KEY_U, kVK_ANSI_V: GHOSTTY_KEY_V, kVK_ANSI_W: GHOSTTY_KEY_W, kVK_ANSI_X: GHOSTTY_KEY_X,
        kVK_ANSI_Y: GHOSTTY_KEY_Y, kVK_ANSI_Z: GHOSTTY_KEY_Z,
        kVK_ANSI_0: GHOSTTY_KEY_DIGIT_0, kVK_ANSI_1: GHOSTTY_KEY_DIGIT_1, kVK_ANSI_2: GHOSTTY_KEY_DIGIT_2,
        kVK_ANSI_3: GHOSTTY_KEY_DIGIT_3, kVK_ANSI_4: GHOSTTY_KEY_DIGIT_4, kVK_ANSI_5: GHOSTTY_KEY_DIGIT_5,
        kVK_ANSI_6: GHOSTTY_KEY_DIGIT_6, kVK_ANSI_7: GHOSTTY_KEY_DIGIT_7, kVK_ANSI_8: GHOSTTY_KEY_DIGIT_8,
        kVK_ANSI_9: GHOSTTY_KEY_DIGIT_9,
        kVK_ANSI_Grave: GHOSTTY_KEY_BACKQUOTE, kVK_ANSI_Backslash: GHOSTTY_KEY_BACKSLASH,
        kVK_ANSI_LeftBracket: GHOSTTY_KEY_BRACKET_LEFT, kVK_ANSI_RightBracket: GHOSTTY_KEY_BRACKET_RIGHT,
        kVK_ANSI_Comma: GHOSTTY_KEY_COMMA, kVK_ANSI_Equal: GHOSTTY_KEY_EQUAL, kVK_ANSI_Minus: GHOSTTY_KEY_MINUS,
        kVK_ANSI_Period: GHOSTTY_KEY_PERIOD, kVK_ANSI_Quote: GHOSTTY_KEY_QUOTE,
        kVK_ANSI_Semicolon: GHOSTTY_KEY_SEMICOLON, kVK_ANSI_Slash: GHOSTTY_KEY_SLASH,
        kVK_ISO_Section: GHOSTTY_KEY_INTL_BACKSLASH, kVK_JIS_Yen: GHOSTTY_KEY_INTL_YEN,
        kVK_JIS_Underscore: GHOSTTY_KEY_INTL_RO,
        kVK_Return: GHOSTTY_KEY_ENTER, kVK_Tab: GHOSTTY_KEY_TAB, kVK_Space: GHOSTTY_KEY_SPACE,
        kVK_Delete: GHOSTTY_KEY_BACKSPACE, kVK_ForwardDelete: GHOSTTY_KEY_DELETE, kVK_Escape: GHOSTTY_KEY_ESCAPE,
        kVK_Home: GHOSTTY_KEY_HOME, kVK_End: GHOSTTY_KEY_END, kVK_PageUp: GHOSTTY_KEY_PAGE_UP,
        kVK_PageDown: GHOSTTY_KEY_PAGE_DOWN, kVK_Help: GHOSTTY_KEY_INSERT,
        kVK_LeftArrow: GHOSTTY_KEY_ARROW_LEFT, kVK_RightArrow: GHOSTTY_KEY_ARROW_RIGHT,
        kVK_UpArrow: GHOSTTY_KEY_ARROW_UP, kVK_DownArrow: GHOSTTY_KEY_ARROW_DOWN,
        kVK_Shift: GHOSTTY_KEY_SHIFT_LEFT, kVK_RightShift: GHOSTTY_KEY_SHIFT_RIGHT,
        kVK_Control: GHOSTTY_KEY_CONTROL_LEFT, kVK_RightControl: GHOSTTY_KEY_CONTROL_RIGHT,
        kVK_Option: GHOSTTY_KEY_ALT_LEFT, kVK_RightOption: GHOSTTY_KEY_ALT_RIGHT,
        kVK_Command: GHOSTTY_KEY_META_LEFT, kVK_RightCommand: GHOSTTY_KEY_META_RIGHT,
        kVK_CapsLock: GHOSTTY_KEY_CAPS_LOCK, kVK_Function: GHOSTTY_KEY_FN,
        kVK_F1: GHOSTTY_KEY_F1, kVK_F2: GHOSTTY_KEY_F2, kVK_F3: GHOSTTY_KEY_F3, kVK_F4: GHOSTTY_KEY_F4,
        kVK_F5: GHOSTTY_KEY_F5, kVK_F6: GHOSTTY_KEY_F6, kVK_F7: GHOSTTY_KEY_F7, kVK_F8: GHOSTTY_KEY_F8,
        kVK_F9: GHOSTTY_KEY_F9, kVK_F10: GHOSTTY_KEY_F10, kVK_F11: GHOSTTY_KEY_F11, kVK_F12: GHOSTTY_KEY_F12,
        kVK_F13: GHOSTTY_KEY_F13, kVK_F14: GHOSTTY_KEY_F14, kVK_F15: GHOSTTY_KEY_F15, kVK_F16: GHOSTTY_KEY_F16,
        kVK_F17: GHOSTTY_KEY_F17, kVK_F18: GHOSTTY_KEY_F18, kVK_F19: GHOSTTY_KEY_F19, kVK_F20: GHOSTTY_KEY_F20,
        kVK_ANSI_Keypad0: GHOSTTY_KEY_NUMPAD_0, kVK_ANSI_Keypad1: GHOSTTY_KEY_NUMPAD_1,
        kVK_ANSI_Keypad2: GHOSTTY_KEY_NUMPAD_2, kVK_ANSI_Keypad3: GHOSTTY_KEY_NUMPAD_3,
        kVK_ANSI_Keypad4: GHOSTTY_KEY_NUMPAD_4, kVK_ANSI_Keypad5: GHOSTTY_KEY_NUMPAD_5,
        kVK_ANSI_Keypad6: GHOSTTY_KEY_NUMPAD_6, kVK_ANSI_Keypad7: GHOSTTY_KEY_NUMPAD_7,
        kVK_ANSI_Keypad8: GHOSTTY_KEY_NUMPAD_8, kVK_ANSI_Keypad9: GHOSTTY_KEY_NUMPAD_9,
        kVK_ANSI_KeypadDecimal: GHOSTTY_KEY_NUMPAD_DECIMAL, kVK_ANSI_KeypadMultiply: GHOSTTY_KEY_NUMPAD_MULTIPLY,
        kVK_ANSI_KeypadPlus: GHOSTTY_KEY_NUMPAD_ADD, kVK_ANSI_KeypadMinus: GHOSTTY_KEY_NUMPAD_SUBTRACT,
        kVK_ANSI_KeypadDivide: GHOSTTY_KEY_NUMPAD_DIVIDE, kVK_ANSI_KeypadEnter: GHOSTTY_KEY_NUMPAD_ENTER,
        kVK_ANSI_KeypadEquals: GHOSTTY_KEY_NUMPAD_EQUAL, kVK_ANSI_KeypadClear: GHOSTTY_KEY_NUM_LOCK,
        kVK_JIS_KeypadComma: GHOSTTY_KEY_NUMPAD_COMMA,
    ]
}
