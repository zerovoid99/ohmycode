import AppKit
import SwiftUI

/// "Problems | Terminal | Debug Console" at the top of the bottom panel.
struct BottomPanelSwitcher: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 2) {
            tab("Problems", .problems, badge: workspace.problems.totalCount) { workspace.showProblems() }
            tab("Tasks", .tasks) { workspace.showTasks() }
            tab("Terminal", .terminal) { workspace.showTerminal() }
            tab("Debug Console", .debugConsole) { workspace.showDebugConsole() }
        }
    }

    private func tab(_ title: String, _ panel: Workspace.BottomPanel, badge: Int = 0,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                if badge > 0 {
                    Text("\(badge)")
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .background(Color.secondary.opacity(0.25), in: Capsule())
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(workspace.bottomPanel == panel ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(workspace.bottomPanel == panel ? Color.secondary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

/// Every error and warning in the folder, by file; clicking one opens it there.
struct ProblemsView: View {
    let workspace: Workspace
    @State private var filter = ""
    @State private var errorsAndWarningsOnly = false
    @State private var collapsed: Set<String> = []

    var body: some View {
        let files = workspace.problems.files(filter: filter, minimum: errorsAndWarningsOnly ? .warning : .hint)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                BottomPanelSwitcher(workspace: workspace)
                Spacer()
                TextField("Filter", text: $filter, prompt: Text("Filter (text, source or file)"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                Toggle(isOn: $errorsAndWarningsOnly) { Image(systemName: "exclamationmark.triangle") }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Show only errors and warnings")
                Button {
                    collapsed = collapsed.isEmpty ? Set(files.map(\.id)) : []
                } label: { Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical") }
                    .help(collapsed.isEmpty ? "Collapse all" : "Expand all")
                Button { workspace.hidePanel() } label: { Image(systemName: "chevron.down") }
                    .help("Hide the panel")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .themedBackground(.panel, fallback: .bar)
            Divider()
            if files.isEmpty {
                Text(workspace.problems.totalCount == 0 ? "No problems have been detected in the workspace."
                     : "No problems match the filter.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(files) { file in
                        fileRow(file)
                        if !collapsed.contains(file.id) {
                            ForEach(Array(file.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                                ProblemRow(diagnostic: diagnostic)
                                    .padding(.leading, 18)
                                    .contentShape(Rectangle())
                                    .onTapGesture { workspace.open(problem: diagnostic, in: file.url) }
                                    .contextMenu {
                                        Button("Copy") { copy(diagnostic, in: file) }
                                        Button("Copy Message") { copy(diagnostic.message) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
    }

    private func fileRow(_ file: ProblemStore.File) -> some View {
        HStack(spacing: 4) {
            Image(systemName: collapsed.contains(file.id) ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(file.url.lastPathComponent).fontWeight(.medium)
            if let folder = folder(of: file.url) {
                Text(folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Text("\(file.diagnostics.count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 5)
                .background(Color.secondary.opacity(0.2), in: Capsule())
            Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed.contains(file.id) { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
        }
    }

    private func folder(of url: URL) -> String? {
        guard let relative = workspace.relativePath(of: url) else { return url.deletingLastPathComponent().path }
        let folder = (relative as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    private func copy(_ diagnostic: Diagnostic, in file: ProblemStore.File) {
        let path = workspace.relativePath(of: file.url) ?? file.url.path
        let severity = String(describing: diagnostic.severity)
        copy("\(path):\(diagnostic.range.start.line + 1):\(diagnostic.range.start.character + 1): \(severity): \(diagnostic.message)")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ProblemRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            ProblemIcon(severity: diagnostic.severity)
            Text(diagnostic.message.components(separatedBy: .newlines).first ?? "")
                .lineLimit(1)
                .help(diagnostic.message)
            if let source = diagnostic.source {
                Text(source).foregroundStyle(.secondary)
            }
            Text("[Ln \(diagnostic.range.start.line + 1), Col \(diagnostic.range.start.character + 1)]")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct ProblemIcon: View {
    let severity: Diagnostic.Severity

    var body: some View {
        switch severity {
        case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .information: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        case .hint: Image(systemName: "lightbulb").foregroundStyle(.secondary)
        }
    }
}
