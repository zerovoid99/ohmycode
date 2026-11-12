import SwiftUI

struct FileTreeView: View {
    let root: FileNode
    let workspace: Workspace
    @State private var selection: URL?

    var body: some View {
        List(root.children ?? [], children: \.children, selection: $selection) { node in
            Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                .lineLimit(1)
                .truncationMode(.middle)
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
