import AppKit

/// An action runnable from the command palette. Menu items and palette share these.
@MainActor
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let icon: String
    let shortcut: String?
    let isAvailable: (Workspace) -> Bool
    let perform: (Workspace) -> Void

    static let all: [PaletteCommand] = [
        PaletteCommand(id: "go.quickOpen", title: "Go to File…", icon: "doc.text.magnifyingglass", shortcut: "⌘P",
                       isAvailable: { $0.rootNode != nil }, perform: { $0.showPalette(.files) }),
        PaletteCommand(id: "go.line", title: "Go to Line…", icon: "arrow.right.to.line", shortcut: "⌃G",
                       isAvailable: { $0.activeDocument != nil }, perform: { $0.showPalette(.goToLine) }),
        PaletteCommand(id: "go.definition", title: "Go to Definition", icon: "arrow.turn.down.right", shortcut: "F12",
                       isAvailable: { $0.activeDocument?.languageClient != nil }, perform: { $0.goToDefinition() }),
        PaletteCommand(id: "file.openFolder", title: "File: Open Folder…", icon: "folder", shortcut: "⌘O",
                       isAvailable: { _ in true }, perform: { $0.presentOpenPanel() }),
        PaletteCommand(id: "file.save", title: "File: Save", icon: "square.and.arrow.down", shortcut: "⌘S",
                       isAvailable: { $0.activeDocument != nil }, perform: { $0.saveActive() }),
        PaletteCommand(id: "file.saveAll", title: "File: Save All", icon: "square.and.arrow.down.on.square",
                       shortcut: "⌥⌘S",
                       isAvailable: { $0.documents.contains(where: \.isDirty) }, perform: { $0.saveAll() }),
        PaletteCommand(id: "edit.find", title: "Edit: Find", icon: "magnifyingglass", shortcut: "⌘F",
                       isAvailable: { $0.activeDocument != nil },
                       perform: { $0.activeDocument?.editor?.showFindInterface() }),
        PaletteCommand(id: "view.closeEditor", title: "View: Close Editor", icon: "xmark", shortcut: "⌘W",
                       isAvailable: { $0.activeDocument != nil },
                       perform: { if let doc = $0.activeDocument { $0.close(doc) } }),
        PaletteCommand(id: "view.closeAll", title: "View: Close All Editors", icon: "xmark.square", shortcut: nil,
                       isAvailable: { !$0.documents.isEmpty }, perform: { $0.closeAll() }),
        PaletteCommand(id: "view.nextEditor", title: "View: Next Editor", icon: "chevron.right", shortcut: "⌥⌘→",
                       isAvailable: { $0.documents.count > 1 }, perform: { $0.selectAdjacentDocument(offset: 1) }),
        PaletteCommand(id: "view.previousEditor", title: "View: Previous Editor", icon: "chevron.left",
                       shortcut: "⌥⌘←",
                       isAvailable: { $0.documents.count > 1 }, perform: { $0.selectAdjacentDocument(offset: -1) }),
        PaletteCommand(id: "view.toggleTerminal", title: "View: Toggle Terminal", icon: "terminal", shortcut: "⌃`",
                       isAvailable: { $0.rootNode != nil }, perform: { $0.toggleTerminal() }),
        PaletteCommand(id: "terminal.new", title: "Terminal: New Terminal", icon: "plus", shortcut: "⌃⇧`",
                       isAvailable: { $0.rootNode != nil }, perform: { $0.newTerminal() }),
        PaletteCommand(id: "terminal.kill", title: "Terminal: Kill Terminal", icon: "xmark", shortcut: nil,
                       isAvailable: { $0.terminal != nil },
                       perform: { if let terminal = $0.terminal { $0.closeTerminal(terminal) } }),
        PaletteCommand(id: "terminal.restart", title: "Terminal: Restart", icon: "arrow.clockwise", shortcut: nil,
                       isAvailable: { $0.terminal != nil }, perform: { $0.restartTerminal() }),
        PaletteCommand(id: "view.explorer", title: "View: Show Explorer", icon: "folder", shortcut: "⇧⌘E",
                       isAvailable: { $0.rootNode != nil }, perform: { $0.sidebarMode = .files }),
        PaletteCommand(id: "view.sourceControl", title: "View: Show Source Control", icon: "arrow.triangle.branch",
                       shortcut: "⌃⇧G", isAvailable: { $0.rootNode != nil }, perform: { $0.sidebarMode = .sourceControl }),
        PaletteCommand(id: "git.stageAll", title: "Git: Stage All Changes", icon: "plus", shortcut: nil,
                       isAvailable: { $0.gitStatus?.unstagedChanges.isEmpty == false },
                       perform: { $0.stage($0.gitStatus?.unstagedChanges.map(\.path) ?? []) }),
        PaletteCommand(id: "git.unstageAll", title: "Git: Unstage All Changes", icon: "minus", shortcut: nil,
                       isAvailable: { $0.gitStatus?.stagedChanges.isEmpty == false },
                       perform: { $0.unstage($0.gitStatus?.stagedChanges.map(\.path) ?? []) }),
        PaletteCommand(id: "git.refresh", title: "Git: Refresh", icon: "arrow.clockwise", shortcut: nil,
                       isAvailable: { $0.gitStatus != nil }, perform: { $0.refreshGit() }),
        PaletteCommand(id: "view.toggleSidebar", title: "View: Toggle Sidebar", icon: "sidebar.left", shortcut: "⌃⌘S",
                       isAvailable: { $0.rootNode != nil },
                       perform: { _ in
                           NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                       }),
    ]
}
