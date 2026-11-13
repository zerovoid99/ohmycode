import AppKit
import Observation
import SwiftUI

/// A side-by-side diff tab: the staged (index) version of a file against the editor's text.
/// It follows the document live, from the hunks the gutter markers already use.
@MainActor
@Observable
final class DiffSession: Identifiable {
    let id = UUID()
    let document: EditorDocument
    /// The document was opened only for this diff (no tab of its own): closing the diff closes it.
    let ownsDocument: Bool

    init(document: EditorDocument, ownsDocument: Bool) {
        self.document = document
        self.ownsDocument = ownsDocument
    }

    var title: String { "\(document.fileName) (Changes)" }
}

/// One row of a side-by-side diff.
struct DiffRow: Identifiable, Equatable {
    enum Kind: Equatable { case same, removed, added, changed, skipped(Int) }
    let id: Int
    let kind: Kind
    /// Zero-based line numbers on each side (nil where that side has no line).
    let old: Int?
    let new: Int?

    /// Rows for `hunks` between `oldCount` and `newCount` lines; runs of unchanged lines longer
    /// than twice `context` are collapsed into one `.skipped` row, except `expanded` runs (by the
    /// first old line of the run).
    static func rows(hunks: [DiffHunk], oldCount: Int, newCount: Int, context: Int = 3, expanded: Set<Int> = []) -> [DiffRow] {
        var rows: [DiffRow] = []
        func add(_ kind: Kind, _ old: Int?, _ new: Int?) { rows.append(DiffRow(id: rows.count, kind: kind, old: old, new: new)) }

        var old = 0, new = 0
        func unchanged(until newEnd: Int, leading: Bool, trailing: Bool) {
            let count = newEnd - new
            guard count > 0 else { return }
            let keepStart = leading ? 0 : context, keepEnd = trailing ? 0 : context
            if count > keepStart + keepEnd + 1, !expanded.contains(old + keepStart) {
                for i in 0..<keepStart { add(.same, old + i, new + i) }
                add(.skipped(count - keepStart - keepEnd), old + keepStart, nil)
                for i in (count - keepEnd)..<count { add(.same, old + i, new + i) }
            } else {
                for i in 0..<count { add(.same, old + i, new + i) }
            }
            old += count
            new += count
        }

        for (index, hunk) in hunks.enumerated() {
            unchanged(until: hunk.newStart, leading: index == 0, trailing: false)
            let paired = min(hunk.oldCount, hunk.newCount)
            for i in 0..<paired { add(.changed, old + i, new + i) }
            for i in paired..<hunk.oldCount { add(.removed, old + i, nil) }
            for i in paired..<hunk.newCount { add(.added, nil, new + i) }
            old += hunk.oldCount
            new += hunk.newCount
        }
        unchanged(until: newCount, leading: hunks.isEmpty, trailing: true)
        return rows
    }
}

struct DiffView: View {
    let session: DiffSession
    let workspace: Workspace
    @State private var expanded: Set<Int> = []
    @State private var currentChange = 0

    private var document: EditorDocument { session.document }

    var body: some View {
        let base = document.diffBaseLines ?? []
        let current = currentLines
        let hunks = document.diffHunks
        let rows = DiffRow.rows(hunks: hunks, oldCount: base.count, newCount: current.count, expanded: expanded)
        let changeRows = rows.filter { $0.kind != .same && !$0.isSkipped }.map(\.id)
        VStack(spacing: 0) {
            header(hunks: hunks, base: base, rows: rows)
            Divider()
            if document.diffBaseLines == nil {
                ContentUnavailableView("Not in Git", systemImage: "questionmark.folder",
                                       description: Text("This file isn't tracked, so there's nothing to compare it with."))
            } else if hunks.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle",
                                       description: Text("The file matches the staged version."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                DiffRowView(row: row, base: base, current: current, onExpand: {
                                    if let old = row.old { expanded.insert(old) }
                                })
                                .id(row.id)
                            }
                        }
                    }
                    .onAppear { if let first = changeRows.first { proxy.scrollTo(first, anchor: .center) } }
                    .onChange(of: currentChange) { _, change in
                        let starts = hunkStartRows(rows)
                        if starts.indices.contains(change) { withAnimation { proxy.scrollTo(starts[change], anchor: .center) } }
                    }
                }
            }
        }
        .background(Color(nsColor: EditorTheme.observed.background))
    }

    private var currentLines: [Substring] {
        _ = document.diffHunks // re-read the text when the hunks change
        return LineDiff.lines(document.textStorage.mutableString as String)
    }

    /// The first row of each hunk, for previous/next change.
    private func hunkStartRows(_ rows: [DiffRow]) -> [Int] {
        var starts: [Int] = []
        var inChange = false
        for row in rows {
            let changed = row.kind != .same && !row.isSkipped
            if changed && !inChange { starts.append(row.id) }
            inChange = changed
        }
        return starts
    }

    private func header(hunks: [DiffHunk], base: [Substring], rows: [DiffRow]) -> some View {
        let added = hunks.reduce(0) { $0 + max(0, $1.newCount - $1.oldCount) }
        let removed = hunks.reduce(0) { $0 + max(0, $1.oldCount - $1.newCount) }
        let changed = hunks.reduce(0) { $0 + min($1.oldCount, $1.newCount) }
        let count = hunkStartRows(rows).count
        return HStack(spacing: 10) {
            Text("Staged").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(removed)").foregroundStyle(.red)
                Text("~\(changed)").foregroundStyle(.orange)
            }
            .font(.caption.monospacedDigit())
            Button { currentChange = max(0, currentChange - 1) } label: { Image(systemName: "arrow.up") }
                .help("Previous Change").disabled(count == 0)
            Button { currentChange = min(count - 1, currentChange + 1) } label: { Image(systemName: "arrow.down") }
                .help("Next Change").disabled(count == 0)
            Button {
                workspace.open(fileAt: document.url)
            } label: { Image(systemName: "doc.text") }
                .help("Open File")
            Text("Working Tree").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .themedBackground(.tabBar, fallback: .bar)
    }
}

extension DiffRow {
    var isSkipped: Bool { if case .skipped = kind { return true } else { return false } }
}

private struct DiffRowView: View {
    let row: DiffRow
    let base: [Substring]
    let current: [Substring]
    let onExpand: () -> Void

    var body: some View {
        if case .skipped(let count) = row.kind {
            Button(action: onExpand) {
                Label("\(count) unchanged lines", systemImage: "arrow.up.and.down")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.08))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 0) {
                side(line: row.old, lines: base, tint: row.kind == .removed || row.kind == .changed ? .red : nil)
                Divider()
                side(line: row.new, lines: current, tint: row.kind == .added || row.kind == .changed ? .green : nil)
            }
        }
    }

    private func side(line: Int?, lines: [Substring], tint: Color?) -> some View {
        HStack(spacing: 6) {
            Text(line.map { String($0 + 1) } ?? "")
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(line.flatMap { lines.indices.contains($0) ? String(lines[$0]) : nil } ?? "")
                .foregroundStyle(Color(nsColor: EditorTheme.observed.foreground))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Font(EditorTheme.font))
        .padding(.vertical, 1)
        .background(line == nil ? Color.secondary.opacity(0.06) : (tint?.opacity(0.18) ?? .clear))
    }
}
