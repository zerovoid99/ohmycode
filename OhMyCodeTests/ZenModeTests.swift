import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

@MainActor
struct ZenModeTests {
    @Test func hidesThePanelsAndPutsThemBack() throws {
        let workspace = Workspace()
        let settings = AppSettings.shared
        settings.zenModeFullScreen = false
        defer { settings.zenModeFullScreen = true }
        workspace.isTerminalVisible = true
        workspace.sidebarVisibility = .all

        workspace.toggleZenMode()
        #expect(workspace.isZenMode && !workspace.isTerminalVisible && workspace.sidebarVisibility == .detailOnly)
        workspace.toggleZenMode()
        #expect(!workspace.isZenMode && workspace.isTerminalVisible && workspace.sidebarVisibility == .all)

        // Hidden before: stays hidden after.
        workspace.isTerminalVisible = false
        workspace.sidebarVisibility = .detailOnly
        workspace.toggleZenMode()
        workspace.toggleZenMode()
        #expect(!workspace.isTerminalVisible && workspace.sidebarVisibility == .detailOnly)
        #expect(Workspace.zenEditorWidth > 400)
    }

    @Test func escapeTwiceInTheEditorLeaves() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-zen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "text\n".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(folder)
        workspace.open(fileAt: folder.appending(path: "a.txt"))
        let document = try #require(workspace.activeDocument)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        document.editor = controller
        AppSettings.shared.zenModeFullScreen = false
        defer { AppSettings.shared.zenModeFullScreen = true }

        // Not in zen mode: Esc is the text view's.
        #expect(!controller.textView(controller.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        workspace.toggleZenMode()
        #expect(controller.textView(controller.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(workspace.isZenMode) // one isn't enough
        #expect(controller.textView(controller.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!workspace.isZenMode)
        withExtendedLifetime(window) {}
    }

    @Test func theWorkspaceViewShowsOnlyTheEditor() throws {
        let workspace = Workspace()
        AppSettings.shared.zenModeFullScreen = false
        defer { AppSettings.shared.zenModeFullScreen = true }
        let host = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        workspace.toggleZenMode()
        host.layoutSubtreeIfNeeded()
        #expect(workspace.isZenMode)
        workspace.toggleZenMode()
        host.layoutSubtreeIfNeeded()
        #expect(!workspace.isZenMode)
    }
}
