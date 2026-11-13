import SwiftUI

@main
struct OhMyCodeApp: App {
    init() {
        DispatchQueue.main.async { AppSettings.shared.applyAppearance() } // once NSApp exists
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            WorkspaceCommands()
        }

        // A folder opened from inside a window (a worktree, a submodule). Not restored at
        // launch, like the windows above.
        WindowGroup("Folder", id: RootView.folderWindowID, for: URL.self) { $folder in
            RootView(folder: folder)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

/// One `Workspace` per window, like a VS Code window.
struct RootView: View {
    static let folderWindowID = "folder"
    /// The folder to open (a window opened for one).
    var folder: URL?
    @State private var workspace = Workspace()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if workspace.rootNode != nil {
                WorkspaceView(workspace: workspace)
            } else {
                WelcomeView(workspace: workspace)
            }
        }
        .overlay(alignment: .top) {
            if let palette = workspace.palette {
                ZStack(alignment: .top) {
                    // Click outside the palette to dismiss it.
                    Color.black.opacity(0.001)
                        .onTapGesture { workspace.closePalette() }
                    PaletteView(model: palette, onDismiss: { workspace.closePalette() })
                        .padding(.top, 8)
                }
            }
        }
        .focusedSceneValue(\.workspace, workspace)
        .task {
            workspace.openInNewWindow = { url in openWindow(id: RootView.folderWindowID, value: url) }
            if let folder, workspace.rootURL == nil { workspace.openFolder(folder) }
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { workspace.errorMessage != nil },
                set: { if !$0 { workspace.errorMessage = nil } }
            ),
            actions: { Button("OK") {} },
            message: { Text(workspace.errorMessage ?? "") }
        )
    }
}
