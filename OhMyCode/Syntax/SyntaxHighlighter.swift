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
///
/// A syntax tree takes about 50 times the text's size, so a long file is parsed a window at a
/// time: the part on screen and some way around it, starting and ending at top-level lines.
/// Scrolling out of it parses a new window; edits inside it reparse incrementally.
@MainActor
final class SyntaxHighlighter {
    /// Files longer than this (UTF-16 units) are parsed a window at a time.
    static let windowThreshold = 1_000_000
    /// How far a window reaches beyond what's on screen, each way.
    static let windowMargin = 128 * 1024
    /// Clients' ranges (editor, minimap, sticky scroll) share one window when they fit in this.
    static let maxSharedWindow = 512 * 1024
    /// How far to look for a top-level line to start or end a window at.
    nonisolated static let boundarySearchLimit = 16 * 1024

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

    /// Whether the file is parsed a window at a time (decided when it opens).
    let isWindowed: Bool
    /// The part of the text the engine's tree covers (kept in step with edits); nil when
    /// nothing is parsed yet, or an edit crossed its edge.
    private(set) var window: NSRange?
    /// Tree-sitter's row and column for a text offset (the document's line index gives it
    /// quickly; without it, lines are counted).
    var pointProvider: ((Int) -> Point)?

    init?(language: SourceLanguage, textStorage: NSTextStorage) {
        if language == .http {
            engine = SyntaxEngine(lineHighlighter: HTTPSyntax.highlights(in:range:))
        } else {
            guard let grammar = GrammarRegistry.grammar(for: language),
                  let engine = SyntaxEngine(grammar: grammar)
            else { return nil }
            self.engine = engine
        }
        self.textStorage = textStorage
        isWindowed = textStorage.length > Self.windowThreshold
        schedule() // initial parse, in the background (a window waits for something on screen)
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
        if let current = window {
            let start = Int(edit.startByte / 2), oldEnd = Int(edit.oldEndByte / 2), newEnd = Int(edit.newEndByte / 2)
            if oldEnd < current.location {
                window = NSRange(location: current.location + newEnd - oldEnd, length: current.length)
            } else if start > NSMaxRange(current) {
                // After it: nothing to do.
            } else if start >= current.location, oldEnd <= NSMaxRange(current) {
                window = NSRange(location: current.location, length: current.length + newEnd - oldEnd)
            } else {
                window = nil // across its edge: the next job parses a new one
            }
        }
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

    /// See `SyntaxEngine.enclosingScopeLines`. Uses the latest parsed tree (no waiting).
    func enclosingScopeLines(line: Int, lineStart: Int) async -> [Int] {
        await engine.enclosingScopeLines(line: line, lineStart: lineStart)
    }

    /// Highlights from the latest parsed tree, without waiting for pending edits (sticky
    /// scroll and other secondary views that tolerate a frame of lag).
    func currentHighlights(in range: NSRange) async -> [NamedRange] {
        await engine.highlights(in: range)
    }

    /// The file's declarations, from the parse of its current text.
    func outline(for language: SourceLanguage) async -> [DocumentSymbol] {
        await waitUntilIdle()
        return await engine.outline(for: language)
    }

    /// See `SyntaxEngine.foldRegions`: from the parse of the current text.
    func foldRegions() async -> [FoldRegion] {
        await waitUntilIdle()
        return await engine.foldRegions()
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

        var snapshot: TextSnapshot?
        var parseWindow: TSRange?
        var reset = false
        if isWindowed {
            if let range, window.map({ NSIntersectionRange($0, range) != range }) ?? true {
                window = makeWindow(containing: range)
                reset = true
            }
            guard let window else { pendingEdits.removeAll(); return } // nothing on screen yet
            guard reset || !pendingEdits.isEmpty || range != nil else { return }
            if reset || !pendingEdits.isEmpty {
                snapshot = TextSnapshot(string: textStorage.mutableString.substring(with: window) as NSString,
                                        offset: window.location)
                parseWindow = TSRange(points: point(at: window.location)..<point(at: NSMaxRange(window)),
                                      bytes: UInt32(window.location * 2)..<UInt32(NSMaxRange(window) * 2))
            }
        } else {
            guard needsParse || range != nil else { return }
            // Copying is one memcpy, and happens at most once per job rather than per keystroke.
            snapshot = needsParse ? TextSnapshot(string: textStorage.mutableString.copy() as! NSString) : nil
        }

        let edits = pendingEdits
        pendingEdits.removeAll()
        let jobGeneration = generation

        inFlight = Task { [engine] in
            let highlights = await engine.process(snapshot: snapshot, edits: edits, highlightRange: range,
                                                  window: parseWindow, reset: reset)
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

    // MARK: Windows

    /// A window around `range`, and around the other clients' ranges when they're close.
    private func makeWindow(containing range: NSRange) -> NSRange {
        let text = textStorage.mutableString
        var lower = range.location, upper = NSMaxRange(range)
        for client in liveClients {
            guard let other = client.highlightRange else { continue }
            let merged = (min(lower, other.location), max(upper, NSMaxRange(other)))
            if merged.1 - merged.0 <= Self.maxSharedWindow { (lower, upper) = merged }
        }
        let start = Self.boundary(in: text, near: max(0, lower - Self.windowMargin), backward: true)
        let end = Self.boundary(in: text, near: min(text.length, upper + Self.windowMargin), backward: false)
        return NSRange(location: start, length: end - start)
    }

    /// A line start near `offset` (searching back or forward) where a top-level declaration
    /// or comment likely starts, so the window parses as whole declarations; else any line
    /// start found, else `offset` itself (one huge line).
    nonisolated static func boundary(in text: NSString, near offset: Int, backward: Bool) -> Int {
        let length = text.length
        guard offset > 0 else { return 0 }
        guard offset < length else { return length }
        var lineStart: Int?
        var position = offset
        for _ in 0..<boundarySearchLimit {
            if position <= 0 { return 0 }
            if position >= length { return length }
            if text.character(at: position - 1) == 0x0A {
                if lineStart == nil { lineStart = position }
                if isTopLevelStart(text.character(at: position)) { return position }
            }
            position += backward ? -1 : 1
        }
        return lineStart ?? offset
    }

    /// A letter, `_`, `@`, `#` or `/` in the first column.
    private nonisolated static func isTopLevelStart(_ unit: unichar) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit == 0x40 || unit == 0x23 || unit == 0x2F
    }

    private func point(at offset: Int) -> Point {
        if let pointProvider { return pointProvider(offset) }
        let text = textStorage.mutableString
        var row = 0, lineStart = 0, position = 0
        while position < offset {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: position, length: offset - position))
            guard found.location != NSNotFound else { break }
            row += 1
            lineStart = NSMaxRange(found)
            position = lineStart
        }
        return Point(row: row, column: (offset - lineStart) * 2)
    }
}
