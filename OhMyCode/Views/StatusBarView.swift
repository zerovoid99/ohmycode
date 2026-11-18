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
    /// Claude Code sessions connected to the window (shown when there are any).
    var claudeCodeSessions = 0
    /// The Agent sidebar's agent: working, or waiting for an answer (shown then).
    var agentActivity: AgentActivity?
    var showAgent: () -> Void = {}
    /// Go to Line (clicking the cursor's position).
    var goToLine: () -> Void = {}
    /// The Source Control sidebar (clicking the branch).
    var showSourceControl: () -> Void = {}
    /// A `.http` file's environment ("No Environment" when none is chosen); clicking switches it.
    var httpEnvironment: String?
    var switchHTTPEnvironment: () -> Void = {}
    /// A SQL file's connection ("No Connection" when none is chosen); clicking switches it.
    var sqlConnection: String?
    var chooseSQLConnection: () -> Void = {}

    enum AgentActivity { case working, waiting }

    var body: some View {
        HStack(spacing: 16) {
            if let gitStatus {
                Button(action: showSourceControl) {
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
                .buttonStyle(StatusBarButtonStyle())
                .help("Source Control")
            }
            if let vimStatus = document?.vimStatus {
                Text(vimStatus)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.primary)
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
                .buttonStyle(StatusBarButtonStyle())
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
            if claudeCodeSessions > 0 {
                Label(claudeCodeSessions > 1 ? "Claude Code ×\(claudeCodeSessions)" : "Claude Code", systemImage: "link")
                    .foregroundStyle(.secondary)
                    .help("Claude Code is connected: it sees the open files and the selection, and its edits open as diffs here. ⌥⌘K sends the selected lines to it.")
            }
            if let task = tasks.last {
                Button(action: showTasks) {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(tasks.count > 1 ? "\(task.task.label) +\(tasks.count - 1)" : task.task.label)
                    }
                }
                .buttonStyle(StatusBarButtonStyle())
                .help("Show the running tasks")
            }
            if let agentActivity {
                Button(action: showAgent) {
                    HStack(spacing: 4) {
                        if agentActivity == .working {
                            ProgressView().controlSize(.mini)
                            Text("Agent working")
                        } else {
                            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                            Text("Agent needs you")
                        }
                    }
                }
                .buttonStyle(StatusBarButtonStyle())
                .help("Show the Agent sidebar")
            }
            ForEach(items.filter(\.isLeft)) { ExtensionStatusItemView(item: $0, run: run) }
            Spacer()
            ForEach(items.filter { !$0.isLeft }) { ExtensionStatusItemView(item: $0, run: run) }
            if let httpEnvironment {
                Button(action: switchHTTPEnvironment) {
                    Label(httpEnvironment, systemImage: "globe")
                }
                .buttonStyle(StatusBarButtonStyle())
                .help("Environment for this folder's requests (REST: Switch Environment)")
            }
            if let sqlConnection {
                Button(action: chooseSQLConnection) {
                    Label(sqlConnection, systemImage: "cylinder")
                }
                .buttonStyle(StatusBarButtonStyle())
                .help("Connection this file's SQL runs on (⌘↩ runs the statement at the cursor, ⇧⌘↩ the selection or file)")
            }
            AIStatusItem()
            if let client = document?.languageClient {
                LanguageServerBadge(client: client)
            }
            if let document {
                Button(action: goToLine) {
                    Text("Ln \(document.cursorLine), Col \(document.cursorColumn)")
                }
                .buttonStyle(StatusBarButtonStyle())
                .help(Keybindings.shared.display(for: "go.line").map { "Go to Line… (\($0))" } ?? "Go to Line…")
                Text("\(document.lineCount) lines")
                IndentationBadge(document: document)
                Text("UTF-8")
                Text(document.language.displayName)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .themedBackground(.statusBar, fallback: .bar)
    }
}

/// A status bar item that does something: highlighted under the pointer.
struct StatusBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : isHovering ? 0.08 : 0)))
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}

/// AI inline suggestions: on or off (click to switch), working, or the last error.
private struct AIStatusItem: View {
    private let settings = AISettings.shared

    var body: some View {
        if settings.inlineSuggestionsEnabled || settings.isConfigured {
            Button { settings.inlineSuggestionsEnabled.toggle() } label: {
                HStack(spacing: 4) {
                    if settings.requestsInFlight > 0 {
                        ProgressView().controlSize(.mini)
                    } else if settings.lastError != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Image(systemName: "sparkles")
                            .opacity(settings.inlineSuggestionsEnabled ? 1 : 0.45)
                    }
                    Text("AI").opacity(settings.inlineSuggestionsEnabled ? 1 : 0.45)
                }
            }
            .buttonStyle(StatusBarButtonStyle())
            .help(help)
        }
    }

    private var help: String {
        var lines = [settings.inlineSuggestionsEnabled
            ? "Inline suggestions are on (\(settings.provider.title)). Click to turn them off."
            : "Inline suggestions are off. Click to turn them on."]
        if let problem = settings.configurationProblem { lines.append(problem) }
        if let error = settings.lastError { lines.append("Last error: \(error)") }
        return lines.joined(separator: "\n")
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

/// "Spaces: 4" or "Tab Size: 4", and the line endings; from .editorconfig when it sets them.
private struct IndentationBadge: View {
    let document: EditorDocument

    var body: some View {
        // Read again when lines come or go (not on every keystroke: it reads the text).
        _ = document.lineCount
        let (size, spaces) = document.indentation
        let config = document.editorConfig
        let source = config.sources.first.map { "set by \($0.path)" }
        return HStack(spacing: 16) {
            Text(spaces ? "Spaces: \(size)" : "Tab Size: \(size)")
                .help("Indentation " + (config.indentStyle != nil || config.indentSize != nil ? source ?? "" : "judged from the file"))
            Text((config.endOfLine ?? document.lineEnding).rawValue.uppercased())
                .help(config.endOfLine != nil ? "Line endings " + (source ?? "") : "The file's line endings")
        }
    }
}
