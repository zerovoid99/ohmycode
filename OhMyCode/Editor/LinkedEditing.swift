import AppKit

/// Linked editing: typing in an HTML, XML or JSX tag's name changes its closing (or opening)
/// tag's name too, as one undoable edit.
extension EditorController {
    /// How far to look for the other tag.
    static let linkedTagSearchLimit = 200_000

    private static func isNameCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 0x2D || unit == 0x2E || unit == 0x3A || unit == 0x5F // - . : _
    }

    private var linksTags: Bool {
        guard AppSettings.shared.linkedEditing else { return false }
        switch document.language {
        case .html, .markdown, .tsx, .javascript: return true
        default: return ["xml", "svg", "plist", "vue", "svelte", "xhtml"].contains(document.url.pathExtension.lowercased())
        }
    }

    /// The tag name the cursor (or selection) is in, and the other tag's name: both ranges,
    /// only when the names match.
    func linkedTagNames(for selection: NSRange? = nil) -> (current: NSRange, partner: NSRange)? {
        guard linksTags else { return nil }
        let selection = selection ?? textView.selectedRange()
        let text = document.textStorage.mutableString
        let length = text.length
        // Back from the cursor over name characters to `<` or `</`.
        var start = selection.location
        while start > 0, Self.isNameCharacter(text.character(at: start - 1)) { start -= 1 }
        guard start > 0 else { return nil }
        let isClosing = start > 1 && text.character(at: start - 1) == 0x2F && text.character(at: start - 2) == 0x3C // </
        guard isClosing || text.character(at: start - 1) == 0x3C else { return nil }
        var end = start
        while end < length, Self.isNameCharacter(text.character(at: end)) { end += 1 }
        let current = NSRange(location: start, length: end - start)
        guard current.length > 0, NSMaxRange(selection) <= end else { return nil }
        let name = text.substring(with: current)
        let partner = isClosing ? openingTag(named: name, before: start - 2) : closingTag(named: name, after: end)
        guard let partner, text.substring(with: partner) == name else { return nil }
        return (current, partner)
    }

    /// The closing tag matching an opening tag ending its name at `offset` (not a self-closing one).
    private func closingTag(named name: String, after offset: Int) -> NSRange? {
        let text = document.textStorage.mutableString
        // The opening tag's end: `/>` means there's no closing tag.
        let tagEnd = text.range(of: ">", options: .literal, range: NSRange(location: offset, length: text.length - offset))
        guard tagEnd.location != NSNotFound, tagEnd.location == 0 || text.character(at: tagEnd.location - 1) != 0x2F else { return nil }
        // A tag still being typed (`<div` then another tag): not linked to a later closing tag.
        let nextOpen = text.range(of: "<", options: .literal, range: NSRange(location: offset, length: tagEnd.location - offset))
        guard nextOpen.location == NSNotFound else { return nil }
        var depth = 0
        for match in tags(named: name, in: NSRange(location: NSMaxRange(tagEnd), length: min(Self.linkedTagSearchLimit, text.length - NSMaxRange(tagEnd)))) {
            if match.isClosing {
                if depth == 0 { return match.name }
                depth -= 1
            } else if !match.isSelfClosing {
                depth += 1
            }
        }
        return nil
    }

    /// The opening tag matching a closing tag starting (its `<`) at `offset`.
    private func openingTag(named name: String, before offset: Int) -> NSRange? {
        let start = max(0, offset - Self.linkedTagSearchLimit)
        var depth = 0
        for match in tags(named: name, in: NSRange(location: start, length: offset - start)).reversed() {
            if match.isClosing {
                depth += 1
            } else if !match.isSelfClosing {
                if depth == 0 { return match.name }
                depth -= 1
            }
        }
        return nil
    }

    /// Tags with exactly this name in a range: where the name is, closing or not, self-closing.
    private func tags(named name: String, in range: NSRange) -> [(name: NSRange, isClosing: Bool, isSelfClosing: Bool)] {
        let text = document.textStorage.mutableString
        let pattern = "<(/?)(" + NSRegularExpression.escapedPattern(for: name) + ")(?=[\\s/>])([^<>]*?)(/?)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text as String, range: range).map { match in
            (match.range(at: 2), match.range(at: 1).length > 0, match.range(at: 4).length > 0)
        }
    }

    /// Typing a name character in a linked tag name: the same at the other tag.
    func handleLinkedTyping(_ text: String) -> Bool {
        guard !hasExtraCursors, !text.isEmpty, (text as NSString).length <= 64,
              text.utf16.allSatisfy(Self.isNameCharacter) else { return false }
        let selection = textView.selectedRange()
        guard let (current, partner) = linkedTagNames(for: selection) else { return false }
        return mirror(selection: selection, current: current, partner: partner, text: text, actionName: "Typing")
    }

    /// Deleting in a linked tag name (not past its start): the same at the other tag.
    func handleLinkedDelete(forward: Bool) -> Bool {
        guard !hasExtraCursors else { return false }
        var selection = textView.selectedRange()
        guard let (current, partner) = linkedTagNames(for: selection) else { return false }
        if selection.length == 0 {
            if forward {
                guard selection.location < NSMaxRange(current) else { return false }
                selection = NSRange(location: selection.location, length: 1)
            } else {
                guard selection.location > current.location else { return false }
                selection = NSRange(location: selection.location - 1, length: 1)
            }
        }
        guard selection.location >= current.location, NSMaxRange(selection) <= NSMaxRange(current) else { return false }
        return mirror(selection: selection, current: current, partner: partner, text: "", actionName: "Delete")
    }

    private func mirror(selection: NSRange, current: NSRange, partner: NSRange, text: String, actionName: String) -> Bool {
        let offset = selection.location - current.location
        let partnerEdit = NSRange(location: partner.location + offset, length: selection.length)
        textView.breakUndoCoalescing()
        guard (try? document.apply([TextReplacement(range: selection, text: text),
                                    TextReplacement(range: partnerEdit, text: text)], actionName: actionName)) == true else { return false }
        let inserted = (text as NSString).length
        let shift = partner.location < current.location ? inserted - selection.length : 0
        textView.setSelectedRange(NSRange(location: selection.location + shift + inserted, length: 0))
        textView.breakUndoCoalescing()
        return true
    }
}
