import AppKit

/// A conflict git left in a file:
///
///     <<<<<<< HEAD
///     current (ours)
///     ||||||| base        (only with merge.conflictStyle diff3/zdiff3)
///     base
///     =======
///     incoming (theirs)
///     >>>>>>> branch
///
/// Ranges are UTF-16 offsets in the document. Content ranges include their lines' newlines,
/// so a side replaces the whole conflict as is.
struct MergeConflict: Equatable {
    /// From the start of the `<<<<<<<` line to the end of the `>>>>>>>` line (with its newline).
    let range: NSRange
    let current: NSRange
    let base: NSRange?
    let incoming: NSRange
    /// The `<<<<<<<` line (without its newline): the actions are drawn after it.
    let startMarker: NSRange
    let currentLabel: String
    let incomingLabel: String

    enum Resolution: String, CaseIterable {
        case current = "Accept Current"
        case incoming = "Accept Incoming"
        case both = "Accept Both"
    }

    /// What the links after the `<<<<<<<` line do.
    enum Action: Equatable, CaseIterable {
        case accept(Resolution)
        case compare
        case mergeEditor

        static let allCases: [Action] = Resolution.allCases.map(Action.accept) + [.compare, .mergeEditor]

        var title: String {
            switch self {
            case .accept(let resolution): resolution.rawValue
            case .compare: "Compare"
            case .mergeEditor: "Merge Editor"
            }
        }
    }

    /// Its two sides, for a diff tab.
    func comparison(in string: NSString) -> ConflictComparison {
        ConflictComparison(current: string.substring(with: current), incoming: string.substring(with: incoming),
                           currentLabel: currentLabel, incomingLabel: incomingLabel)
    }

    /// The text that replaces the conflict.
    func text(for resolution: Resolution, in string: NSString) -> String {
        switch resolution {
        case .current: string.substring(with: current)
        case .incoming: string.substring(with: incoming)
        case .both: string.substring(with: current) + string.substring(with: incoming)
        }
    }
}

enum ConflictParser {
    private static let marker = 7

    /// Whether `range` of `text` holds a conflict's opening `<<<<<<<` (a conflict needs one).
    static func hasStart(in text: NSString, range: NSRange? = nil) -> Bool {
        text.containsRun(of: 0x3C, count: marker, in: range) // "<"
    }

    /// Every complete conflict in `text`, in order. Unfinished or malformed blocks are skipped.
    static func conflicts(in text: NSString) -> [MergeConflict] {
        // Most files have none: one quick scan instead of a line walk.
        guard hasStart(in: text) else { return [] }
        enum State { case idle, current, base, incoming }
        var state = State.idle
        var result: [MergeConflict] = []
        var start = 0, startLineEnd = 0, currentEnd = 0, baseStart: Int?, baseEnd = 0, incomingStart = 0
        var currentLabel = ""

        var lineStart = 0
        let length = text.length
        while lineStart < length {
            var lineEnd = 0, contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let line = NSRange(location: lineStart, length: contentsEnd - lineStart)
            func isMarker(_ character: String, exact: Bool = false) -> Bool {
                guard line.length >= marker,
                      text.substring(with: NSRange(location: lineStart, length: marker)) == String(repeating: character, count: marker)
                else { return false }
                if line.length == marker { return true }
                return !exact && text.character(at: lineStart + marker) == 0x20 // a space before the label
            }
            func label() -> String {
                line.length > marker + 1 ? text.substring(with: NSRange(location: lineStart + marker + 1, length: line.length - marker - 1)) : ""
            }

            if isMarker("<") {
                // A new conflict (an unfinished one before it is dropped).
                state = .current
                start = lineStart
                startLineEnd = lineEnd
                currentLabel = label()
                baseStart = nil
            } else if state == .current, isMarker("|") {
                currentEnd = lineStart
                baseStart = lineEnd
                state = .base
            } else if state == .current || state == .base, isMarker("=", exact: true) {
                if state == .current { currentEnd = lineStart } else { baseEnd = lineStart }
                incomingStart = lineEnd
                state = .incoming
            } else if state == .incoming, isMarker(">") {
                result.append(MergeConflict(
                    range: NSRange(location: start, length: lineEnd - start),
                    current: NSRange(location: startLineEnd, length: currentEnd - startLineEnd),
                    base: baseStart.map { NSRange(location: $0, length: baseEnd - $0) },
                    incoming: NSRange(location: incomingStart, length: lineStart - incomingStart),
                    startMarker: NSRange(location: start, length: (startLineEnd - start) - lineBreakLength(text, start, startLineEnd)),
                    currentLabel: currentLabel, incomingLabel: label()))
                state = .idle
            }
            lineStart = lineEnd
        }
        return result
    }

    private static func lineBreakLength(_ text: NSString, _ start: Int, _ end: Int) -> Int {
        var lineEnd = 0, contentsEnd = 0
        text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
        return end - contentsEnd
    }
}

// MARK: Resolving

extension EditorDocument {
    /// Replaces conflicts with one of their sides, as one undoable edit.
    @discardableResult
    func resolve(_ conflicts: [MergeConflict], with resolution: MergeConflict.Resolution) -> Bool {
        guard !conflicts.isEmpty else { return false }
        let text = textStorage.mutableString
        let edits = conflicts.map { TextReplacement(range: $0.range, text: $0.text(for: resolution, in: text)) }
        let name = conflicts.count == 1 ? resolution.rawValue : "\(resolution.rawValue) (All)"
        return (try? apply(edits, actionName: name)) ?? false
    }

    /// The conflict containing `location` (a cursor on its markers counts).
    func conflict(at location: Int) -> MergeConflict? {
        conflicts.first { NSLocationInRange(location, $0.range) || NSMaxRange($0.range) == location && location == textStorage.length }
    }
}

// MARK: Editor

extension EditorController {
    /// Where a conflict's actions are drawn: after its `<<<<<<<` line. Also the click targets.
    func conflictActionRects() -> [(rect: NSRect, conflict: MergeConflict, action: MergeConflict.Action)] {
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -200)
        let font = Self.conflictActionFont
        var result: [(NSRect, MergeConflict, MergeConflict.Action)] = []
        for conflict in visibleConflicts() {
            guard let line = rect(for: conflict.startMarker.length > 0 ? conflict.startMarker
                                                                       : NSRange(location: conflict.startMarker.location, length: 0)),
                  line.intersects(visible) else { continue }
            var x = line.maxX + 18
            for action in MergeConflict.Action.allCases {
                let width = (action.title as NSString).size(withAttributes: [.font: font]).width
                result.append((NSRect(x: x, y: line.minY, width: width, height: line.height), conflict, action))
                x += width + 14
            }
        }
        return result
    }

    /// Full-width bands behind each side of the visible conflicts: current, base, incoming, markers.
    func conflictBands() -> [(rect: NSRect, kind: ConflictBand)] {
        let visible = textView.visibleRect.insetBy(dx: 0, dy: -200)
        let width = max(textView.bounds.width, visible.maxX)
        var result: [(NSRect, ConflictBand)] = []
        func band(_ range: NSRange, _ kind: ConflictBand) {
            guard range.length > 0, let rect = rect(for: range), rect.intersects(visible) else { return }
            result.append((NSRect(x: 0, y: rect.minY, width: width, height: rect.height), kind))
        }
        let text = document.textStorage.mutableString
        for conflict in visibleConflicts() {
            // Marker lines: everything in the conflict that isn't content.
            let contents = [conflict.current, conflict.base, conflict.incoming].compactMap { $0 }
            var cursor = conflict.range.location
            for content in contents + [NSRange(location: NSMaxRange(conflict.range), length: 0)] {
                if content.location > cursor {
                    let markerLine = text.lineRange(for: NSRange(location: cursor, length: 0))
                    band(NSIntersectionRange(markerLine, NSRange(location: cursor, length: content.location - cursor)), .marker)
                }
                cursor = NSMaxRange(content)
            }
            band(conflict.current, .current)
            if let base = conflict.base { band(base, .base) }
            band(conflict.incoming, .incoming)
        }
        return result
    }

    /// Conflicts near the screen, by character range: measuring others would lay out text
    /// far away on every redraw.
    private func visibleConflicts() -> [MergeConflict] {
        guard !document.conflicts.isEmpty, let near = highlightRange else { return [] }
        return document.conflicts.filter { NSIntersectionRange($0.range, near).length > 0 }
    }

    static var conflictActionFont: NSFont {
        NSFont.systemFont(ofSize: max(10, EditorTheme.font.pointSize - 1), weight: .medium)
    }

    /// Runs the action under a click; true if there was one.
    func handleConflictClick(at point: NSPoint) -> Bool {
        guard let hit = conflictActionRects().first(where: { $0.rect.insetBy(dx: -3, dy: 0).contains(point) }) else { return false }
        switch hit.action {
        case .accept(let resolution): document.resolve([hit.conflict], with: resolution)
        case .compare: compareConflict(hit.conflict)
        case .mergeEditor: document.workspace?.openMergeEditor(document)
        }
        return true
    }

    /// Opens the conflict's two sides in a diff tab (the workspace does; beeps without one).
    func compareConflict(_ conflict: MergeConflict? = nil) {
        guard let conflict = conflict ?? document.conflict(at: textView.selectedRange().location),
              let compare = document.compareConflictAction else { NSSound.beep(); return }
        compare(conflict)
    }

    /// Resolves the conflict at the cursor (palette); beeps if there is none.
    func resolveConflictAtCursor(with resolution: MergeConflict.Resolution) {
        guard let conflict = document.conflict(at: textView.selectedRange().location) else { NSSound.beep(); return }
        document.resolve([conflict], with: resolution)
    }

    /// Moves the cursor to the next (or previous) conflict, wrapping around.
    func revealConflict(forward: Bool) {
        let conflicts = document.conflicts
        guard !conflicts.isEmpty else { NSSound.beep(); return }
        let location = textView.selectedRange().location
        let target = forward
            ? conflicts.first { $0.range.location > location } ?? conflicts[0]
            : conflicts.last { NSMaxRange($0.range) <= location } ?? conflicts[conflicts.count - 1]
        textView.setSelectedRange(NSRange(location: target.range.location, length: 0))
        textView.scrollRangeToVisible(target.range)
    }
}

enum ConflictBand {
    case current, base, incoming, marker

    var color: NSColor {
        switch self {
        case .current: NSColor.systemGreen.withAlphaComponent(0.16)
        case .base: NSColor.systemGray.withAlphaComponent(0.14)
        case .incoming: NSColor.systemBlue.withAlphaComponent(0.16)
        case .marker: NSColor.systemGray.withAlphaComponent(0.22)
        }
    }
}
