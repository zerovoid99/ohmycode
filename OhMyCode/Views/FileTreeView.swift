import SwiftUI
import UniformTypeIdentifiers

struct FileTreeView: View {
    let workspace: Workspace
    @State private var selection: URL?

    /// One folder: its contents. Several: each folder is a top-level row.
    private var topLevel: [FileNode] {
        workspace.isMultiRoot ? workspace.rootNodes : workspace.rootNode?.children ?? []
    }

    var body: some View {
        let roots = Set(workspace.isMultiRoot ? workspace.rootNodes.map(\.url) : [])
        List(topLevel, children: \.children, selection: $selection) { node in
            Group {
                if roots.contains(node.url) {
                    FolderRootRow(name: workspace.label(of: node.url), url: node.url,
                                  branch: workspace.repositories.first { $0.folders.contains(node.url) }?.status.branch)
                } else {
                    FileRow(node: node, status: workspace.gitStatus(for: node.url, isDirectory: node.isDirectory),
                            submodule: node.isDirectory ? workspace.submodule(at: node.url) : nil)
                        .draggable(node.url)
                }
            }
            // Dropped on a folder: moved into it (also from another of the window's folders), or
            // copied from outside them (a file's row takes it to the file's folder).
            .dropDestination(for: URL.self) { urls, _ in
                let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
                Task { for url in urls where url.isFileURL { await workspace.move(url, into: folder) } }
                return true
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: URL.self) { urls in
            ExplorerMenu(workspace: workspace, target: urls.first)
        }
        .onChange(of: selection) { _, url in
            if let url, !url.hasDirectoryPath, !workspace.rootNodes.contains(where: { $0.url == url }) {
                workspace.open(fileAt: url)
            }
        }
        .onChange(of: workspace.activeDocument?.url) { _, url in
            if let url { selection = url }
        }
    }
}

/// The Explorer's right-click menu: on an item (or, on empty space, the folder itself). On a
/// workspace's folder: adding and removing folders.
private struct ExplorerMenu: View {
    let workspace: Workspace
    let target: URL?

    private var isRoot: Bool {
        guard let target, workspace.isMultiRoot else { return false }
        return workspace.rootNodes.contains { $0.url == target }
    }

    var body: some View {
        Button("New File…") { workspace.promptNewFile(in: target) }
        Button("New Folder…") { workspace.promptNewFolder(in: target) }
        if let target, isRoot {
            Divider()
            Button("Add Folder to Workspace…") { workspace.presentAddFolderPanel() }
            Button("Remove Folder from Workspace") { workspace.removeFolder(target) }
            Divider()
            Button("Reveal in Finder") { workspace.revealInFinder(target) }
            Button("Copy Path") { workspace.copyPath(target, relative: false) }
        } else if let target {
            Divider()
            Button("Rename…") { workspace.promptRename(target) }
            Button("Move to Trash") { workspace.trash([target]) }
            Divider()
            Button("Reveal in Finder") { workspace.revealInFinder(target) }
            Button("Copy Path") { workspace.copyPath(target, relative: false) }
            Button("Copy Relative Path") { workspace.copyPath(target, relative: true) }
        } else {
            Divider()
            Button("Add Folder to Workspace…") { workspace.presentAddFolderPanel() }
        }
    }
}

/// A workspace folder's top-level row: its name (or the one the workspace gives it) and branch.
private struct FolderRootRow: View {
    let name: String
    let url: URL
    let branch: String?

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(name).fontWeight(.semibold)
            } icon: {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if let branch {
                Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .transaction { $0.animation = nil }
        .help((url.path as NSString).abbreviatingWithTildeInPath)
    }
}

private struct FileRow: View {
    let node: FileNode
    let status: GitFileStatus?
    let submodule: GitSubmodule?

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(node.name)
                    .foregroundStyle(status.map { Color(nsColor: $0.color) } ?? .primary)
                    .strikethrough(status == .deleted)
            } icon: {
                // One view whatever the kind, so a recycled row swaps its symbol rather than
                // cross-fading between two different views.
                let style = submodule != nil ? (symbol: "shippingbox", color: Color.secondary)
                    : FileIcon.style(for: node.name, isDirectory: node.isDirectory)
                Image(systemName: style.symbol)
                    .foregroundStyle(style.color)
                    .symbolRenderingMode(.hierarchical)
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
        // The outline reuses row views as folders open and close; animating a reused row's
        // change of content left the old row's name and icon faded over the new one.
        .transaction { $0.animation = nil }
        .help(submodule.map { "\(node.name): submodule at \($0.shortSHA) — \($0.stateDescription)" }
              ?? status.map { "\(node.name): \($0.label)" } ?? node.name)
    }
}
