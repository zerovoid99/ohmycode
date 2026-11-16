import AppKit

/// Multiple cursors. NSTextView keeps one selection (several selected ranges, but no several
/// insertion points), so the extra cursors live here: they're drawn by the overlay, and typing,
/// deleting and cursor movement are applied to all of them as one edit.
extension EditorController {
    var hasExtraCursors: Bool { !extraSelections.isEmpty }

    /// Every selection, the text view's first: sorted copies are made where order matters.
    var allSelections: [NSRange] { [textView.selectedRange()] + extraSelections }

    func clearExtraCursors() {
        guard hasExtraCursors else { return }
        extraSelections = []
        diagnosticsOverlay?.needsDisplay = true
    }

    /// ⌥-click: adds a cursor there, or removes the one already there.
    func toggleCursor(at location: Int) {
        let location = min(max(0, location), document.textStorage.length)
        if let index = extraSelections.firstIndex(where: { $0.location == location && $0.length == 0 }) {
            extraSelections.remove(at: index)
        } else if textView.selectedRange() == NSRange(location: location, length: 0) {
            return
        } else {
            extraSelections.append(NSRange(location: location, length: 0))
        }
        diagnosticsOverlay?.needsDisplay = true
    }

    /// ⌘D: with no selection, selects the word at the cursor; then adds the next occurrence of
    /// the selected text (wrapping around) as another selection.
    func addNextOccurrence() {
        let main = textView.selectedRange()
        let text = document.textStorage.mutableString
        if main.length == 0, !hasExtraCursors {
            if let word = document.wordRange(at: main.location) { setSelections(main: word, extras: []) }
            return
        }
        let needle = text.substring(with: main)
        guard !needle.isEmpty else { return }
        let taken = allSelections
        var from = taken.map(NSMaxRange).max() ?? NSMaxRange(main)
        for _ in 0..<2 { // after the last selection, then from the top
            var search = NSRange(location: from, length: text.length - from)
            while search.length > 0 {
                let found = text.range(of: needle, options: [.literal], range: search)
                guard found.location != NSNotFound else { break }
                if !taken.contains(where: { NSIntersectionRange($0, found).length > 0 || $0 == found }) {
                    setSelections(main: main, extras: extraSelections + [found])
                    textView.scrollRangeToVisible(found)
                    return
                }
                search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            }
            from = 0
        }
        NSSound.beep() // every occurrence is selected
    }

    /// ⇧⌘L: selects every occurrence of the selection (or of the word at the cursor).
    func selectAllOccurrences() {
        var main = textView.selectedRange()
        if main.length == 0, let word = document.wordRange(at: main.location) { main = word }
        guard main.length > 0 else { return }
        let text = document.textStorage.mutableString
        let needle = text.substring(with: main)
        var extras: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: needle, options: [.literal], range: search)
            guard found.location != NSNotFound else { break }
            if found != main { extras.append(found) }
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        setSelections(main: main, extras: extras)
    }

    /// ⌥⌘↑ / ⌥⌘↓: adds a cursor on the line above the topmost cursor, or below the lowest.
    func addCursorVertically(_ direction: Int) {
        let index = document.lineIndex
        let cursors = allSelections.map { $0.location + ($0.length > 0 && direction > 0 ? $0.length : 0) }
        guard let edge = direction < 0 ? cursors.min() : cursors.max() else { return }
        let line = index.line(containing: edge) + direction
        guard line >= 0, line < index.lineCount else { return }
        let column = edge - index.lineStarts[index.line(containing: edge)]
        let location = position(line: line, column: column)
        guard !allSelections.contains(where: { $0.location == location }) else { return }
        setSelections(main: textView.selectedRange(), extras: extraSelections + [NSRange(location: location, length: 0)])
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    // MARK: Editing at every cursor

    /// Typing with several cursors: replaces each selection with `text`.
    func insertAtAllCursors(_ text: String) {
        edit(actionName: "Typing") { selection in TextReplacement(range: selection, text: text) }
    }

    func deleteAtAllCursors(forward: Bool) {
        let string = document.textStorage.mutableString
        edit(actionName: "Delete") { selection in
            if selection.length > 0 { return TextReplacement(range: selection, text: "") }
            if forward {
                guard selection.location < string.length else { return nil }
                return TextReplacement(range: string.rangeOfComposedCharacterSequence(at: selection.location), text: "")
            }
            guard selection.location > 0 else { return nil }
            return TextReplacement(range: string.rangeOfComposedCharacterSequence(at: selection.location - 1), text: "")
        }
    }

    /// Applies one edit per selection as a single undo step; each cursor ends after its edit.
    private func edit(actionName: String, _ make: (NSRange) -> TextReplacement?) {
        let main = textView.selectedRange()
        let selections = merged(allSelections)
        let edits = selections.compactMap { selection in make(selection).map { (selection, $0) } }
        guard !edits.isEmpty else { return }
        textView.breakUndoCoalescing()
        guard (try? document.apply(edits.map(\.1), actionName: actionName)) == true else { return }
        // New cursor positions, in order: each edit shifts the ones after it.
        var shift = 0
        var carets: [(selection: NSRange, caret: Int)] = []
        for (selection, edit) in edits {
            let newLength = (edit.text as NSString).length
            carets.append((selection, edit.range.location + shift + newLength))
            shift += newLength - edit.range.length
        }
        let mainCaret = carets.first { NSLocationInRange(main.location, $0.selection) || $0.selection.location == main.location }?.caret
            ?? carets[0].caret
        var extras = carets.map { NSRange(location: $0.caret, length: 0) }
        if let index = extras.firstIndex(where: { $0.location == mainCaret }) { extras.remove(at: index) }
        setSelections(main: NSRange(location: mainCaret, length: 0), extras: extras)
        textView.breakUndoCoalescing()
    }

    // MARK: Moving every cursor

    /// Handles a text view command for all cursors; false lets the text view handle it (after
    /// dropping the extra cursors, for commands that don't apply to several).
    func handleMultiCursorCommand(_ selector: Selector) -> Bool {
        guard hasExtraCursors else { return false }
        let string = document.textStorage.mutableString
        let index = document.lineIndex
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)): deleteAtAllCursors(forward: false)
        case #selector(NSResponder.deleteForward(_:)): deleteAtAllCursors(forward: true)
        case #selector(NSResponder.insertNewline(_:)): insertAtAllCursors("\n")
        case #selector(NSResponder.insertTab(_:)): insertAtAllCursors("\t")
        case #selector(NSResponder.moveLeft(_:)):
            move { $0.length > 0 ? $0.location : ($0.location > 0 ? string.rangeOfComposedCharacterSequence(at: $0.location - 1).location : 0) }
        case #selector(NSResponder.moveRight(_:)):
            move { $0.length > 0 ? NSMaxRange($0)
                : ($0.location < string.length ? NSMaxRange(string.rangeOfComposedCharacterSequence(at: $0.location)) : $0.location) }
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            let direction = selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1
            move { selection in
                let line = index.line(containing: selection.location)
                let target = line + direction
                guard target >= 0, target < index.lineCount else { return direction < 0 ? 0 : string.length }
                return self.position(line: target, column: selection.location - index.lineStarts[line])
            }
        case #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)):
            move { index.lineStarts[index.line(containing: $0.location)] }
        case #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)):
            move { self.position(line: index.line(containing: $0.location), column: .max) }
        case #selector(NSResponder.cancelOperation(_:)):
            clearExtraCursors()
        default:
            clearExtraCursors()
            return false
        }
        return true
    }

    private func move(_ newLocation: (NSRange) -> Int) {
        let carets = allSelections.map { NSRange(location: newLocation($0), length: 0) }
        setSelections(main: carets[0], extras: Array(carets.dropFirst()))
    }

    /// Offset of `column` on `line`, clamped to the line's end (before its newline).
    func position(line: Int, column: Int) -> Int {
        let index = document.lineIndex
        let start = index.lineStarts[line]
        let end = line + 1 < index.lineCount ? index.lineStarts[line + 1] - 1 : document.textStorage.length
        return start + min(max(0, column), end - start)
    }

    /// Sets the text view's selection and the extra cursors (duplicates and overlaps merged).
    func setSelections(main: NSRange, extras: [NSRange]) {
        textView.setSelectedRange(main)
        extraSelections = merged(extras).filter { NSIntersectionRange($0, main).length == 0 && $0 != main }
        diagnosticsOverlay?.needsDisplay = true
    }

    private func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { ($0.location, $0.length) < ($1.location, $1.length) }) {
            if let last = result.last, range.location < NSMaxRange(last) || range == last {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: Drawing (by the overlay)

    /// Extra cursors as caret bars and selection rects, in text view coordinates.
    func extraCursorShapes() -> (carets: [NSRect], selections: [NSRect]) {
        var carets: [NSRect] = [], selections: [NSRect] = []
        // Only the ones in the laid-out viewport: a rect anywhere else has TextKit lay out a
        // line there, on every redraw (200 ms with 1,000 cursors through a file).
        guard !extraSelections.isEmpty, let viewport = visibleCharacterRange() else { return (carets, selections) }
        for selection in extraSelections where selection.location <= NSMaxRange(viewport) && NSMaxRange(selection) >= viewport.location {
            let shown = NSIntersectionRange(selection, viewport)
            if shown.length > 0, let rect = rect(for: shown) { selections.append(rect) }
            let end = NSMaxRange(selection)
            if end >= viewport.location, end <= NSMaxRange(viewport), let caret = caretRect(at: end) { carets.append(caret) }
        }
        return (carets, selections)
    }

    private func caretRect(at location: Int) -> NSRect? {
        let length = document.textStorage.length
        guard location >= 0, location <= length else { return nil }
        let string = document.textStorage.mutableString
        if location < length, string.character(at: location) != 0x0A, let rect = rect(for: NSRange(location: location, length: 1)) {
            return NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
        }
        if location > 0, string.character(at: location - 1) != 0x0A, let rect = rect(for: NSRange(location: location - 1, length: 1)) {
            return NSRect(x: rect.maxX, y: rect.minY, width: 2, height: rect.height)
        }
        // An empty line: the start of the line fragment.
        guard location < length, let rect = rect(for: NSRange(location: location, length: 1)) else { return nil }
        return NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
    }
}
