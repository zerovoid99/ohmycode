import AppKit
import SwiftUI

extension Workspace {
    /// Selects a symbol's name in its document and focuses the editor.
    func reveal(_ symbol: DocumentSymbol, in document: EditorDocument) {
        if activeDocumentID != document.id { activeDocumentID = document.id }
        document.reveal(symbol.selectionRange)
        document.editor?.focus()
    }
}

/// The Outline sidebar: the active file's declarations; the one the cursor is in is selected.
struct OutlineView: View {
    let workspace: Workspace
    @State private var filter = ""
    @State private var sortsByName = false
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter", text: $filter, prompt: Text("Filter symbols"))
                    .textFieldStyle(.roundedBorder)
                Button { sortsByName.toggle() } label: {
                    Image(systemName: sortsByName ? "textformat.abc" : "list.number")
                }
                .help(sortsByName ? "Sorted by name" : "Sorted by position")
                Button {
                    if let document = workspace.activeDocument {
                        collapsed = collapsed.isEmpty ? Set(DocumentSymbol.flattened(document.symbols).filter { !$0.symbol.children.isEmpty }.map(\.symbol.id)) : []
                    }
                } label: { Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical") }
                    .help(collapsed.isEmpty ? "Collapse all" : "Expand all")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if let document = workspace.activeDocument {
                let symbols = visible(document.symbols)
                if symbols.isEmpty {
                    Text(document.symbols.isEmpty ? "No symbols in \(document.fileName)." : "No symbols match.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let current = document.symbolPathAtCursor.last?.id
                    ScrollViewReader { proxy in
                        List {
                            ForEach(symbols) { symbol in rows(symbol, depth: 0, document: document, current: current) }
                        }
                        .listStyle(.sidebar)
                        .onChange(of: current) { _, id in
                            if let id { withAnimation { proxy.scrollTo(id) } }
                        }
                    }
                }
            } else {
                Text("Open a file to see its outline.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Filtered (keeping the containers of matches) and sorted.
    private func visible(_ symbols: [DocumentSymbol]) -> [DocumentSymbol] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let kept: [DocumentSymbol] = symbols.compactMap { symbol in
            var copy = symbol
            copy.children = visible(symbol.children)
            if needle.isEmpty || symbol.name.lowercased().contains(needle) || !copy.children.isEmpty { return copy }
            return nil
        }
        return sortsByName ? kept.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : kept
    }

    private func rows(_ symbol: DocumentSymbol, depth: Int, document: EditorDocument, current: String?) -> AnyView {
        let isCollapsed = collapsed.contains(symbol.id) && filter.isEmpty
        return AnyView(Group {
            SymbolRow(symbol: symbol, depth: depth, isCollapsed: isCollapsed, isCurrent: symbol.id == current,
                      toggle: { if collapsed.contains(symbol.id) { collapsed.remove(symbol.id) } else { collapsed.insert(symbol.id) } })
                .id(symbol.id)
                .contentShape(Rectangle())
                .onTapGesture { workspace.reveal(symbol, in: document) }
            if !isCollapsed {
                ForEach(symbol.children) { child in rows(child, depth: depth + 1, document: document, current: current) }
            }
        })
    }
}

private struct SymbolRow: View {
    let symbol: DocumentSymbol
    let depth: Int
    let isCollapsed: Bool
    let isCurrent: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if symbol.children.isEmpty {
                Color.clear.frame(width: 10)
            } else {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggle)
            }
            SymbolIcon(kind: symbol.kind)
            Text(symbol.name).lineLimit(1).truncationMode(.tail)
            if let detail = symbol.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.vertical, 1)
        .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct SymbolIcon: View {
    let kind: DocumentSymbol.Kind

    var body: some View {
        Image(systemName: kind.icon)
            .foregroundStyle(color)
            .help(kind.name)
    }

    private var color: Color {
        switch kind {
        case .class, .struct, .interface, .enum, .typeParameter: .orange
        case .method, .function, .constructor, .operator: .purple
        case .property, .field, .variable, .enumMember: .blue
        case .constant: .teal
        default: .secondary
        }
    }
}

/// Above the editor: the file's folders and name, then the symbols the cursor is in. Each
/// part lists its neighbours to jump to.
struct BreadcrumbsView: View {
    let workspace: Workspace
    let document: EditorDocument

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let folders = folderPath
                ForEach(Array(folders.enumerated()), id: \.offset) { index, folder in
                    Menu {
                        folderMenu(folder)
                    } label: {
                        Text(folder.lastPathComponent)
                    }
                    separator
                }
                Menu {
                    symbolMenu(document.symbols)
                } label: {
                    Label(document.fileName, systemImage: "doc.text")
                }
                let path = document.symbolPathAtCursor
                ForEach(Array(path.enumerated()), id: \.element.id) { index, symbol in
                    separator
                    Menu {
                        symbolMenu(index == 0 ? document.symbols : path[index - 1].children)
                    } label: {
                        Label(symbol.name, systemImage: symbol.kind.icon)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(height: 22)
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
    }

    /// The folders from the workspace's root down to the file's.
    private var folderPath: [URL] {
        let folder = document.url.deletingLastPathComponent()
        guard let root = workspace.rootURL, let relative = workspace.relativePath(of: folder) ?? (folder == root ? "" : nil) else {
            return [folder]
        }
        var url = root
        var path = [root]
        for part in relative.split(separator: "/") {
            url = url.appending(path: String(part))
            path.append(url)
        }
        return path
    }

    private func folderMenu(_ folder: URL) -> AnyView {
        let entries = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let files = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
        let folders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return AnyView(Group {
            ForEach(folders.prefix(100), id: \.self) { subfolder in
                Menu(subfolder.lastPathComponent) { folderMenu(subfolder) }
            }
            if !folders.isEmpty && !files.isEmpty { Divider() }
            ForEach(files.prefix(200), id: \.self) { file in
                Button(file.lastPathComponent) { workspace.open(fileAt: file) }
            }
        })
    }

    @ViewBuilder
    private func symbolMenu(_ symbols: [DocumentSymbol]) -> some View {
        if symbols.isEmpty {
            Text("No symbols")
        }
        ForEach(symbols) { symbol in
            Button {
                workspace.reveal(symbol, in: document)
            } label: {
                Label(symbol.name, systemImage: symbol.kind.icon)
            }
        }
    }
}
