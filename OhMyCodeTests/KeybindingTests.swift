import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

@MainActor
private func keyEvent(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String, window: NSWindow? = nil) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                     windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code)!
}

@MainActor
private func withBindings(_ body: (Keybindings) throws -> Void) rethrows {
    let file = FileManager.default.temporaryDirectory.appending(path: "omc-keys-\(UUID().uuidString).json")
    let saved = Keybindings.shared
    let bindings = Keybindings(file: file)
    Keybindings.shared = bindings
    defer { Keybindings.shared = saved }
    try body(bindings)
}

@MainActor
struct KeybindingTests {
    @Test func chordsRoundTripAndBecomeMenuShortcuts() throws {
        let chord = try KeyChord(parsing: "Shift+Cmd+B")
        #expect(chord.spec == "shift+cmd+b")
        #expect(try KeyChord(parsing: chord.spec) == chord)
        #expect(chord.keyboardShortcut == KeyboardShortcut("b", modifiers: [.command, .shift]))
        #expect(try KeyChord(parsing: "f5").keyboardShortcut?.key == KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)))
        #expect(try KeyChord(parsing: "alt+cmd+left").keyboardShortcut == KeyboardShortcut(.leftArrow, modifiers: [.command, .option]))
        #expect(try KeyChord(parsing: "cmd+enter").spec == "cmd+enter")
        #expect(try KeyChord(parsing: "ctrl+escape").keyboardShortcut?.key == .escape)

        // A recorded key press.
        #expect(KeyChord(event: keyEvent(11, [.command, .shift], "B")) == chord)
        let f5 = try KeyChord(parsing: "f5")
        #expect(KeyChord(event: keyEvent(96, [], "")) == f5)
        #expect(KeyChord(event: keyEvent(11, [], "b")) == nil) // would take over typing
        #expect(KeyChord(event: keyEvent(11, [.shift], "B")) == nil)
    }

    @Test func userRulesChangeRemoveAndResetDefaults() throws {
        try withBindings { bindings in
            #expect(bindings.display(for: "tasks.build") == "⇧⌘B" && bindings.source(for: "tasks.build") == .builtIn)
            #expect(bindings.chord(for: "tasks.run") == nil && bindings.source(for: "tasks.run") == .none)
            #expect(bindings.shortcut("file.save") == KeyboardShortcut("s", modifiers: .command))
            // Every menu shortcut is a valid chord.
            for (command, spec) in Keybindings.builtInDefaults {
                #expect((try? KeyChord(parsing: spec))?.keyboardShortcut != nil, "\(command): \(spec)")
            }

            bindings.set(try KeyChord(parsing: "ctrl+alt+r"), for: "tasks.run")
            #expect(bindings.display(for: "tasks.run") == "⌃⌥R" && bindings.source(for: "tasks.run") == .user)
            bindings.set(nil, for: "tasks.build")
            #expect(bindings.chord(for: "tasks.build") == nil && bindings.source(for: "tasks.build") == .removed)
            // The default again is no change at all.
            bindings.set(try KeyChord(parsing: "cmd+s"), for: "file.save")
            #expect(bindings.rules.count == 2)

            // Conflicts: two commands, one key.
            let commandP = try KeyChord(parsing: "cmd+p")
            bindings.set(commandP, for: "tasks.show")
            #expect(bindings.conflicts(with: commandP, except: "tasks.show") == ["go.quickOpen"])

            // Saved, and read back (comments are fine).
            let reread = Keybindings(file: bindings.file)
            #expect(reread.rules == bindings.rules)
            #expect(reread.display(for: "tasks.run") == "⌃⌥R" && reread.chord(for: "tasks.build") == nil)
            let text = try String(contentsOf: bindings.file, encoding: .utf8)
            #expect(text.contains(#"{ "key": "shift+cmd+b", "command": "-tasks.build" }"#))

            bindings.reset("tasks.build")
            bindings.reset("tasks.show")
            #expect(bindings.display(for: "tasks.build") == "⇧⌘B" && bindings.conflicts(with: commandP).count == 1)
        }
    }

    @Test func readsHandEditedFilesAndReportsProblems() throws {
        try withBindings { bindings in
            try """
            // mine
            [
              { "key": "cmd+k", "command": "view.problems", "when": "editorTextFocus" },
              { "key": "hyper+x", "command": "tasks.run" },
              { "key": "x" },
            ]
            """.write(to: bindings.file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: bindings.file.path)
            bindings.reloadIfChanged()
            #expect(bindings.display(for: "view.problems") == "⌘K" && bindings.when(for: "view.problems") == "editorTextFocus")
            #expect(bindings.loadError?.contains("tasks.run") == true && bindings.loadError?.contains("without a \"command\"") == true)

            try "{ not a list".write(to: bindings.file, atomically: true, encoding: .utf8)
            bindings.load()
            #expect(bindings.loadError != nil && bindings.rules.isEmpty)
        }
    }

    @Test func extensionCommandsHaveDefaultsUsersCanChange() throws {
        try withBindings { bindings in
            bindings.setExtensionCommands("x.tool", name: "Tool", commands: [("tool.go", "Tool: Go")], defaults: ["tool.go": "cmd+shift+u"])
            #expect(bindings.commands.last == Keybindings.Command(id: "tool.go", title: "Tool: Go", extensionName: "Tool"))
            #expect(bindings.source(for: "tool.go") == .extension("Tool") && bindings.display(for: "tool.go") == "⇧⌘U")
            bindings.set(try KeyChord(parsing: "ctrl+u"), for: "tool.go")
            #expect(bindings.display(for: "tool.go") == "⌃U")
            bindings.removeExtension("x.tool")
            #expect(!bindings.commands.contains { $0.id == "tool.go" })
        }
    }

    @Test func keysRunCommandsThatAreNotInAMenu() throws {
        try withBindings { bindings in
            let root = FileManager.default.temporaryDirectory.appending(path: "omc-keys-ws-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let workspace = Workspace()
            workspace.openFolder(root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            let host = workspace.extensions
            let press = keyEvent(17, [.control, .option], "t") // ⌃⌥T
            #expect(!host.handleKeyDown(press, in: window))
            bindings.set(try KeyChord(parsing: "ctrl+alt+t"), for: "tasks.show")
            #expect(host.handleKeyDown(press, in: window))
            #expect(workspace.bottomPanel == .tasks && workspace.isTerminalVisible)

            // A key a menu item has is left to the menu. (The test host has no menus of its own.)
            let menus = NSApp.mainMenu
            defer { NSApp.mainMenu = menus }
            let menu = NSMenu(), view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            view.submenu = NSMenu()
            view.submenu?.addItem(NSMenuItem(title: "Problems", action: nil, keyEquivalent: "M"))
            menu.addItem(view)
            NSApp.mainMenu = menu
            workspace.hidePanel()
            #expect(!host.handleKeyDown(keyEvent(46, [.command, .shift], "M"), in: window))
            #expect(!workspace.isTerminalVisible)
            withExtendedLifetime(window) {}
        }
    }
}

@MainActor
struct ShortcutRecorderTests {
    @Test func recordsChordsAndCancelsOnEscape() throws {
        let view = ShortcutRecorder.RecorderView()
        var recorded: [KeyChord] = [], cancelled = 0
        view.onRecord = { recorded.append($0) }
        view.onCancel = { cancelled += 1 }
        view.handle(keyEvent(11, [], "b")) // a plain letter can't be a shortcut: still recording
        #expect(recorded.isEmpty && cancelled == 0)
        view.handle(keyEvent(11, [.command, .option], "b"))
        #expect(recorded == [try KeyChord(parsing: "alt+cmd+b")])
        view.handle(keyEvent(12, [.command], "q")) // done: further keys are ignored
        #expect(recorded.count == 1)

        let other = ShortcutRecorder.RecorderView()
        other.onRecord = { recorded.append($0) }
        other.onCancel = { cancelled += 1 }
        other.handle(keyEvent(53, [], "\u{1b}"))
        #expect(cancelled == 1 && recorded.count == 1)
    }
}
