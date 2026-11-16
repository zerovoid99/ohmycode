import AppKit

/// The syntax colors an editor last gave TextKit, one per character of the range they were
/// applied to, kept in step with edits the way TextKit keeps its rendering attributes: text
/// after an edit moves with it, and the edited text has no color it can be sure of.
///
/// Applying colors costs TextKit about 2 µs per run (removing and adding rendering attributes),
/// and a keystroke's parse gives back the colors of the whole highlighted range, unchanged but
/// for the edited line or two; a scroll step mostly overlaps the range colored before. With
/// this, only the characters whose color changed are given to TextKit.
struct AppliedColors {
    /// A color's index in `palette`, plus one; `none` is no color.
    typealias Index = UInt8
    static let none: Index = 0
    /// What TextKit has there isn't known (edited, or never applied by this): set it again.
    static let unknown: Index = .max
    /// Longest edit (in characters) kept track of inside the range; a longer one forgets it all.
    static let maxTrackedEdit = 4096

    private(set) var range = NSRange(location: 0, length: 0)
    private(set) var colors: [Index] = []
    private(set) var palette: [NSColor] = []

    /// The index for `color`, adding it to the palette (nil when it's full: call `reset`).
    mutating func index(of color: NSColor) -> Index? {
        if let found = palette.firstIndex(where: { $0 === color || $0 == color }) { return Index(found + 1) }
        guard palette.count + 1 < Int(Self.unknown) else { return nil }
        palette.append(color)
        return Index(palette.count)
    }

    func color(_ index: Index) -> NSColor? {
        index == Self.none || index == Self.unknown ? nil : palette[Int(index) - 1]
    }

    /// Forgets everything (and the palette, which only ever grows otherwise: themes change).
    mutating func reset() {
        self = AppliedColors()
    }

    /// The color known to be applied at `offset`.
    func applied(at offset: Int) -> Index {
        let local = offset - range.location
        return local >= 0 && local < colors.count ? colors[local] : Self.unknown
    }

    /// The text `start..<oldEnd` (pre-edit offsets) was replaced by `newLength` characters.
    mutating func edit(start: Int, oldEnd: Int, newLength: Int) {
        guard !colors.isEmpty else { return }
        let delta = newLength - (oldEnd - start)
        if oldEnd <= range.location {
            range.location += delta
        } else if start >= NSMaxRange(range) {
            // After it: nothing moves.
        } else if start >= range.location, oldEnd <= NSMaxRange(range), newLength <= Self.maxTrackedEdit {
            let local = start - range.location
            colors.replaceSubrange(local..<(oldEnd - range.location), with: repeatElement(Self.unknown, count: newLength))
            range.length += delta
        } else {
            reset() // across its edge, or too big to be worth it
        }
    }

    /// Records `new` (one index per character of `newRange`) as applied, and returns the
    /// parts of `newRange` to give TextKit: each with whether its old colors must be removed
    /// first. Parts closer than `gap` characters are joined (a range costs more than a few
    /// characters set to what they already are).
    mutating func update(to new: [Index], in newRange: NSRange, gap: Int = 32) -> [(range: NSRange, remove: Bool)] {
        precondition(new.count == newRange.length)
        var spans: [(range: NSRange, remove: Bool)] = []
        var spanStart = -1, spanEnd = -1, remove = false
        new.withUnsafeBufferPointer { new in
            colors.withUnsafeBufferPointer { old in
                let shift = newRange.location - range.location // old index of new[0]
                for index in 0..<new.count {
                    let oldIndex = index + shift
                    let before = oldIndex >= 0 && oldIndex < old.count ? old[oldIndex] : Self.unknown
                    guard before != new[index] else { continue }
                    if spanStart >= 0, index - spanEnd < gap {
                        spanEnd = index + 1
                    } else {
                        if spanStart >= 0 {
                            spans.append((NSRange(location: newRange.location + spanStart, length: spanEnd - spanStart), remove))
                        }
                        spanStart = index
                        spanEnd = index + 1
                        remove = false
                    }
                    if before != Self.none { remove = true }
                }
            }
        }
        if spanStart >= 0 {
            spans.append((NSRange(location: newRange.location + spanStart, length: spanEnd - spanStart), remove))
        }
        // The caller adds every run of `new` in each span: that also covers the characters of a
        // joined gap (they had their color already, so they never need removing).
        range = newRange
        colors = new
        return spans
    }
}
