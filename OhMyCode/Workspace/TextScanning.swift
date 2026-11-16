import Foundation

extension NSString {
    /// Calls `body` with the UTF-16 units of `range` a chunk at a time, and the offset of each
    /// chunk; `body` returns false to stop. Much faster than `range(of:)` or reading a character
    /// at a time on a text storage's string (20 MB: 18 ms against 76–124 ms).
    func forEachChunk(in range: NSRange? = nil, _ body: (UnsafeBufferPointer<unichar>, Int) -> Bool) {
        let range = range ?? NSRange(location: 0, length: length)
        guard range.length > 0 else { return }
        let size = min(16 * 1024, range.length)
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: size) { buffer in
            var position = range.location
            let end = NSMaxRange(range)
            while position < end {
                let count = min(size, end - position)
                getCharacters(buffer.baseAddress!, range: NSRange(location: position, length: count))
                guard body(UnsafeBufferPointer(rebasing: buffer[0..<count]), position) else { return }
                position += count
            }
        }
    }

    /// Whether `range` holds `count` of `unit` in a row (a tab; a conflict marker's `<<<<<<<`).
    func containsRun(of unit: unichar, count: Int = 1, in range: NSRange? = nil) -> Bool {
        var run = 0, found = false
        forEachChunk(in: range) { units, _ in
            for current in units {
                run = current == unit ? run + 1 : 0
                if run == count { found = true; return false }
            }
            return true
        }
        return found
    }

    /// Every place `needle` appears from `start` on (compared unit by unit, overlapping places
    /// too), with the units before and after it (nil at the text's ends) for whole-word checks;
    /// `body` returns false to stop. Reads in chunks, like `forEachChunk`.
    func forEachOccurrence(of needle: NSString, from start: Int = 0, _ body: (NSRange, unichar?, unichar?) -> Bool) {
        let count = needle.length, length = length
        guard count > 0, start >= 0, start + count <= length else { return }
        let pattern = [unichar](unsafeUninitializedCapacity: count) { buffer, initialized in
            needle.getCharacters(buffer.baseAddress!, range: NSRange(location: 0, length: count))
            initialized = count
        }
        let first = pattern[0]
        let step = 64 * 1024
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: step + count + 1) { buffer in
            let units = buffer.baseAddress!
            var position = start
            while position + count <= length {
                // The places a match can start in this round, and the text they need: a unit
                // before the first, and the needle's length and a unit more after the last.
                let candidates = min(step, length - count - position + 1)
                let readStart = max(position - 1, 0)
                let readCount = min(position + candidates + count, length) - readStart
                getCharacters(units, range: NSRange(location: readStart, length: readCount))
                let lead = position - readStart
                for index in lead..<lead + candidates where units[index] == first {
                    var matches = true
                    for offset in 1..<count where units[index + offset] != pattern[offset] { matches = false; break }
                    guard matches else { continue }
                    let before = index > 0 ? units[index - 1] : nil
                    let after = index + count < readCount ? units[index + count] : nil
                    guard body(NSRange(location: readStart + index, length: count), before, after) else { return }
                }
                position += candidates
            }
        }
    }
}
