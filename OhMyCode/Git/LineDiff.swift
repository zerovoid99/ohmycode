import Foundation

enum DiffMarker: Sendable, Equatable {
    case added, modified
    /// Lines were removed just above this line.
    case deletedAbove
}

/// Line-level diff between the index version and the buffer, for gutter markers.
enum LineDiff {
    /// Above this many differing lines (after trimming the common prefix/suffix) the middle is
    /// marked modified as a whole instead of running Myers, whose cost grows with the change size.
    static let maxDiffLines = 20_000

    /// Markers keyed by zero-based line in `current`.
    static func markers(base: [Substring], current: [Substring]) -> [Int: DiffMarker] {
        var prefix = 0
        while prefix < base.count, prefix < current.count, base[prefix] == current[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < base.count - prefix, suffix < current.count - prefix,
              base[base.count - 1 - suffix] == current[current.count - 1 - suffix] { suffix += 1 }

        let old = base[prefix..<(base.count - suffix)]
        let new = current[prefix..<(current.count - suffix)]
        var markers: [Int: DiffMarker] = [:]
        if old.isEmpty && new.isEmpty { return markers }
        if old.count + new.count > maxDiffLines {
            for line in new.indices { markers[line] = .modified }
            if new.isEmpty { markers[prefix] = .deletedAbove }
            return markers
        }

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
            let kind: DiffMarker = removedRun > 0 && insertedRun > 0 ? .modified : .added
            for k in 0..<insertedRun { markers[prefix + j + k] = kind }
            if insertedRun == 0 { markers[prefix + j] = .deletedAbove }
            i += removedRun
            j += insertedRun
        }
        return markers
    }

    static func lines(_ text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}
