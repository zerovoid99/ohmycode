import SwiftUI

/// Review sheet for multi-file edits (rename, replace all): every change per file, with
/// checkboxes to leave files out.
struct EditPreviewView: View {
    @Bindable var preview: EditPreview
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.title).font(.headline).lineLimit(2)
                Text("\(preview.changeCount) change\(preview.changeCount == 1 ? "" : "s") in \(preview.includedFiles.count) of \(preview.files.count) file\(preview.files.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            List {
                ForEach($preview.files) { $file in
                    DisclosureGroup(isExpanded: .constant(true)) {
                        ForEach(file.changes) { change in
                            ChangeRow(change: change)
                        }
                    } label: {
                        Toggle(isOn: $file.isIncluded) {
                            HStack(spacing: 6) {
                                Text((file.path as NSString).lastPathComponent)
                                Text((file.path as NSString).deletingLastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                Spacer()
                                if workspace.document(matching: file.url) == nil {
                                    Text("not open").font(.caption2).foregroundStyle(.secondary)
                                        .help("Will open as an unsaved tab, so you can review, save or undo it")
                                }
                                Text("\(file.edits.count)")
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 5)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Text("Files that aren't open open as unsaved tabs, so every change can be undone.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { workspace.cancelPendingEdit() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { workspace.applyPendingEdit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.includedFiles.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 480)
    }
}

private struct ChangeRow: View {
    let change: EditPreview.LineChange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(change.line + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                line(change.old, removed: true)
                line(change.new, removed: false)
            }
        }
    }

    private func line(_ text: String, removed: Bool) -> some View {
        Text(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\n", with: " ⏎ "))
            .strikethrough(removed, color: .red.opacity(0.6))
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((removed ? Color.red : Color.green).opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}
