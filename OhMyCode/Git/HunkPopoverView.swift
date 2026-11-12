import SwiftUI

/// Shown when clicking a change marker in the gutter: the staged lines (red) and current
/// lines (green) of that hunk, with Revert.
struct HunkPopoverView: View {
    let oldLines: [String]
    let newLines: [String]
    let onRevert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Revert", systemImage: "arrow.uturn.backward", action: onRevert)
                    .help("Revert this change to the staged version (undoable)")
            }
            .padding(8)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(oldLines.enumerated()), id: \.offset) { _, line in
                        row("-", line, Color.red)
                    }
                    ForEach(Array(newLines.enumerated()), id: \.offset) { _, line in
                        row("+", line, Color.green)
                    }
                }
                .frame(minWidth: 520, alignment: .leading) // rows span the popover even when short
                .padding(.vertical, 4)
            }
            // Fit the lines, up to a scrollable maximum.
            .frame(height: min(CGFloat(oldLines.count + newLines.count) * 18 + 8, 280))
        }
        .frame(width: 520)
    }

    private var summary: String {
        switch (oldLines.count, newLines.count) {
        case (0, let added): "\(added) line\(added == 1 ? "" : "s") added"
        case (let removed, 0): "\(removed) line\(removed == 1 ? "" : "s") removed"
        case (1, 1): "1 line changed"
        default: "\(oldLines.count) line\(oldLines.count == 1 ? "" : "s") → \(newLines.count) line\(newLines.count == 1 ? "" : "s")"
        }
    }

    private func row(_ sign: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(sign).foregroundStyle(color)
            Text(text.isEmpty ? " " : text)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
    }
}
