import SwiftUI

struct StatusBarView: View {
    let document: EditorDocument?
    var gitStatus: GitStatus?
    /// The folder's problems (counted in the bar; clicking shows the Problems panel).
    var problems: ProblemStore?
    var showProblems: () -> Void = {}
    /// Running tasks (shown with a spinner; clicking shows the Tasks panel).
    var tasks: [TaskRun] = []
    var showTasks: () -> Void = {}
    /// Extensions' items: left ones after the branch, right ones before the cursor position.
    var items: [ExtensionStatusItem] = []
    var run: (String) -> Void = { _ in }

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
            if let problems {
                let errors = problems.errorCount
                let warnings = problems.warningCount
                Button(action: showProblems) {
                    HStack(spacing: 8) {
                        Label("\(errors)", systemImage: "xmark.circle.fill")
                            .foregroundStyle(errors > 0 ? .red : .secondary)
                        Label("\(warnings)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(warnings > 0 ? .yellow : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Problems (⇧⌘M)")
            }
            if let document, !document.diagnostics.isEmpty {
                if let diagnostic = document.diagnosticAtCursor {
                    Text(diagnostic.message)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(diagnostic.message)
                }
            }
            if let task = tasks.last {
                Button(action: showTasks) {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(tasks.count > 1 ? "\(task.task.label) +\(tasks.count - 1)" : task.task.label)
                    }
                }
                .buttonStyle(.plain)
                .help("Show the running tasks")
            }
            ForEach(items.filter(\.isLeft)) { ExtensionStatusItemView(item: $0, run: run) }
            Spacer()
            ForEach(items.filter { !$0.isLeft }) { ExtensionStatusItemView(item: $0, run: run) }
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
        .themedBackground(.statusBar, fallback: .bar)
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
