import AppKit
import Observation
import SwiftUI

/// A side-by-side diff tab. Working tree: the staged (index) version of a file against the
/// editor's text, following the document live from the hunks the gutter markers use. Staged:
/// the last commit (HEAD) against the index, re-read whenever git state changes.
@MainActor
@Observable
final class DiffSession: Identifiable {
    enum Mode: Equatable { case workingTree, staged }

    let id = UUID()
    let mode: Mode
    let url: URL
    /// The open document (working tree mode only).
    let document: EditorDocument?
    /// The document was opened only for this diff (no tab of its own): closing the diff closes it.
    let ownsDocument: Bool

    /// Staged mode: HEAD's lines ([""] for a file new in the index) and the index's lines;
    /// both nil when nothing is staged for the file.
    private(set) var headLines: [Substring]?
    private(set) var indexLines: [Substring]?
    private(set) var stagedHunks: [DiffHunk] = []
    /// HEAD had no such file (a newly added one).
    private(set) var isNewFile = false
    private(set) var isLoaded = false

    init(document: EditorDocument, ownsDocument: Bool) {
        mode = .workingTree
        url = document.url
        self.document = document
        self.ownsDocument = ownsDocument
    }

    init(stagedChangesOf url: URL) {
        mode = .staged
        self.url = url
        document = nil
        ownsDocument = false
    }

    var fileName: String { url.lastPathComponent }
    var title: String { mode == .staged ? "\(fileName) (Staged)" : "\(fileName) (Changes)" }
    var help: String { mode == .staged ? "\(url.path) — HEAD ↔ staged" : "\(url.path) — staged ↔ working tree" }

    /// The left side of the diff (nil: nothing to compare with).
    var baseLines: [Substring]? { mode == .staged ? headLines : document?.diffBaseLines }

    /// The right side.
    var currentLines: [Substring] {
        if mode == .staged { return indexLines ?? [] }
        guard let document else { return [] }
        _ = document.diffHunks // re-read the text when the hunks change
        return LineDiff.lines(document.textStorage.mutableString as String)
    }

    var hunks: [DiffHunk] { mode == .staged ? stagedHunks : document?.diffHunks ?? [] }

    func setStaged(head: String?, index: String?) {
        isNewFile = head == nil && index != nil
        let headLines = index == nil ? nil : LineDiff.lines(head ?? "")
        let indexLines = index.map(LineDiff.lines)
        isLoaded = true
        guard headLines != self.headLines || indexLines != self.indexLines else { return }
        self.headLines = headLines
        self.indexLines = indexLines
        stagedHunks = headLines.flatMap { head in indexLines.map { LineDiff.hunks(base: head, current: $0) } } ?? []
    }
}

/// One row of a side-by-side diff.
struct DiffRow: Identifiable, Equatable {
    enum Kind: Equatable { case same, removed, added, changed, skipped(Int) }
    let id: Int
    let kind: Kind
    /// Zero-based line numbers on each side (nil where that side has no line).
    let old: Int?
    let new: Int?
    /// Index of the hunk this row belongs to (changed rows only).
    var hunk: Int? = nil

    /// Rows for `hunks` between `oldCount` and `newCount` lines; runs of unchanged lines longer
    /// than twice `context` are collapsed into one `.skipped` row, except `expanded` runs (by the
    /// first old line of the run).
    static func rows(hunks: [DiffHunk], oldCount: Int, newCount: Int, context: Int = 3, expanded: Set<Int> = []) -> [DiffRow] {
        var rows: [DiffRow] = []
        func add(_ kind: Kind, _ old: Int?, _ new: Int?, hunk: Int? = nil) {
            rows.append(DiffRow(id: rows.count, kind: kind, old: old, new: new, hunk: hunk))
        }

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
            for i in 0..<paired { add(.changed, old + i, new + i, hunk: index) }
            for i in paired..<hunk.oldCount { add(.removed, old + i, nil, hunk: index) }
            for i in paired..<hunk.newCount { add(.added, nil, new + i, hunk: index) }
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

    private var isStaged: Bool { session.mode == .staged }

    var body: some View {
        let base = session.baseLines ?? []
        let current = session.currentLines
        let hunks = session.hunks
        let rows = DiffRow.rows(hunks: hunks, oldCount: base.count, newCount: current.count, expanded: expanded)
        let starts = DiffRow.hunkStarts(rows)
        VStack(spacing: 0) {
            header(hunks: hunks, count: starts.count)
            Divider()
            if session.baseLines == nil {
                if isStaged {
                    if session.isLoaded {
                        ContentUnavailableView("Nothing Staged", systemImage: "tray",
                                               description: Text("No changes to this file are staged."))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ContentUnavailableView("Not in Git", systemImage: "questionmark.folder",
                                           description: Text("This file isn't tracked, so there's nothing to compare it with."))
                }
            } else if hunks.isEmpty {
                ContentUnavailableView(isStaged ? "Nothing Staged" : "No Changes", systemImage: "checkmark.circle",
                                       description: Text(isStaged ? "The staged version matches the last commit."
                                                                  : "The file matches the staged version."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                VStack(spacing: 0) {
                                    if let hunk = row.hunk, starts.first(where: { $0.hunk == hunk })?.row == row.id,
                                       hunks.indices.contains(hunk) {
                                        hunkBar(hunks[hunk])
                                    }
                                    DiffRowView(row: row, base: base, current: current, onExpand: {
                                        if let old = row.old { expanded.insert(old) }
                                    })
                                }
                                .id(row.id)
                            }
                        }
                    }
                    .onAppear { if let first = starts.first { proxy.scrollTo(first.row, anchor: .center) } }
                    .onChange(of: currentChange) { _, change in
                        if starts.indices.contains(change) { withAnimation { proxy.scrollTo(starts[change].row, anchor: .center) } }
                    }
                }
            }
        }
        .background(Color(nsColor: EditorTheme.observed.background))
    }

    /// Actions for one change, above its lines.
    private func hunkBar(_ hunk: DiffHunk) -> some View {
        HStack(spacing: 12) {
            Spacer()
            if isStaged {
                Button("Unstage Change", systemImage: "minus") { workspace.unstageHunk(hunk, in: session) }
                    .help("Remove this change from the staged version")
            } else if let document = session.document {
                Button("Revert", systemImage: "arrow.uturn.backward") { workspace.revertHunk(hunk, in: document) }
                    .help("Revert this change to the staged version (undoable)")
                Button("Stage Change", systemImage: "plus") { workspace.stageHunk(hunk, of: document) }
                    .help("Stage only this change")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .disabled(workspace.isRunningGitCommand)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1))
    }

    private func header(hunks: [DiffHunk], count: Int) -> some View {
        let added = hunks.reduce(0) { $0 + max(0, $1.newCount - $1.oldCount) }
        let removed = hunks.reduce(0) { $0 + max(0, $1.oldCount - $1.newCount) }
        let changed = hunks.reduce(0) { $0 + min($1.oldCount, $1.newCount) }
        return HStack(spacing: 10) {
            Text(isStaged ? "HEAD" : "Staged").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                workspace.openChanges(for: session.url, staged: !isStaged)
            } label: { Image(systemName: isStaged ? "pencil.and.list.clipboard" : "tray.full") }
                .help(isStaged ? "Show Working Tree Changes" : "Show Staged Changes")
            Button {
                workspace.open(fileAt: session.url)
            } label: { Image(systemName: "doc.text") }
                .help("Open File")
            Text(isStaged ? "Staged" : "Working Tree").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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

    /// The first row of each hunk, in order (for previous/next change and the hunk actions).
    static func hunkStarts(_ rows: [DiffRow]) -> [(hunk: Int, row: Int)] {
        var starts: [(hunk: Int, row: Int)] = []
        for row in rows {
            if let hunk = row.hunk, starts.last?.hunk != hunk { starts.append((hunk, row.id)) }
        }
        return starts
    }
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
