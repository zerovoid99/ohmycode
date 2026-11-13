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
    /// Replaces the Replace All confirmation (tests): gets match and file counts.
    @ObservationIgnored var confirmReplaceAll: ((Int, Int) -> Bool)?
    @ObservationIgnored private var previewRegex: (SearchOptions, NSRegularExpression)?

    @ObservationIgnored private unowned let workspace: Workspace
    @ObservationIgnored private var task: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

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
        guard !options.query.isEmpty, let root = workspace.rootURL else {
            results = []
            isSearching = false
            return
        }
        let options = options
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
            var collected: [SearchFileResult] = []
            results = []
            do {
                try await TextSearch.search(options, root: root, files: files, overrides: overrides) { batch in
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        collected.append(contentsOf: batch)
                        collected.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                        self.results = collected
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
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

    /// Replaces every match in every result file (after confirming).
    @discardableResult
    func replaceAll() -> Task<Void, Never>? {
        guard !results.isEmpty else { return nil }
        let files = results.count, matches = matchCount
        let confirmed = confirmReplaceAll.map { $0(matches, files) } ?? {
            let alert = NSAlert()
            alert.messageText = "Replace \(matches) occurrence\(matches == 1 ? "" : "s") across \(files) file\(files == 1 ? "" : "s") with “\(replacement)”?"
            alert.informativeText = "Open files can be restored with Undo. Files that aren't open are changed on disk."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }()
        guard confirmed else { return nil }
        return replace(in: results, only: nil)
    }

    /// Replaces all matches in one file.
    @discardableResult
    func replace(in result: SearchFileResult) -> Task<Void, Never>? {
        replace(in: [result], only: nil)
    }

    /// Replaces a single match.
    @discardableResult
    func replace(_ match: SearchMatch, in result: SearchFileResult) -> Task<Void, Never>? {
        replace(in: [result], only: match)
    }

    /// Matches are found again in each file's current text (the results may be stale), so
    /// only text that still matches is replaced.
    private func replace(in files: [SearchFileResult], only match: SearchMatch?) -> Task<Void, Never>? {
        guard !isReplacing else { return nil }
        let options = options
        let template = TextSearch.template(replacement, regex: options.regex)
        let regex: NSRegularExpression
        do {
            regex = try TextSearch.replacementRegex(options)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        task?.cancel()
        isReplacing = true

        var closedFiles: [URL] = []
        var failures: [String] = []
        for file in files {
            guard let document = workspace.document(matching: file.url) else {
                closedFiles.append(file.url)
                continue
            }
            let text = document.textStorage.mutableString as String
            var edits = TextSearch.replacements(in: text, regex: regex, template: template)
            if let match {
                let start = document.offset(for: LSPPosition(line: match.line, character: match.column))
                edits = edits.filter { $0.range.location == start }
            }
            do {
                try document.apply(edits, actionName: "Replace")
            } catch {
                failures.append(file.path)
            }
        }

        let urls = closedFiles
        return Task {
            let diskFailures = await Task.detached(priority: .userInitiated) {
                SearchModel.replaceOnDisk(urls, options: options, template: template, only: match)
            }.value
            failures += diskFailures.compactMap { workspace.relativePath(of: $0) }
            isReplacing = false
            if !failures.isEmpty { errorMessage = "Couldn't replace in \(failures.joined(separator: ", "))" }
            refresh()
            await self.task?.value
        }
    }

    /// Rewrites files that aren't open. Returns the files that failed.
    nonisolated private static func replaceOnDisk(_ urls: [URL], options: SearchOptions, template: String,
                                                  only match: SearchMatch?) -> [URL] {
        guard !urls.isEmpty, let regex = try? TextSearch.replacementRegex(options) else { return urls }
        var failed: [URL] = []
        for url in urls {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                var edits = TextSearch.replacements(in: text, regex: regex, template: template)
                if let match {
                    let start = LineIndex(string: text as NSString).offset(
                        for: LSPPosition(line: match.line, character: match.column), length: (text as NSString).length)
                    edits = edits.filter { $0.range.location == start }
                }
                let updated = try TextReplacement.apply(edits, to: text)
                if updated != text { try Workspace.write(updated, to: url) }
            } catch {
                failed.append(url)
            }
        }
        return failed
    }

    /// Waits for the current search (tests).
    func waitUntilDone() async {
        await task?.value
    }
}
