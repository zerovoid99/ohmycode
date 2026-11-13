import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    static func functionKey(_ key: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt16(key))!))
    }

    private func supports(_ feature: LanguageClient.Feature) -> Bool {
        workspace?.activeDocument?.languageClient?.supports(feature) == true
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { workspace?.presentOpenPanel() }
                .keyboardShortcut("o")
                .disabled(workspace == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspace?.saveActive() }
                .keyboardShortcut("s")
                .disabled(workspace?.activeDocument == nil)

            Button("Save All") { workspace?.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(workspace?.documents.contains(where: \.isDirty) != true)

            Button("Close Tab") {
                if let workspace, let doc = workspace.activeDocument {
                    workspace.close(doc)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
        }

        // ⌘P belongs to Quick Open, as in other code editors.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { AppSettings.shared.zoom(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { AppSettings.shared.zoom(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Zoom") { AppSettings.shared.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }

        CommandGroup(after: .sidebar) {
            Button("Explorer") { workspace?.sidebarMode = .files }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(workspace?.rootNode == nil)
            Button("Search") { workspace?.showSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace?.rootNode == nil)
            Button("Replace in Files") { workspace?.showSearch(replace: true) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(workspace?.rootNode == nil)
            Button("Source Control") { workspace?.sidebarMode = .sourceControl }
                .keyboardShortcut("g", modifiers: [.control, .shift])
                .disabled(workspace?.rootNode == nil)
        }

        CommandMenu("Debug") {
            let session = workspace?.debugSession
            let isActive = session?.isActive == true
            let isStopped = session?.state == .stopped
            Button(isStopped ? "Continue" : "Start Debugging") { workspace?.startOrContinueDebugging() }
                .keyboardShortcut(Self.functionKey(NSF5FunctionKey), modifiers: [])
                .disabled(workspace?.rootURL == nil || (isActive && !isStopped))
            Button("Stop Debugging") { workspace?.stopDebugging() }
                .keyboardShortcut(Self.functionKey(NSF5FunctionKey), modifiers: .shift)
                .disabled(!isActive)
            Button("Restart Debugging") { workspace?.restartDebugging() }
                .keyboardShortcut(Self.functionKey(NSF5FunctionKey), modifiers: [.shift, .command])
                .disabled(!isActive)
            Divider()
            Button("Step Over") { session?.stepOver() }
                .keyboardShortcut(Self.functionKey(NSF10FunctionKey), modifiers: [])
                .disabled(!isStopped)
            Button("Step Into") { session?.stepInto() }
                .keyboardShortcut(Self.functionKey(NSF11FunctionKey), modifiers: [])
                .disabled(!isStopped)
            Button("Step Out") { session?.stepOut() }
                .keyboardShortcut(Self.functionKey(NSF11FunctionKey), modifiers: .shift)
                .disabled(!isStopped)
            Button("Pause") { session?.pause() }
                .disabled(session?.state != .running)
            Divider()
            Button("Toggle Breakpoint") { workspace?.toggleBreakpointAtCursor() }
                .keyboardShortcut(Self.functionKey(NSF9FunctionKey), modifiers: [])
                .disabled(workspace?.activeDocument == nil)
            Button("Show Run and Debug") { workspace?.sidebarMode = .debug }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }

        CommandMenu("Terminal") {
            Button(workspace?.isTerminalVisible == true ? "Hide Terminal" : "Show Terminal") {
                workspace?.toggleTerminal()
            }
            .keyboardShortcut("`", modifiers: .control)
            .disabled(workspace?.rootNode == nil)

            Button("New Terminal") { workspace?.newTerminal() }
                .keyboardShortcut("`", modifiers: [.control, .shift])
                .disabled(workspace?.rootNode == nil)

            Button("Restart Terminal") { workspace?.restartTerminal() }
                .disabled(workspace?.terminal == nil)

            Button("Kill Terminal") { if let terminal = workspace?.terminal { workspace?.closeTerminal(terminal) } }
                .disabled(workspace?.terminal == nil)
        }

        CommandMenu("Go") {
            Button("Go to File…") { workspace?.showPalette(.files) }
                .keyboardShortcut("p")
                .disabled(workspace == nil)
            Button("Command Palette…") { workspace?.showPalette(.commands) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(workspace == nil)
            Button("Go to Line…") { workspace?.showPalette(.goToLine) }
                .keyboardShortcut("g", modifiers: .control)
                .disabled(workspace?.activeDocument == nil)

            Button("Go to Definition") { workspace?.goToDefinition() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: [])
                .disabled(workspace?.activeDocument?.languageClient == nil)
            Button("Find All References") { workspace?.findReferences() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: .shift)
                .disabled(!supports(.references))
            Button("Rename Symbol…") { workspace?.renameSymbol() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])
                .disabled(!supports(.rename))
            Button("Format Document") { workspace?.formatDocument() }
                .keyboardShortcut("f", modifiers: [.shift, .option])
                .disabled(!(workspace?.activeDocument.map { workspace?.canFormat($0) == true } ?? false))

            Divider()

            Button("Add Next Occurrence") { workspace?.activeDocument?.editor?.addNextOccurrence() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(workspace?.activeDocument == nil)
            Button("Select All Occurrences") { workspace?.activeDocument?.editor?.selectAllOccurrences() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(workspace?.activeDocument == nil)
            Button("Add Cursor Above") { workspace?.activeDocument?.editor?.addCursorVertically(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(workspace?.activeDocument == nil)
            Button("Add Cursor Below") { workspace?.activeDocument?.editor?.addCursorVertically(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(workspace?.activeDocument == nil)

            Divider()

            Button("Fold") { workspace?.activeDocument?.editor?.foldAtCursor(true) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(workspace?.activeDocument == nil)
            Button("Unfold") { workspace?.activeDocument?.editor?.foldAtCursor(false) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(workspace?.activeDocument == nil)
            Button("Fold All") { workspace?.activeDocument?.foldAll() }
                .disabled(workspace?.activeDocument == nil)
            Button("Unfold All") { workspace?.activeDocument?.unfoldAll() }
                .disabled(workspace?.activeDocument == nil)

            Divider()

            Button("Next Editor") { workspace?.selectAdjacentDocument(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled((workspace?.activeGroup.documentIDs.count ?? 0) < 2)
            Button("Previous Editor") { workspace?.selectAdjacentDocument(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled((workspace?.activeGroup.documentIDs.count ?? 0) < 2)

            Divider()

            Button("Split Editor") { workspace?.splitEditor() }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(workspace?.activeDocument == nil || (workspace?.groups.count ?? 0) >= Workspace.maxGroups)
            Button("Move Editor into Next Group") { workspace?.moveActiveEditor(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(workspace?.activeDocument == nil)
            Button("Move Editor into Previous Group") { workspace?.moveActiveEditor(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(workspace?.activeDocument == nil)
            ForEach(0..<Workspace.maxGroups, id: \.self) { index in
                Button("Focus Editor Group \(index + 1)") { workspace?.focusGroup(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled((workspace?.groups.count ?? 0) <= index)
            }
        }
    }
}
