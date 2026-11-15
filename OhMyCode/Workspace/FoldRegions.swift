import AppKit
import SwiftTreeSitter

/// A region a line folds, from the code's structure: the header line stays, lines after it
/// through `end` hide (a block's closing bracket line stays visible).
struct FoldRegion: Equatable, Sendable {
    enum Kind: String, Sendable { case code, comment, imports, region }

    var start: Int
    var end: Int
    var kind: Kind
}

extension SyntaxEngine {
    /// Fold regions from the parsed tree: bracketed blocks (to the line before their closing
    /// bracket), multi-line comments and runs of line comments, runs of imports, and
    /// `// MARK:` / `#region` sections.
    func foldRegions() -> [FoldRegion] {
        guard let root = currentRoot else { return [] }
        let text = currentText
        var byStart: [Int: FoldRegion] = [:]
        func add(_ region: FoldRegion) {
            guard region.end > region.start else { return }
            // One region per header line: the widest (a function and its body start together).
            if let existing = byStart[region.start], existing.end >= region.end { return }
            byStart[region.start] = region
        }
        var comments: [(start: Int, end: Int, text: String)] = []
        var imports: [(start: Int, end: Int)] = []
        var stack: [Node] = [root]
        var visited = 0
        while let node = stack.popLast(), visited < 500_000 {
            visited += 1
            let startRow = Int(node.pointRange.lowerBound.row), endRow = Int(node.pointRange.upperBound.row)
            let type = node.nodeType ?? ""
            if type.contains("comment") {
                let range = node.range
                let body = NSMaxRange(range) <= text.length ? text.substring(with: range) : ""
                comments.append((startRow, endRow, body))
                continue
            }
            if type.contains("import"), node.parent?.parent == nil || node.parent?.nodeType == "source_file" {
                imports.append((startRow, endRow))
            }
            // Ends with a closing bracket on its own last line (its rightmost token: a function
            // ends with its body's "}"): fold to the line before it.
            if endRow > startRow, let closer = Self.rightmostToken(of: node), let closerType = closer.nodeType,
               ["}", ")", "]"].contains(closerType), Int(closer.pointRange.lowerBound.row) == endRow {
                add(FoldRegion(start: startRow, end: endRow - 1, kind: .code))
            }
            if endRow > startRow {
                for index in stride(from: node.childCount - 1, through: 0, by: -1) {
                    if let child = node.child(at: index) { stack.append(child) }
                }
            }
        }

        // Comments: a multi-line one, or a run of line comments (one per line, back to back).
        comments.sort { $0.start < $1.start }
        var runStart: Int?, runEnd = -2
        func closeRun() {
            if let start = runStart, runEnd > start { add(FoldRegion(start: start, end: runEnd, kind: .comment)) }
            runStart = nil
        }
        for comment in comments where !Self.isMarker(comment.text) {
            if comment.end > comment.start { closeRun(); add(FoldRegion(start: comment.start, end: comment.end, kind: .comment)); continue }
            if comment.start == runEnd + 1 { runEnd = comment.start } else { closeRun(); runStart = comment.start; runEnd = comment.start }
        }
        closeRun()

        // Imports one after another.
        imports.sort { $0.start < $1.start }
        var importStart: Int?, importEnd = -2
        for item in imports {
            if let start = importStart, item.start <= importEnd + 2 {
                importEnd = max(importEnd, item.end)
                _ = start
            } else {
                if let start = importStart, importEnd > start { add(FoldRegion(start: start, end: importEnd, kind: .imports)) }
                importStart = item.start
                importEnd = item.end
            }
        }
        if let start = importStart, importEnd > start { add(FoldRegion(start: start, end: importEnd, kind: .imports)) }

        // Marked sections: `#region` to its `#endregion`; `MARK:` to the next MARK.
        let lineCount = Int(root.pointRange.upperBound.row) + 1
        var openRegions: [Int] = []
        var marks: [Int] = []
        for comment in comments {
            let body = comment.text
            if body.contains("#endregion") {
                if let start = openRegions.popLast() { add(FoldRegion(start: start, end: comment.start, kind: .region)) }
            } else if body.contains("#region") {
                openRegions.append(comment.start)
            } else if body.contains("MARK:") {
                marks.append(comment.start)
            }
        }
        var lineStarts: [Int] = []
        if !marks.isEmpty {
            lineStarts = [0]
            for index in 0..<text.length where text.character(at: index) == 0x0A { lineStarts.append(index + 1) }
        }
        func isBlank(_ line: Int) -> Bool {
            guard line < lineStarts.count else { return true }
            let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : text.length
            return text.substring(with: NSRange(location: lineStarts[line], length: end - lineStarts[line])).allSatisfy(\.isWhitespace)
        }
        for (index, mark) in marks.enumerated() {
            let next = index + 1 < marks.count ? marks[index + 1] : lineCount
            var end = next - 1
            while end > mark, isBlank(end) { end -= 1 }
            add(FoldRegion(start: mark, end: end, kind: .region))
        }
        // A region ending where an enclosing one ends adds nothing (a function's body
        // starting on its `) {` line): fold the whole declaration from its first line.
        let sorted = byStart.values.sorted { $0.start < $1.start }
        var outerEnds: Set<Int> = []
        var result: [FoldRegion] = []
        for region in sorted {
            if region.kind == .code, outerEnds.contains(region.end) { continue }
            if region.kind == .code { outerEnds.insert(region.end) }
            result.append(region)
        }
        return result
    }

    private static func rightmostToken(of node: Node) -> Node? {
        var current = node
        for _ in 0..<12 {
            guard current.childCount > 0, let last = current.child(at: current.childCount - 1) else { return current }
            current = last
        }
        return nil
    }

    private static func isMarker(_ comment: String) -> Bool {
        comment.contains("MARK:") || comment.contains("#region") || comment.contains("#endregion")
    }

}

extension EditorDocument {
    /// The structural fold region `line` starts, if any.
    func structuralFold(atLine line: Int) -> FoldRegion? {
        guard let region = foldRegions[line], region.end > line, region.end < lineIndex.lineCount else { return nil }
        return region
    }

    /// Reads the fold regions again: the language server's, else the syntax tree's (after
    /// `delay`, restarted by every call). Indentation still folds where neither has a region.
    func refreshFoldRegions(after delay: Duration = .zero) {
        foldRegionsTask?.cancel()
        foldRegionsTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            let version = self.editVersion
            var regions: [FoldRegion]?
            if let client = self.languageClient, client.state == .ready, client.supports(.foldingRange) {
                regions = try? await client.foldingRanges(url: self.url)
            }
            if regions?.isEmpty ?? true, let highlighter = self.highlighter {
                regions = await highlighter.foldRegions()
            }
            guard !Task.isCancelled, version == self.editVersion else { return }
            let byStart = Dictionary((regions ?? []).map { ($0.start, $0) }, uniquingKeysWith: { $0.end >= $1.end ? $0 : $1 })
            guard byStart != self.foldRegions else { return }
            self.foldRegions = byStart
            self.redrawGutters()
        }
    }

    func waitForFoldRegions() async { await foldRegionsTask?.value }

    /// Lines `old` became `count` lines: regions after them move, regions they touched go
    /// (until the next refresh).
    func shiftFoldRegions(replacing old: Range<Int>, with count: Int) {
        guard !foldRegions.isEmpty else { return }
        let delta = count - old.count
        var shifted: [Int: FoldRegion] = [:]
        for region in foldRegions.values {
            if region.end < old.lowerBound {
                shifted[region.start] = region
            } else if region.start >= old.upperBound {
                var moved = region
                moved.start += delta
                moved.end += delta
                shifted[moved.start] = moved
            } else if region.start < old.lowerBound, region.end >= old.upperBound - 1 {
                // The edit is inside the region: it grows or shrinks with it.
                var resized = region
                resized.end += delta
                if resized.end > resized.start { shifted[resized.start] = resized }
            }
        }
        foldRegions = shifted
    }

    /// Every region (structural ones, and indentation's where there's none), with how many
    /// regions enclose it: level 1 is outermost.
    func allFoldRegions() -> [(lines: ClosedRange<Int>, kind: FoldRegion.Kind, level: Int)] {
        var regions: [(ClosedRange<Int>, FoldRegion.Kind)] = []
        for line in 0..<lineIndex.lineCount {
            if let structural = structuralFold(atLine: line) {
                regions.append(((line + 1)...structural.end, structural.kind))
            } else if foldsByIndentation, isIndentationFoldable(line: line), let lines = indentationFoldRange(atLine: line) {
                regions.append((lines, .code))
            }
        }
        // Enclosing regions come earlier (they start before): count them with a stack.
        var stack: [ClosedRange<Int>] = []
        var result: [(ClosedRange<Int>, FoldRegion.Kind, Int)] = []
        for (lines, kind) in regions {
            let header = lines.lowerBound - 1
            while let top = stack.last, !top.contains(header) { stack.removeLast() }
            result.append((lines, kind, stack.count + 1))
            stack.append(lines)
        }
        return result
    }

    /// Folds every region at `level` (1: outermost), leaving others as they are.
    func foldLevel(_ level: Int) {
        var all = folds
        for region in allFoldRegions() where region.level == level {
            let range = characterRange(ofLines: region.lines)
            if !all.contains(range) { all.append(range) }
        }
        setFolds(all)
    }

    /// Folds every comment region (doc comments, comment blocks).
    func foldAllComments() {
        var all = folds
        for region in allFoldRegions() where region.kind == .comment {
            let range = characterRange(ofLines: region.lines)
            if !all.contains(range) { all.append(range) }
        }
        setFolds(all)
    }
}
