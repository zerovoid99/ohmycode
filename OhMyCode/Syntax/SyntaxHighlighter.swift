import AppKit
import SwiftTreeSitter

/// Receives highlights computed in the background.
@MainActor
protocol SyntaxHighlighterClient: AnyObject {
    /// Range to highlight now (visible text plus overscan), or nil if nothing is on screen.
    var highlightRange: NSRange? { get }
    func applyHighlights(_ highlights: [NamedRange], in range: NSRange)
}

/// Main-thread side of syntax highlighting. Per keystroke it only records the edit; parsing and
/// querying run in `SyntaxEngine`. At most one job is in flight: edits arriving meanwhile are
/// batched into the next job, and results for text that has since changed are dropped.
@MainActor
final class SyntaxHighlighter {
    /// Files above this size open as plain text.
    static let maxFileLength = 8 * 1024 * 1024

    weak var client: SyntaxHighlighterClient? {
        didSet { requestHighlights() }
    }

    private let engine: SyntaxEngine
    private let textStorage: NSTextStorage
    private var pendingEdits: [InputEdit] = []
    private var hasParsed = false
    private var wantsHighlights = false
    /// Bumped on every edit; a job's result is only applied if no edit happened since it started.
    private var generation = 0
    private var inFlight: Task<Void, Never>?

    init?(language: SourceLanguage, textStorage: NSTextStorage) {
        guard textStorage.length <= Self.maxFileLength,
              let grammar = GrammarRegistry.grammar(for: language),
              let engine = SyntaxEngine(grammar: grammar)
        else { return nil }
        self.engine = engine
        self.textStorage = textStorage
        schedule() // initial parse, in the background
    }

    func didEdit(_ edit: InputEdit) {
        pendingEdits.append(edit)
        generation += 1
        schedule()
    }

    /// Re-highlight the client's current range (e.g. after scrolling).
    func requestHighlights() {
        wantsHighlights = true
        schedule()
    }

    /// Waits for all scheduled work, then returns highlights for `range` (for tests and tools).
    func highlights(in range: NSRange) async -> [NamedRange] {
        await waitUntilIdle()
        return await engine.highlights(in: range)
    }

    func waitUntilIdle() async {
        while let inFlight { await inFlight.value }
    }

    private func schedule() {
        guard inFlight == nil else { return }
        let needsParse = !hasParsed || !pendingEdits.isEmpty
        let range = (needsParse || wantsHighlights) ? client?.highlightRange : nil
        guard needsParse || range != nil else { return }

        let edits = pendingEdits
        pendingEdits.removeAll()
        wantsHighlights = false
        // Copying is one memcpy, and happens at most once per job rather than per keystroke.
        let snapshot = needsParse ? TextSnapshot(string: textStorage.mutableString.copy() as! NSString) : nil
        let jobGeneration = generation

        inFlight = Task { [engine] in
            let highlights = await engine.process(snapshot: snapshot, edits: edits, highlightRange: range)
            self.inFlight = nil
            self.hasParsed = true
            if jobGeneration == self.generation {
                if let range, let highlights { self.client?.applyHighlights(highlights, in: range) }
            } else {
                self.wantsHighlights = true // text changed meanwhile; highlight after the next parse
            }
            self.schedule()
        }
    }
}
