import SwiftUI

/// A window with no folder open: the app, how to open one, and the folders opened lately.
struct WelcomeView: View {
    let workspace: Workspace

    var body: some View {
        let recent = Array(RecentFolders.shared.existing.prefix(10))
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                    Text("Oh My Code").font(.largeTitle.weight(.semibold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    WelcomeRow(symbol: "folder", title: "Open Folder…", detail: "⌘O") { workspace.presentOpenPanel() }
                    WelcomeRow(symbol: "gearshape", title: "Settings…", detail: "⌘,") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
                Text("Or drop a folder on this window.").font(.caption).foregroundStyle(.tertiary).padding(.leading, 8)
            }
            .frame(width: 260, alignment: .leading)
            .padding(32)

            Divider().padding(.vertical, 24)

            VStack(alignment: .leading, spacing: 4) {
                Text("RECENT")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.bottom, 4)
                if recent.isEmpty {
                    Text("Folders you open show up here.").font(.callout).foregroundStyle(.tertiary).padding(.leading, 8)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(recent, id: \.self) { url in
                            RecentFolderRow(url: url) { OpenRouter.shared.apply(OpenRequest(url: url), in: workspace) }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(width: 340, alignment: .leading)
            .padding(.vertical, 32)
            .padding(.horizontal, 20)
        }
        .frame(maxHeight: 420)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct WelcomeRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
                Text(title)
                Spacer()
                Text(detail).font(.callout.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isHovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RecentFolderRow: View {
    let url: URL
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(Color(nsColor: .systemBlue).opacity(0.8)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).foregroundStyle(.primary).lineLimit(1)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
                Button { RecentFolders.shared.remove(url) } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
                    .help("Remove from Recent")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(isHovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(url.path)
    }
}
