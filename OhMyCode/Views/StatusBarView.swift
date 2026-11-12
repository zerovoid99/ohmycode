import SwiftUI

struct StatusBarView: View {
    let document: EditorDocument?
    var gitStatus: GitStatus?

    var body: some View {
        HStack(spacing: 16) {
            if let gitStatus {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(gitStatus.branch ?? "detached")
                    if gitStatus.ahead > 0 { Text("↑\(gitStatus.ahead)") }
                    if gitStatus.behind > 0 { Text("↓\(gitStatus.behind)") }
                    if gitStatus.changedFileCount > 0 {
                        Text("•\(gitStatus.changedFileCount)")
                            .help("\(gitStatus.changedFileCount) changed files")
                    }
                }
            }
            if document?.hasExternalChanges == true {
                Label("Changed on disk, your unsaved edits were kept", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let document, !document.diagnostics.isEmpty {
                let errors = document.diagnostics.filter { $0.severity == .error }.count
                let warnings = document.diagnostics.count - errors
                HStack(spacing: 8) {
                    Label("\(errors)", systemImage: "xmark.circle.fill")
                        .foregroundStyle(errors > 0 ? .red : .secondary)
                    Label("\(warnings)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(warnings > 0 ? .yellow : .secondary)
                }
                if let diagnostic = document.diagnosticAtCursor {
                    Text(diagnostic.message)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(diagnostic.message)
                }
            }
            Spacer()
            if let client = document?.languageClient {
                LanguageServerBadge(client: client)
            }
            if let document {
                Text("Ln \(document.cursorLine), Col \(document.cursorColumn)")
                Text("\(document.lineCount) lines")
                Text("UTF-8")
                Text(document.language.displayName)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(.bar)
    }
}

private struct LanguageServerBadge: View {
    let client: LanguageClient

    var body: some View {
        switch client.state {
        case .starting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(client.name)
            }
        case .ready:
            Label(client.name, systemImage: "bolt.fill")
        case .failed(let message):
            Label(client.name, systemImage: "bolt.slash.fill")
                .foregroundStyle(.orange)
                .help(message)
        case .stopped:
            EmptyView()
        }
    }
}
