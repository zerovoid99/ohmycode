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

    /// Editors showing the document (weak). Each gets highlights for its own viewport.
    private let clients = NSHashTable<AnyObject>.weakObjects()
    /// Clients whose highlights are out of date.
    private var staleClients = Set<ObjectIdentifier>()

    private let engine: SyntaxEngine
    private let textStorage: NSTextStorage
    private var pendingEdits: [InputEdit] = []
    private var hasParsed = false
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

    func addClient(_ client: SyntaxHighlighterClient) {
        clients.add(client)
        requestHighlights(for: client)
    }

    func removeClient(_ client: SyntaxHighlighterClient) {
        clients.remove(client)
        staleClients.remove(ObjectIdentifier(client))
    }

    func didEdit(_ edit: InputEdit) {
        pendingEdits.append(edit)
        generation += 1
        markAllStale()
        schedule()
    }

    /// Re-highlight a client's current range (e.g. after scrolling).
    func requestHighlights(for client: SyntaxHighlighterClient) {
        staleClients.insert(ObjectIdentifier(client))
        schedule()
    }

    private var liveClients: [SyntaxHighlighterClient] {
        clients.allObjects.compactMap { $0 as? SyntaxHighlighterClient }
    }

    private func markAllStale() {
        for client in liveClients { staleClients.insert(ObjectIdentifier(client)) }
    }

    /// Waits for all scheduled work, then returns highlights for `range` (for tests and tools).
    func highlights(in range: NSRange) async -> [NamedRange] {
        await waitUntilIdle()
        return await engine.highlights(in: range)
    }

    func waitUntilIdle() async {
        while let inFlight { await inFlight.value }
    }

    /// One job at a time: parse pending edits if any, and highlight the first stale client.
    /// When it finishes, the next stale client gets its own job (their viewports may be far apart).
    private func schedule() {
        guard inFlight == nil else { return }
        let needsParse = !hasParsed || !pendingEdits.isEmpty
        var target: SyntaxHighlighterClient?
        var range: NSRange?
        for client in liveClients where staleClients.contains(ObjectIdentifier(client)) {
            staleClients.remove(ObjectIdentifier(client))
            if let clientRange = client.highlightRange { // nil: nothing on screen
                target = client
                range = clientRange
                break
            }
        }
        staleClients.formIntersection(liveClients.map { ObjectIdentifier($0) })
        guard needsParse || range != nil else { return }

        let edits = pendingEdits
        pendingEdits.removeAll()
        // Copying is one memcpy, and happens at most once per job rather than per keystroke.
        let snapshot = needsParse ? TextSnapshot(string: textStorage.mutableString.copy() as! NSString) : nil
        let jobGeneration = generation

        inFlight = Task { [engine] in
            let highlights = await engine.process(snapshot: snapshot, edits: edits, highlightRange: range)
            self.inFlight = nil
            self.hasParsed = true
            if jobGeneration == self.generation {
                if let range, let highlights { target?.applyHighlights(highlights, in: range) }
            } else if let target {
                // Text changed meanwhile; highlight after the next parse.
                self.staleClients.insert(ObjectIdentifier(target))
            }
            self.schedule()
        }
    }
}
