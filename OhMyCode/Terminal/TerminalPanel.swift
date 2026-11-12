import AppKit
import SwiftUI

/// Bottom panel hosting the workspace's terminal, like VS Code's integrated terminal.
struct TerminalPanel: View {
    let workspace: Workspace
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !session.isRunning {
                    Text("exited").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    workspace.restartTerminal()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Restart Terminal")
                Button {
                    workspace.toggleTerminal()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Hide Terminal (⌃`)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.bar)

            Divider()

            TerminalViewRepresentable(session: session, focusRequest: workspace.terminalFocusRequest)
        }
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
