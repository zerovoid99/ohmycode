import Foundation
import Testing
@testable import Oh_My_Code

struct LineIndexRandomTests {
    /// Random edits, some typed in one place, some jumping around: the index always matches
    /// one built from scratch.
    @Test(arguments: [1, 2, 3, 4, 5])
    func matchesARebuildAfterRandomEdits(seed: Int) {
        var generator = SeededGenerator(seed: UInt64(seed))
        let text = NSMutableString(string: (0..<200).map { "line \($0) with some text" }.joined(separator: "\n"))
        var index = LineIndex(string: text)
        var cursor = text.length / 2
        let pieces = ["a", "bc", "\n", "x\ny", "\n\n", "\r\n", "", "long piece of text\n"]
        for step in 0..<3_000 {
            // Mostly typing near the cursor; sometimes somewhere else.
            if Int.random(in: 0..<10, using: &generator) == 0 { cursor = Int.random(in: 0...text.length, using: &generator) }
            cursor = min(cursor, text.length)
            let deleting = Int.random(in: 0..<4, using: &generator) == 0
            let length = deleting ? min(Int.random(in: 0...3, using: &generator), text.length - cursor) : 0
            let piece = pieces.randomElement(using: &generator)!
            text.replaceCharacters(in: NSRange(location: cursor, length: length), with: piece)
            let delta = (piece as NSString).length - length
            index.apply(editedRange: NSRange(location: cursor, length: (piece as NSString).length), changeInLength: delta, in: text)
            cursor += (piece as NSString).length
            if step % 50 == 0 || step == 2_999 {
                let rebuilt = LineIndex(string: text)
                #expect(index.lineStarts.array == rebuilt.lineStarts.array, "seed \(seed), step \(step)")
                if index.lineStarts.array != rebuilt.lineStarts.array { return }
                for offset in stride(from: 0, through: text.length, by: max(1, text.length / 97)) {
                    #expect(index.line(containing: offset) == rebuilt.line(containing: offset))
                }
            }
        }
    }
}

/// Deterministic random numbers (SplitMix64), for reproducible failures.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
