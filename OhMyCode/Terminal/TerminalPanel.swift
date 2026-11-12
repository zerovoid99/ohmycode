import AppKit
import SwiftUI

/// Bottom panel hosting the workspace's terminal, like VS Code's integrated terminal.
struct TerminalPanel: View {
    let workspace: Workspace
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(workspace.terminals) { terminal in
                            TerminalTab(session: terminal, isActive: terminal.id == session.id,
                                        onSelect: { workspace.selectTerminal(terminal) },
                                        onClose: { workspace.closeTerminal(terminal) })
                        }
                    }
                    .padding(.horizontal, 6)
                }
                Spacer(minLength: 8)
                Group {
                    Button { workspace.newTerminal() } label: { Image(systemName: "plus") }
                        .help("New Terminal (⌃⇧`)")
                    Button { workspace.restartTerminal() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Restart Terminal")
                    Button { workspace.toggleTerminal() } label: { Image(systemName: "chevron.down") }
                        .help("Hide Terminal (⌃`)")
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 8)
            }
            .frame(height: 30)
            .background(.bar)

            Divider()

            TerminalViewRepresentable(session: session, focusRequest: workspace.terminalFocusRequest)
        }
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(session.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
                .foregroundStyle(isActive ? .primary : .secondary)
            if !session.isRunning {
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
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

private struct TerminalViewRepresentable: NSViewRepresentable {
    let session: TerminalSession
    let focusRequest: Int

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
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
}
