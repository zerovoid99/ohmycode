import SwiftUI

/// A folder comparison tab: the two folders, counts per status, a filter, and the files that
/// differ. Clicking a file in both folders opens its diff; double-clicking one in only one
/// folder opens it.
struct FolderComparisonView: View {
    let session: FolderComparisonSession
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .editorBackground()
    }

    private var header: some View {
        HStack(spacing: 8) {
            folderLabel(session.left)
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            folderLabel(session.right)
            Spacer(minLength: 8)
            if session.isRunning {
                ProgressView().controlSize(.small)
                if session.progress.total > 0 {
                    Text("\(session.progress.done) of \(session.progress.total)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Button { session.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .themedBackground(.tabBar, fallback: .bar)
    }

    private func folderLabel(_ url: URL) -> some View {
        Label(url.lastPathComponent, systemImage: "folder")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .help(url.path)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            ForEach(FolderCompareStatus.allCases, id: \.self) { status in
                HStack(spacing: 4) {
                    Self.icon(status)
                    Text("\(status.title) \(session.count(status))")
                }
                .font(.caption.monospacedDigit())
            }
            Toggle("Show Same", isOn: Binding(get: { session.showsSame }, set: { session.showsSame = $0 }))
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer(minLength: 8)
            TextField("Filter", text: Binding(get: { session.filter }, set: { session.filter = $0 }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder private var content: some View {
        let entries = session.visibleEntries
        if entries.isEmpty {
            if session.isRunning {
                ProgressView("Comparing…")
            } else {
                ContentUnavailableView(session.entries.isEmpty ? "No Files" : "No Differences", systemImage: "checkmark.circle",
                                       description: Text(session.entries.isEmpty ? "Neither folder has files to compare."
                                                         : session.filter.isEmpty ? "The folders have the same files with the same content."
                                                         : "No listed file matches the filter."))
            }
        } else {
            List(entries) { entry in
                row(entry)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ entry: FolderCompareEntry) -> some View {
        let name = (entry.path as NSString).lastPathComponent
        let folder = (entry.path as NSString).deletingLastPathComponent
        let row = HStack(spacing: 6) {
            Self.icon(entry.status)
            Text(name)
            if !folder.isEmpty { Text(folder).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            Text(entry.status.title).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        .help(help(entry))
        return Group {
            switch entry.status {
            case .different, .same:
                row.onTapGesture {
                    workspace.compareFiles(session.url(entry, onLeft: true), session.url(entry, onLeft: false))
                }
            case .onlyLeft, .onlyRight:
                row.onTapGesture(count: 2) {
                    workspace.open(fileAt: session.url(entry, onLeft: entry.status == .onlyLeft))
                }
            }
        }
    }

    private func help(_ entry: FolderCompareEntry) -> String {
        switch entry.status {
        case .different: "Click to compare the two versions"
        case .same: "Click to compare (the content is the same)"
        case .onlyLeft: "Only in \(session.left.path) — double-click to open"
        case .onlyRight: "Only in \(session.right.path) — double-click to open"
        }
    }

    @ViewBuilder static func icon(_ status: FolderCompareStatus) -> some View {
        switch status {
        case .onlyLeft: Image(systemName: "arrow.left.square.fill").foregroundStyle(.red)
        case .onlyRight: Image(systemName: "arrow.right.square.fill").foregroundStyle(.green)
        case .different: Image(systemName: "plusminus.circle.fill").foregroundStyle(.orange)
        case .same: Image(systemName: "equal.circle").foregroundStyle(.secondary)
        }
    }
}

/// The Explorer's compare items: Select for Compare, then Compare with Selected on another file
/// (or folder).
struct ExplorerCompareMenu: View {
    let workspace: Workspace
    let target: URL

    var body: some View {
        Button("Select for Compare") { workspace.comparisons.selected = target }
        if let selected = workspace.comparisons.selected, workspace.canCompareWithSelected(target) {
            Button("Compare with Selected (\(selected.lastPathComponent))") { workspace.compareWithSelected(target) }
        }
    }
}
