import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var workspace: Workspace?
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    /// Every shortcut comes from here (Settings → Keyboard Shortcuts changes them).
    private var keys: Keybindings { Keybindings.shared }

    private func supports(_ feature: LanguageClient.Feature) -> Bool {
        workspace?.activeDocument?.languageClient?.supports(feature) == true
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") { workspace?.presentOpenPanel() }
                .keyboardShortcut(keys.shortcut("file.openFolder"))
                .disabled(workspace == nil)
            Menu("Open Recent") {
                let recent = RecentFolders.shared.existing
                ForEach(recent, id: \.self) { url in
                    Button(url.lastPathComponent + "  —  " + (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) {
                        OpenRouter.shared.open(OpenRequest(url: url))
                    }
                }
                if !recent.isEmpty { Divider() }
                Button("Clear Menu") { RecentFolders.shared.clear() }
                    .disabled(recent.isEmpty)
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                .disabled(!AppUpdater.shared.canCheckForUpdates)
        }

        CommandGroup(after: .appSettings) {
            Button("Install “omc” Command…") { workspace?.installCommandLineTool() }
                .disabled(workspace == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspace?.saveActive() }
                .keyboardShortcut(keys.shortcut("file.save"))
                .disabled(workspace?.activeDocument == nil)

            Button("Save All") { workspace?.saveAll() }
                .keyboardShortcut(keys.shortcut("file.saveAll"))
                .disabled(workspace?.documents.contains(where: \.isDirty) != true)

            Button("Close Tab") {
                if let workspace, let doc = workspace.activeDocument {
                    workspace.close(doc)
                } else if workspace?.confirmClosingWindow() != false {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut(keys.shortcut("view.closeEditor"))
        }

        // ⌘P belongs to Quick Open, as in other code editors.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { AppSettings.shared.zoom(by: 1) }
                .keyboardShortcut(keys.shortcut("view.zoomIn"))
            Button("Zoom Out") { AppSettings.shared.zoom(by: -1) }
                .keyboardShortcut(keys.shortcut("view.zoomOut"))
            Button("Reset Zoom") { AppSettings.shared.resetZoom() }
                .keyboardShortcut(keys.shortcut("view.resetZoom"))
            Divider()
        }

        CommandGroup(after: .sidebar) {
            Button("Explorer") { workspace?.sidebarMode = .files }
                .keyboardShortcut(keys.shortcut("view.explorer"))
                .disabled(workspace?.rootNode == nil)
            Button("Search") { workspace?.showSearch() }
                .keyboardShortcut(keys.shortcut("view.search"))
                .disabled(workspace?.rootNode == nil)
            Button("Replace in Files") { workspace?.showSearch(replace: true) }
                .keyboardShortcut(keys.shortcut("view.replace"))
                .disabled(workspace?.rootNode == nil)
            Button("Source Control") { workspace?.sidebarMode = .sourceControl }
                .keyboardShortcut(keys.shortcut("view.sourceControl"))
                .disabled(workspace?.rootNode == nil)
            Button("Markdown Preview") { workspace?.toggleMarkdownPreview() }
                .keyboardShortcut(keys.shortcut("markdown.preview"))
                .disabled(workspace?.activeDocument?.language != .markdown)
            Button("Problems") { workspace?.toggleProblems() }
                .keyboardShortcut(keys.shortcut("view.problems"))
                .disabled(workspace?.rootNode == nil)
            Button("Agent") { workspace?.sidebarMode = .agent }
                .keyboardShortcut(keys.shortcut("view.agent"))
                .disabled(workspace?.rootNode == nil)
            Button("Send Selection to Claude Code") { workspace?.sendSelectionToClaudeCode() }
                .keyboardShortcut(keys.shortcut("claude.sendSelection"))
                .disabled(workspace?.activeDocument == nil)
            Divider()
            Button(workspace?.isZenMode == true ? "Leave Zen Mode" : "Zen Mode") { workspace?.toggleZenMode() }
                .keyboardShortcut(keys.shortcut("view.zenMode"))
                .disabled(workspace == nil)
        }

        CommandMenu("Debug") {
            let session = workspace?.debugSession
            let isActive = session?.isActive == true
            let isStopped = session?.state == .stopped
            Button(isStopped ? "Continue" : "Start Debugging") { workspace?.startOrContinueDebugging() }
                .keyboardShortcut(keys.shortcut("debug.start"))
                .disabled(workspace?.rootURL == nil || (isActive && !isStopped))
            Button("Stop Debugging") { workspace?.stopDebugging() }
                .keyboardShortcut(keys.shortcut("debug.stop"))
                .disabled(!isActive)
            Button("Restart Debugging") { workspace?.restartDebugging() }
                .keyboardShortcut(keys.shortcut("debug.restart"))
                .disabled(!isActive)
            Divider()
            Button("Step Over") { session?.stepOver() }
                .keyboardShortcut(keys.shortcut("debug.stepOver"))
                .disabled(!isStopped)
            Button("Step Into") { session?.stepInto() }
                .keyboardShortcut(keys.shortcut("debug.stepInto"))
                .disabled(!isStopped)
            Button("Step Out") { session?.stepOut() }
                .keyboardShortcut(keys.shortcut("debug.stepOut"))
                .disabled(!isStopped)
            Button("Pause") { session?.pause() }
                .disabled(session?.state != .running)
            Divider()
            Button("Toggle Breakpoint") { workspace?.toggleBreakpointAtCursor() }
                .keyboardShortcut(keys.shortcut("debug.toggleBreakpoint"))
                .disabled(workspace?.activeDocument == nil)
            Divider()
            Button("Run All Tests") { workspace?.runAllTests() }
                .keyboardShortcut(keys.shortcut("test.runAll"))
                .disabled(workspace?.rootURL == nil)
            Button("Run Test at Cursor") { workspace?.runTestAtCursor() }
                .keyboardShortcut(keys.shortcut("test.runAtCursor"))
                .disabled(workspace?.activeDocument == nil)
            Button("Show Testing") { workspace?.sidebarMode = .testing }
                .disabled(workspace == nil)
            Button("Show Run and Debug") { workspace?.sidebarMode = .debug }
                .keyboardShortcut(keys.shortcut("debug.show"))
                .disabled(workspace == nil)
        }

        CommandMenu("Terminal") {
            Button(workspace?.isTerminalVisible == true && workspace?.bottomPanel == .terminal ? "Hide Terminal" : "Show Terminal") {
                workspace?.toggleTerminal()
            }
            .keyboardShortcut(keys.shortcut("view.toggleTerminal"))
            .disabled(workspace?.rootNode == nil)

            Button("New Terminal") { workspace?.newTerminal() }
                .keyboardShortcut(keys.shortcut("terminal.new"))
                .disabled(workspace?.rootNode == nil)

            Button("Restart Terminal") { workspace?.restartTerminal() }
                .disabled(workspace?.terminal == nil)

            Button("Kill Terminal") { if let terminal = workspace?.terminal { workspace?.closeTerminal(terminal) } }
                .disabled(workspace?.terminal == nil)

            Divider()
            Button("Run Task…") { Task { await workspace?.pickAndRunTask() } }
                .disabled(workspace?.rootURL == nil)
            Button("Run Build Task") { workspace?.runBuildTask() }
                .keyboardShortcut(keys.shortcut("tasks.build"))
                .disabled(workspace?.rootURL == nil)
            Button("Run Test Task") { workspace?.runTestTask() }
                .disabled(workspace?.rootURL == nil)
            Button("Rerun Last Task") { workspace?.rerunLastTask() }
                .disabled(workspace?.taskHistory.isEmpty != false)
            Button("Terminate Task") { Task { await workspace?.terminateRunningTask() } }
                .disabled(workspace?.taskRuns.contains { $0.state.isRunning } != true)
            Button("Configure Tasks…") { workspace?.configureTasks() }
                .disabled(workspace?.rootURL == nil)
        }

        CommandMenu("Go") {
            Button("Go to File…") { workspace?.showPalette(.files) }
                .keyboardShortcut(keys.shortcut("go.quickOpen"))
                .disabled(workspace == nil)
            Button("Command Palette…") { workspace?.showPalette(.commands) }
                .keyboardShortcut(keys.shortcut("view.commandPalette"))
                .disabled(workspace == nil)
            Button("Go to Symbol in Workspace…") { workspace?.showPalette(.workspaceSymbols) }
                .keyboardShortcut(keys.shortcut("go.workspaceSymbol"))
                .disabled(workspace?.rootURL == nil)
            Button("Go to Symbol in File…") { workspace?.showPalette(.symbols) }
                .keyboardShortcut(keys.shortcut("go.symbol"))
                .disabled(workspace?.activeDocument == nil)
            Button("Go to Line…") { workspace?.showPalette(.goToLine) }
                .keyboardShortcut(keys.shortcut("go.line"))
                .disabled(workspace?.activeDocument == nil)

            Button("Go to Definition") { workspace?.goToDefinition() }
                .keyboardShortcut(keys.shortcut("go.definition"))
                .disabled(workspace?.activeDocument?.languageClient == nil)
            Button("Go to Implementation") { workspace?.goToImplementation() }
                .keyboardShortcut(keys.shortcut("go.implementation"))
                .disabled(!supports(.implementation))
            Button("Go to Type Definition") { workspace?.goToTypeDefinition() }
                .keyboardShortcut(keys.shortcut("go.typeDefinition"))
                .disabled(!supports(.typeDefinition))
            Button("Show Call Hierarchy") { workspace?.showCallHierarchy() }
                .keyboardShortcut(keys.shortcut("go.callHierarchy"))
                .disabled(!supports(.callHierarchy))
            Button("Find All References") { workspace?.findReferences() }
                .keyboardShortcut(keys.shortcut("go.references"))
                .disabled(!supports(.references))
            Button("Rename Symbol…") { workspace?.renameSymbol() }
                .keyboardShortcut(keys.shortcut("edit.rename"))
                .disabled(!supports(.rename))
            Button("Quick Fix & Refactor…") { workspace?.showCodeActions() }
                .keyboardShortcut(keys.shortcut("edit.codeActions"))
                .disabled(!supports(.codeAction))
            Button("Organize Imports") { workspace?.organizeImports() }
                .keyboardShortcut(keys.shortcut("edit.organizeImports"))
                .disabled(!supports(.codeAction))
            Button("Trigger Parameter Hints") { workspace?.activeDocument?.editor?.signatureHelp.trigger() }
                .keyboardShortcut(keys.shortcut("edit.parameterHints"))
                .disabled(!supports(.signatureHelp))
            Button("Format Document") { workspace?.formatDocument() }
                .keyboardShortcut(keys.shortcut("edit.format"))
                .disabled(!(workspace?.activeDocument.map { workspace?.canFormat($0) == true } ?? false))

            Divider()

            Button("Add Next Occurrence") { workspace?.activeDocument?.editor?.addNextOccurrence() }
                .keyboardShortcut(keys.shortcut("edit.addNextOccurrence"))
                .disabled(workspace?.activeDocument == nil)
            Button("Select All Occurrences") { workspace?.activeDocument?.editor?.selectAllOccurrences() }
                .keyboardShortcut(keys.shortcut("edit.selectAllOccurrences"))
                .disabled(workspace?.activeDocument == nil)
            Button(keys.display(for: "view.toggleWordWrap").map { "Toggle Word Wrap  \($0)" } ?? "Toggle Word Wrap") {
                workspace?.activeDocument?.editor?.toggleWordWrap()
            }
            .disabled(workspace?.activeDocument?.editor == nil)
            Button(keys.display(for: "go.bracket").map { "Go to Bracket  \($0)" } ?? "Go to Bracket") {
                workspace?.activeDocument?.editor?.jumpToBracket()
            }
            .disabled(workspace?.activeDocument?.editor == nil)
            // No menu shortcuts: the editor handles their keys itself, so they still work in
            // other text fields (⌥↑ in the commit message).
            Menu("Lines") {
                ForEach(LineCommand.allCases, id: \.self) { command in
                    Button(keys.display(for: command.id).map { "\(command.title)  \($0)" } ?? command.title) {
                        workspace?.activeDocument?.editor?.perform(command)
                    }
                }
            }
            .disabled(workspace?.activeDocument?.editor == nil)
            // AI: no menu shortcuts either (the editor handles ⌘I and ⌥\ itself).
            Button(keys.display(for: "ai.editSelection").map { "Edit Selection with AI…  \($0)" } ?? "Edit Selection with AI…") {
                workspace?.activeDocument?.editor?.inlineEdit.begin()
            }
            .disabled(workspace?.activeDocument?.editor == nil)
            Button(keys.display(for: "ai.triggerSuggestion").map { "Trigger Inline Suggestion  \($0)" } ?? "Trigger Inline Suggestion") {
                workspace?.activeDocument?.editor?.inlineSuggestions.trigger()
            }
            .disabled(workspace?.activeDocument?.editor == nil)
            Button(AISettings.shared.inlineSuggestionsEnabled ? "Turn Off Inline Suggestions" : "Turn On Inline Suggestions") {
                AISettings.shared.inlineSuggestionsEnabled.toggle()
            }
            Button("Go to Next Symbol Highlight") { workspace?.activeDocument?.editor?.moveToOccurrence(forward: true) }
                .keyboardShortcut(keys.shortcut("go.nextHighlight"))
                .disabled(workspace?.activeDocument == nil)
            Button("Go to Previous Symbol Highlight") { workspace?.activeDocument?.editor?.moveToOccurrence(forward: false) }
                .keyboardShortcut(keys.shortcut("go.previousHighlight"))
                .disabled(workspace?.activeDocument == nil)
            Button("Add Cursor Above") { workspace?.activeDocument?.editor?.addCursorVertically(-1) }
                .keyboardShortcut(keys.shortcut("edit.cursorAbove"))
                .disabled(workspace?.activeDocument == nil)
            Button("Add Cursor Below") { workspace?.activeDocument?.editor?.addCursorVertically(1) }
                .keyboardShortcut(keys.shortcut("edit.cursorBelow"))
                .disabled(workspace?.activeDocument == nil)

            Divider()

            Button("Fold") { workspace?.activeDocument?.editor?.foldAtCursor(true) }
                .keyboardShortcut(keys.shortcut("edit.fold"))
                .disabled(workspace?.activeDocument == nil)
            Button("Unfold") { workspace?.activeDocument?.editor?.foldAtCursor(false) }
                .keyboardShortcut(keys.shortcut("edit.unfold"))
                .disabled(workspace?.activeDocument == nil)
            Button("Fold All") { workspace?.activeDocument?.foldAll() }
                .disabled(workspace?.activeDocument == nil)
            Button("Unfold All") { workspace?.activeDocument?.unfoldAll() }
                .disabled(workspace?.activeDocument == nil)

            Divider()

            Button("Next Editor") { workspace?.selectAdjacentDocument(offset: 1) }
                .keyboardShortcut(keys.shortcut("view.nextEditor"))
                .disabled((workspace?.activeGroup.documentIDs.count ?? 0) < 2)
            Button("Previous Editor") { workspace?.selectAdjacentDocument(offset: -1) }
                .keyboardShortcut(keys.shortcut("view.previousEditor"))
                .disabled((workspace?.activeGroup.documentIDs.count ?? 0) < 2)

            Divider()

            Button("Split Editor") { workspace?.splitEditor() }
                .keyboardShortcut(keys.shortcut("view.splitEditor"))
                .disabled(workspace?.activeDocument == nil || (workspace?.groups.count ?? 0) >= Workspace.maxGroups)
            Button("Move Editor into Next Group") { workspace?.moveActiveEditor(by: 1) }
                .keyboardShortcut(keys.shortcut("view.moveEditorNext"))
                .disabled(workspace?.activeDocument == nil)
            Button("Move Editor into Previous Group") { workspace?.moveActiveEditor(by: -1) }
                .keyboardShortcut(keys.shortcut("view.moveEditorPrevious"))
                .disabled(workspace?.activeDocument == nil)
            ForEach(0..<Workspace.maxGroups, id: \.self) { index in
                Button("Focus Editor Group \(index + 1)") { workspace?.focusGroup(at: index) }
                    .keyboardShortcut(keys.shortcut("view.focusGroup\(index + 1)"))
                    .disabled((workspace?.groups.count ?? 0) <= index)
            }
        }
    }
}
