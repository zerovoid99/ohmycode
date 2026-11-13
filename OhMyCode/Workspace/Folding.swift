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

    /// The lines `header` folds (header excluded), or nil if it doesn't start a fold region.
    func foldRange(atLine header: Int) -> ClosedRange<Int>? {
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

    /// Whether `line` starts a fold region; checks only up to the next non-blank line.
    func isFoldable(line: Int) -> Bool {
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
        return folds.first { $0.location == start }
    }

    func isFolded(line header: Int) -> Bool { fold(atHeader: header) != nil }

    /// Whether `offset` is in a hidden line.
    func isHidden(_ offset: Int) -> Bool {
        folds.contains { NSLocationInRange(offset, $0) }
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
        let remaining = folds.filter { fold in
            !(NSLocationInRange(range.location, fold) || NSIntersectionRange(fold, range).length > 0
              || (range.length > 0 && NSLocationInRange(NSMaxRange(range) - 1, fold)))
        }
        if remaining.count != folds.count { setFolds(remaining) }
    }

    func foldAll() {
        var all = folds
        for line in 0..<lineIndex.lineCount where isFoldable(line: line) {
            if let lines = foldRange(atLine: line) {
                let range = characterRange(ofLines: lines)
                if !all.contains(range) { all.append(range) }
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

    func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions = []) -> Bool {
        let ranges = lock.withLock { hidden }
        guard !ranges.isEmpty, let range = textElement.elementRange else { return true }
        let offset = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        return !ranges.contains { NSLocationInRange(offset, $0) }
    }
}
