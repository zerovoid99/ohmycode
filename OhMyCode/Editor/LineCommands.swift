import AppKit

/// Editing commands on whole lines (and the selection's case), like other editors': each is
/// one undoable step on the selection's lines.
enum LineCommand: String, CaseIterable {
    case toggleComment, moveUp, moveDown, copyUp, copyDown, delete, indent, outdent
    case insertBelow, insertAbove, join, sortAscending, sortDescending, deleteDuplicates
    case upperCase, lowerCase, titleCase, trimTrailingWhitespace

    /// The palette's (and keybindings') id.
    var id: String { "edit.line." + rawValue }

    var title: String {
        switch self {
        case .toggleComment: "Toggle Line Comment"
        case .moveUp: "Move Line Up"
        case .moveDown: "Move Line Down"
        case .copyUp: "Copy Line Up"
        case .copyDown: "Copy Line Down"
        case .delete: "Delete Line"
        case .indent: "Indent Line"
        case .outdent: "Outdent Line"
        case .insertBelow: "Insert Line Below"
        case .insertAbove: "Insert Line Above"
        case .join: "Join Lines"
        case .sortAscending: "Sort Lines Ascending"
        case .sortDescending: "Sort Lines Descending"
        case .deleteDuplicates: "Delete Duplicate Lines"
        case .upperCase: "Transform to Uppercase"
        case .lowerCase: "Transform to Lowercase"
        case .titleCase: "Transform to Title Case"
        case .trimTrailingWhitespace: "Trim Trailing Whitespace"
        }
    }

    var icon: String {
        switch self {
        case .toggleComment: "number"
        case .moveUp: "arrow.up.square"
        case .moveDown: "arrow.down.square"
        case .copyUp, .copyDown: "plus.square.on.square"
        case .delete: "delete.left"
        case .indent: "increase.indent"
        case .outdent: "decrease.indent"
        case .insertBelow: "text.insert"
        case .insertAbove: "text.append"
        case .join: "arrow.right.and.line.vertical.and.arrow.left"
        case .sortAscending: "arrow.up.arrow.down"
        case .sortDescending: "arrow.up.arrow.down"
        case .deleteDuplicates: "minus.square"
        case .upperCase, .lowerCase, .titleCase: "textformat"
        case .trimTrailingWhitespace: "scissors"
        }
    }

    var defaultKey: String? {
        switch self {
        case .toggleComment: "cmd+/"
        case .moveUp: "alt+up"
        case .moveDown: "alt+down"
        case .copyUp: "alt+shift+up"
        case .copyDown: "alt+shift+down"
        case .delete: "shift+cmd+k"
        case .indent: "cmd+]"
        case .outdent: "cmd+["
        case .insertBelow: "cmd+enter"
        case .insertAbove: "shift+cmd+enter"
        case .join: "ctrl+j"
        default: nil
        }
    }

    static func command(id: String) -> LineCommand? {
        guard id.hasPrefix("edit.line.") else { return nil }
        return LineCommand(rawValue: String(id.dropFirst("edit.line.".count)))
    }

    @MainActor var paletteCommand: PaletteCommand {
        PaletteCommand(id: id, title: "Edit: " + title, icon: icon, key: defaultKey,
                       isAvailable: { $0.activeDocument?.editor != nil },
                       perform: { $0.activeDocument?.editor?.perform(self) })
    }
}

extension EditorController {
    private var text: NSString { document.textStorage.mutableString }

    /// A key press in the editor bound to a line command (by default or by the user): run it.
    /// Handled here rather than by menu shortcuts, so the keys still work in other text fields.
    func handleLineCommandKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let id = Keybindings.shared.command(for: event) else { return false }
        if id == "go.bracket" { jumpToBracket(); return true }
        guard let command = LineCommand.command(id: id) else { return false }
        perform(command)
        return true
    }

    func perform(_ command: LineCommand) {
        guard textView != nil else { return }
        clearExtraCursors()
        completion.dismiss()
        switch command {
        case .toggleComment: toggleComment()
        case .moveUp: moveLines(up: true)
        case .moveDown: moveLines(up: false)
        case .copyUp: copyLines(up: true)
        case .copyDown: copyLines(up: false)
        case .delete: deleteLines()
        case .indent: indentLines()
        case .outdent: outdentLines()
        case .insertBelow: insertLine(below: true)
        case .insertAbove: insertLine(below: false)
        case .join: joinLines()
        case .sortAscending: sortLines(ascending: true)
        case .sortDescending: sortLines(ascending: false)
        case .deleteDuplicates: deleteDuplicateLines()
        case .upperCase: transformCase { $0.uppercased() }
        case .lowerCase: transformCase { $0.lowercased() }
        case .titleCase: transformCase { $0.capitalized }
        case .trimTrailingWhitespace: trimTrailingWhitespace()
        }
    }

    // MARK: Lines

    /// The selection's lines: the first and last (a selection ending at a line's start doesn't
    /// take that line).
    func selectedLines(_ selection: NSRange? = nil) -> ClosedRange<Int> {
        let selection = selection ?? textView.selectedRange()
        let index = document.lineIndex
        let first = index.line(containing: selection.location)
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, end == index.lineStarts[index.line(containing: end)] { end -= 1 }
        return first...max(first, index.line(containing: end))
    }

    /// Where a line starts, and where it ends without and with its line break.
    private func bounds(ofLine line: Int) -> (start: Int, contentEnd: Int, end: Int) {
        let index = document.lineIndex
        let start = index.lineStarts[line]
        let end = line + 1 < index.lineCount ? index.lineStarts[line + 1] : text.length
        var contentEnd = end
        if contentEnd > start, text.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
        if contentEnd > start, text.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }
        return (start, contentEnd, end)
    }

    private func lineText(_ line: Int) -> String {
        let bounds = bounds(ofLine: line)
        return text.substring(with: NSRange(location: bounds.start, length: bounds.contentEnd - bounds.start))
    }

    /// The text's line break ("\n" unless it uses "\r\n").
    private var lineBreak: String { document.lineEnding.characters }

    private func edit(_ edits: [TextReplacement], _ name: String, select selection: NSRange? = nil) {
        guard (try? document.apply(edits, actionName: name)) == true else { if selection == nil { NSSound.beep() }; return }
        if let selection {
            let length = text.length
            let location = min(max(0, selection.location), length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    // MARK: Comments

    private func toggleComment() {
        let lines = selectedLines()
        let selection = textView.selectedRange()
        guard let marker = document.language.lineComment else {
            toggleBlockComment(lines: lines)
            return
        }
        // Lines with text; blank ones are left alone (unless that's all there is).
        var nonBlank = lines.filter { !lineText($0).allSatisfy(\.isWhitespace) }
        if nonBlank.isEmpty { nonBlank = Array(lines) }
        let indent: (Int) -> Int = { line in self.lineText(line).prefix { $0 == " " || $0 == "\t" }.utf16.count }
        let isCommented = nonBlank.allSatisfy { line in
            self.lineText(line).dropFirst(self.lineText(line).prefix { $0 == " " || $0 == "\t" }.count).hasPrefix(marker)
        }
        var edits: [TextReplacement] = []
        if isCommented {
            for line in nonBlank {
                let start = bounds(ofLine: line).start + indent(line)
                let rest = lineText(line).utf16.dropFirst(indent(line) + marker.utf16.count)
                let length = marker.utf16.count + (rest.first == 0x20 ? 1 : 0)
                edits.append(TextReplacement(range: NSRange(location: start, length: length), text: ""))
            }
        } else {
            // At the least indented line's column, so the markers line up.
            let column = nonBlank.map(indent).min() ?? 0
            for line in nonBlank {
                let start = bounds(ofLine: line).start
                let available = bounds(ofLine: line).contentEnd - start
                edits.append(TextReplacement(range: NSRange(location: start + min(column, available), length: 0), text: marker + " "))
            }
        }
        // The cursor stays on its text (the edit before it moves it).
        let delta = edits.filter { $0.range.location <= selection.location }
            .reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
        let lengthDelta = edits.filter { $0.range.location > selection.location && $0.range.location < NSMaxRange(selection) }
            .reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
        edit(edits, isCommented ? "Uncomment" : "Comment",
             select: NSRange(location: max(bounds(ofLine: lines.lowerBound).start, selection.location + delta),
                             length: max(0, selection.length + lengthDelta)))
    }

    /// Languages without line comments: wrap the lines in a block comment (or unwrap them).
    private func toggleBlockComment(lines: ClosedRange<Int>) {
        guard let (open, close) = document.language.blockComment else { NSSound.beep(); return }
        let start = bounds(ofLine: lines.lowerBound).start
        let end = bounds(ofLine: lines.upperBound).contentEnd
        let content = text.substring(with: NSRange(location: start, length: end - start))
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(open), trimmed.hasSuffix(close), trimmed.count >= open.count + close.count {
            let leading = content.prefix { $0 == " " || $0 == "\t" }
            var inner = String(trimmed.dropFirst(open.count).dropLast(close.count))
            if inner.hasPrefix(" ") { inner.removeFirst() }
            if inner.hasSuffix(" ") { inner.removeLast() }
            edit([TextReplacement(range: NSRange(location: start, length: end - start), text: leading + inner)], "Uncomment",
                 select: NSRange(location: start, length: (leading + inner).utf16.count))
        } else {
            let leading = content.prefix { $0 == " " || $0 == "\t" }
            let wrapped = leading + open + " " + content.dropFirst(leading.count) + " " + close
            edit([TextReplacement(range: NSRange(location: start, length: end - start), text: String(wrapped))], "Comment",
                 select: NSRange(location: start, length: wrapped.utf16.count))
        }
    }

    // MARK: Moving and copying

    /// The lines' text with a line break after it (added for the text's last line).
    private func block(_ lines: ClosedRange<Int>) -> (range: NSRange, text: String, endsWithBreak: Bool) {
        let start = bounds(ofLine: lines.lowerBound).start
        let last = bounds(ofLine: lines.upperBound)
        let range = NSRange(location: start, length: last.end - start)
        let endsWithBreak = last.end > last.contentEnd
        return (range, text.substring(with: range), endsWithBreak)
    }

    private func moveLines(up: Bool) {
        let lines = selectedLines()
        let selection = textView.selectedRange()
        let lineCount = document.lineIndex.lineCount
        // The last line when the text ends with a line break is empty and stays put.
        let lastMovable = text.length > 0 && text.character(at: text.length - 1) == 0x0A ? lineCount - 2 : lineCount - 1
        guard up ? lines.lowerBound > 0 : lines.upperBound < lastMovable else { return }
        let other = up ? lines.lowerBound - 1 : lines.upperBound + 1
        let both = up ? other...lines.upperBound : lines.lowerBound...other
        let whole = block(both)
        var moving = block(lines).text
        var neighbour = block(other...other).text
        // The text's last line has no line break: the pair keeps one between them, none at the end.
        if !whole.endsWithBreak {
            if up { moving += lineBreak; neighbour = String(neighbour.dropLast(lineBreak.count)) } else { neighbour += lineBreak; moving = String(moving.dropLast(lineBreak.count)) }
        }
        let replacement = up ? moving + neighbour : neighbour + moving
        // Where the moved lines start now, against where they started.
        let newStart = whole.range.location + (up ? 0 : (neighbour as NSString).length)
        let shift = newStart - block(lines).range.location
        edit([TextReplacement(range: whole.range, text: replacement)], up ? "Move Line Up" : "Move Line Down",
             select: NSRange(location: selection.location + shift, length: selection.length))
    }

    private func copyLines(up: Bool) {
        let lines = selectedLines()
        let selection = textView.selectedRange()
        let block = block(lines)
        if block.endsWithBreak {
            let copy = TextReplacement(range: NSRange(location: block.range.location, length: 0), text: block.text)
            // Copy down: the cursor goes to the copy below (the inserted text is the upper one).
            edit([copy], up ? "Copy Line Up" : "Copy Line Down",
                 select: up ? selection : NSRange(location: selection.location + block.range.length, length: selection.length))
        } else {
            // The text's last line: the copy goes after it, after a line break.
            let copy = TextReplacement(range: NSRange(location: NSMaxRange(block.range), length: 0), text: lineBreak + block.text)
            edit([copy], up ? "Copy Line Up" : "Copy Line Down",
                 select: up ? selection : NSRange(location: selection.location + (lineBreak + block.text).utf16.count, length: selection.length))
        }
    }

    private func deleteLines() {
        let lines = selectedLines()
        var block = block(lines)
        let column = textView.selectedRange().location - bounds(ofLine: lines.lowerBound).start
        if !block.endsWithBreak, block.range.location > 0 {
            // The last line: the line break before it goes too.
            let breakLength = text.character(at: block.range.location - 1) == 0x0A && block.range.location > 1
                && text.character(at: block.range.location - 2) == 0x0D ? 2 : 1
            block.range = NSRange(location: block.range.location - breakLength, length: block.range.length + breakLength)
        }
        guard block.range.length > 0 else { return }
        edit([TextReplacement(range: block.range, text: "")], "Delete Line")
        // The cursor keeps its column on the line that took the deleted ones' place.
        let line = min(lines.lowerBound, document.lineIndex.lineCount - 1)
        let target = bounds(ofLine: line)
        textView.setSelectedRange(NSRange(location: min(target.start + column, target.contentEnd), length: 0))
    }

    // MARK: Indentation

    private func indentLines() {
        let lines = selectedLines()
        let selection = textView.selectedRange()
        let unit = indentUnit
        // One line with no selection: the line indents too (not a tab at the cursor).
        let targets = lines.filter { lines.count == 1 || !lineText($0).isEmpty }
        let edits = targets.map { TextReplacement(range: NSRange(location: bounds(ofLine: $0).start, length: 0), text: unit) }
        let unitLength = (unit as NSString).length
        let firstShifts = targets.contains(lines.lowerBound)
        edit(edits, "Indent", select: NSRange(location: selection.location + (firstShifts ? unitLength : 0),
                                              length: selection.length + unitLength * (targets.count - (firstShifts ? 1 : 0))))
    }

    private func outdentLines() {
        let lines = selectedLines()
        let selection = textView.selectedRange()
        let width = document.indentation.tabSize
        var edits: [TextReplacement] = []
        var removedBefore = 0, removedInside = 0
        for line in lines {
            let bounds = bounds(ofLine: line)
            let content = lineText(line).utf16
            var length = 0
            if content.first == 0x09 {
                length = 1
            } else {
                while length < width, length < content.count, content[content.index(content.startIndex, offsetBy: length)] == 0x20 { length += 1 }
            }
            guard length > 0 else { continue }
            edits.append(TextReplacement(range: NSRange(location: bounds.start, length: length), text: ""))
            if bounds.start < selection.location {
                let before = min(length, selection.location - bounds.start)
                removedBefore += before
                removedInside += length - before
            } else {
                removedInside += length
            }
        }
        guard !edits.isEmpty else { return }
        edit(edits, "Outdent", select: NSRange(location: selection.location - removedBefore,
                                               length: max(0, selection.length - min(removedInside, selection.length))))
    }

    private func insertLine(below: Bool) {
        let line = below ? selectedLines().upperBound : selectedLines().lowerBound
        let bounds = bounds(ofLine: line)
        let indent = String(lineText(line).prefix { $0 == " " || $0 == "\t" })
        if below {
            let inserted = lineBreak + indent
            edit([TextReplacement(range: NSRange(location: bounds.contentEnd, length: 0), text: inserted)], "Insert Line Below",
                 select: NSRange(location: bounds.contentEnd + (inserted as NSString).length, length: 0))
        } else {
            edit([TextReplacement(range: NSRange(location: bounds.start, length: 0), text: indent + lineBreak)], "Insert Line Above",
                 select: NSRange(location: bounds.start + (indent as NSString).length, length: 0))
        }
    }

    // MARK: Joining, sorting, case

    private func joinLines() {
        var lines = selectedLines()
        if lines.count == 1 {
            guard lines.upperBound + 1 < document.lineIndex.lineCount else { return }
            lines = lines.lowerBound...(lines.upperBound + 1)
        }
        var edits: [TextReplacement] = []
        var cursor = 0
        for line in lines.dropLast() {
            let current = bounds(ofLine: line)
            let next = bounds(ofLine: line + 1)
            // The line's trailing spaces, its break, and the next line's indentation: one space
            // (none before an empty line or a closing bracket).
            var start = current.contentEnd
            while start > current.start, [0x20, 0x09].contains(text.character(at: start - 1)) { start -= 1 }
            var end = next.start
            while end < next.contentEnd, [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
            let nextText = text.substring(with: NSRange(location: end, length: next.contentEnd - end))
            let separator = nextText.isEmpty || start == current.start || [")", "]", "}"].contains(nextText.first) ? "" : " "
            edits.append(TextReplacement(range: NSRange(location: start, length: end - start), text: separator))
            if line == lines.lowerBound { cursor = start }
        }
        let selection = textView.selectedRange()
        edit(edits, "Join Lines", select: selection.length == 0 ? NSRange(location: cursor, length: 0) : nil)
    }

    /// The lines to sort or dedupe: the selection's (when more than one), else the whole text.
    private func linesToReorder() -> ClosedRange<Int> {
        let lines = selectedLines()
        if lines.count > 1 { return lines }
        var last = document.lineIndex.lineCount - 1
        if last > 0, bounds(ofLine: last).start == text.length { last -= 1 }
        return 0...max(0, last)
    }

    private func replaceLines(_ lines: ClosedRange<Int>, with newLines: [String], name: String) {
        let start = bounds(ofLine: lines.lowerBound).start
        let end = bounds(ofLine: lines.upperBound).contentEnd
        let replacement = newLines.joined(separator: lineBreak)
        edit([TextReplacement(range: NSRange(location: start, length: end - start), text: replacement)], name,
             select: NSRange(location: start, length: (replacement as NSString).length))
    }

    private func sortLines(ascending: Bool) {
        let lines = linesToReorder()
        let texts = lines.map(lineText)
        // Natural order: "item2" before "item10"; case only breaks ties.
        var sorted = texts.sorted { lhs, rhs in
            let result = lhs.compare(rhs, options: [.numeric, .caseInsensitive])
            return result == .orderedSame ? lhs < rhs : result == .orderedAscending
        }
        if !ascending { sorted.reverse() }
        guard sorted != texts else { return }
        replaceLines(lines, with: sorted, name: "Sort Lines")
    }

    private func deleteDuplicateLines() {
        let lines = linesToReorder()
        var seen = Set<String>()
        let unique = lines.map(lineText).filter { seen.insert($0).inserted }
        guard unique.count < lines.count else { return }
        replaceLines(lines, with: unique, name: "Delete Duplicate Lines")
    }

    private func transformCase(_ transform: (String) -> String) {
        var selection = textView.selectedRange()
        if selection.length == 0 {
            guard let word = document.wordRange(at: selection.location) else { return }
            selection = word
        }
        let original = text.substring(with: selection)
        let changed = transform(original)
        guard changed != original else { return }
        edit([TextReplacement(range: selection, text: changed)], "Transform Case",
             select: NSRange(location: selection.location, length: (changed as NSString).length))
    }

    private func trimTrailingWhitespace() {
        var edits: [TextReplacement] = []
        for line in 0..<document.lineIndex.lineCount {
            let bounds = bounds(ofLine: line)
            var start = bounds.contentEnd
            while start > bounds.start, [0x20, 0x09].contains(text.character(at: start - 1)) { start -= 1 }
            if start < bounds.contentEnd { edits.append(TextReplacement(range: NSRange(location: start, length: bounds.contentEnd - start), text: "")) }
        }
        guard !edits.isEmpty else { return }
        edit(edits, "Trim Trailing Whitespace")
    }
}
