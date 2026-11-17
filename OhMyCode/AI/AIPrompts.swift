import Foundation

/// What's sent for suggestions and edits, and how replies are cleaned up.
enum AIPrompts {
    static let suggestionCharactersBefore = 6_000
    static let suggestionCharactersAfter = 2_000
    static let suggestionMaxLines = 12
    static let editContextLines = 40
    static let editContextCharacters = 6_000

    // MARK: Inline suggestions

    static let suggestionSystem = """
        You are the inline code completion engine of a code editor. You are given a file's text before \
        the cursor (<prefix>) and after it (<suffix>). Reply with ONLY the text to insert at the cursor, \
        exactly as it should appear: no explanation, no Markdown, no code fences. Don't repeat any text \
        that's already before or after the cursor. Complete the current line and, when it's natural, a \
        few more lines; follow the file's style and indentation. If nothing useful fits, reply with \
        nothing.
        """

    struct SuggestionContext: Equatable {
        var path: String
        var languageId: String
        var before: String
        var after: String
    }

    /// The text around `caret`: up to 6,000 characters before and 2,000 after (not splitting a
    /// surrogate pair).
    static func suggestionContext(text: NSString, caret: Int, path: String, languageId: String) -> SuggestionContext {
        var start = max(0, caret - suggestionCharactersBefore)
        if start > 0, start < text.length, UTF16.isTrailSurrogate(text.character(at: start)) { start += 1 }
        var end = min(text.length, caret + suggestionCharactersAfter)
        if end < text.length, end > 0, UTF16.isLeadSurrogate(text.character(at: end - 1)) { end -= 1 }
        return SuggestionContext(path: path, languageId: languageId,
                                 before: text.substring(with: NSRange(location: start, length: caret - start)),
                                 after: text.substring(with: NSRange(location: caret, length: end - caret)))
    }

    static func suggestionUser(_ context: SuggestionContext) -> String {
        """
        File: \(context.path)
        Language: \(context.languageId)

        <prefix>\(context.before)</prefix><suffix>\(context.after)</suffix>

        Reply with only the text to insert between the prefix and the suffix.
        """
    }

    static func suggestionRequest(_ context: SuggestionContext, model: String) -> AIRequest {
        AIRequest(purpose: .suggestion, model: model, system: suggestionSystem, user: suggestionUser(context),
                  maxTokens: AISettings.suggestionMaxTokens)
    }

    /// The reply as text to insert: without code fences, without the current line repeated at its
    /// start, without the text after the cursor repeated at its end, at most 12 lines.
    static func sanitizeSuggestion(_ reply: String, before: String, after: String, maxLines: Int = suggestionMaxLines) -> String {
        var text = stripFences(reply)
        // The line so far, repeated (models like to start over).
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let indentEnd = line.firstIndex { $0 != " " && $0 != "\t" } ?? line.endIndex
        let typed = String(line[indentEnd...])
        if !typed.isEmpty {
            if text.hasPrefix(line) {
                text.removeFirst(line.count)
            } else if text.hasPrefix(typed) {
                text.removeFirst(typed.count)
            }
        }
        // Lines past the limit, and trailing blank space.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines { text = lines.prefix(maxLines).joined(separator: "\n") }
        while let last = text.last, last.isWhitespace { text.removeLast() }
        // What's already after the cursor (closing brackets, the next lines), repeated at its end.
        let afterStart = String(after.prefix(400))
        var overlap = min(text.count, afterStart.count)
        while overlap > 0 {
            let candidate = afterStart.prefix(overlap)
            if text.hasSuffix(candidate), candidate.contains(where: { !$0.isWhitespace }) {
                text.removeLast(overlap)
                break
            }
            overlap -= 1
        }
        while let last = text.last, last.isNewline { text.removeLast() }
        return text.allSatisfy(\.isWhitespace) ? "" : text
    }

    /// Drops a Markdown code fence around the reply (```lang … ```), and one that's still open
    /// (a reply being streamed).
    static func stripFences(_ reply: String) -> String {
        var lines = reply.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstContent = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[firstContent].trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return reply }
        lines.removeSubrange(0...firstContent)
        if let close = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            lines.removeSubrange(close...)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: ⌘I edits

    static let editSystem = """
        You edit code inside a code editor. You are given a file's path and language, an instruction, \
        the code to change (<selection>) and the code around it (<context_before>, <context_after>), \
        which is only context. Reply with ONLY the code that replaces the selection: complete, with its \
        indentation kept as in the file, no explanation, no Markdown, no code fences. Don't repeat the \
        context before or after the selection.
        """

    static let insertSystem = """
        You write code inside a code editor. You are given a file's path and language, an instruction, \
        and the code before and after the cursor (<context_before>, <context_after>), which is only \
        context. Reply with ONLY the code to insert at the cursor: complete lines, indented as they \
        should be in the file, no explanation, no Markdown, no code fences. Don't repeat the context.
        """

    /// The request for an edit of `range` (empty: code to insert there).
    static func editRequest(text: NSString, range: NSRange, instruction: String, path: String, languageId: String,
                            model: String) -> AIRequest {
        let (before, after) = editContext(text: text, range: range)
        let isInsertion = range.length == 0
        var user = """
            File: \(path)
            Language: \(languageId)
            Instruction: \(instruction)

            <context_before>
            \(before)</context_before>

            """
        if !isInsertion {
            user += "<selection>\n\(text.substring(with: range))</selection>\n\n"
        } else {
            user += "(The code goes here, at the cursor.)\n\n"
        }
        user += "<context_after>\n\(after)</context_after>"
        return AIRequest(purpose: .edit, model: model, system: isInsertion ? insertSystem : editSystem, user: user,
                         maxTokens: AISettings.editMaxTokens)
    }

    /// Up to 40 lines (and 6,000 characters) on each side of `range`.
    static func editContext(text: NSString, range: NSRange) -> (before: String, after: String) {
        var start = range.location, lines = 0
        while start > 0, range.location - start < editContextCharacters {
            if text.character(at: start - 1) == 0x0A {
                lines += 1
                if lines > editContextLines { break }
            }
            start -= 1
        }
        var end = NSMaxRange(range)
        lines = 0
        while end < text.length, end - NSMaxRange(range) < editContextCharacters {
            if text.character(at: end) == 0x0A {
                lines += 1
                if lines > editContextLines { break }
            }
            end += 1
        }
        if start > 0, start < text.length, UTF16.isTrailSurrogate(text.character(at: start)) { start += 1 }
        if end < text.length, end > 0, UTF16.isLeadSurrogate(text.character(at: end - 1)) { end -= 1 }
        return (text.substring(with: NSRange(location: start, length: range.location - start)),
                text.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))))
    }

    /// The reply as the selection's replacement: no fences, and ending with a line break exactly
    /// when the selection did.
    static func sanitizeEdit(_ reply: String, original: String) -> String {
        var text = stripFences(reply)
        while let last = text.last, last.isNewline { text.removeLast() }
        if original.hasSuffix("\n") { text += "\n" }
        return text
    }
}

/// A line diff of an edit's replacement against the original, for the ⌘I preview.
enum AIEditDiff {
    enum Kind { case same, removed, added }

    struct Row: Identifiable, Equatable {
        let id: Int
        let kind: Kind
        let text: String
    }

    static func rows(old: String, new: String) -> [Row] {
        let oldLines = lines(old), newLines = lines(new)
        var rows: [Row] = []
        func add(_ kind: Kind, _ text: Substring) { rows.append(Row(id: rows.count, kind: kind, text: String(text))) }
        var oldIndex = 0, newIndex = 0
        for hunk in LineDiff.hunks(base: oldLines, current: newLines) {
            while oldIndex < hunk.oldStart { add(.same, oldLines[oldIndex]); oldIndex += 1; newIndex += 1 }
            for line in oldLines[hunk.oldStart..<hunk.oldStart + hunk.oldCount] { add(.removed, line) }
            for line in newLines[hunk.newStart..<hunk.newStart + hunk.newCount] { add(.added, line) }
            oldIndex = hunk.oldStart + hunk.oldCount
            newIndex = hunk.newStart + hunk.newCount
        }
        while oldIndex < oldLines.count { add(.same, oldLines[oldIndex]); oldIndex += 1 }
        return rows
    }

    /// Lines without the empty one after a final line break (an empty text has none).
    private static func lines(_ text: String) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
