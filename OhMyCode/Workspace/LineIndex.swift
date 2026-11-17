import Foundation

/// UTF-16 offsets of the start of every line, maintained incrementally on edit.
/// Lookups are O(log n); an edit only scans the inserted characters, and the lines after it
/// move by a pending shift (see `LineStarts`) instead of being rewritten one by one.
struct LineIndex: Equatable {
    /// The line starts, with the shift of the lines after the latest edits applied as they're
    /// read: typing in one place keeps adding to the shift (no work per line); an edit
    /// elsewhere first writes it into the lines it covers.
    struct LineStarts: RandomAccessCollection, Equatable {
        fileprivate var base: [Int]
        /// Lines from here on are `shift` further than `base` says.
        fileprivate var shiftFrom: Int
        fileprivate var shift = 0

        fileprivate init(_ base: [Int]) {
            self.base = base
            shiftFrom = base.count
        }

        var startIndex: Int { 0 }
        var endIndex: Int { base.count }

        subscript(index: Int) -> Int { index >= shiftFrom ? base[index] &+ shift : base[index] }

        /// Writes the pending shift into the lines `from..<to` (that part of it no longer pending).
        fileprivate mutating func settle(_ from: Int, _ to: Int) {
            guard shift != 0, from < to else { return }
            base.withUnsafeMutableBufferPointer { starts in
                for index in from..<to { starts[index] &+= shift }
            }
        }

        /// The starts as a plain array (for code that wants one).
        var array: [Int] { Array(self) }

        static func == (lhs: LineStarts, rhs: LineStarts) -> Bool { lhs.elementsEqual(rhs) }
    }

    private(set) var lineStarts = LineStarts([0])

    /// Where the line starts are stored. Tests check that edits change them in place: a copy of
    /// the index kept somewhere makes each edit copy all of them.
    var storageAddress: UnsafeRawPointer? {
        lineStarts.base.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    var lineCount: Int { lineStarts.count }

    init(string: NSString) {
        lineStarts = LineStarts([0] + Self.newlineStarts(in: string, range: NSRange(location: 0, length: string.length)))
    }

    /// UTF-16 offset for an LSP position (line, UTF-16 column), clamped to its line and the text.
    func offset(for position: LSPPosition, length: Int) -> Int {
        guard position.line < lineCount else { return length }
        // Before the first line is the start of the text (servers and extensions can send any line).
        guard position.line >= 0 else { return 0 }
        let lineStart = lineStarts[position.line]
        let lineEnd = position.line + 1 < lineCount ? lineStarts[position.line + 1] - 1 : length
        return min(lineStart + max(0, position.character), max(lineStart, lineEnd))
    }

    func range(for range: LSPRange, length: Int) -> NSRange {
        let start = offset(for: range.start, length: length)
        let end = max(start, offset(for: range.end, length: length))
        return NSRange(location: start, length: end - start)
    }

    /// Text of a zero-based line, without its newline.
    func lineText(_ line: Int, in string: NSString) -> String {
        guard line >= 0, line < lineCount else { return "" }
        let start = lineStarts[line]
        var end = line + 1 < lineCount ? lineStarts[line + 1] - 1 : string.length
        if end > start, string.character(at: end - 1) == 0x0D { end -= 1 }
        return string.substring(with: NSRange(location: start, length: max(0, end - start)))
    }

    /// Zero-based line containing the UTF-16 `offset`.
    func line(containing offset: Int) -> Int {
        max(0, upperBound(offset) - 1)
    }

    /// Update for an edit as reported by `NSTextStorageDelegate`:
    /// `editedRange` is in post-edit coordinates, `delta` is the change in length.
    mutating func apply(editedRange: NSRange, changeInLength delta: Int, in string: NSString) {
        let location = editedRange.location
        let oldEnd = location + editedRange.length - delta

        // Line starts produced by newlines inside the replaced range: (location, oldEnd].
        let removeLower = upperBound(location)
        let removeUpper = upperBound(oldEnd)

        // The pending shift has to start at `removeUpper`: write it into the lines between
        // where it starts and there (few, typing in one place; all of them once, editing above).
        if lineStarts.shiftFrom < removeUpper {
            lineStarts.settle(lineStarts.shiftFrom, removeUpper)
        } else if lineStarts.shiftFrom > removeUpper {
            lineStarts.settle(lineStarts.shiftFrom, lineStarts.base.count)
            lineStarts.shift = 0
        }
        let inserted = Self.newlineStarts(in: string, range: editedRange)
        lineStarts.base.replaceSubrange(removeLower..<removeUpper, with: inserted)
        // The lines after the edit move by `delta`, on top of what was pending.
        lineStarts.shift &+= delta
        lineStarts.shiftFrom = removeUpper + inserted.count - (removeUpper - removeLower)
        if lineStarts.shift == 0 { lineStarts.shiftFrom = lineStarts.base.count }
    }

    /// Index of the first line start strictly greater than `offset`.
    private func upperBound(_ offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func newlineStarts(in string: NSString, range: NSRange) -> [Int] {
        var result: [Int] = []
        guard range.length > 0 else { return result }
        let chunkSize = min(16 * 1024, range.length)
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: chunkSize) { buffer in
            var position = range.location
            let end = NSMaxRange(range)
            while position < end {
                let length = min(chunkSize, end - position)
                string.getCharacters(buffer.baseAddress!, range: NSRange(location: position, length: length))
                for i in 0..<length where buffer[i] == 0x0A {
                    result.append(position + i + 1)
                }
                position += length
            }
        }
        return result
    }
}
