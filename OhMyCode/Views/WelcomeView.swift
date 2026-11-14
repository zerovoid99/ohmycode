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
            Text("⌘O, or drop a folder here").font(.caption).foregroundStyle(.tertiary)
            let recent = RecentFolders.shared.existing.prefix(8)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent").font(.headline).padding(.bottom, 4)
                    ForEach(Array(recent), id: \.self) { url in
                        RecentFolderRow(url: url) { OpenRouter.shared.apply(OpenRequest(url: url), in: workspace) }
                    }
                }
                .frame(width: 420, alignment: .leading)
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecentFolderRow: View {
    let url: URL
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Button(url.lastPathComponent, action: open)
                .buttonStyle(.link)
            Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            Button { RecentFolders.shared.remove(url) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .opacity(isHovering ? 1 : 0)
                .help("Remove from Recent")
        }
        .font(.callout)
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
    }
}
