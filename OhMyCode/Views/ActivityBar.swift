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
        Item(mode: .database, symbol: "cylinder.split.1x2", command: nil),
        Item(mode: .extensions, symbol: "puzzlepiece.extension", command: nil),
    ]

    private var visibleItems: [Item] {
        var items = Self.items
        if workspace.references != nil { items.append(Item(mode: .references, symbol: "link", command: nil)) }
        if workspace.callHierarchy != nil { items.append(Item(mode: .callHierarchy, symbol: "phone.arrow.down.left", command: nil)) }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(visibleItems) { item in
                        ActivityButton(symbol: item.symbol, help: help(for: item), isSelected: workspace.sidebarMode == item.mode,
                                       badge: badge(for: item.mode)) {
                            workspace.sidebarMode = item.mode
                        }
                        .disabled(workspace.rootNode == nil && item.mode != .files && item.mode != .extensions && item.mode != .database)
                    }
                }
                .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
            SettingsLink {
                ActivityIcon(symbol: "gearshape", isSelected: false, badge: nil)
            }
            .buttonStyle(.plain)
            .frame(width: ActivityBar.width)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .padding(.bottom, 8)
        }
        .frame(width: Self.width)
    }

    static let width: CGFloat = 44

    private func help(for item: Item) -> String {
        let shortcut = item.command.flatMap { Keybindings.shared.display(for: $0) }
        let name = item.mode == .files ? "Explorer" : item.mode.rawValue
        return shortcut.map { "\(name) (\($0))" } ?? name
    }

    private func badge(for mode: Workspace.SidebarMode) -> ActivityBadge? {
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

/// What an icon of the activity bar says about its panel.
enum ActivityBadge: Equatable {
    /// How many (changed files).
    case count(Int)
    /// Waiting for an answer (an agent asking for permission).
    case attention
    /// Running (an agent at work, a debug session).
    case busy

    var accessibilityValue: String {
        switch self {
        case .count(let count): "\(count)"
        case .attention: "Needs attention"
        case .busy: "Running"
        }
    }
}

private struct ActivityButton: View {
    let symbol: String
    let help: String
    let isSelected: Bool
    let badge: ActivityBadge?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActivityIcon(symbol: symbol, isSelected: isSelected, badge: badge)
        }
        .buttonStyle(.plain)
        .frame(width: ActivityBar.width)
        .overlay(alignment: .leading) {
            // The active panel's mark, against the window edge.
            if isSelected {
                UnevenRoundedRectangle(bottomTrailingRadius: 1.5, topTrailingRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: 18)
            }
        }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(badge?.accessibilityValue ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// An icon of the activity bar: highlighted when selected or under the mouse, with its badge
/// in the top corner. The badge cuts a ring out of the icon behind it, so it reads apart from
/// the icon on any sidebar background (the sidebar is translucent).
private struct ActivityIcon: View {
    let symbol: String
    let isSelected: Bool
    let badge: ActivityBadge?
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private static let size = CGSize(width: 34, height: 32)
    /// The ring cut around a badge.
    private static let ring: CGFloat = 2

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.1 : isHovering && isEnabled ? 0.06 : 0))
            Image(systemName: symbol)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : isHovering && isEnabled ? Color.primary.opacity(0.85) : Color.secondary)
                .frame(width: 22, height: 22)
            if let badge {
                badgeShape(badge, inset: -Self.ring)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay(alignment: .topTrailing) {
            if let badge { badgeShape(badge, inset: 0) }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: badge)
    }

    /// The badge, or (with a negative inset) the shape a little bigger than it that's cut out
    /// of the icon, both placed in the top trailing corner.
    @ViewBuilder private func badgeShape(_ badge: ActivityBadge, inset: CGFloat) -> some View {
        let grow = -inset * 2
        Group {
            switch badge {
            case .count(let count):
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Capsule().fill(Color.accentColor))
                    .padding(-inset)
                    .background(inset < 0 ? Capsule().fill(Color.black) : nil)
                    .offset(x: 1 - inset, y: -1 + inset)
            case .attention:
                Circle().fill(inset < 0 ? Color.black : Color.orange)
                    .frame(width: 8 + grow, height: 8 + grow)
                    .offset(x: -4 - inset, y: 4 + inset)
            case .busy:
                Circle().fill(inset < 0 ? Color.black : Color.green)
                    .frame(width: 7 + grow, height: 7 + grow)
                    .offset(x: -4 - inset, y: 4 + inset)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topTrailing)
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
