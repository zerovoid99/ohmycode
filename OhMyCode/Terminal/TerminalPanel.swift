import AppKit
import SwiftUI

/// Bottom panel hosting the workspace's terminal, like VS Code's integrated terminal.
struct TerminalPanel: View {
    let workspace: Workspace
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BottomPanelSwitcher(workspace: workspace).padding(.leading, 8)
                Divider().frame(height: 16).padding(.horizontal, 6)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        // One tab per group of split terminals.
                        ForEach(Array(workspace.terminalGroups.indices), id: \.self) { index in
                            let members = workspace.terminalGroup(at: index)
                            if let first = members.first {
                                let active = members.first { $0.id == session.id }
                                TerminalTab(sessions: members, isActive: active != nil,
                                            onSelect: { workspace.selectTerminal(active ?? first) },
                                            onClose: { members.forEach { workspace.closeTerminal($0) } },
                                            onRename: { workspace.renameTerminal(active ?? first) },
                                            onSplit: { workspace.selectTerminal(active ?? first); workspace.splitTerminal() })
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                Spacer(minLength: 8)
                Group {
                    Button { workspace.newTerminal() } label: { Image(systemName: "plus") }
                        .help("New Terminal (⌃⇧`)")
                    Button { workspace.splitTerminal() } label: { Image(systemName: "square.split.2x1") }
                        .help("Split Terminal")
                    Button { workspace.restartTerminal() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Restart Terminal")
                    Button { workspace.toggleTerminal() } label: { Image(systemName: "chevron.down") }
                        .help("Hide Terminal (⌃`)")
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 8)
            }
            .frame(height: 30)
            .themedBackground(.panel, fallback: .bar)

            Divider()

            let group = workspace.activeTerminalGroup
            if group.count > 1 {
                HSplitView {
                    ForEach(group) { member in
                        TerminalViewRepresentable(session: member, focusRequest: member.id == session.id ? workspace.terminalFocusRequest : -1,
                                                  onFocus: { if workspace.activeTerminalID != member.id { workspace.activeTerminalID = member.id } },
                                                  onOpenLink: { workspace.openTerminalLink($0) })
                            .frame(minWidth: 120, maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .top) {
                                // Which pane typing goes to.
                                if member.id == session.id { Color.accentColor.opacity(0.7).frame(height: 1) }
                            }
                    }
                }
            } else {
                TerminalViewRepresentable(session: session, focusRequest: workspace.terminalFocusRequest, onFocus: {},
                                          onOpenLink: { workspace.openTerminalLink($0) })
            }
        }
    }
}

private struct TerminalTab: View {
    let sessions: [TerminalSession]
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onSplit: () -> Void
    @State private var isHovering = false

    private var session: TerminalSession { sessions[0] }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: sessions.count > 1 ? "square.split.2x1" : "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(sessions.map(\.displayTitle).joined(separator: " | "))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
                .foregroundStyle(isActive ? .primary : .secondary)
            if !sessions.contains(where: \.isRunning) {
                Text("exited").font(.caption2).foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(isActive || isHovering ? 1 : 0)
            .help("Kill Terminal")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isActive ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onRename)
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Split Terminal", action: onSplit)
            Divider()
            Button(sessions.count > 1 ? "Kill Terminals" : "Kill Terminal", action: onClose)
        }
    }
}

private struct TerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let focusRequest: Int
    let onFocus: () -> Void
    var onOpenLink: (TerminalLink) -> Void = { _ in }

    final class Coordinator {
        var lastFocusRequest = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.session = session
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        view.session = session
        view.onFocus = onFocus
        view.onOpenLink = onOpenLink
        if focusRequest >= 0, context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}
