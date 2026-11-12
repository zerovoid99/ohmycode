import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

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

            Divider()

            Button("Next Editor") { workspace?.selectAdjacentDocument(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled((workspace?.documents.count ?? 0) < 2)
            Button("Previous Editor") { workspace?.selectAdjacentDocument(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled((workspace?.documents.count ?? 0) < 2)
        }
    }
}
