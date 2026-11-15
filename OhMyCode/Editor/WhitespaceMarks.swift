import AppKit

/// Which spaces and tabs are drawn as · and →.
enum RenderWhitespace: String, CaseIterable, Identifiable {
    case none
    /// In the selected text.
    case selection
    /// Leading and trailing whitespace, and runs of two or more between words.
    case boundary
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .selection: "In the selection"
        case .boundary: "Leading, trailing and repeated"
        case .all: "All"
        }
    }
}

extension EditorController {
    /// The whitespace marks in view: each space's or tab's rect, and whether it's a tab.
    func whitespaceMarks() -> [(rect: NSRect, isTab: Bool)] {
        let mode = AppSettings.shared.renderWhitespace
        guard mode != .none, let visible = visibleCharacterRange() else { return [] }
        let text = document.textStorage.mutableString
        var scope = NSIntersectionRange(visible, NSRange(location: 0, length: text.length))
        let selection = textView.selectedRange()
        if mode == .selection {
            guard selection.length > 0 else { return [] }
            scope = NSIntersectionRange(scope, selection)
            guard scope.length > 0 else { return [] }
        }
        var result: [(NSRect, Bool)] = []
        let index = document.lineIndex
        var line = index.line(containing: scope.location)
        while line < index.lineCount, index.lineStarts[line] < NSMaxRange(scope) {
            let start = index.lineStarts[line]
            var end = line + 1 < index.lineCount ? index.lineStarts[line + 1] : text.length
            while end > start, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
            let firstText = (start..<end).first { ![0x20, 0x09].contains(text.character(at: $0)) } ?? end
            let lastText = (start..<end).last { ![0x20, 0x09].contains(text.character(at: $0)) }.map { $0 + 1 } ?? start
            // Runs of one kind (spaces or one tab): one geometry lookup each.
            var position = max(start, scope.location)
            let stop = min(end, NSMaxRange(scope))
            while position < stop {
                let unit = text.character(at: position)
                guard unit == 0x20 || unit == 0x09 else { position += 1; continue }
                var runEnd = position + 1
                if unit == 0x20 { while runEnd < stop, text.character(at: runEnd) == 0x20 { runEnd += 1 } }
                let isBoundary = position < firstText || runEnd > lastText || runEnd - position > 1 || unit == 0x09
                if (mode != .boundary || isBoundary), let rect = rect(for: NSRange(location: position, length: runEnd - position)) {
                    if unit == 0x09 {
                        result.append((rect, true))
                    } else {
                        let width = rect.width / CGFloat(runEnd - position)
                        for offset in 0..<(runEnd - position) {
                            result.append((NSRect(x: rect.minX + CGFloat(offset) * width, y: rect.minY, width: width, height: rect.height), false))
                        }
                    }
                }
                position = runEnd
            }
            line += 1
        }
        return result
    }
}
