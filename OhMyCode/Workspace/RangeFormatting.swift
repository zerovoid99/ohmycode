import AppKit

/// What format on save formats.
enum FormatOnSaveScope: String, CaseIterable, Identifiable {
    case file
    /// Only lines changed since the last commit (the whole file when it isn't in git).
    case modifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .file: "The whole file"
        case .modifications: "Only changed lines"
        }
    }
}

extension EditorDocument {
    /// The lines changed against git's staged version, as ranges of zero-based lines; nil when
    /// the file isn't in git. Diffed now (the gutter's diff may lag behind the last keystroke).
    func changedLineRanges() -> [Range<Int>]? {
        guard let base = diffBaseLines else { return nil }
        return LineDiff.hunks(base: base, current: LineDiff.lines(textStorage.mutableString as String))
            .filter { $0.newCount > 0 }
            .map { $0.newStart..<($0.newStart + $0.newCount) }
    }

    /// Whole lines as an LSP range (from the first line's start to the last line's end).
    func lspRange(ofLines lines: Range<Int>) -> LSPRange {
        let start = lineIndex.lineStarts[min(lines.lowerBound, lineIndex.lineCount - 1)]
        let last = min(lines.upperBound, lineIndex.lineCount) - 1
        var end = last + 1 < lineIndex.lineCount ? lineIndex.lineStarts[last + 1] - 1 : textStorage.length
        if end > start, textStorage.mutableString.character(at: end - 1) == 0x0D { end -= 1 }
        return LSPRange(start: lspPosition(at: start), end: lspPosition(at: max(start, end)))
    }
}

extension Workspace {
    func canFormatRanges(_ document: EditorDocument) -> Bool {
        guard let client = document.languageClient else { return false }
        return client.state == .ready && client.supports(.rangeFormatting)
    }

    /// Format Selection: the selected lines (the cursor's line without a selection).
    @discardableResult
    func formatSelection(_ target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let document = target ?? activeDocument, let editor = document.editor, canFormatRanges(document) else {
            NSSound.beep()
            return nil
        }
        let lines = editor.selectedLines()
        return Task {
            do {
                try await format(document, lines: [lines.lowerBound..<(lines.upperBound + 1)], actionName: "Format Selection")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Formats some lines of a file (each range asked for separately, all against the same
    /// text) as one undoable step. Returns whether the text changed.
    @discardableResult
    func format(_ document: EditorDocument, lines: [Range<Int>], actionName: String) async throws -> Bool {
        guard let client = document.languageClient, !lines.isEmpty else { return false }
        let version = document.editVersion
        let (tabSize, insertSpaces) = document.indentation
        var edits: [TextReplacement] = []
        for range in lines {
            let result = try await client.rangeFormatting(url: document.url, range: document.lspRange(ofLines: range),
                                                          tabSize: tabSize, insertSpaces: insertSpaces)
            guard document.editVersion == version, !Task.isCancelled else { return false }
            edits += result.map { TextReplacement(range: document.range(for: $0.range), text: $0.newText) }
        }
        // Ranges next to each other can both touch the line between them: keep the first.
        var kept: [TextReplacement] = []
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            if let last = kept.last, edit.range.location < NSMaxRange(last.range) { continue }
            kept.append(edit)
        }
        return try document.apply(kept, actionName: actionName)
    }

    /// Format on save, as the setting says: the whole file, or the lines changed since the
    /// last commit (when the server can format ranges and the file is in git).
    func formatForSave(_ document: EditorDocument) async throws {
        if effectiveFormatOnSaveScope == .modifications, !extensions.hasProviders(.formatting, for: document),
           canFormatRanges(document), let changed = document.changedLineRanges() {
            try await format(document, lines: changed, actionName: "Format Changed Lines")
        } else {
            try await format(document)
        }
    }
}
