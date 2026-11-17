import SwiftUI

/// What an editor group shows with no file open: the folder, ways to get going (with their
/// shortcuts, to learn them), and the files opened lately.
struct StartPageView: View {
    let workspace: Workspace

    private struct Action: Identifiable {
        let title: String
        let symbol: String
        let command: String?
        let perform: @MainActor (Workspace) -> Void
        var id: String { title }
    }

    private var actions: [Action] {
        var actions = [
            Action(title: "Go to File…", symbol: "doc.text.magnifyingglass", command: "go.quickOpen") { $0.showPalette(.files) },
            Action(title: "Command Palette…", symbol: "command", command: "view.commandPalette") { $0.showPalette(.commands) },
            Action(title: "Find in Files", symbol: "magnifyingglass", command: "view.search") { $0.showSearch() },
            Action(title: "New File…", symbol: "doc.badge.plus", command: nil) { $0.promptNewFile(in: nil) },
            Action(title: "Terminal", symbol: "terminal", command: "view.toggleTerminal") { $0.toggleTerminal() },
            Action(title: "Ask the Agent", symbol: "sparkles", command: "view.agent") { $0.sidebarMode = .agent },
        ]
        if workspace.rootNode == nil { actions.removeAll() }
        actions.append(Action(title: "Open Folder…", symbol: "folder", command: "file.openFolder") { $0.presentOpenPanel() })
        return actions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                section("Start") {
                    ForEach(actions) { action in
                        StartRow(symbol: action.symbol, title: action.title,
                                 detail: action.command.flatMap { Keybindings.shared.display(for: $0) }) { action.perform(workspace) }
                    }
                }
                let recent = workspace.recentFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(8)
                if !recent.isEmpty {
                    section("Recent") {
                        ForEach(Array(recent), id: \.self) { url in
                            StartRow(fileName: url.lastPathComponent,
                                     detail: workspace.relativePath(of: url.deletingLastPathComponent()).flatMap { $0.isEmpty ? nil : $0 }) {
                                workspace.open(fileAt: url)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIconImage(size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.rootURL?.lastPathComponent ?? "Oh My Code").font(.title2.weight(.semibold))
                if let branch = workspace.gitStatus?.branch {
                    Label(branch, systemImage: "arrow.triangle.branch").font(.callout).foregroundStyle(.secondary)
                } else if let root = workspace.rootURL {
                    Text((root.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold)).tracking(0.4)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.bottom, 4)
            content()
        }
    }
}

private struct StartRow: View {
    var symbol: String?
    var fileName: String?
    let title: String
    let detail: String?
    let action: () -> Void
    @State private var isHovering = false

    init(symbol: String, title: String, detail: String?, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.action = action
    }

    init(fileName: String, detail: String?, action: @escaping () -> Void) {
        self.fileName = fileName
        title = fileName
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let fileName { FileIcon(name: fileName) } else if let symbol { Image(systemName: symbol).foregroundStyle(.tint) }
                }
                .frame(width: 18)
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                if let detail {
                    Text(detail)
                        .font(fileName == nil ? .callout.monospaced() : .callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
