import SwiftUI

struct TabBarView: View {
    let workspace: Workspace
    let group: EditorGroup
    /// Where a dragged tab would land (index in this group's tabs), while hovering.
    @State private var dropIndex: Int?
    @State private var tabWidths: [EditorDocument.ID: CGFloat] = [:]

    var body: some View {
        let isActiveGroup = workspace.activeGroupID == group.id
        let tabs = group.documentIDs.compactMap { id in workspace.tabInfo(id).map { (id: id, info: $0) } }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    // Not the document itself: SwiftUI keeps a closed tab's closures (its menu)
                    // for a while, and they would keep the closed document.
                    let fileURL = workspace.document(id: tab.id)?.url
                    let isViewer = workspace.viewer(id: tab.id) != nil
                    TabItemView(
                        title: tab.info.title, help: tab.info.help, isDirty: tab.info.isDirty, isDiff: tab.info.isDiff,
                        isActive: tab.id == group.activeDocumentID,
                        isActiveGroup: isActiveGroup,
                        onSelect: {
                            workspace.activeGroupID = group.id
                            workspace.activeDocumentID = tab.id
                            workspace.document(id: tab.id)?.editor(inGroup: group)?.focus()
                        },
                        onClose: { workspace.closeTab(tab.id, in: group) }
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabWidths[tab.id] = $0 }
                    .overlay(alignment: .leading) { dropMarker(at: index) }
                    .overlay(alignment: .trailing) { if index == tabs.count - 1 { dropMarker(at: tabs.count) } }
                    .draggable(TabDragPayload(documentID: tab.id, groupID: group.id).string) {
                        Label(tab.info.title, systemImage: tab.info.isDiff ? "plusminus" : "doc.text")
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    // Dropping on a tab's left half puts the tab before it, on the right half after.
                    .onDrop(of: [.text], delegate: TabDropDelegate(
                        dropIndex: $dropIndex,
                        target: { $0.x < (tabWidths[tab.id] ?? 0) / 2 ? index : index + 1 },
                        perform: { drop($0, at: $1) }))
                    .contextMenu {
                        Button("Close") { workspace.closeTab(tab.id, in: group) }
                        if let fileURL {
                            Button("Open Changes") { workspace.openChanges(for: fileURL) }
                            Button("Show File History") {
                                workspace.activeGroupID = group.id
                                workspace.activeDocumentID = tab.id
                                workspace.showFileHistory()
                            }
                            Divider()
                            Button("Compare with…") { Task { await workspace.pickFileToCompare(with: fileURL) } }
                            Button("Compare with Clipboard") { workspace.compareWithClipboard(fileURL) }
                            Button("Compare with Saved") { workspace.compareWithSaved(fileURL) }
                                .disabled(workspace.document(id: tab.id)?.isDirty != true)
                        }
                        if fileURL != nil || isViewer {
                            Divider()
                            Button("Split Right") {
                                workspace.activeGroupID = group.id
                                workspace.activeDocumentID = tab.id
                                workspace.splitEditor()
                            }
                            .disabled(workspace.groups.count >= Workspace.maxGroups)
                            Button("Move to Next Group") {
                                workspace.activeGroupID = group.id
                                workspace.activeDocumentID = tab.id
                                workspace.moveActiveEditor(by: 1)
                            }
                            Button("Move to Previous Group") {
                                workspace.activeGroupID = group.id
                                workspace.activeDocumentID = tab.id
                                workspace.moveActiveEditor(by: -1)
                            }
                        }
                    }
                    Divider()
                }
                // The empty rest of the bar: drop to put the tab last.
                Color.clear
                    .frame(minWidth: 40, maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: TabDropDelegate(
                        dropIndex: $dropIndex, target: { _ in tabs.count }, perform: { drop($0, at: $1) }))
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 34)
        .themedBackground(.tabBar, fallback: .bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private func dropMarker(at index: Int) -> some View {
        if dropIndex == index {
            Color.accentColor.frame(width: 2).padding(.vertical, 4)
        }
    }

    private func drop(_ payload: TabDragPayload, at index: Int) {
        dropIndex = nil
        guard let source = workspace.group(id: payload.groupID) else { return }
        workspace.moveTab(payload.documentID, from: source, to: group, at: index)
        workspace.document(id: payload.documentID)?.editor(inGroup: group)?.focus()
    }
}

/// Shows where a dragged tab would land and moves it there on drop. Only tab payloads are
/// accepted; other dragged text is ignored.
private struct TabDropDelegate: DropDelegate {
    @Binding var dropIndex: Int?
    let target: (CGPoint) -> Int
    let perform: @MainActor @Sendable (TabDragPayload, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { dropIndex = target(info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropIndex = target(info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { dropIndex = nil }

    func performDrop(info: DropInfo) -> Bool {
        let index = target(info.location)
        dropIndex = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let perform = perform
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let payload = TabDragPayload(string) else { return }
            Task { @MainActor in perform(payload, index) }
        }
        return true
    }
}

private struct TabItemView: View {
    let title: String
    let help: String
    let isDirty: Bool
    let isDiff: Bool
    let isActive: Bool
    let isActiveGroup: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isDiff { Image(systemName: "plusminus").foregroundStyle(.secondary) } else { FileIcon(name: title) }
            }
            .font(.system(size: 11))
            .frame(width: 14)
            .opacity(isActive ? 1 : 0.75)
            Text(title)
                .font(.callout)
                .foregroundStyle(isActive && isActiveGroup ? .primary : .secondary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: isDirty && !isHovering ? "circle.fill" : "xmark")
                    .font(.system(size: isDirty && !isHovering ? 7 : 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isActive || isHovering || isDirty ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color(nsColor: EditorTheme.observed.background) : isHovering ? Color.primary.opacity(0.04) : .clear)
        .overlay(alignment: .top) {
            // The active tab: marked in the accent color in the focused group, quieter in others.
            if isActive {
                Rectangle().fill(isActiveGroup ? Color.accentColor : Color.secondary.opacity(0.5)).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
