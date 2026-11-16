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

    /// Files longer than this (UTF-16 units) are searched in view first, then in full off the
    /// main thread: a whole-file scan of 20 MB held it for 19–39 ms.
    var backgroundThreshold = 256 * 1024
    /// Units copied per turn of the run loop when copying the text for a background scan
    /// (about 0.4 ms each).
    static let snapshotSlice = 1 << 20
    /// Tests: called after a background scan, before its result is checked and shown.
    var willApplyBackgroundScan: (() -> Void)?

    /// The cursor or selection moved (or the text changed): highlight again after a pause.
    func update() {
        guard let editor, AppSettings.shared.highlightsOccurrences else { task?.cancel(); clear(); return }
        let document = editor.document
        let selection = editor.textView.selectedRange()
        // Still on a highlighted symbol (or one selected by Go to Next Highlight), nothing
        // edited: the highlights stay (and a scan of the rest of the file goes on).
        if version == document.editVersion, highlights.contains(where: { highlight in
            selection.length == 0
                ? NSLocationInRange(selection.location, highlight.range) || NSMaxRange(highlight.range) == selection.location
                : highlight.range == selection
        }) {
            return
        }
        task?.cancel()
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
        editor?.diagnosticsOverlay?.marksDidChange()
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
            guard let ranges = await find(selected, wholeWord: wholeWord, version: version, isCurrent: {
                editor.textView.selectedRange() == selection
            }) else { return }
            found = ranges.map { ($0, .text) }
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
                    // Still on the same word (anywhere in it): a scan that finishes after the
                    // cursor moved within the word is still right.
                    guard let ranges = await find(name, wholeWord: true, version: version, isCurrent: {
                        let current = editor.textView.selectedRange()
                        return current.length == 0 && document.wordRange(at: current.location) == word
                    }) else { return }
                    found = ranges.map { ($0, .text) }
                }
            }
        }
        guard !Task.isCancelled else { return }
        show(found, version: version)
    }

    /// Where `needle` appears (as a whole word if asked); nothing if only once. A small file is
    /// scanned at once. A big one is scanned in view first (shown right away), then whole, on a
    /// copy of the text, off the main thread. nil: the text changed, the task was cancelled, or
    /// `isCurrent` says the cursor moved on before the whole-file scan finished.
    private func find(_ needle: String, wholeWord: Bool, version: Int, isCurrent: () -> Bool) async -> [NSRange]? {
        guard let editor else { return nil }
        let document = editor.document
        let text = document.textStorage.mutableString
        let limit = Self.maxMatches
        guard text.length > backgroundThreshold else {
            let found = text.occurrences(of: needle as NSString, wholeWord: wholeWord, limit: limit)
            return found.count < 2 ? [] : found
        }
        // In view, and a screenful around it: cheap, and what's seen.
        var visible: [NSRange] = []
        if let range = editor.visibleCharacterRange() {
            let margin = max(range.length, 4096)
            let start = max(0, range.location - margin), end = min(text.length, NSMaxRange(range) + margin)
            visible = text.occurrences(of: needle as NSString, wholeWord: wholeWord, limit: limit,
                                       in: NSRange(location: start, length: end - start))
            show(visible.count < 2 ? [] : visible.map { ($0, .text) }, version: version)
        }
        // The copy lives only as long as the scan: kept until the next edit it would cost twice
        // the file's size (40 MB for 20 MB) for every editor that once scanned. Copied in slices,
        // it never holds the main thread long.
        guard let snapshot = await snapshot(of: document, version: version) else { return nil }
        let scan = Task.detached(priority: .userInitiated) {
            snapshot.string.occurrences(of: needle as NSString, wholeWord: wholeWord, limit: limit)
        }
        let all = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
        willApplyBackgroundScan?()
        guard !Task.isCancelled, document.editVersion == version, isCurrent() else { return nil }
        // The file's first `maxMatches`, and those in view even when they come after them.
        let found = all + visible.filter { $0.location > (all.last?.location ?? -1) }
        return found.count < 2 ? [] : found
    }

    /// The text as of `version`, copied a slice at a time with the run loop turning in between
    /// (a 20 MB file in one go held the main thread for 7.5 ms). nil if it changed meanwhile.
    private func snapshot(of document: EditorDocument, version: Int) async -> TextSnapshot? {
        let text = document.textStorage.mutableString
        let length = text.length
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: max(length, 1))
        var position = 0
        while position < length {
            if position > 0 {
                try? await Task.sleep(for: .milliseconds(1))
                guard !Task.isCancelled, document.editVersion == version, text.length == length else {
                    buffer.deallocate()
                    return nil
                }
            }
            let count = min(Self.snapshotSlice, length - position)
            text.getCharacters(buffer + position, range: NSRange(location: position, length: count))
            position += count
        }
        return TextSnapshot(string: NSString(charactersNoCopy: buffer, length: length, freeWhenDone: true))
    }

    private func show(_ found: [(NSRange, DocumentHighlight.Kind)], version: Int) {
        guard let editor else { return }
        let found = found.sorted { $0.0.location < $1.0.location }
        self.version = version
        let changed = found.map(\.0) != ranges || found.map(\.1) != highlights.map(\.kind)
        highlights = found.map { (range: $0.0, kind: $0.1) }
        if changed { editor.diagnosticsOverlay?.marksDidChange() }
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
        // In chunks, the units around each place checked as they're read: `range(of:)` from
        // each place on, and two `wordRange(at:)`, took 1.9 s for a one-letter name in 20 MB.
        textStorage.mutableString.occurrences(of: string as NSString, wholeWord: wholeWord, limit: limit)
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
