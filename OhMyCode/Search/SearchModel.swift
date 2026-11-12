import Foundation
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

    @ObservationIgnored private unowned let workspace: Workspace
    @ObservationIgnored private var task: Task<Void, Never>?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }
    var isTruncated: Bool { matchCount >= TextSearch.maxResults }

    func focus(prefill: String?) {
        if let prefill, !prefill.isEmpty, !prefill.contains("\n") { options.query = prefill }
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
        workspace.open(fileAt: result.url)
        guard let document = workspace.activeDocument else { return }
        let start = document.offset(for: LSPPosition(line: match.line, character: match.column))
        document.reveal(NSRange(location: start, length: match.length))
    }

    /// Waits for the current search (tests).
    func waitUntilDone() async {
        await task?.value
    }
}
