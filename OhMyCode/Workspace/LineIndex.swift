import Foundation

/// UTF-16 offsets of the start of every line, maintained incrementally on edit.
/// Lookups are O(log n); an edit only scans the inserted characters.
struct LineIndex: Equatable {
    private(set) var lineStarts: [Int] = [0]

    var lineCount: Int { lineStarts.count }

    init(string: NSString) {
        lineStarts = [0] + Self.newlineStarts(in: string, range: NSRange(location: 0, length: string.length))
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

        if delta != 0 && removeUpper < lineStarts.count {
            lineStarts.withUnsafeMutableBufferPointer { starts in
                for i in removeUpper..<starts.count { starts[i] &+= delta }
            }
        }
        lineStarts.replaceSubrange(removeLower..<removeUpper,
                                   with: Self.newlineStarts(in: string, range: editedRange))
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
