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
        let lineCount = lineStarts.count
        let baseLines = base[hunk.oldStart..<(hunk.oldStart + hunk.oldCount)].joined(separator: "\n")
        let endsAtEnd = hunk.newStart + hunk.newCount >= lineCount
        if hunk.newCount == 0 {
            // Lines were deleted: put them back before line newStart (or after the last line).
            if hunk.newStart < lineCount {
                return (NSRange(location: lineStarts[hunk.newStart], length: 0), baseLines + "\n")
            }
            return (NSRange(location: text.length, length: 0), "\n" + baseLines)
        }
        var start = lineStarts[hunk.newStart]
        let end = endsAtEnd ? text.length : lineStarts[hunk.newStart + hunk.newCount]
        if hunk.oldCount == 0 {
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

    static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
