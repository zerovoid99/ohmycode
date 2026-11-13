import SwiftUI

struct TabBarView: View {
    let workspace: Workspace
    let group: EditorGroup

    var body: some View {
        let isActiveGroup = workspace.activeGroupID == group.id
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.documents(in: group)) { document in
                    TabItemView(
                        document: document,
                        isActive: document.id == group.activeDocumentID,
                        isActiveGroup: isActiveGroup,
                        onSelect: {
                            workspace.activeGroupID = group.id
                            workspace.activeDocumentID = document.id
                            document.editor(inGroup: group)?.focus()
                        },
                        onClose: { workspace.close(document, in: group) }
                    )
                    .contextMenu {
                        Button("Close") { workspace.close(document, in: group) }
                        Divider()
                        Button("Split Right") {
                            workspace.activeGroupID = group.id
                            workspace.activeDocumentID = document.id
                            workspace.splitEditor()
                        }
                        .disabled(workspace.groups.count >= Workspace.maxGroups)
                        Button("Move to Next Group") {
                            workspace.activeGroupID = group.id
                            workspace.activeDocumentID = document.id
                            workspace.moveActiveEditor(by: 1)
                        }
                        Button("Move to Previous Group") {
                            workspace.activeGroupID = group.id
                            workspace.activeDocumentID = document.id
                            workspace.moveActiveEditor(by: -1)
                        }
                    }
                    Divider()
                }
            }
        }
        .frame(height: 32)
        .themedBackground(.tabBar, fallback: .bar)
    }
}

private struct TabItemView: View {
    let document: EditorDocument
    let isActive: Bool
    let isActiveGroup: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(document.fileName)
                .font(.callout)
                .foregroundStyle(isActive && isActiveGroup ? .primary : .secondary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: document.isDirty && !isHovering ? "circle.fill" : "xmark")
                    .font(.system(size: document.isDirty && !isHovering ? 7 : 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isActive || isHovering || document.isDirty ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color(nsColor: EditorTheme.observed.background) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(document.url.path)
    }
}
