import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

@MainActor
struct SidebarLayoutTests {
    /// No sidebar mode sets the window's minimum height. Run and Debug's empty-state text,
    /// sized for a tiny width, asked for 1,746 pt: in a shorter window the whole sidebar, its
    /// picker too, was pushed up under the title bar.
    @Test(arguments: Workspace.SidebarMode.allCases) func noModeMakesTheWindowTaller(mode: Workspace.SidebarMode) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-sidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let a = 1\n".write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.sidebarMode = mode
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: WorkspaceView(workspace: workspace))
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(host.fittingSize.height <= 420, "\(mode.rawValue): the window must be at least \(host.fittingSize.height) pt tall")
        #expect(window.frame.height == 420)
        withExtendedLifetime(window) {}
    }
}
