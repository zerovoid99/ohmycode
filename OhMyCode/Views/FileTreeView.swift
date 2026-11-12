import SwiftUI

struct FileTreeView: View {
    let root: FileNode
    let workspace: Workspace
    @State private var selection: URL?

    var body: some View {
        List(root.children ?? [], children: \.children, selection: $selection) { node in
            FileRow(node: node, status: workspace.gitStatus(for: node.url, isDirectory: node.isDirectory))
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, url in
            if let url, !url.hasDirectoryPath {
                workspace.open(fileAt: url)
            }
        }
        .onChange(of: workspace.activeDocument?.url) { _, url in
            if let url { selection = url }
        }
    }
}

private struct FileRow: View {
    let node: FileNode
    let status: GitFileStatus?

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(node.name)
                    .foregroundStyle(status.map { Color(nsColor: $0.color) } ?? .primary)
                    .strikethrough(status == .deleted)
            } icon: {
                Image(systemName: node.isDirectory ? "folder" : "doc.text")
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 4)
            if let status {
                if node.isDirectory {
                    Circle()
                        .fill(Color(nsColor: status.color))
                        .frame(width: 6, height: 6)
                } else {
                    Text(status.letter)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(Color(nsColor: status.color))
                }
            }
        }
        .help(status.map { "\(node.name): \($0.label)" } ?? node.name)
    }
}
