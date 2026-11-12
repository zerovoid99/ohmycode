import SwiftUI

struct TabBarView: View {
    let workspace: Workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.documents) { document in
                    TabItemView(
                        document: document,
                        isActive: document.id == workspace.activeDocumentID,
                        onSelect: { workspace.activeDocumentID = document.id },
                        onClose: { workspace.close(document) }
                    )
                    Divider()
                }
            }
        }
        .frame(height: 32)
        .background(.bar)
    }
}

private struct TabItemView: View {
    let document: EditorDocument
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(document.fileName)
                .font(.callout)
                .foregroundStyle(isActive ? .primary : .secondary)
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
        .background(isActive ? Color(nsColor: .textBackgroundColor) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(document.url.path)
    }
}
