import SwiftUI

/// The Testing sidebar: the folder's tests by file, with their last results.
struct TestingView: View {
    let workspace: Workspace
    @State private var filter = ""
    @State private var failedOnly = false
    @State private var expanded: Set<String> = []
    @State private var selection: String?

    private var testing: TestController { workspace.testing }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                let counts = testing.counts
                if testing.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundStyle(.secondary)
                } else if counts.total > 0 {
                    Label("\(counts.passed)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Label("\(counts.failed)", systemImage: "xmark.circle.fill").foregroundStyle(counts.failed > 0 ? .red : .secondary)
                    Text("of \(counts.total)").foregroundStyle(.secondary)
                }
                Spacer()
                Group {
                    if testing.isRunning {
                        Button { testing.cancel() } label: { Image(systemName: "stop.fill") }.help("Stop")
                    } else {
                        Button { workspace.runAllTests() } label: { Image(systemName: "play.fill") }.help("Run All Tests (⌘U)")
                        Button { testing.runFailed() } label: { Image(systemName: "arrow.counterclockwise") }
                            .help("Run Failed Tests").disabled(counts.failed == 0)
                    }
                    Button { Task { await testing.discover() } } label: { Image(systemName: "arrow.clockwise") }.help("Find Tests Again")
                    Button { workspace.showTestOutput() } label: { Image(systemName: "text.alignleft") }
                        .help("Show Output").disabled(testing.runs.isEmpty)
                }
                .buttonStyle(.borderless)
            }
            .font(.callout)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            HStack {
                TextField("Filter", text: $filter, prompt: Text("Filter tests"))
                    .textFieldStyle(.roundedBorder)
                Toggle(isOn: $failedOnly) { Image(systemName: "xmark.circle") }
                    .toggleStyle(.button)
                    .help("Show only failed tests")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Divider()
            if testing.files.isEmpty {
                VStack(spacing: 8) {
                    if testing.isDiscovering { ProgressView().controlSize(.small) }
                    Text(testing.isDiscovering ? "Looking for tests…" : "No tests found.")
                        .foregroundStyle(.secondary)
                    Text("Swift (XCTest, Swift Testing), Go, Python, Jest, Vitest and Rust tests are listed here.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(visibleFiles) { file in row(file, depth: 0) }
                }
                .listStyle(.sidebar)
            }
        }
    }

    /// Files and their items that match the filter.
    private var visibleFiles: [TestItem] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        func keep(_ item: TestItem) -> TestItem? {
            if item.kind == .test {
                let matchesText = needle.isEmpty || item.label.lowercased().contains(needle) || item.id.lowercased().contains(needle)
                let matchesState = !failedOnly || testing.results[item.id]?.state == .failed
                return matchesText && matchesState ? item : nil
            }
            var copy = item
            copy.children = item.children.compactMap(keep)
            return copy.children.isEmpty ? nil : copy
        }
        return testing.tree.compactMap(keep)
    }

    private func isExpanded(_ item: TestItem) -> Bool {
        !filter.isEmpty || failedOnly || expanded.contains(item.id) || item.kind == .folder
            || item.kind == .file && testing.files.count <= 3
    }

    private func row(_ item: TestItem, depth: Int) -> AnyView {
        AnyView(Group {
            TestRow(item: item, state: testing.state(of: item), result: testing.results[item.id], depth: depth,
                    isExpanded: isExpanded(item),
                    toggle: { if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) } },
                    run: { testing.run([item]) })
                .tag(item.id)
                .contextMenu {
                    Button("Run") { testing.run([item]) }
                    if item.kind != .folder { Button("Go to Test") { workspace.open(test: item) } }
                    if item.kind == .test, let issue = testing.results[item.id]?.issues.first, let url = issue.url {
                        Button("Go to Failure") {
                            workspace.open(fileAt: workspace.workspaceURL(for: url))
                            if let line = issue.line { workspace.activeDocument?.revealLine(line + 1) }
                        }
                    }
                    Divider()
                    Button("Copy Test ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.name, forType: .string)
                    }
                }
                .onTapGesture(count: 2) { if item.kind != .folder { workspace.open(test: item) } }
            if item.kind == .test, let issues = testing.results[item.id]?.issues, testing.results[item.id]?.state == .failed {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Text(issue.message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .padding(.leading, CGFloat(depth + 1) * 14 + 22)
                        .onTapGesture {
                            guard let url = issue.url else { return }
                            workspace.open(fileAt: workspace.workspaceURL(for: url))
                            if let line = issue.line { workspace.activeDocument?.revealLine(line + 1) }
                        }
                }
            }
            if item.kind != .test, isExpanded(item) {
                ForEach(item.children) { child in row(child, depth: depth + 1) }
            }
        })
    }
}

private struct TestRow: View {
    let item: TestItem
    let state: TestController.State
    let result: TestController.Result?
    let depth: Int
    let isExpanded: Bool
    let toggle: () -> Void
    let run: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if item.kind == .test {
                Color.clear.frame(width: 10)
            } else {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggle)
            }
            TestStateIcon(state: state)
            if item.kind == .file { Image(systemName: "doc.text").foregroundStyle(.secondary) }
            if item.kind == .folder { Image(systemName: "folder").foregroundStyle(.secondary) }
            Text(item.label).lineLimit(1).truncationMode(.middle)
            if item.kind == .file {
                Text(item.framework.displayName).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if let duration = result?.duration, item.kind == .test {
                Text(duration < 1 ? "\(Int(duration * 1000)) ms" : String(format: "%.1f s", duration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(action: run) { Image(systemName: "play.fill").font(.system(size: 9)) }
                .buttonStyle(.borderless)
                .opacity(isHovering ? 1 : 0)
                .help("Run")
        }
        .padding(.leading, CGFloat(depth) * 14)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

struct TestStateIcon: View {
    let state: TestController.State

    var body: some View {
        switch state {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .running: ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .skipped: Image(systemName: "forward.circle").foregroundStyle(.secondary)
        case .notRun: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        case .unknown: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}
