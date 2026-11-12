import SwiftUI

@main
struct OhMyCodeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
    }
}
