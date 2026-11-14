import SwiftUI

@main
struct OhMyCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        DispatchQueue.main.async {
            AppSettings.shared.applyAppearance() // once NSApp exists
            // Profiles follow (and save) the settings from now on; tests use their own.
            if !AppSettings.isRunningTests {
                ProfileManager.shared.attach(.init(settings: .shared, keybindings: .shared, snippets: .shared, extensions: .shared))
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        // Files and folders from outside go through OpenRouter (AppDelegate), which picks the window.
        .handlesExternalEvents(matching: [])
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
        .handlesExternalEvents(matching: [])
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
            if workspace.rootNode != nil || !workspace.documents.isEmpty {
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
        .background(WindowReader { [workspace] in workspace.window = $0 })
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            for url in files { OpenRouter.shared.apply(OpenRequest(url: url.standardizedFileURL), in: workspace) }
            return !files.isEmpty
        }
        .task {
            let router = OpenRouter.shared
            workspace.openInNewWindow = { url in openWindow(id: RootView.folderWindowID, value: url) }
            router.openWindow = { url in openWindow(id: RootView.folderWindowID, value: url) }
            // A window opened for a folder or file (from inside, or from outside).
            if let folder, workspace.rootURL == nil, workspace.documents.isEmpty {
                router.apply(router.takeRequest(for: folder), in: workspace)
            }
            router.register(workspace)
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

/// Reports the window a view is in.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let found: (NSWindow?) -> Void
        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found(window)
        }
    }
}
