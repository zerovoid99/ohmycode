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
        /// The two sides of a merge conflict, as they were when compared.
        case conflict(ConflictComparison)
        /// A version from the local history against the editor's text (live, like compare).
        case history(LocalHistoryEntry)
        /// A change a coding agent proposes: the file's text against the proposed text, fixed.
        case proposed(ProposedChange)
        /// Compare files: another file, the clipboard or the saved file against the editor's text
        /// (live, like compare), or two binary files.
        case files(FileComparison)
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

    init(document: EditorDocument, ownsDocument: Bool, comparingWithHistory entry: LocalHistoryEntry) {
        mode = .history(entry)
        url = document.url
        self.document = document
        self.ownsDocument = ownsDocument
    }

    /// Compares the editor's text with another file, the clipboard or the saved file.
    init(document: EditorDocument, ownsDocument: Bool, comparing comparison: FileComparison) {
        mode = .files(comparison)
        url = document.url
        self.document = document
        self.ownsDocument = ownsDocument
    }

    /// Two files that aren't both text: only whether they're the same is shown.
    init(binary comparison: FileComparison, of url: URL, identical: Bool) {
        mode = .files(comparison)
        self.url = url
        document = nil
        ownsDocument = false
        binaryDifference = !identical
        isLoaded = true
    }

    /// Set when the files aren't text: whether they differ.
    private(set) var binaryDifference: Bool?

    /// Loaded text on the left against the live document on the right (compare, history).
    var isLiveComparison: Bool {
        switch mode {
        case .compare, .history: true
        case .files: document != nil
        default: false
        }
    }

    private static func short(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .shortened) }

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

    /// A proposed change's tab: accepted or rejected with `decide` when `onDecision` is set
    /// (the agent waits for the answer), else only shown.
    init(proposed change: ProposedChange, of url: URL, onDecision: ((Bool) -> Void)? = nil) {
        mode = .proposed(change)
        self.url = url
        document = nil
        ownsDocument = false
        self.onDecision = onDecision
        setLoaded(base: change.old ?? "", current: change.new, isNewFile: change.old == nil)
    }

    /// Answers a proposed change (once); closing its tab undecided rejects it.
    @ObservationIgnored private var onDecision: ((Bool) -> Void)?
    /// Waiting for Accept or Reject.
    var awaitsDecision: Bool { onDecision != nil }

    func decide(_ accept: Bool) {
        guard let onDecision else { return }
        self.onDecision = nil
        decisionVersion += 1
        onDecision(accept)
    }

    /// Bumped when the change is decided (the header's buttons go).
    private(set) var decisionVersion = 0

    init(conflict: ConflictComparison, of url: URL) {
        mode = .conflict(conflict)
        self.url = url
        document = nil
        ownsDocument = false
        setLoaded(base: conflict.current, current: conflict.incoming, isNewFile: false)
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
        case .history(let entry): "\(fileName) (\(Self.short(entry.date)) ↔ Current)"
        case .conflict: "\(fileName) (Current ↔ Incoming)"
        case .proposed(let change): change.title.isEmpty ? "\(fileName) (Proposed)" : change.title
        case .files(let comparison): comparison.title(right: url)
        }
    }

    var help: String {
        switch mode {
        case .workingTree: "\(url.path) — staged ↔ working tree"
        case .staged: "\(url.path) — HEAD ↔ staged"
        case .commit(let commit): "\(url.path) — \(commit.summary) (\(commit.shortSHA))"
        case .compare(let commit): "\(url.path) — \(commit.shortSHA) ↔ working tree"
        case .history(let entry): "\(url.path) — local history (\(entry.reason.title), \(Self.short(entry.date))) ↔ current"
        case .conflict(let conflict): "\(url.path) — merge conflict: \(conflict.currentLabel) ↔ \(conflict.incomingLabel)"
        case .proposed(let change): "\(url.path) — proposed by \(change.source)"
        case .files(.file(let left)): "\(left.path) ↔ \(url.path)"
        case .files(.clipboard): "Clipboard ↔ \(url.path)"
        case .files(.saved): "\(url.path) — saved ↔ edited"
        }
    }

    /// Names of the two sides, for the header.
    var sideLabels: (base: String, current: String) {
        switch mode {
        case .workingTree: ("Staged", "Working Tree")
        case .staged: ("HEAD", "Staged")
        case .commit(let commit): (commit.parents.first.map { String($0.prefix(7)) } ?? "(none)", commit.shortSHA)
        case .compare(let commit): (commit.shortSHA, "Working Tree")
        case .history(let entry): ("\(entry.reason.title) \(Self.short(entry.date))", "Current")
        case .conflict(let conflict): ("Current: \(conflict.currentLabel)", "Incoming: \(conflict.incomingLabel)")
        case .proposed(let change): (change.old == nil ? "(new file)" : "Current", "Proposed by \(change.source)")
        case .files(.file(let left)): { let names = FileComparison.distinctNames(left, url); return (names.left, names.right) }()
        case .files(.clipboard): ("Clipboard", fileName)
        case .files(.saved): ("Saved", "Edited")
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
        case .compare, .history: compareHunks
        case .files: isLiveComparison ? compareHunks : loadedHunks
        case .staged, .commit, .conflict, .proposed: loadedHunks
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
        guard isLiveComparison, let document, let base = loadedBase else { return }
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
            if let differ = session.binaryDifference {
                ContentUnavailableView(differ ? "Binary Files Differ" : "Binary Files Are Identical", systemImage: "doc.on.doc",
                                       description: Text(differ ? "The files aren't text, so only that they differ is shown."
                                                         : "The files aren't text; their bytes are the same."))
            } else if session.baseLines == nil {
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
        case .history: "The file matches this saved version."
        case .conflict: "Both sides of the conflict are the same."
        case .proposed: "The proposed text is the same as the file's."
        case .files(.clipboard): "The file matches the clipboard."
        case .files(.saved): "The edits leave the file as it's saved."
        case .files(.file): "The files have the same content."
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
            if session.binaryDifference == nil { HStack(spacing: 6) {
                Text("+\(added)").foregroundStyle(.green)
                Text("−\(removed)").foregroundStyle(.red)
                Text("~\(changed)").foregroundStyle(.orange)
            }
            .font(.caption.monospacedDigit())
            Button { currentChange = max(0, currentChange - 1) } label: { Image(systemName: "arrow.up") }
                .help("Previous Change").disabled(count == 0)
            Button { currentChange = min(count - 1, currentChange + 1) } label: { Image(systemName: "arrow.down") }
                .help("Next Change").disabled(count == 0)
            }
            if canEdit {
                Button {
                    workspace.openChanges(for: session.url, staged: !isStaged)
                } label: { Image(systemName: isStaged ? "pencil.and.list.clipboard" : "tray.full") }
                    .help(isStaged ? "Show Working Tree Changes" : "Show Staged Changes")
            }
            if case .files(.file) = session.mode {
                Button { workspace.swapSides(of: session) } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Swap Sides")
            }
            Button {
                workspace.open(fileAt: session.url)
            } label: { Image(systemName: "doc.text") }
                .help("Open File")
            if session.awaitsDecision {
                Button("Reject") { session.decide(false) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Turn the change down")
                Button("Accept") { session.decide(true) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("Let the agent make the change")
            }
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
        guard let line, lines.indices.contains(line) else { return nil }
        // A CRLF line keeps its "\r" (see `LineDiff.lines`); shown, it would break the row.
        let scalars = lines[line].unicodeScalars
        return String(Substring(scalars.last == "\r" ? scalars.dropLast() : scalars[...]))
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

/// A change a coding agent proposes to a file, for a diff tab.
struct ProposedChange: Hashable, Sendable {
    let id = UUID()
    /// The tab's title (empty: the file's name).
    let title: String
    /// Who proposes it ("Claude Code").
    let source: String
    /// The file's text now (nil: it doesn't exist yet).
    let old: String?
    let new: String
}

/// A merge conflict's two sides, for a diff tab.
struct ConflictComparison: Hashable, Sendable {
    let current: String
    let incoming: String
    let currentLabel: String
    let incomingLabel: String
}

/// What a file is compared with (Compare Files): the left side of the diff tab.
enum FileComparison: Hashable, Sendable {
    /// Another file (its text when compared).
    case file(URL)
    /// The clipboard's text when compared.
    case clipboard
    /// The file as it is on disk, against its unsaved edits.
    case saved

    /// The tab's title for `right` compared with this: "a.swift ↔ b.swift" (with their folders
    /// when the names are the same), "a.swift (Clipboard)", "a.swift (Saved ↔ Edited)".
    func title(right: URL) -> String {
        switch self {
        case .file(let left):
            let names = Self.distinctNames(left, right)
            return "\(names.left) ↔ \(names.right)"
        case .clipboard: return "\(right.lastPathComponent) (Clipboard)"
        case .saved: return "\(right.lastPathComponent) (Saved ↔ Edited)"
        }
    }

    /// Names for two files or folders that tell them apart: their own names, or with the same
    /// name, the nearest folders above them that differ ("left/main.swift", "a/…/main.swift").
    static func distinctNames(_ left: URL, _ right: URL) -> (left: String, right: String) {
        let a = left.lastPathComponent, b = right.lastPathComponent
        let above = (left: Array(left.deletingLastPathComponent().pathComponents.reversed()),
                     right: Array(right.deletingLastPathComponent().pathComponents.reversed()))
        guard a == b, let depth = zip(above.left, above.right).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset else { return (a, b) }
        let gap = depth == 0 ? "/" : "/…/"
        return (above.left[depth] + gap + a, above.right[depth] + gap + b)
    }
}
