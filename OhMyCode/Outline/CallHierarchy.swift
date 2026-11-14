import AppKit
import Observation
import SwiftUI

/// Who calls a function (incoming) or what it calls (outgoing), level by level as they're
/// expanded (the Call Hierarchy sidebar).
@MainActor
@Observable
final class CallHierarchy {
    @MainActor
    @Observable
    final class Node: Identifiable {
        let id = UUID()
        let item: CallHierarchyItem
        /// The calls' ranges: in `item`'s file for incoming calls (where it calls its parent),
        /// in the parent's file for outgoing ones.
        let ranges: [LSPRange]
        /// The file the ranges are in.
        let rangesURL: URL
        var children: [Node]?
        var isLoading = false
        var isExpanded = false

        init(item: CallHierarchyItem, ranges: [LSPRange], rangesURL: URL) {
            self.item = item
            self.ranges = ranges
            self.rangesURL = rangesURL
        }
    }

    let root: CallHierarchyItem
    private(set) var incoming: Bool
    /// The root's callers or callees.
    private(set) var nodes: [Node] = []
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private let client: LanguageClient

    init(root: CallHierarchyItem, incoming: Bool, client: LanguageClient) {
        self.root = root
        self.incoming = incoming
        self.client = client
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            nodes = try await children(of: root)
            error = nil
        } catch {
            nodes = []
            self.error = error.localizedDescription
        }
    }

    /// Incoming ↔ outgoing.
    func setIncoming(_ incoming: Bool) async {
        guard incoming != self.incoming else { return }
        self.incoming = incoming
        await load()
    }

    /// Opens or closes a node, loading its level the first time.
    func toggle(_ node: Node) async {
        node.isExpanded.toggle()
        guard node.isExpanded, node.children == nil else { return }
        node.isLoading = true
        node.children = (try? await children(of: node.item)) ?? []
        node.isLoading = false
    }

    private func children(of item: CallHierarchyItem) async throws -> [Node] {
        let incoming = incoming
        return try await client.calls(item, incoming: incoming).map { call in
            Node(item: call.item, ranges: call.ranges, rangesURL: incoming ? call.item.url : item.url)
        }
        .sorted { ($0.item.url.path, $0.item.range.start.line) < ($1.item.url.path, $1.item.range.start.line) }
    }
}

extension Workspace {
    /// ⌥⇧H: the calls to (or from) the function at the cursor, in the sidebar.
    @discardableResult
    func showCallHierarchy(incoming: Bool = true, in target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let document = target ?? activeDocument, let client = document.languageClient,
              client.state == .ready, client.supports(.callHierarchy),
              let selection = document.editor?.textView.selectedRange() ?? document.viewState?.selection else {
            NSSound.beep()
            return nil
        }
        return Task {
            do {
                guard let item = try await client.prepareCallHierarchy(url: document.url, position: document.lspPosition(at: selection.location)).first else {
                    NSSound.beep()
                    return
                }
                let hierarchy = CallHierarchy(root: item, incoming: incoming, client: client)
                callHierarchy = hierarchy
                sidebarMode = .callHierarchy
                await hierarchy.load()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Selects a range in a file the hierarchy names.
    func open(_ range: LSPRange, in url: URL) {
        open(fileAt: workspaceURL(for: url))
        guard let document = activeDocument else { return }
        document.reveal(document.range(for: range))
        document.editor?.focus()
    }
}

/// The Call Hierarchy sidebar.
struct CallHierarchyView: View {
    let workspace: Workspace

    var body: some View {
        if let hierarchy = workspace.callHierarchy {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    SymbolIcon(kind: DocumentSymbol.Kind(rawValue: hierarchy.root.kind) ?? .function)
                    Text(hierarchy.root.name).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Button {
                        workspace.callHierarchy = nil
                        workspace.sidebarMode = .files
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Close the call hierarchy")
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                Picker("Direction", selection: Binding(get: { hierarchy.incoming },
                                                       set: { incoming in Task { await hierarchy.setIncoming(incoming) } })) {
                    Text("Callers").tag(true)
                    Text("Calls").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
                if hierarchy.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = hierarchy.error {
                    Text(error).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hierarchy.nodes.isEmpty {
                    Text(hierarchy.incoming ? "Nothing calls \(hierarchy.root.name)." : "\(hierarchy.root.name) calls nothing.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(hierarchy.nodes) { node in CallNodeRows(node: node, depth: 0, hierarchy: hierarchy, workspace: workspace) }
                    }
                    .listStyle(.sidebar)
                }
            }
        } else {
            ContentUnavailableView("No Call Hierarchy", systemImage: "arrow.triangle.branch",
                                   description: Text("Use Show Call Hierarchy (⌥⇧H) on a function."))
        }
    }
}

private struct CallNodeRows: View {
    let node: CallHierarchy.Node
    let depth: Int
    let hierarchy: CallHierarchy
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .contentShape(Rectangle())
                .onTapGesture { Task { await hierarchy.toggle(node) } }
            SymbolIcon(kind: DocumentSymbol.Kind(rawValue: node.item.kind) ?? .function)
            Text(node.item.name).lineLimit(1)
            Text("\(workspace.relativePath(of: workspace.workspaceURL(for: node.item.url)) ?? node.item.url.lastPathComponent):\(node.item.selectionRange.start.line + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if node.ranges.count > 1 {
                Text("\(node.ranges.count)×").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        // The call itself; double-click: the function's declaration.
        .onTapGesture(count: 2) { workspace.open(node.item.selectionRange, in: node.item.url) }
        .onTapGesture {
            if let range = node.ranges.first { workspace.open(range, in: node.rangesURL) }
            else { workspace.open(node.item.selectionRange, in: node.item.url) }
        }
        .contextMenu {
            Button("Go to Call") { if let range = node.ranges.first { workspace.open(range, in: node.rangesURL) } }
                .disabled(node.ranges.isEmpty)
            Button("Go to Definition") { workspace.open(node.item.selectionRange, in: node.item.url) }
        }
        if node.isExpanded {
            if node.isLoading {
                ProgressView().controlSize(.small).padding(.leading, CGFloat(depth + 1) * 12 + 20)
            }
            ForEach(node.children ?? []) { child in
                CallNodeRows(node: child, depth: depth + 1, hierarchy: hierarchy, workspace: workspace)
            }
        }
    }
}
