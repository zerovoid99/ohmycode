import AppKit
import Observation

/// State of the Find in Files panel: re-runs the search (debounced, cancelling the previous
/// run) as the query or options change, and collects streamed results.
@MainActor
@Observable
final class SearchModel {
    var options = SearchOptions() {
        didSet { if options != oldValue { schedule() } }
    }
    private(set) var results: [SearchFileResult] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    /// Bumped to move keyboard focus into the query field (⇧⌘F).
    private(set) var focusRequest = 0
    /// Replace field: editing it only changes the previews, it doesn't search again.
    var replacement = ""
    var showsReplace = false
    private(set) var isReplacing = false
    @ObservationIgnored private var previewRegex: (SearchOptions, NSRegularExpression)?

    /// Weak: work still in flight when the window closes goes to a closed workspace (does nothing).
    @ObservationIgnored private weak var owner: Workspace?
    private var workspace: Workspace { owner ?? Workspace.closed }
    @ObservationIgnored private var task: Task<Void, Never>?

    init(workspace: Workspace) {
        self.owner = workspace
    }

    /// With several folders, their labels (results' paths start with them; "label/**" in the
    /// include filter searches one folder).
    var folderLabels: [String] { workspace.isMultiRoot ? workspace.roots.folders.map(\.label) : [] }

    var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }
    var isTruncated: Bool { matchCount >= TextSearch.maxResults }

    func focus(prefill: String?, replace: Bool = false) {
        if let prefill, !prefill.isEmpty, !prefill.contains("\n") { options.query = prefill }
        if replace { showsReplace = true }
        focusRequest += 1
    }

    /// Search again with the same options (e.g. after files changed).
    func refresh() { schedule(delay: .zero) }

    private func schedule(delay: Duration = .milliseconds(200)) {
        task?.cancel()
        errorMessage = nil
        guard !options.query.isEmpty, !workspace.folders.isEmpty else {
            results = []
            isSearching = false
            return
        }
        let options = options
        let roots = workspace.roots
        isSearching = true
        task = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let files = await workspace.searchableFiles()
            // Unsaved editors are searched as they are on screen, not as on disk.
            var overrides: [String: String] = [:]
            for document in workspace.documents where document.isDirty {
                if let path = workspace.relativePath(of: document.url) {
                    overrides[path] = document.textStorage.mutableString as String
                }
            }
            // Batches are sorted in as they arrive, off the main thread, and shown at most ten
            // times a second: the list is laid out again for every new `results` (20,000 files
            // in 64 batches: 3.7 s of the main thread).
            let collected = SortedResults()
            results = []
            do {
                try await TextSearch.search(options, roots: roots, files: files, overrides: overrides) { batch in
                    guard let snapshot = collected.add(batch) else { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        self.results = snapshot
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            if results.count != collected.all.count { results = collected.all }
            isSearching = false
        }
    }

    /// Opens the file and selects the match.
    func open(_ result: SearchFileResult, _ match: SearchMatch) {
        workspace.open(result, match)
    }

    // MARK: Replace

    /// What `match` would become (regex groups expanded), for the preview.
    func replacementPreview(for match: SearchMatch) -> String {
        let template = TextSearch.template(replacement, regex: options.regex)
        guard options.regex else { return replacement }
        let regex: NSRegularExpression
        if let (cachedOptions, cached) = previewRegex, cachedOptions == options {
            regex = cached
        } else if let built = try? TextSearch.replacementRegex(options) {
            previewRegex = (options, built)
            regex = built
        } else {
            return replacement
        }
        // Lookarounds can't see outside the line; the real replacement uses the whole file.
        let preview = match.preview as NSString
        guard NSMaxRange(match.previewRange) <= preview.length,
              let found = regex.firstMatch(in: match.preview, range: match.previewRange) else { return replacement }
        return regex.replacementString(for: found, in: match.preview, offset: 0, template: template)
    }

    /// Replace All: computes every replacement and shows them for review before applying.
    @discardableResult
    func replaceAll() -> Task<Void, Never>? {
        guard !results.isEmpty else { return nil }
        return buildPreview(for: results, only: nil) { [weak self] preview in self?.workspace.review(preview) }
    }

    /// Replaces all matches in one file (no review: it's what the button says).
    @discardableResult
    func replace(in result: SearchFileResult) -> Task<Void, Never>? {
        buildPreview(for: [result], only: nil) { [weak self] preview in self?.workspace.apply(preview) }
    }

    /// Replaces a single match.
    @discardableResult
    func replace(_ match: SearchMatch, in result: SearchFileResult) -> Task<Void, Never>? {
        buildPreview(for: [result], only: match) { [weak self] preview in self?.workspace.apply(preview) }
    }

    /// Finds the matches again in each file's current text (results may be stale), so only
    /// text that still matches is replaced. Files on disk are read and matched off the main thread.
    private func buildPreview(for files: [SearchFileResult], only match: SearchMatch?,
                              then handle: @escaping @MainActor (EditPreview) -> Void) -> Task<Void, Never>? {
        guard !isReplacing else { return nil }
        let options = options
        let replacement = replacement
        let template = TextSearch.template(replacement, regex: options.regex)
        do {
            _ = try TextSearch.replacementRegex(options)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        isReplacing = true
        // Open documents are read here, as they are on screen; other files in the background.
        let inputs: [(url: URL, path: String, text: String?)] = files.map { file in
            (file.url, file.path, workspace.document(matching: file.url).map { $0.textStorage.mutableString as String })
        }
        return Task {
            let computed = await Task.detached(priority: .userInitiated) {
                SearchModel.replacements(inputs, options: options, template: template, only: match)
            }.value
            let count = computed.reduce(0) { $0 + $1.edits.count }
            let preview = EditPreview(
                title: "Replace \(count) occurrence\(count == 1 ? "" : "s") of “\(options.query)” with “\(replacement)”",
                actionName: "Replace",
                files: computed.map { EditPreview.FileEdit(url: $0.url, path: $0.path, edits: $0.edits, baseText: $0.text) })
            preview.onApplied = { [weak self = self] in self?.refresh() }
            isReplacing = false
            handle(preview)
            await self.task?.value // the search refreshed by an immediate apply
        }
    }

    nonisolated private static func replacements(_ inputs: [(url: URL, path: String, text: String?)], options: SearchOptions,
                                                 template: String, only match: SearchMatch?)
        -> [(url: URL, path: String, text: String, edits: [TextReplacement])] {
        guard let regex = try? TextSearch.replacementRegex(options) else { return [] }
        return inputs.compactMap { input in
            guard let text = input.text ?? (try? String(contentsOf: input.url, encoding: .utf8)) else { return nil }
            var edits = TextSearch.replacements(in: text, regex: regex, template: template)
            if let match {
                let start = LineIndex(string: text as NSString).offset(
                    for: LSPPosition(line: match.line, character: match.column), length: (text as NSString).length)
                edits = edits.filter { $0.range.location == start }
            }
            return edits.isEmpty ? nil : (input.url, input.path, text, edits)
        }
    }

    /// Waits for the current search (tests).
    func waitUntilDone() async {
        await task?.value
    }
}

/// A search's results so far, sorted by path. Used from one place at a time: the search's
/// batches arrive one after another, and the model reads it when the search is over.
private final class SortedResults: @unchecked Sendable {
    static let interval: Duration = .milliseconds(100)
    private(set) var all: [SearchFileResult] = []
    private var shown: ContinuousClock.Instant?

    /// Merges a batch in; returns everything when it's time to show it (the first batch at
    /// once, then every `interval`).
    func add(_ batch: [SearchFileResult]) -> [SearchFileResult]? {
        func precedes(_ a: SearchFileResult, _ b: SearchFileResult) -> Bool {
            a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        let new = batch.sorted(by: precedes)
        var merged: [SearchFileResult] = []
        merged.reserveCapacity(all.count + new.count)
        var i = 0, j = 0
        while i < all.count, j < new.count {
            if precedes(new[j], all[i]) { merged.append(new[j]); j += 1 } else { merged.append(all[i]); i += 1 }
        }
        merged.append(contentsOf: all[i...])
        merged.append(contentsOf: new[j...])
        all = merged
        let now = ContinuousClock.now
        if let shown, now - shown < Self.interval { return nil }
        shown = now
        return all
    }
}
