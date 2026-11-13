import AppKit
import Observation
import SwiftUI

/// A side-by-side diff tab of one file:
/// - working tree: the staged (index) version against the editor's text, live, from the hunks
///   the gutter markers use;
/// - staged: the last commit (HEAD) against the index, re-read whenever git state changes;
/// - commit: what a commit changed (its parent's version against its own), fixed;
/// - compare: a commit's version against the editor's text, live.
@MainActor
@Observable
final class DiffSession: Identifiable {
    enum Mode: Hashable {
        case workingTree, staged
        case commit(GitCommit)
        case compare(GitCommit)
    }

    let id = UUID()
    let mode: Mode
    let url: URL
    /// The open document (working tree and compare modes).
    let document: EditorDocument?
    /// The document was opened only for this diff (no tab of its own): closing the diff closes it.
    let ownsDocument: Bool

    /// Text loaded from git: the left side (all but working tree mode) and the right side
    /// (staged and commit modes). Staged mode: HEAD ([""] for a file new in the index) and the
    /// index, both nil when nothing is staged.
    private(set) var loadedBase: [Substring]?
    private(set) var loadedCurrent: [Substring]?
    private var loadedHunks: [DiffHunk] = []
    /// Compare mode: hunks of the commit's text against the document's, and the text version
    /// they were computed for.
    private var compareHunks: [DiffHunk] = []
    private var compareVersion: Int?
    /// The left side had no such file (a newly added one).
    private(set) var isNewFile = false
    private(set) var isLoaded = false
    /// Bumped when loaded text changes.
    private(set) var loadedVersion = 0

    /// Syntax colors per line of each side, and the content versions they were made for.
    private(set) var baseSpans: [[LineSpan]]?
    private(set) var currentSpans: [[LineSpan]]?
    private var baseSpansVersion: Int?
    private var currentSpansVersion: Int?

    init(document: EditorDocument, ownsDocument: Bool, comparingWith commit: GitCommit? = nil) {
        mode = commit.map(Mode.compare) ?? .workingTree
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

    init(commit: GitCommit, of url: URL) {
        mode = .commit(commit)
        self.url = url
        document = nil
        ownsDocument = false
    }

    var fileName: String { url.lastPathComponent }
    var isStaged: Bool { mode == .staged }
    /// The left side follows the editor's text (and edits there show up live).
    var followsDocument: Bool { document != nil }

    var title: String {
        switch mode {
        case .workingTree: "\(fileName) (Changes)"
        case .staged: "\(fileName) (Staged)"
        case .commit(let commit): "\(fileName) (\(commit.shortSHA))"
        case .compare(let commit): "\(fileName) (\(commit.shortSHA) ↔ Current)"
        }
    }

    var help: String {
        switch mode {
        case .workingTree: "\(url.path) — staged ↔ working tree"
        case .staged: "\(url.path) — HEAD ↔ staged"
        case .commit(let commit): "\(url.path) — \(commit.summary) (\(commit.shortSHA))"
        case .compare(let commit): "\(url.path) — \(commit.shortSHA) ↔ working tree"
        }
    }

    /// Names of the two sides, for the header.
    var sideLabels: (base: String, current: String) {
        switch mode {
        case .workingTree: ("Staged", "Working Tree")
        case .staged: ("HEAD", "Staged")
        case .commit(let commit): (commit.parents.first.map { String($0.prefix(7)) } ?? "(none)", commit.shortSHA)
        case .compare(let commit): (commit.shortSHA, "Working Tree")
        }
    }

    // Aliases for staged mode.
    var headLines: [Substring]? { isStaged ? loadedBase : nil }
    var indexLines: [Substring]? { isStaged ? loadedCurrent : nil }
    var stagedHunks: [DiffHunk] { isStaged ? loadedHunks : [] }

    /// The left side of the diff (nil: nothing to compare with).
    var baseLines: [Substring]? { mode == .workingTree ? document?.diffBaseLines : loadedBase }

    /// The right side.
    var currentLines: [Substring] {
        guard followsDocument else { return loadedCurrent ?? [] }
        guard let document else { return [] }
        _ = document.diffTextVersion // re-read the text when it was diffed again
        return LineDiff.lines(document.textStorage.mutableString as String)
    }

    var hunks: [DiffHunk] {
        switch mode {
        case .workingTree: document?.diffHunks ?? []
        case .compare: compareHunks
        case .staged, .commit: loadedHunks
        }
    }

    var baseVersion: Int { mode == .workingTree ? document?.diffBaseVersion ?? 0 : loadedVersion }
    var currentVersion: Int { followsDocument ? document?.diffTextVersion ?? 0 : loadedVersion }

    /// Colors the sides whose text changed since they were last colored. Old colors stay up
    /// until the new ones are ready (spans past a line's end are skipped when drawing).
    func refreshHighlights() async {
        let language = SourceLanguage(fileExtension: url.pathExtension)
        let base = baseVersion, current = currentVersion
        if baseSpansVersion != base, let lines = baseLines {
            let spans = await DiffSyntax.highlight(lines.joined(separator: "\n"), language: language)
            guard !Task.isCancelled, base == baseVersion else { return }
            baseSpans = spans
            baseSpansVersion = base
        }
        if currentSpansVersion != current {
            let text: String
            if let document, followsDocument {
                text = document.textStorage.mutableString as String
            } else {
                guard let lines = loadedCurrent else { return }
                text = lines.joined(separator: "\n")
            }
            let spans = await DiffSyntax.highlight(text, language: language)
            guard !Task.isCancelled, current == currentVersion else { return }
            currentSpans = spans
            currentSpansVersion = current
        }
    }

    /// Compare mode: diffs the commit's text against the document's current text (off the main
    /// thread), unless that text was already diffed.
    func refreshCompare() async {
        guard case .compare = mode, let document, let base = loadedBase else { return }
        let version = document.diffTextVersion
        guard compareVersion != version || loadedVersion != comparedLoadedVersion else { return }
        let loaded = loadedVersion
        let text = document.textStorage.mutableString as String
        let hunks = await Task.detached(priority: .utility) {
            LineDiff.hunks(base: base, current: LineDiff.lines(text))
        }.value
        guard !Task.isCancelled, version == document.diffTextVersion, loaded == loadedVersion else { return }
        compareHunks = hunks
        compareVersion = version
        comparedLoadedVersion = loaded
    }
    private var comparedLoadedVersion: Int?

    func setStaged(head: String?, index: String?) {
        setLoaded(base: index == nil ? nil : head ?? "", current: index, isNewFile: head == nil && index != nil)
    }

    /// Sets the text loaded from git (`current` is ignored in modes that follow the document).
    func setLoaded(base: String?, current: String?, isNewFile: Bool) {
        self.isNewFile = isNewFile
        let baseLines = base.map(LineDiff.lines)
        let currentLines = current.map(LineDiff.lines)
        isLoaded = true
        guard baseLines != loadedBase || currentLines != loadedCurrent else { return }
        loadedBase = baseLines
        loadedCurrent = currentLines
        loadedVersion += 1
        loadedHunks = baseLines.flatMap { base in currentLines.map { LineDiff.hunks(base: base, current: $0) } } ?? []
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
    /// Changed rows picked by clicking their line numbers, to stage or unstage only those.
    @State private var selection: Set<DiffLinePair> = []

    init(session: DiffSession, workspace: Workspace, selection: Set<DiffLinePair> = []) {
        self.session = session
        self.workspace = workspace
        _selection = State(initialValue: selection)
    }

    private var isStaged: Bool { session.mode == .staged }
    /// Staging and reverting only make sense between the index and the working tree.
    private var canEdit: Bool { session.mode == .workingTree || session.mode == .staged }

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
                } else if session.mode == .workingTree {
                    ContentUnavailableView("Not in Git", systemImage: "questionmark.folder",
                                           description: Text("This file isn't tracked, so there's nothing to compare it with."))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if hunks.isEmpty {
                ContentUnavailableView(isStaged ? "Nothing Staged" : "No Changes", systemImage: "checkmark.circle",
                                       description: Text(emptyDescription))
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                VStack(spacing: 0) {
                                    if canEdit, let hunk = row.hunk, starts.first(where: { $0.hunk == hunk })?.row == row.id,
                                       hunks.indices.contains(hunk) {
                                        hunkBar(hunks[hunk], all: hunks)
                                    }
                                    DiffRowView(row: row, base: base, current: current,
                                                baseSpans: session.baseSpans, currentSpans: session.currentSpans,
                                                isSelected: selection.contains(row.pair),
                                                onToggle: row.hunk == nil || !canEdit ? nil : {
                                                    if selection.remove(row.pair) == nil { selection.insert(row.pair) }
                                                },
                                                onExpand: {
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
        .task(id: [session.baseVersion, session.currentVersion]) {
            await session.refreshCompare()
            await session.refreshHighlights()
        }
        // Rows are line numbers: after the text or the index changes they may mean other lines.
        .onChange(of: [session.baseVersion, session.currentVersion]) { selection = [] }
    }

    private var emptyDescription: String {
        switch session.mode {
        case .workingTree: "The file matches the staged version."
        case .staged: "The staged version matches the last commit."
        case .commit: "This commit didn't change the file's content."
        case .compare: "The file matches this commit's version."
        }
    }

    /// Actions for one change, above its lines.
    private func hunkBar(_ hunk: DiffHunk, all hunks: [DiffHunk]) -> some View {
        let picked = selection.intersection(LineDiff.pairs(in: hunk))
        return HStack(spacing: 12) {
            if picked.isEmpty {
                Text("Click line numbers to pick lines").foregroundStyle(.tertiary)
            } else {
                Button("Clear", systemImage: "xmark") { selection.subtract(picked) }
                    .labelStyle(.titleOnly)
            }
            Spacer()
            if !picked.isEmpty {
                let count = "\(selection.count) Selected Line\(selection.count == 1 ? "" : "s")"
                if isStaged {
                    Button("Unstage \(count)", systemImage: "minus.square") { workspace.unstageRows(selection, in: session) }
                        .help("Remove the selected lines (in every change) from the staged version")
                } else if let document = session.document {
                    let rows = selection
                    Button("Revert \(count)", systemImage: "arrow.uturn.backward.square") {
                        workspace.revertRows(of: document) { $0 == hunks ? rows : nil }
                    }
                    .help("Revert only the selected lines to the staged version (undoable)")
                    Button("Stage \(count)", systemImage: "plus.square") {
                        // Only if the diff is still the one the rows were picked from.
                        workspace.stageRows(of: document) { $0 == hunks ? rows : nil }
                    }
                    .help("Stage only the selected lines (in every change)")
                }
            }
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
            Text(session.sideLabels.base).font(.caption.weight(.semibold).monospaced()).foregroundStyle(.secondary)
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
            if canEdit {
                Button {
                    workspace.openChanges(for: session.url, staged: !isStaged)
                } label: { Image(systemName: isStaged ? "pencil.and.list.clipboard" : "tray.full") }
                    .help(isStaged ? "Show Working Tree Changes" : "Show Staged Changes")
            }
            Button {
                workspace.open(fileAt: session.url)
            } label: { Image(systemName: "doc.text") }
                .help("Open File")
            Text(session.sideLabels.current).font(.caption.weight(.semibold).monospaced()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .themedBackground(.tabBar, fallback: .bar)
    }
}

extension DiffRow {
    var pair: DiffLinePair { DiffLinePair(old: old, new: new) }

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
    let baseSpans: [[LineSpan]]?
    let currentSpans: [[LineSpan]]?
    var isSelected = false
    /// Picks or unpicks the row (changed rows only).
    var onToggle: (() -> Void)? = nil
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
            let oldText = text(row.old, base), newText = text(row.new, current)
            // A changed line pair: mark the words that differ, more strongly than the line.
            let words = row.kind == .changed ? WordDiff.changes(old: oldText ?? "", new: newText ?? "") : (old: [], new: [])
            HStack(spacing: 0) {
                side(line: row.old, text: oldText, spans: baseSpans, words: words.old,
                     tint: row.kind == .removed || row.kind == .changed ? .red : nil)
                Divider()
                side(line: row.new, text: newText, spans: currentSpans, words: words.new,
                     tint: row.kind == .added || row.kind == .changed ? .green : nil)
            }
            // Long lines wrap (so every change is visible); both sides take the taller height.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func text(_ line: Int?, _ lines: [Substring]) -> String? {
        line.flatMap { lines.indices.contains($0) ? String(lines[$0]) : nil }
    }

    private func side(line: Int?, text: String?, spans: [[LineSpan]]?, words: [NSRange], tint: Color?) -> some View {
        let lineSpans = line.flatMap { spans?.indices.contains($0) == true ? spans?[$0] : nil }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(line.map { String($0 + 1) } ?? "")
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .fontWeight(isSelected ? .bold : nil)
                .frame(width: 44, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { onToggle?() }
                .help(onToggle == nil ? "" : (isSelected ? "Unpick this line" : "Pick this line to stage it alone"))
            Text(DiffLineStyle.attributed(text ?? "", spans: lineSpans, words: words, wordTint: tint?.opacity(0.4)))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .font(Font(EditorTheme.font))
        .padding(.vertical, 1)
        .background(line == nil ? Color.secondary.opacity(0.06) : (tint?.opacity(isSelected ? 0.3 : 0.15) ?? .clear))
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
    }
}
