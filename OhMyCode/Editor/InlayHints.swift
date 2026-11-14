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
        return NSFont.monospacedSystemFont(ofSize: max(9, base.pointSize - 1), weight: .regular)
    }

    /// The gap a hint needs: its text and a little room on each side.
    static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 6
    }
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
            guard AppSettings.shared.showsInlayHints, let client = self.languageClient, client.state == .ready,
                  client.supports(.inlayHint), self.lineIndex.lineCount <= Self.inlayHintLineLimit else {
                self.setInlayHints([])
                return
            }
            let version = self.editVersion
            let end = self.lspPosition(at: self.textStorage.length)
            let hints = (try? await client.inlayHints(url: self.url, range: LSPRange(start: LSPPosition(line: 0, character: 0), end: end))) ?? []
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
        var hasMarks = false
        textStorage.enumerateAttribute(.omcInlayHint, in: whole) { value, _, stop in
            if value != nil { hasMarks = true; stop.pointee = true }
        }
        guard hasMarks || !marks.isEmpty else { return }
        // Layout attributes only: the document's edit observer ignores them (no LSP change,
        // not dirty, nothing to undo).
        textStorage.beginEditing()
        textStorage.removeAttribute(.omcInlayHint, range: whole)
        textStorage.removeAttribute(.kern, range: whole)
        for (index, mark) in marks.sorted(by: { $0.index < $1.index }) {
            textStorage.addAttributes([.omcInlayHint: mark, .kern: mark.width], range: NSRange(location: index, length: 1))
        }
        textStorage.endEditing()
        editors.forEach { $0.diagnosticsOverlay?.needsDisplay = true }
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
            // The character's segment includes the gap after it.
            result.append((NSRect(x: rect.maxX - mark.width + 2, y: rect.minY + 1, width: mark.width - 4, height: max(rect.height - 2, 1)), mark))
        }
        return result
    }

    /// Typed text doesn't take on a hint's gap from the character before it.
    func strippingInlayHint(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes = attributes
        attributes[.kern] = nil
        attributes[.omcInlayHint] = nil
        return attributes
    }
}
