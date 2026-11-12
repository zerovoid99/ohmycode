import SwiftUI

@main
struct OhMyCodeApp: App {
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
