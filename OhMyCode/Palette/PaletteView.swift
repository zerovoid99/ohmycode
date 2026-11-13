import AppKit
import SwiftUI

struct PaletteView: View {
    let model: PaletteModel
    let onDismiss: () -> Void

    private static let rowHeight: CGFloat = 30
    private static let maxListHeight: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                PaletteTextField(
                    text: Binding(get: { model.query }, set: { model.query = $0 }),
                    placeholder: model.placeholder,
                    onMove: model.moveSelection,
                    onSubmit: model.acceptSelection,
                    onCancel: onDismiss
                )
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            Divider()

            if let message = model.emptyMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
            } else {
                results
            }
        }
        .frame(width: 640)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }

    private var icon: String {
        switch model.mode {
        case .files: "magnifyingglass"
        case .commands: "chevron.right"
        case .goToLine: "number"
        case .prompt: "questionmark.bubble"
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isSelected: index == model.selection)
                            .frame(height: Self.rowHeight)
                            .onTapGesture {
                                model.selection = index
                                model.accept(item)
                            }
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(model.items.count) * Self.rowHeight + 12, Self.maxListHeight))
            .onChange(of: model.selection) { _, selection in
                if model.items.indices.contains(selection) {
                    proxy.scrollTo(model.items[selection].id)
                }
            }
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            highlighted(item.title, item.titleMatches)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = item.detail {
                highlighted(detail, item.detailMatches)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    /// Bolds matched characters. Positions are UTF-8 offsets; only ASCII bytes are ever matched
    /// against ASCII query bytes, so mapping through unicode scalars is safe.
    private func highlighted(_ text: String, _ positions: [Int]) -> Text {
        guard !positions.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        let matched = Set(positions)
        var byteOffset = 0
        var index = attributed.startIndex
        for scalar in text.unicodeScalars {
            let next = attributed.unicodeScalars.index(after: index)
            if matched.contains(byteOffset) {
                attributed[index..<next].foregroundColor = .accentColor
                attributed[index..<next].font = .body.bold()
            }
            byteOffset += String(scalar).utf8.count
            index = next
        }
        return Text(attributed)
    }
}

/// AppKit text field so arrow keys, Return and Escape are handled deterministically
/// through the field editor's command selectors.
private struct PaletteTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            Self.moveCursorToEnd(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text {
            field.stringValue = text
            Self.moveCursorToEnd(field)
        }
    }

    private static func moveCursorToEnd(_ field: NSTextField) {
        let length = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: length, length: 0)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteTextField
        init(parent: PaletteTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
