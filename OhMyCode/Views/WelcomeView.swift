import SwiftUI

struct WelcomeView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("Oh My Code").font(.largeTitle.weight(.semibold))
                Text("A native code editor for Apple silicon").foregroundStyle(.secondary)
            }
            Button("Open Folder…") { workspace.presentOpenPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("⌘O").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
