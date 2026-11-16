import AppKit

/// Highlights where the symbol under the cursor appears in the file: the language server's
/// document highlights (read and written places told apart) or, without one, the same whole
/// word. A selection on one line highlights the same text elsewhere.
@MainActor
final class OccurrenceHighlighter {
    nonisolated(unsafe) static var delay: Duration = .milliseconds(150)
    /// More matches than this (a one-letter name in a big file) aren't worth drawing.
    static let maxMatches = 2_000
    /// Selections longer than this aren't looked for.
    static let maxSelectionLength = 200

    /// Weak: it may close while a request is pending.
    private weak var editor: EditorController?
    private var task: Task<Void, Never>?
    /// What's highlighted now, in document order.
    private(set) var highlights: [(range: NSRange, kind: DocumentHighlight.Kind)] = []
    /// The edit the highlights belong to (stale after any edit).
    private var version = -1

    init(editor: EditorController) {
        self.editor = editor
    }

    var ranges: [NSRange] { highlights.map(\.range) }

    /// The cursor or selection moved (or the text changed): highlight again after a pause.
    func update() {
        task?.cancel()
        guard let editor, AppSettings.shared.highlightsOccurrences else { clear(); return }
        let document = editor.document
        let selection = editor.textView.selectedRange()
        // Still on a highlighted symbol (or one selected by Go to Next Highlight), nothing
        // edited: the highlights stay.
        if version == document.editVersion, highlights.contains(where: { highlight in
            selection.length == 0
                ? NSLocationInRange(selection.location, highlight.range) || NSMaxRange(highlight.range) == selection.location
                : highlight.range == selection
        }) {
            return
        }
        if version != document.editVersion { clear() }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self else { return }
            await self.compute(for: selection)
        }
    }

    /// Waits for the lookup in progress (tests).
    func waitForUpdate() async { await task?.value }

    func clear() {
        task?.cancel()
        guard !highlights.isEmpty else { return }
        highlights = []
        editor?.diagnosticsOverlay?.needsDisplay = true
    }

    private func compute(for selection: NSRange) async {
        guard let editor else { return }
        let document = editor.document
        let version = document.editVersion
        let text = document.textStorage.mutableString
        var found: [(NSRange, DocumentHighlight.Kind)] = []
        if selection.length > 0 {
            // A selection: the same text elsewhere (only a single word, for a symbol).
            guard selection.length <= Self.maxSelectionLength, NSMaxRange(selection) <= text.length else { clear(); return }
            let selected = text.substring(with: selection)
            guard !selected.contains(where: \.isNewline), !selected.allSatisfy(\.isWhitespace) else { clear(); return }
            let wholeWord = document.wordRange(at: selection.location) == selection
            found = document.ranges(of: selected, wholeWord: wholeWord, limit: Self.maxMatches).map { ($0, .text) }
            if found.count < 2 { found = [] }
        } else if let word = document.wordRange(at: selection.location) {
            if let client = document.languageClient, client.state == .ready, client.supports(.documentHighlight) {
                let position = document.lspPosition(at: selection.location)
                guard let result = try? await client.documentHighlights(url: document.url, position: position) else { return }
                // Moved or edited meanwhile: the newer request decides.
                guard !Task.isCancelled, version == document.editVersion,
                      editor.textView.selectedRange() == selection else { return }
                found = result.prefix(Self.maxMatches).map { (document.range(for: $0.range), $0.kind) }
                    .filter { $0.0.length > 0 && NSMaxRange($0.0) <= text.length }
            } else {
                let name = text.substring(with: word)
                // Numbers aren't symbols.
                if let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) {
                    found = document.ranges(of: name, wholeWord: true, limit: Self.maxMatches).map { ($0, .text) }
                }
                if found.count < 2 { found = [] }
            }
        }
        guard !Task.isCancelled else { return }
        found.sort { $0.0.location < $1.0.location }
        self.version = version
        let changed = found.map(\.0) != ranges || found.map(\.1) != highlights.map(\.kind)
        highlights = found.map { (range: $0.0, kind: $0.1) }
        if changed { editor.diagnosticsOverlay?.needsDisplay = true }
    }

    /// The next (or previous) highlight after the cursor, wrapping around.
    func target(forward: Bool, from selection: NSRange) -> NSRange? {
        let ranges = ranges
        guard !ranges.isEmpty else { return nil }
        if forward {
            return ranges.first { $0.location > selection.location } ?? ranges.first
        }
        return ranges.last { $0.location < selection.location } ?? ranges.last
    }
}

extension EditorDocument {
    /// Where `string` appears (as a whole word if asked), up to `limit` places.
    func ranges(of string: String, wholeWord: Bool, limit: Int) -> [NSRange] {
        var result: [NSRange] = []
        guard limit > 0 else { return result }
        // In chunks, the units around each place checked as they're read: `range(of:)` from
        // each place on, and two `wordRange(at:)`, took 1.9 s for a one-letter name in 20 MB.
        textStorage.mutableString.forEachOccurrence(of: string as NSString) { found, before, after in
            if !wholeWord || (!Self.isWordUnit(before) && !Self.isWordUnit(after)) {
                result.append(found)
            }
            return result.count < limit
        }
        return result
    }
}

extension EditorController {
    /// The highlights in view: their text's rects, and whether the symbol is written there.
    func occurrenceRects() -> [(rect: NSRect, isWrite: Bool)] {
        let highlights = occurrences.highlights
        guard !highlights.isEmpty, let visible = visibleCharacterRange() else { return [] }
        let selection = textView.selectedRange()
        var result: [(NSRect, Bool)] = []
        for highlight in highlights where NSIntersectionRange(highlight.range, visible).length > 0 {
            // The selected text is already shown as selected.
            if selection.length > 0, highlight.range == selection { continue }
            guard let rect = rect(for: highlight.range) else { continue }
            result.append((rect, highlight.kind == .write))
        }
        return result
    }

    /// Go to Next/Previous Highlight: selects the symbol's next place.
    func moveToOccurrence(forward: Bool) {
        guard let target = occurrences.target(forward: forward, from: textView.selectedRange()) else { NSSound.beep(); return }
        reveal(target)
    }
}
