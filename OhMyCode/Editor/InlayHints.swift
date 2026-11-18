import AppKit

extension NSAttributedString.Key {
    /// On the character before an inlay hint: the hint (an `InlayHintMark`). With a `.kern`
    /// that opens the gap it's drawn in. Layout only: the text itself doesn't change.
    static let omcInlayHint = NSAttributedString.Key("omcInlayHint")
}

/// An inlay hint as kept in the text (attributes move with the text as it's edited).
final class InlayHintMark: NSObject {
    let text: String
    let kind: InlayHint.Kind?
    let width: CGFloat

    init(text: String, kind: InlayHint.Kind?, width: CGFloat) {
        self.text = text
        self.kind = kind
        self.width = width
    }
}

@MainActor
enum InlayHintStyle {
    static var font: NSFont {
        let base = EditorTheme.font
        if let cachedFont, cachedFont.base === base { return cachedFont.font }
        let font = NSFont.monospacedSystemFont(ofSize: max(9, base.pointSize - 1), weight: .regular)
        cachedFont = (base, font)
        return font
    }

    private static var cachedFont: (base: NSFont, font: NSFont)?

    /// The gap a hint needs: its text and a little room on each side. Remembered per text
    /// (a file's hints are mostly the same few: ": Int", "name:") until the font changes.
    static func width(of text: String) -> CGFloat {
        let font = font
        if font !== widthsFont {
            widthsFont = font
            widths.removeAll()
        }
        if let width = widths[text] { return width }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 6
        widths[text] = width
        return width
    }

    private static var widths: [String: CGFloat] = [:]
    private static var widthsFont: NSFont?
}

extension EditorDocument {
    /// The hints shown now (tests): their character index (the hint comes after it) and text.
    var shownInlayHints: [(index: Int, text: String)] {
        var hints: [(Int, String)] = []
        textStorage.enumerateAttribute(.omcInlayHint, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if let mark = value as? InlayHintMark { hints.append((range.location, mark.text)) }
        }
        return hints
    }

    /// Asks the language server for the file's hints again (after `delay`, restarted by every call).
    func refreshInlayHints(after delay: Duration = .zero) {
        inlayHintsTask?.cancel()
        inlayHintsTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            guard self.projectSettings.showsInlayHints ?? AppSettings.shared.showsInlayHints, self.canUse(.inlayHint, .inlayHint),
                  self.lineIndex.lineCount <= Self.inlayHintLineLimit else {
                self.setInlayHints([])
                return
            }
            let client = self.readyLanguageClient.flatMap { $0.supports(.inlayHint) ? $0 : nil }
            let version = self.editVersion
            let end = self.lspPosition(at: self.textStorage.length)
            let range = LSPRange(start: LSPPosition(line: 0, character: 0), end: end)
            // The server's, then the extensions'.
            var hints: [InlayHint] = []
            if let client { hints = (try? await client.inlayHints(url: self.url, range: range)) ?? [] }
            hints += await self.extensionHost?.inlayHints(for: self, range: range) ?? []
            // An edit since: its own refresh brings the hints for the new text.
            guard !Task.isCancelled, version == self.editVersion else { return }
            self.setInlayHints(hints)
        }
    }

    /// Big files: no hints (they'd be asked for and laid out on every pause).
    static let inlayHintLineLimit = 5_000

    /// Waits for the refresh in progress (tests).
    func waitForInlayHints() async { await inlayHintsTask?.value }

    /// Replaces the hints: each is a gap (kern) after the character before its position, with
    /// the hint on that character. A hint at the start of a line has no character before it
    /// on its line, and isn't shown.
    func setInlayHints(_ hints: [InlayHint]) {
        let text = textStorage.mutableString
        let whole = NSRange(location: 0, length: textStorage.length)
        var marks: [(index: Int, mark: InlayHintMark)] = []
        for hint in hints {
            let offset = offset(for: hint.position)
            guard offset > 0, offset <= text.length, text.character(at: offset - 1) != 0x0A else { continue }
            let index = offset - 1
            // Two hints at one place (rare): one gap with both.
            if let last = marks.last, last.index == index {
                let joined = last.mark.text + " " + hint.text
                marks[marks.count - 1] = (index, InlayHintMark(text: joined, kind: hint.kind, width: InlayHintStyle.width(of: joined)))
                continue
            }
            marks.append((index, InlayHintMark(text: hint.text, kind: hint.kind, width: InlayHintStyle.width(of: hint.text))))
        }
        marks.sort { $0.index < $1.index }
        // What's shown now. Only the differences are written: the text's attributes changing
        // makes TextKit lay it out again, and after a pause in typing nearly every hint is
        // where the last answer (and the edits since) left it.
        var stale: [NSRange] = []
        var kept = Set<Int>()
        var next = 0
        textStorage.enumerateAttribute(.omcInlayHint, in: whole) { value, range, _ in
            guard let shown = value as? InlayHintMark else { return }
            while next < marks.count, marks[next].index < range.location { next += 1 }
            if range.length == 1, next < marks.count, marks[next].index == range.location,
               marks[next].mark.text == shown.text, marks[next].mark.kind == shown.kind, marks[next].mark.width == shown.width {
                kept.insert(range.location)
            } else {
                stale.append(range)
            }
        }
        let added = marks.filter { !kept.contains($0.index) }
        guard !stale.isEmpty || !added.isEmpty else { return }
        // The most room hints take on one line: the text view is that much wider without wrap.
        var perLine: [Int: CGFloat] = [:]
        for (index, mark) in marks { perLine[lineIndex.line(containing: index), default: 0] += mark.width }
        let widest = perLine.values.max() ?? 0
        let widthChanged = widest > widestInlayHints
        if widthChanged { widestInlayHints = widest }
        // Layout attributes only: the document's edit observer ignores them (no LSP change,
        // not dirty, nothing to undo).
        textStorage.beginEditing()
        for range in stale {
            textStorage.removeAttribute(.omcInlayHint, range: range)
            textStorage.removeAttribute(.kern, range: range)
        }
        for (index, mark) in added {
            textStorage.addAttributes([.omcInlayHint: mark, .kern: mark.width], range: NSRange(location: index, length: 1))
        }
        textStorage.endEditing()
        editors.forEach { $0.diagnosticsOverlay?.needsDisplay = true }
        if widthChanged { editors.forEach { $0.updateTextWidth() } }
    }
}

extension EditorController {
    /// The hints in view, as their labels' rects (the gaps after their characters).
    func inlayHintRects() -> [(rect: NSRect, mark: InlayHintMark)] {
        guard let range = visibleCharacterRange() else { return [] }
        var result: [(NSRect, InlayHintMark)] = []
        let storage = document.textStorage
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(.omcInlayHint, in: clipped) { value, attributeRange, _ in
            guard let mark = value as? InlayHintMark,
                  let rect = rect(for: NSRange(location: attributeRange.location, length: 1)) else { return }
            // The gap (the kern) starts right after the character's glyph. (TextKit splits it
            // between this character's segment and the next one's: the caret sits mid-gap.)
            let character = storage.mutableString.substring(with: NSRange(location: attributeRange.location, length: 1)) as NSString
            let font = storage.attribute(.font, at: attributeRange.location, effectiveRange: nil) as? NSFont ?? EditorTheme.font
            let gapStart = rect.minX + character.size(withAttributes: [.font: font]).width
            result.append((NSRect(x: gapStart + 2, y: rect.minY + 1, width: mark.width - 4, height: max(rect.height - 2, 1)), mark))
        }
        return result
    }

    /// Typed text doesn't take on a hint's gap from the character before it.
    func strippingInlayHint(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes = attributes
        attributes[.kern] = nil
        attributes[.omcInlayHint] = nil
        attributes[.omcColorSwatch] = nil
        // Nor a suggestion's gap or room (see InlineSuggestions.swift).
        attributes[.omcGhostGap] = nil
        attributes[.omcGhostSpacing] = nil
        attributes[.paragraphStyle] = nil
        return attributes
    }
}
