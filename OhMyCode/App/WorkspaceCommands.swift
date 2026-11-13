import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

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
                .disabled(!supports(.formatting))

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
