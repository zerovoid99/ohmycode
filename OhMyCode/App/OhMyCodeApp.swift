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

        Settings {
            SettingsView()
        }
    }
}

/// One `Workspace` per window, like a VS Code window.
struct RootView: View {
    @State private var workspace = Workspace()

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
