import AppKit

/// Code folding. Fold regions come from indentation, like VS Code's default: a line folds the
/// lines after it that are indented deeper, so `func f() {` folds its body and the closing `}`
/// stays visible. Folded lines are hidden from TextKit 2 layout through the content storage
/// delegate (`shouldEnumerate`), so the text itself is untouched. Folds belong to the document:
/// every split view of it shows them.
extension EditorDocument {
    /// Indent width of a line (tabs count 4), or nil for a blank line.
    func indentation(ofLine line: Int) -> Int? {
        let text = textStorage.mutableString
        var position = lineIndex.lineStarts[line]
        let end = line + 1 < lineIndex.lineCount ? lineIndex.lineStarts[line + 1] - 1 : text.length
        var width = 0
        while position < end {
            switch text.character(at: position) {
            case 0x20: width += 1
            case 0x09: width += 4
            case 0x0D: break
            default: return width
            }
            position += 1
        }
        return nil
    }

    /// The lines `header` folds (header excluded), or nil if it doesn't start a fold region: the
    /// code's structure says (see FoldRegions.swift), else indentation.
    func foldRange(atLine header: Int) -> ClosedRange<Int>? {
        if let region = structuralFold(atLine: header) { return (header + 1)...region.end }
        return foldsByIndentation ? indentationFoldRange(atLine: header) : nil
    }

    /// Whether `line` starts a fold region.
    func isFoldable(line: Int) -> Bool {
        structuralFold(atLine: line) != nil || (foldsByIndentation && isIndentationFoldable(line: line))
    }

    /// Indentation folds code only when the structure gives no code regions (Python, YAML,
    /// plain text): with brackets, it would add a region per `) {` line inside a declaration.
    var foldsByIndentation: Bool { !foldRegions.values.contains { $0.kind == .code } }

    /// The lines deeper-indented than `header` after it.
    func indentationFoldRange(atLine header: Int) -> ClosedRange<Int>? {
        guard header < lineIndex.lineCount, let base = indentation(ofLine: header) else { return nil }
        var last: Int?
        var line = header + 1
        while line < lineIndex.lineCount {
            if let indent = indentation(ofLine: line) {
                if indent <= base { break }
                last = line
            }
            line += 1
        }
        guard let last else { return nil }
        return (header + 1)...last // trailing blank lines stay visible
    }

    /// Whether `line` starts an indentation fold region; checks only up to the next non-blank line.
    func isIndentationFoldable(line: Int) -> Bool {
        guard line < lineIndex.lineCount, let base = indentation(ofLine: line) else { return false }
        var next = line + 1
        while next < lineIndex.lineCount {
            if let indent = indentation(ofLine: next) { return indent > base }
            next += 1
        }
        return false
    }

    /// Characters of whole lines `lines` (through the newline of the last one).
    func characterRange(ofLines lines: ClosedRange<Int>) -> NSRange {
        let start = lineIndex.lineStarts[lines.lowerBound]
        let end = lines.upperBound + 1 < lineIndex.lineCount ? lineIndex.lineStarts[lines.upperBound + 1] : textStorage.length
        return NSRange(location: start, length: end - start)
    }

    // MARK: Fold state

    /// The fold starting at `header`, if folded.
    func fold(atHeader header: Int) -> NSRange? {
        guard header + 1 < lineIndex.lineCount else { return nil }
        let start = lineIndex.lineStarts[header + 1]
        let index = FoldRanges.firstIndex(in: folds, startingAtOrAfter: start)
        return index < folds.count && folds[index].location == start ? folds[index] : nil
    }

    func isFolded(line header: Int) -> Bool { fold(atHeader: header) != nil }

    /// Whether `offset` is in a hidden line.
    func isHidden(_ offset: Int) -> Bool {
        FoldRanges.contains(hiddenRanges, offset)
    }

    @discardableResult
    func foldLines(atHeader header: Int) -> Bool {
        guard !isFolded(line: header), let lines = foldRange(atLine: header) else { return false }
        setFolds(folds + [characterRange(ofLines: lines)])
        return true
    }

    @discardableResult
    func unfold(atHeader header: Int) -> Bool {
        guard let fold = fold(atHeader: header) else { return false }
        setFolds(folds.filter { $0 != fold })
        return true
    }

    func toggleFold(atLine line: Int) {
        if !unfold(atHeader: line) { foldLines(atHeader: line) }
    }

    /// Folds the innermost region containing `line` (its own, if it's a header).
    func foldEnclosing(line: Int) {
        if !isFolded(line: line), foldRange(atLine: line) != nil {
            foldLines(atHeader: line)
            return
        }
        var header = line - 1
        while header >= 0 {
            if !isFolded(line: header), let range = foldRange(atLine: header), range.contains(line) {
                foldLines(atHeader: header)
                return
            }
            header -= 1
        }
    }

    /// Unfolds the fold at `line` or the ones hiding it.
    func unfoldEnclosing(line: Int) {
        if unfold(atHeader: line) { return }
        unfold(containing: NSRange(location: lineIndex.lineStarts[line], length: 0))
    }

    /// Unfolds whatever hides any part of `range` (the cursor moved there, a search result…).
    func unfold(containing range: NSRange) {
        // Asked on every cursor move: nothing hidden there is the usual answer, and a quick one.
        let end = max(NSMaxRange(range), range.location + 1)
        guard let first = hiddenRanges.first(where: { NSMaxRange($0) > range.location }), first.location < end else { return }
        let remaining = folds.filter { fold in
            !(NSLocationInRange(range.location, fold) || NSIntersectionRange(fold, range).length > 0
              || (range.length > 0 && NSLocationInRange(NSMaxRange(range) - 1, fold)))
        }
        if remaining.count != folds.count { setFolds(remaining) }
    }

    func foldAll() {
        var all = folds
        var seen = Set(folds.map { [$0.location, $0.length] })
        for line in 0..<lineIndex.lineCount where isFoldable(line: line) {
            if let lines = foldRange(atLine: line) {
                let range = characterRange(ofLines: lines)
                if seen.insert([range.location, range.length]).inserted { all.append(range) }
            }
        }
        setFolds(all)
    }

    func unfoldAll() {
        if !folds.isEmpty { setFolds([]) }
    }

    /// Keeps folds on their lines across an edit (pre-edit range `start..<oldEnd`); an edit
    /// touching a fold's hidden lines unfolds it.
    func adjustFolds(editStart start: Int, oldEnd: Int, delta: Int) {
        guard !folds.isEmpty else { return }
        // Usually the edit touches no fold: the ones after it move, in place (with everything
        // folded, sorting and joining 8,000 folds again took a quarter of a keystroke).
        // It touches a fold exactly when it touches what they hide together (they cover it).
        let hiddenAfter = FoldRanges.firstIndex(in: hiddenRanges, endingAfter: start)
        if hiddenAfter == hiddenRanges.count || hiddenRanges[hiddenAfter].location > oldEnd {
            if delta != 0 {
                shiftFolds(from: FoldRanges.firstIndex(in: folds, startingAtOrAfter: oldEnd + 1), hiddenFrom: hiddenAfter, by: delta)
            }
            return
        }
        var changed = false
        var result: [NSRange] = []
        for fold in folds {
            if oldEnd < fold.location {
                result.append(NSRange(location: fold.location + delta, length: fold.length))
                changed = changed || delta != 0
            } else if start >= NSMaxRange(fold) {
                result.append(fold)
            } else {
                changed = true // edited inside (or the newline before it): show it
            }
        }
        // No relayout here (this runs while the text storage processes the edit): TextKit lays
        // out the viewport again after the edit and asks the delegate afresh.
        if changed { setFolds(result, relayout: false) }
    }
}

/// Answers TextKit 2's "lay out this paragraph?" for a document's folds. Not tied to the main
/// actor: TextKit calls it from inside layout, where Swift's actor-isolation check crashed. It
/// reads its own lock-protected copy of the fold ranges instead of the document.
final class FoldingDelegate: NSObject, NSTextContentStorageDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var hidden: [NSRange] = []

    func setHidden(_ ranges: [NSRange]) {
        lock.withLock { hidden = ranges }
    }

    /// Where tabs stop (points; 0: AppKit's default). Lines with tabs get a paragraph style
    /// with it, so a tab is as wide as the tab width in spaces.
    private var tabInterval: CGFloat = 0

    func setTabInterval(_ interval: CGFloat) {
        lock.withLock { tabInterval = interval }
    }

    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        let interval = lock.withLock { tabInterval }
        guard interval > 0, let storage = textContentStorage.textStorage,
              storage.mutableString.range(of: "\t", options: .literal, range: range).location != NSNotFound else { return nil }
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = interval
        // The room an AI suggestion below the line takes (see InlineSuggestions.swift).
        if let spacing = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing {
            style.paragraphSpacing = spacing
        }
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        return NSTextParagraph(attributedString: paragraph)
    }

    func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions = []) -> Bool {
        let (ranges, start) = lock.withLock { (hidden, documentStart) }
        guard !ranges.isEmpty, let range = textElement.elementRange else { return true }
        // Asked for every paragraph TextKit walks past, hidden ones included (most of them, with
        // everything folded): `documentRange` takes a lock each time. Where the text starts
        // doesn't change (offset 0); it's only asked for once.
        let documentStart: NSTextLocation
        if let start {
            documentStart = start
        } else {
            documentStart = textContentManager.documentRange.location
            lock.withLock { self.documentStart = documentStart }
        }
        return !FoldRanges.contains(ranges, textContentManager.offset(from: documentStart, to: range.location))
    }

    private var documentStart: NSTextLocation?
}

/// What a document's folds hide, as ranges that don't overlap, in order: "is this hidden?" is
/// asked for every paragraph TextKit lays out and for every fold drawn, and looking through
/// every fold each time made a file with everything folded take seconds to redraw.
enum FoldRanges {
    /// `folds` (sorted by location; they nest) joined where they overlap.
    static func merged(_ folds: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for fold in folds where fold.length > 0 {
            if let last = result.last, fold.location <= NSMaxRange(last) {
                result[result.count - 1].length = max(NSMaxRange(last), NSMaxRange(fold)) - last.location
            } else {
                result.append(fold)
            }
        }
        return result
    }

    /// Whether one of `merged` has `offset` (binary search).
    static func contains(_ merged: [NSRange], _ offset: Int) -> Bool {
        let index = firstIndex(in: merged, endingAfter: offset)
        return index < merged.count && merged[index].location <= offset
    }

    /// Index of the first of `merged` that ends after `offset`.
    static func firstIndex(in merged: [NSRange], endingAfter offset: Int) -> Int {
        var low = 0, high = merged.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(merged[middle]) <= offset { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Index of the first of `folds` (sorted by location) starting at or after `location`.
    static func firstIndex(in folds: [NSRange], startingAtOrAfter location: Int) -> Int {
        var low = 0, high = folds.count
        while low < high {
            let middle = (low + high) / 2
            if folds[middle].location < location { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
