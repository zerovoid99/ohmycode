import AppKit
import SwiftUI

/// The Timeline sidebar panel: the commits that changed the active file, newest first.
/// Clicking one shows what it changed; the context menu compares it with the current text.
struct TimelineView: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = workspace.activeFileURL ?? workspace.fileHistory?.url {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text(url.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if workspace.fileHistory?.isLoading == true { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
                content(for: url)
            } else {
                ContentUnavailableView("No File", systemImage: "clock.arrow.circlepath",
                                       description: Text("Open a file to see the commits that changed it."))
            }
        }
        // Follow the active file.
        .task(id: workspace.activeFileURL) {
            if let url = workspace.activeFileURL, url != workspace.fileHistory?.url { workspace.loadHistory(for: url) }
        }
    }

    @ViewBuilder
    private func content(for url: URL) -> some View {
        if let history = workspace.fileHistory, history.url == url, let commits = history.commits {
            if commits.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock",
                                       description: Text("This file hasn't been committed yet."))
            } else {
                List(commits) { commit in
                    CommitRow(commit: commit)
                        .contentShape(Rectangle())
                        .onTapGesture { workspace.openCommit(commit, for: url) }
                        .contextMenu {
                            Button("Open Changes") { workspace.openCommit(commit, for: url) }
                            Button("Compare with Current") { workspace.compare(commit, with: url) }
                                .disabled(commit.path == nil)
                            Divider()
                            Button("Copy Commit Hash") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(commit.sha, forType: .string)
                            }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        } else if workspace.fileHistory?.isLoading == true || workspace.fileHistory?.url != url {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Not in Git", systemImage: "questionmark.folder",
                                   description: Text("This file isn't in a git repository."))
        }
    }
}

private struct CommitRow: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(commit.summary).lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge.letter)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(badge.color)
                        .help(badge.help)
                }
            }
            HStack(spacing: 4) {
                Text(commit.author)
                Text("·")
                Text(commit.date, format: .relative(presentation: .named))
                Spacer(minLength: 4)
                Text(commit.shortSHA).monospaced()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
        .help("\(commit.summary)\n\(commit.author) — \(commit.date.formatted(date: .abbreviated, time: .shortened))\n\(commit.sha)")
    }

    private var badge: (letter: String, color: Color, help: String)? {
        switch commit.change {
        case .modified: nil
        case .added: ("A", .green, "Added in this commit")
        case .deleted: ("D", .red, "Deleted in this commit")
        case .renamed: ("R", .orange, "Renamed from \(commit.parentPath ?? "")")
        }
    }
}
