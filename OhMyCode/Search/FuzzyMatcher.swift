import Foundation

/// A string prepared once for repeated fuzzy matching (e.g. a file's relative path).
struct FuzzyCandidate: Sendable {
    let text: String
    let bytes: [UInt8]
    let lowercased: [UInt8]
    /// Byte offset where the last path component starts.
    let nameStart: Int

    init(_ text: String) {
        self.text = text
        bytes = Array(text.utf8)
        lowercased = bytes.map(FuzzyMatcher.asciiLowercase)
        nameStart = (bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
    }
}

struct FuzzyMatch: Sendable, Equatable {
    let score: Int
    /// UTF-8 byte offsets of matched characters in the candidate text.
    let positions: [Int]
}

/// Subsequence matcher in the style of fzf v1: a forward scan finds a match, a backward scan
/// tightens it to the shortest window, then the window is scored. Prefers matches in the file
/// name, at word boundaries and in consecutive runs. Linear in the candidate length.
enum FuzzyMatcher {
    static func prepareQuery(_ query: String) -> [UInt8] {
        query.utf8.filter { $0 != UInt8(ascii: " ") }.map(asciiLowercase)
    }

    static func match(_ query: [UInt8], _ candidate: FuzzyCandidate) -> FuzzyMatch? {
        guard !query.isEmpty else { return FuzzyMatch(score: 0, positions: []) }
        // Prefer a match entirely inside the file name; fall back to the whole path.
        if let positions = window(query, candidate, from: candidate.nameStart) {
            return FuzzyMatch(score: score(positions, candidate) + 40, positions: positions)
        }
        guard candidate.nameStart > 0, let positions = window(query, candidate, from: 0) else { return nil }
        return FuzzyMatch(score: score(positions, candidate), positions: positions)
    }

    /// Best `limit` matches, highest score first. Checks for cancellation while scanning.
    static func search(_ query: String, in candidates: [FuzzyCandidate], limit: Int) -> [(index: Int, match: FuzzyMatch)] {
        let prepared = prepareQuery(query)
        var results: [(index: Int, match: FuzzyMatch)] = []
        for (index, candidate) in candidates.enumerated() {
            if index & 4095 == 0, Task.isCancelled { return [] }
            if let match = match(prepared, candidate) {
                results.append((index, match))
            }
        }
        results.sort { lhs, rhs in
            if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
            let l = candidates[lhs.index], r = candidates[rhs.index]
            if l.bytes.count != r.bytes.count { return l.bytes.count < r.bytes.count }
            return l.text < r.text
        }
        return Array(results.prefix(limit))
    }

    private static func window(_ query: [UInt8], _ candidate: FuzzyCandidate, from start: Int) -> [Int]? {
        let text = candidate.lowercased
        // Forward: earliest position where the whole query has matched.
        var q = 0, end = -1
        var i = start
        while i < text.count {
            if text[i] == query[q] {
                q += 1
                if q == query.count { end = i; break }
            }
            i += 1
        }
        guard end >= 0 else { return nil }
        // Backward from `end`: latest start that still matches, giving the tightest window.
        q = query.count - 1
        var windowStart = end
        i = end
        while i >= start {
            if text[i] == query[q] {
                if q == 0 { windowStart = i; break }
                q -= 1
            }
            i -= 1
        }
        // Forward again inside the window to record positions.
        var positions: [Int] = []
        positions.reserveCapacity(query.count)
        q = 0
        i = windowStart
        while q < query.count {
            if text[i] == query[q] { positions.append(i); q += 1 }
            i += 1
        }
        return positions
    }

    private static func score(_ positions: [Int], _ candidate: FuzzyCandidate) -> Int {
        let bytes = candidate.bytes
        var score = 0
        for (n, p) in positions.enumerated() {
            score += 16
            let previous = p > 0 ? bytes[p - 1] : UInt8(ascii: "/")
            if p == candidate.nameStart {
                score += 24
            } else if isSeparator(previous) {
                score += 12
            } else if isLower(previous) && isUpper(bytes[p]) {
                score += 10
            }
            if n > 0 {
                let gap = p - positions[n - 1] - 1
                score += gap == 0 ? 12 : -min(gap, 8)
            }
        }
        return score - bytes.count / 8
    }

    static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    private static func isUpper(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }
    private static func isLower(_ byte: UInt8) -> Bool { byte >= 97 && byte <= 122 }
    private static func isSeparator(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "/"), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: " "): true
        default: false
        }
    }
}
