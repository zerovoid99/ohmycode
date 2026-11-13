import AppKit

/// Replaces `range` (UTF-16, in the text the edit was computed against) with `text`.
struct TextReplacement: Equatable, Sendable {
    var range: NSRange
    var text: String
}

enum TextReplacementError: LocalizedError {
    case overlapping
    case outOfBounds

    var errorDescription: String? {
        switch self {
        case .overlapping: "The edits overlap."
        case .outOfBounds: "The edits don't fit the document."
        }
    }
}

extension TextReplacement {
    /// Sorted by position, validated to be in bounds and non-overlapping.
    static func validated(_ edits: [TextReplacement], length: Int) throws -> [TextReplacement] {
        // Stable sort: inserts at the same position keep their given order.
        let sorted = edits.enumerated().sorted {
            ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset)
        }.map(\.element)
        var end = 0
        for edit in sorted {
            guard edit.range.location >= 0, NSMaxRange(edit.range) <= length else { throw TextReplacementError.outOfBounds }
            guard edit.range.location >= end else { throw TextReplacementError.overlapping }
            end = NSMaxRange(edit.range)
        }
        return sorted
    }

    /// Applies edits to a plain string (files that aren't open).
    static func apply(_ edits: [TextReplacement], to text: String) throws -> String {
        let string = NSMutableString(string: text)
        for edit in try validated(edits, length: string.length).reversed() {
            string.replaceCharacters(in: edit.range, with: edit.text)
        }
        return string as String
    }
}

extension EditorDocument {
    /// Applies several edits as one undoable step (also when no editor shows the document).
    /// Returns false when nothing changed.
    @discardableResult
    func apply(_ edits: [TextReplacement], actionName: String) throws -> Bool {
        let sorted = try TextReplacement.validated(edits, length: textStorage.length)
        let text = textStorage.mutableString
        let effective = sorted.filter { $0.range.length > 0 || !$0.text.isEmpty }
            .filter { text.substring(with: $0.range) != $0.text }
        guard !effective.isEmpty else { return false }

        // Inverse edits, in post-edit coordinates: each edit moves by the length changes before it.
        var inverse: [TextReplacement] = []
        var shift = 0
        for edit in effective {
            let newLength = (edit.text as NSString).length
            inverse.append(TextReplacement(range: NSRange(location: edit.range.location + shift, length: newLength),
                                           text: text.substring(with: edit.range)))
            shift += newLength - edit.range.length
        }

        let textView = editor?.textView
        let selection = textView?.selectedRange()
        textView?.breakUndoCoalescing()
        // Back to front, so earlier ranges stay valid. One storage edit each: the document's
        // incremental line index, parser and LSP sync all see ordinary single edits.
        for edit in effective.reversed() {
            textStorage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.text, attributes: EditorTheme.baseAttributes))
        }
        if let textView, let selection {
            textView.setSelectedRange(Self.adjust(selection, by: effective, length: textStorage.length))
        }

        // Our own group, so the step stays separate from typing; not while undoing/redoing,
        // where the registration belongs to the group being undone.
        let ownsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if ownsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { _ = try? document.apply(inverse, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        if ownsGroup { undoManager.endUndoGrouping() }
        editor?.textDidChangeProgrammatically()
        return true
    }

    /// Where a selection lands after `edits` (sorted, pre-edit coordinates).
    private static func adjust(_ selection: NSRange, by edits: [TextReplacement], length: Int) -> NSRange {
        var location = selection.location
        for edit in edits.reversed() where edit.range.location < selection.location {
            let newLength = (edit.text as NSString).length
            if NSMaxRange(edit.range) <= location {
                location += newLength - edit.range.length
            } else {
                location = edit.range.location + newLength // the cursor was inside a replaced range
            }
        }
        location = min(max(0, location), length)
        return NSRange(location: location, length: 0)
    }
}
