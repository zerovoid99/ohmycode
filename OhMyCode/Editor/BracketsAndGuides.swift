import AppKit
import SwiftTreeSitter

/// The bracket matching the one beside the cursor (both outlined), and indent guides: a thin
/// line at each indentation level, brighter for the block the cursor is in.
extension EditorController {
    static let bracketPairs: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D] // ( [ {

    /// The language configuration's brackets (single characters), else ( [ {.
    var bracketPairs: [UInt16: UInt16] {
        guard let brackets = LanguageRegistry.shared.configuration(for: document.language)?.brackets else { return Self.bracketPairs }
        var pairs: [UInt16: UInt16] = [:]
        for bracket in brackets where bracket.open.utf16.count == 1 && bracket.close.utf16.count == 1 {
            pairs[bracket.open.utf16.first!] = bracket.close.utf16.first!
        }
        return pairs
    }
    /// How far to look for a match (a missing bracket in a huge file stays cheap).
    static let bracketSearchLimit = 100_000

    // MARK: Brackets

    /// Remembers where strings and comments are in the highlighted text: brackets there don't count.
    func rememberNonCode(_ highlights: [NamedRange]) {
        nonCodeRanges = highlights.filter { highlight in
            let name = highlight.name
            return name.hasPrefix("string") || name.hasPrefix("comment") || name.hasPrefix("character")
                || (TextMateScopes.isScopeList(name) && TextMateScopes.isNonCode(name))
        }.map(\.range).sorted { $0.location < $1.location }
        nonCodeVersion = document.editVersion
        bracketCache = nil
    }

    /// Whether a character is in a string or a comment (as far as the last highlights tell).
    private func isNonCode(_ index: Int) -> Bool {
        guard nonCodeVersion == document.editVersion, !nonCodeRanges.isEmpty else { return false }
        // Binary search: the last range starting at or before `index`.
        var low = 0, high = nonCodeRanges.count - 1, found = -1
        while low <= high {
            let middle = (low + high) / 2
            if nonCodeRanges[middle].location <= index { found = middle; low = middle + 1 } else { high = middle - 1 }
        }
        // Ranges can nest (an escape inside a string): check a few before too.
        var candidate = found
        while candidate >= 0, candidate >= found - 4 {
            if NSLocationInRange(index, nonCodeRanges[candidate]) { return true }
            candidate -= 1
        }
        return false
    }

    /// The bracket at `index` and its match, if both are code.
    func matchingBracket(at index: Int) -> Int? {
        let text = document.textStorage.mutableString
        guard index >= 0, index < text.length, !isNonCode(index) else { return nil }
        let bracketPairs = self.bracketPairs
        let unit = text.character(at: index)
        if let close = bracketPairs[unit] {
            return scan(from: index + 1, step: 1, open: unit, close: close)
        }
        if let open = bracketPairs.first(where: { $0.value == unit })?.key {
            return scan(from: index - 1, step: -1, open: unit, close: open)
        }
        return nil
    }

    /// Walks from `start` counting `open` (nesting) until an unmatched `close`.
    private func scan(from start: Int, step: Int, open: UInt16, close: UInt16) -> Int? {
        let text = document.textStorage.mutableString
        var depth = 0
        var index = start
        var steps = 0
        while index >= 0, index < text.length, steps < Self.bracketSearchLimit {
            let unit = text.character(at: index)
            if unit == open || unit == close, !isNonCode(index) {
                if unit == open {
                    depth += 1
                } else if depth == 0 {
                    return index
                } else {
                    depth -= 1
                }
            }
            index += step
            steps += 1
        }
        return nil
    }

    /// The bracket pair beside the cursor: the one before it, else the one after.
    func bracketPairAtCursor() -> (Int, Int)? {
        guard AppSettings.shared.highlightsMatchingBrackets else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        if let bracketCache, bracketCache.location == selection.location, bracketCache.version == document.editVersion {
            return bracketCache.pair
        }
        var pair: (Int, Int)?
        for index in [selection.location - 1, selection.location] {
            if let match = matchingBracket(at: index) { pair = (index, match); break }
        }
        bracketCache = (selection.location, document.editVersion, pair)
        return pair
    }

    /// Rects of the cursor's bracket and its match.
    func bracketRects() -> [NSRect] {
        guard let (one, other) = bracketPairAtCursor() else { return [] }
        return [one, other].compactMap { rect(for: NSRange(location: $0, length: 1)) }
    }

    /// Go to Bracket: to the match of the bracket beside the cursor, or to the closing bracket
    /// of the pair the cursor is in.
    func jumpToBracket() {
        let selection = textView.selectedRange()
        let location = selection.location
        var target: Int?
        for index in [location - 1, location] {
            if let match = matchingBracket(at: index) { target = match; break }
        }
        if target == nil {
            // Inside a pair: its nearest unmatched opener, then that one's match.
            let text = document.textStorage.mutableString
            let bracketPairs = self.bracketPairs
            var depths: [UInt16: Int] = [:]
            var index = location - 1
            var steps = 0
            while index >= 0, steps < Self.bracketSearchLimit, target == nil {
                let unit = text.character(at: index)
                if !isNonCode(index) {
                    if let open = bracketPairs.first(where: { $0.value == unit })?.key {
                        depths[open, default: 0] += 1
                    } else if bracketPairs[unit] != nil {
                        if depths[unit, default: 0] == 0 { target = matchingBracket(at: index) } else { depths[unit]! -= 1 }
                    }
                }
                index -= 1
                steps += 1
            }
        }
        guard let target else { NSSound.beep(); return }
        textView.setSelectedRange(NSRange(location: target, length: 0))
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    // MARK: Indent guides

    /// Columns of indentation of a line (tabs count as the tab width); nil for blank lines.
    func indentColumns(ofLine line: Int, tabSize: Int) -> Int? {
        let text = document.textStorage.mutableString
        let index = document.lineIndex
        var position = index.lineStarts[line]
        let end = line + 1 < index.lineCount ? index.lineStarts[line + 1] : text.length
        var columns = 0
        while position < end {
            switch text.character(at: position) {
            case 0x20: columns += 1
            case 0x09: columns += tabSize - columns % tabSize
            case 0x0A, 0x0D: return nil
            default: return columns
            }
            position += 1
        }
        return nil
    }

    /// A line's indent level; a blank line takes the smaller of its neighbours' (so guides
    /// run through blank lines inside a block).
    func indentLevel(ofLine line: Int, tabSize: Int) -> Int {
        if let columns = indentColumns(ofLine: line, tabSize: tabSize) { return columns / tabSize }
        let count = document.lineIndex.lineCount
        func nearest(_ step: Int) -> Int {
            var other = line + step
            var looked = 0
            while other >= 0, other < count, looked < 200 {
                if let columns = indentColumns(ofLine: other, tabSize: tabSize) { return columns / tabSize }
                other += step
                looked += 1
            }
            return 0
        }
        return min(nearest(-1), nearest(1))
    }

    /// The indent guide of the block the cursor is in: its level (guides are drawn at levels
    /// 0..<a line's level) and its lines.
    func activeIndentGuide(tabSize: Int) -> (level: Int, lines: ClosedRange<Int>)? {
        let count = document.lineIndex.lineCount
        let cursorLine = document.lineIndex.line(containing: textView.selectedRange().location)
        let level = indentLevel(ofLine: cursorLine, tabSize: tabSize)
        // On a line that opens a block: that block's guide.
        var next = cursorLine + 1
        while next < count, indentColumns(ofLine: next, tabSize: tabSize) == nil { next += 1 }
        let opensBlock = next < count && indentLevel(ofLine: next, tabSize: tabSize) > level
            && indentColumns(ofLine: cursorLine, tabSize: tabSize) != nil
        let guide = opensBlock ? level : level - 1
        guard guide >= 0 else { return nil }
        var first = opensBlock ? cursorLine + 1 : cursorLine
        var last = first
        // Far enough for any screen (a huge block stays cheap to redraw on every keystroke).
        let reach = 2_000
        while first - 1 >= 0, cursorLine - first < reach, indentLevel(ofLine: first - 1, tabSize: tabSize) > guide { first -= 1 }
        while last + 1 < count, last - cursorLine < reach, indentLevel(ofLine: last + 1, tabSize: tabSize) > guide { last += 1 }
        return (guide, first...last)
    }

    /// The guides in `rect` (the visible rect by default) and the viewport: one thin rect per
    /// line and level, and whether it's the active block's. `onlyActive`: just those, the same
    /// rects, its lines looked up one by one (the cursor's marks, on every cursor move).
    func indentGuideRects(in rect: NSRect? = nil, onlyActive: Bool = false) -> [(rect: NSRect, isActive: Bool)] {
        guard AppSettings.shared.showsIndentGuides, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange else { return [] }
        let tabSize = max(1, document.displayTabWidth)
        let active = activeIndentGuide(tabSize: tabSize)
        if onlyActive, active == nil { return [] }
        let space = (" " as NSString).size(withAttributes: [.font: EditorTheme.font]).width
        let origin = textView.textContainerOrigin
        let left = origin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        let area = rect ?? textView.visibleRect
        let documentStart = contentManager.documentRange.location
        let index = document.lineIndex
        var result: [(NSRect, Bool)] = []
        // A line's guides (levels in `levels`), from its paragraph's frame.
        func add(line: Int, fragment: NSTextLayoutFragment, levels: Range<Int>) {
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            guard frame.maxY >= area.minY, frame.minY <= area.maxY else { return }
            for guide in levels {
                let x = left + CGFloat(guide * tabSize) * space
                let isActive = active.map { $0.level == guide && $0.lines.contains(line) } ?? false
                result.append((NSRect(x: floor(x), y: frame.minY, width: 1, height: frame.height), isActive))
            }
        }
        let viewStart = contentManager.offset(from: documentStart, to: viewport.location)
        let viewEnd = contentManager.offset(from: documentStart, to: viewport.endLocation)
        if onlyActive, let active {
            // The block's lines in the viewport, each its own paragraph (a hidden line isn't).
            let first = max(active.lines.lowerBound, index.line(containing: viewStart))
            let last = min(active.lines.upperBound, index.line(containing: max(viewStart, viewEnd - 1)))
            guard first <= last else { return [] }
            for line in first...last {
                let start = index.lineStarts[line]
                guard let location = contentManager.location(documentStart, offsetBy: start),
                      let fragment = layoutManager.textLayoutFragment(for: location),
                      contentManager.offset(from: documentStart, to: fragment.rangeInElement.location) == start else { continue }
                let level = indentLevel(ofLine: line, tabSize: tabSize)
                add(line: line, fragment: fragment, levels: active.level..<max(active.level, min(level, active.level + 1)))
            }
            return result
        }
        // The viewport's paragraphs down to the bottom of `area`; those above it are skipped
        // before their indentation is read.
        layoutManager.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > area.maxY { return false }
            let more = fragment.rangeInElement.endLocation.compare(viewport.endLocation) == .orderedAscending
            if frame.maxY + origin.y < area.minY { return more }
            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            guard offset <= document.textStorage.length else { return false }
            let line = index.line(containing: offset)
            add(line: line, fragment: fragment, levels: 0..<indentLevel(ofLine: line, tabSize: tabSize))
            return more
        }
        return result
    }
}
