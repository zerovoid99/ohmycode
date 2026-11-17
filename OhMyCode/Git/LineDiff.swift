import Foundation

enum DiffMarker: Sendable, Equatable {
    case added, modified
    /// Lines were removed just above this line.
    case deletedAbove
}

/// A changed region: `oldCount` lines at `oldStart` in the base became `newCount` lines at
/// `newStart` in the current text (zero-based line numbers).
struct DiffHunk: Sendable, Equatable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int

    /// Whether a gutter marker on `line` (current text) belongs to this hunk.
    func contains(line: Int) -> Bool {
        newCount == 0 ? line == newStart : (newStart..<(newStart + newCount)).contains(line)
    }
}

/// One row of a hunk: a changed line pair, or a line only removed (`new` nil) or only added.
struct DiffLinePair: Hashable, Sendable {
    let old: Int?
    let new: Int?
}

/// Line-level diff between the index version and the buffer, for gutter markers.
enum LineDiff {
    /// Above this many differing lines (after trimming the common prefix/suffix) the middle is
    /// marked modified as a whole instead of running Myers, whose cost grows with the change size.
    static let maxDiffLines = 20_000

    /// Markers keyed by zero-based line in `current`.
    static func markers(base: [Substring], current: [Substring]) -> [Int: DiffMarker] {
        markers(for: hunks(base: base, current: current))
    }

    static func markers(for hunks: [DiffHunk]) -> [Int: DiffMarker] {
        var markers: [Int: DiffMarker] = [:]
        for hunk in hunks {
            if hunk.newCount == 0 {
                markers[hunk.newStart] = .deletedAbove
            } else {
                let kind: DiffMarker = hunk.oldCount > 0 ? .modified : .added
                for line in hunk.newStart..<(hunk.newStart + hunk.newCount) { markers[line] = kind }
            }
        }
        return markers
    }

    static func hunks(base: [Substring], current: [Substring]) -> [DiffHunk] {
        var prefix = 0
        while prefix < base.count, prefix < current.count, base[prefix] == current[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < base.count - prefix, suffix < current.count - prefix,
              base[base.count - 1 - suffix] == current[current.count - 1 - suffix] { suffix += 1 }

        let old = base[prefix..<(base.count - suffix)]
        let new = current[prefix..<(current.count - suffix)]
        if old.isEmpty && new.isEmpty { return [] }
        if old.count + new.count > maxDiffLines {
            return [DiffHunk(oldStart: prefix, oldCount: old.count, newStart: prefix, newCount: new.count)]
        }
        var hunks: [DiffHunk] = []

        let difference = Array(new).difference(from: Array(old))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Walk both sides in step; unchanged lines pair up in order between change runs.
        var i = 0, j = 0
        while i < old.count || j < new.count {
            var removedRun = 0, insertedRun = 0
            while removed.contains(i + removedRun) { removedRun += 1 }
            while inserted.contains(j + insertedRun) { insertedRun += 1 }
            if removedRun == 0 && insertedRun == 0 {
                i += 1; j += 1
                continue
            }
            hunks.append(DiffHunk(oldStart: prefix + i, oldCount: removedRun, newStart: prefix + j, newCount: insertedRun))
            i += removedRun
            j += insertedRun
        }
        return hunks
    }

    /// The edit that undoes `hunk` in `current`: a UTF-16 range of `text` and its replacement.
    /// Applying it makes those lines equal the base again.
    static func revertEdit(for hunk: DiffHunk, base: [Substring], text: NSString,
                           lineStarts: [Int]) -> (range: NSRange, replacement: String) {
        replaceEdit(for: hunk, with: Array(base[hunk.oldStart..<(hunk.oldStart + hunk.oldCount)]),
                    text: text, lineStarts: lineStarts)
    }

    /// The edit that turns the hunk's lines in `text` into `lines` (any number, none deletes them).
    static func replaceEdit(for hunk: DiffHunk, with lines: [Substring], text: NSString,
                            lineStarts: [Int]) -> (range: NSRange, replacement: String) {
        let lineCount = lineStarts.count
        let baseLines = lines.joined(separator: "\n")
        let endsAtEnd = hunk.newStart + hunk.newCount >= lineCount
        if hunk.newCount == 0 {
            let at = hunk.newStart < lineCount ? lineStarts[hunk.newStart] : text.length
            guard !lines.isEmpty else { return (NSRange(location: at, length: 0), "") } // nothing to put back
            // Lines were deleted: put them back before line newStart (or after the last line).
            if hunk.newStart < lineCount { return (NSRange(location: at, length: 0), baseLines + "\n") }
            return (NSRange(location: text.length, length: 0), "\n" + baseLines)
        }
        var start = lineStarts[hunk.newStart]
        let end = endsAtEnd ? text.length : lineStarts[hunk.newStart + hunk.newCount]
        if lines.isEmpty {
            // Added lines go away entirely; at the end of the file, so does the newline before them.
            if endsAtEnd && start > 0 { start -= 1 }
            return (NSRange(location: start, length: end - start), "")
        }
        return (NSRange(location: start, length: end - start), baseLines + (endsAtEnd ? "" : "\n"))
    }

    /// `old` with the hunk's lines replaced by its lines in `new`: staging one change of
    /// `old` (index) → `new` (working tree) gives the new index text.
    static func applying(_ hunk: DiffHunk, old: [Substring], new: [Substring]) -> String {
        var result = old
        result.replaceSubrange(hunk.oldStart..<(hunk.oldStart + hunk.oldCount),
                               with: new[hunk.newStart..<(hunk.newStart + hunk.newCount)])
        return result.joined(separator: "\n")
    }

    /// `new` with the hunk's lines put back as they are in `old`: unstaging one change of
    /// `old` (HEAD) → `new` (index) gives the new index text.
    static func reverting(_ hunk: DiffHunk, old: [Substring], new: [Substring]) -> String {
        var result = new
        result.replaceSubrange(hunk.newStart..<(hunk.newStart + hunk.newCount),
                               with: old[hunk.oldStart..<(hunk.oldStart + hunk.oldCount)])
        return result.joined(separator: "\n")
    }

    /// The rows of a hunk as the diff view shows them: old and new lines paired in order, then
    /// the extra removed or added lines.
    static func pairs(in hunk: DiffHunk) -> [DiffLinePair] {
        let paired = min(hunk.oldCount, hunk.newCount)
        return (0..<paired).map { DiffLinePair(old: hunk.oldStart + $0, new: hunk.newStart + $0) }
            + (paired..<hunk.oldCount).map { DiffLinePair(old: hunk.oldStart + $0, new: nil) }
            + (paired..<hunk.newCount).map { DiffLinePair(old: nil, new: hunk.newStart + $0) }
    }

    /// `old` with the changed rows for which `useNew` is true taken from `new`: a changed pair
    /// becomes its new line, a removed line goes, an added line comes in. Rows left out stay as
    /// in `old`. Staging selected lines (old = index, new = working tree) gives the new index;
    /// unstaging them (old = HEAD, new = index) uses the rows *not* selected.
    static func mixing(old: [Substring], new: [Substring], hunks: [DiffHunk],
                       useNew: (DiffLinePair) -> Bool) -> String {
        var result: [Substring] = []
        var oldLine = 0
        for hunk in hunks {
            result.append(contentsOf: old[oldLine..<hunk.oldStart])
            for pair in pairs(in: hunk) {
                let line = useNew(pair) ? pair.new.map { new[$0] } : pair.old.map { old[$0] }
                if let line { result.append(line) }
            }
            oldLine = hunk.oldStart + hunk.oldCount
        }
        result.append(contentsOf: old[oldLine...])
        return result.joined(separator: "\n")
    }

    /// Which rows a selection of lines in the new text (zero-based) covers. Removed lines have
    /// no line there: they count when the selection touches their hunk's new lines, or for a
    /// pure deletion, the line it sits on or the one above.
    static func rows(touching lines: Set<Int>, in hunks: [DiffHunk]) -> Set<DiffLinePair> {
        var selected = Set<DiffLinePair>()
        for hunk in hunks {
            let touched = hunk.newCount == 0
                ? lines.contains(hunk.newStart) || lines.contains(hunk.newStart - 1)
                : (hunk.newStart..<(hunk.newStart + hunk.newCount)).contains { lines.contains($0) }
            guard touched else { continue }
            for pair in pairs(in: hunk) where pair.new.map(lines.contains) ?? true { selected.insert(pair) }
        }
        return selected
    }

    /// Edits that revert the chosen rows of `hunks` in the current text to `old`, leaving the
    /// other rows as they are: one edit per hunk touched, in the current text's coordinates.
    static func revertEdits(rows: Set<DiffLinePair>, hunks: [DiffHunk], old: [Substring], new: [Substring],
                            text: NSString, lineStarts: [Int]) -> [(range: NSRange, replacement: String)] {
        hunks.compactMap { hunk in
            let pairs = pairs(in: hunk)
            guard pairs.contains(where: rows.contains) else { return nil }
            let lines = pairs.compactMap { pair in rows.contains(pair) ? pair.old.map { old[$0] } : pair.new.map { new[$0] } }
            return replaceEdit(for: hunk, with: lines, text: text, lineStarts: lineStarts)
        }
    }

    /// The lines of `text`, split on each "\n" like the editor's line index. A "\r" before it
    /// stays in the line: splitting on Characters would treat "\r\n" as one character that
    /// isn't "\n", and a CRLF file would come out as a single line.
    static func lines(_ text: String) -> [Substring] {
        let utf8 = text.utf8
        var lines: [Substring] = []
        var start = utf8.startIndex
        while let newline = utf8[start...].firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Substring(text.unicodeScalars[start..<newline]))
            start = utf8.index(after: newline)
        }
        lines.append(Substring(text.unicodeScalars[start...]))
        return lines
    }
}
