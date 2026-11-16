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
}
