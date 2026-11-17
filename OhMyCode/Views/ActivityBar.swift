import SwiftUI

/// The column of panel icons at the sidebar's left edge: one per panel, the active one marked,
/// with counts where they help (changed files, an agent waiting for an answer). Each icon's
/// tooltip names the panel and its shortcut.
struct ActivityBar: View {
    @Bindable var workspace: Workspace

    struct Item: Identifiable {
        let mode: Workspace.SidebarMode
        let symbol: String
        /// The command whose shortcut shows the panel (for the tooltip).
        let command: String?
        var id: Workspace.SidebarMode { mode }
    }

    static let items: [Item] = [
        Item(mode: .files, symbol: "doc.on.doc", command: "view.explorer"),
        Item(mode: .search, symbol: "magnifyingglass", command: "view.search"),
        Item(mode: .sourceControl, symbol: "arrow.triangle.branch", command: "view.sourceControl"),
        Item(mode: .agent, symbol: "sparkles", command: "view.agent"),
        Item(mode: .debug, symbol: "play.circle", command: "debug.show"),
        Item(mode: .testing, symbol: "checkmark.diamond", command: nil),
        Item(mode: .outline, symbol: "list.bullet.indent", command: "view.outline"),
        Item(mode: .history, symbol: "clock.arrow.circlepath", command: nil),
        Item(mode: .pullRequests, symbol: "arrow.triangle.pull", command: nil),
        Item(mode: .extensions, symbol: "puzzlepiece.extension", command: nil),
    ]

    private var visibleItems: [Item] {
        var items = Self.items
        if workspace.references != nil { items.append(Item(mode: .references, symbol: "link", command: nil)) }
        if workspace.callHierarchy != nil { items.append(Item(mode: .callHierarchy, symbol: "phone.arrow.down.left", command: nil)) }
        return items
    }

    var body: some View {
        VStack(spacing: 2) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(visibleItems) { item in
                        ActivityButton(symbol: item.symbol, help: help(for: item), isSelected: workspace.sidebarMode == item.mode,
                                       badge: badge(for: item.mode)) {
                            workspace.sidebarMode = item.mode
                        }
                        .disabled(workspace.rootNode == nil && item.mode != .files && item.mode != .extensions)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 4)
            }
            Spacer(minLength: 0)
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings (⌘,)")
            .padding(.bottom, 6)
        }
        .frame(width: 44)
    }

    private func help(for item: Item) -> String {
        let shortcut = item.command.flatMap { Keybindings.shared.display(for: $0) }
        let name = item.mode == .files ? "Explorer" : item.mode.rawValue
        return shortcut.map { "\(name) (\($0))" } ?? name
    }

    private func badge(for mode: Workspace.SidebarMode) -> ActivityButton.Badge? {
        switch mode {
        case .sourceControl:
            let count = workspace.gitStatus?.changedFileCount ?? 0
            return count > 0 ? .count(count) : nil
        case .agent:
            guard let client = workspace.agentPanel.client else { return nil }
            if !client.permissions.isEmpty { return .attention }
            return client.state == .working ? .busy : nil
        case .debug:
            return workspace.debugSession == nil ? nil : .busy
        default:
            return nil
        }
    }
}

private struct ActivityButton: View {
    enum Badge: Equatable { case count(Int), attention, busy }

    let symbol: String
    let help: String
    let isSelected: Bool
    let badge: Badge?
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 34, height: 32)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(isSelected ? 0.1 : isHovering && isEnabled ? 0.06 : 0))
                }
                .overlay(alignment: .topTrailing) { badgeView }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            // The active panel's mark, against the window edge.
            if isSelected {
                Capsule().fill(Color.accentColor).frame(width: 3, height: 16).offset(x: -1)
            }
        }
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .opacity(isEnabled ? 1 : 0.4)
    }

    @ViewBuilder private var badgeView: some View {
        switch badge {
        case .count(let count):
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 3.5)
                .frame(minWidth: 14, minHeight: 14)
                .background(Capsule().fill(Color.accentColor))
                .offset(x: 3, y: -1)
        case .attention:
            Circle().fill(.orange).frame(width: 8, height: 8).offset(x: 1, y: 3)
        case .busy:
            Circle().fill(.green).frame(width: 7, height: 7).offset(x: 1, y: 3)
        case nil:
            EmptyView()
        }
    }
}

/// The name of the panel the sidebar shows, with the panel's own actions beside it.
struct SidebarPanelHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            actions
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 30)
    }
}
