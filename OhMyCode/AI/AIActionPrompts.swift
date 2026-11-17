import Foundation

/// What's sent for Explain, Fix with AI and commit messages, and how replies are cleaned up.
extension AIPrompts {
    /// Lines kept on each side of a problem's lines in the region a fix replaces.
    static let fixRegionPadding = 3
    /// At most this many lines are replaced by one fix (a problem spanning more is cut).
    static let fixRegionMaxLines = 60
    /// Lines of code sent around the region a fix replaces.
    static let fixContextLines = 30
    /// The end of a terminal's or task's output that's explained (the rest is cut).
    static let outputCharacters = 12_000
    /// The diff sent for a commit message; past it, the remaining files are listed with counts.
    static let commitDiffCharacters = 30_000
    /// Files listed after a cut diff.
    static let commitSummaryMaxFiles = 200
    static let commitSubjectMaxLength = 72

    // MARK: Explain

    static let explainSystem = """
        You explain code to a programmer inside a code editor. You are given a file's path and \
        language, the code to explain (<code>) and the code around it (<context_before>, \
        <context_after>), which is only context. Explain what the code does and why, concisely, in \
        Markdown: start with a one- or two-sentence summary, then only the details that matter \
        (inputs, outputs, side effects, edge cases, anything surprising or wrong). Quote code in \
        backticks or fenced blocks. Don't restate the code line by line.
        """

    static let explainOutputSystem = """
        You help a programmer understand output from a terminal or a build task, usually an error \
        message or a stack trace. Explain in Markdown, concisely: what went wrong, the likely cause, \
        and how to fix it, with commands or code where they help. If the output isn't an error, say \
        what it means. Say so when the output alone isn't enough to tell.
        """

    /// The request to explain `range` of a file (lines numbered from 1 in the prompt). `focus`:
    /// the word at the caret, when the range is the caret's line.
    static func explainCodeRequest(text: NSString, range: NSRange, lineIndex: LineIndex, focus: String?,
                                   path: String, languageId: String, model: String) -> AIRequest {
        let (before, after) = editContext(text: text, range: range)
        let first = lineIndex.line(containing: range.location) + 1
        var endLocation = NSMaxRange(range)
        if endLocation > range.location, text.character(at: endLocation - 1) == 0x0A { endLocation -= 1 }
        let last = max(first, lineIndex.line(containing: endLocation) + 1)
        var user = """
            File: \(path)
            Language: \(languageId)
            Lines: \(first == last ? "\(first)" : "\(first)-\(last)")

            """
        if let focus, !focus.isEmpty { user += "The cursor is on `\(focus)`: focus on it.\n" }
        user += """

            <context_before>
            \(before)</context_before>

            <code>
            \(text.substring(with: range))</code>

            <context_after>
            \(after)</context_after>

            Explain the code in <code>.
            """
        return AIRequest(purpose: .edit, model: model, system: explainSystem, user: user, maxTokens: AISettings.editMaxTokens)
    }

    /// The request to explain output selected in a terminal or a task's output. `source` says
    /// where it's from ("Terminal", "Task “build”"); `command` and the active file, when known,
    /// are context.
    static func explainOutputRequest(output: String, source: String, command: String?, activeFile: String?,
                                     languageId: String?, model: String) -> AIRequest {
        var output = output
        if output.count > outputCharacters {
            output = "[… earlier output cut]\n" + String(output.suffix(outputCharacters))
        }
        var user = "Source: \(source)\n"
        if let command, !command.trimmingCharacters(in: .whitespaces).isEmpty { user += "Command: \(command)\n" }
        if let activeFile {
            user += "File open in the editor: \(activeFile)" + (languageId.map { " (\($0))" } ?? "") + "\n"
        }
        user += """

            <output>
            \(output)
            </output>

            Explain this output.
            """
        return AIRequest(purpose: .edit, model: model, system: explainOutputSystem, user: user, maxTokens: AISettings.editMaxTokens)
    }

    // MARK: Fix with AI

    static let fixSystem = """
        You fix problems in code inside a code editor. You are given a file's path and language, a \
        problem a compiler, linter or language server reported, the lines it's on (<region>) and the \
        code around them (<context_before>, <context_after>), which is only context. Reply with ONLY \
        the code that replaces the region: all of its lines, corrected, with their indentation kept \
        as in the file, no explanation, no Markdown, no code fences. Change only what fixes the \
        problem. Don't repeat the context before or after the region. If the problem can't be fixed \
        inside the region, reply with the region unchanged.
        """

    /// The whole lines a fix for a problem on `lines` (0-based) replaces: those lines and three
    /// on each side (at most 60 in all), with the last one's line break.
    static func fixRegion(lines: ClosedRange<Int>, lineIndex: LineIndex, textLength: Int) -> NSRange {
        let count = lineIndex.lineCount
        let first = max(0, min(lines.lowerBound, count - 1) - fixRegionPadding)
        var last = min(count - 1, lines.upperBound + fixRegionPadding)
        last = min(last, first + fixRegionMaxLines - 1)
        let start = lineIndex.lineStarts[first]
        let end = last + 1 < count ? lineIndex.lineStarts[last + 1] : textLength
        return NSRange(location: start, length: end - start)
    }

    /// The request for a fix of `diagnostic` replacing `region` (whole lines), with 30 lines of
    /// code on each side. `instruction`: what the person added, if anything.
    static func fixRequest(text: NSString, region: NSRange, diagnostic: Diagnostic, lineIndex: LineIndex,
                           instruction: String?, path: String, languageId: String, model: String) -> AIRequest {
        let (before, after) = editContext(text: text, range: region, maxLines: fixContextLines)
        let first = lineIndex.line(containing: region.location) + 1
        var endLocation = NSMaxRange(region)
        if endLocation > region.location, text.character(at: endLocation - 1) == 0x0A { endLocation -= 1 }
        let last = max(first, lineIndex.line(containing: endLocation) + 1)
        let start = diagnostic.range.start, end = diagnostic.range.end
        let severity = String(describing: diagnostic.severity)
        var user = """
            File: \(path)
            Language: \(languageId)
            Problem (\(severity)\(diagnostic.source.map { ", from \($0)" } ?? "")) at line \(start.line + 1), \
            column \(start.character + 1) to line \(end.line + 1), column \(end.character + 1): \(diagnostic.message)
            The region is lines \(first)-\(last).

            """
        if let instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user += "Instruction: \(instruction)\n"
        }
        user += """

            <context_before>
            \(before)</context_before>

            <region>
            \(text.substring(with: region))</region>

            <context_after>
            \(after)</context_after>

            Reply with only the corrected lines of the region.
            """
        return AIRequest(purpose: .edit, model: model, system: fixSystem, user: user, maxTokens: AISettings.editMaxTokens)
    }

    /// The reply as the region's replacement: without an introduction before a code block ("Here's
    /// the fix:"), fences, or region tags; ending with a line break exactly when the region did.
    static func sanitizeFix(_ reply: String, original: String) -> String {
        var lines = reply.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func isFence(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        if let firstContent = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           !isFence(lines[firstContent]), let fence = lines.firstIndex(where: isFence), fence > firstContent,
           let lead = lines[..<fence].last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lead.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
            lines.removeSubrange(..<fence)
        }
        var text = stripFences(lines.joined(separator: "\n"))
        var body = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if body.first?.trimmingCharacters(in: .whitespaces) == "<region>" { body.removeFirst() }
        if let index = body.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let line = body[index]
            if line.trimmingCharacters(in: .whitespaces) == "</region>" {
                body.removeSubrange(index...)
            } else if line.hasSuffix("</region>") {
                body[index] = String(line.dropLast("</region>".count))
                body.removeSubrange((index + 1)...)
            }
        }
        text = body.joined(separator: "\n")
        return sanitizeEdit(text, original: original)
    }

    // MARK: Commit messages

    static let commitSystem = """
        You write git commit messages. You are given the diff of the changes to commit (when it's \
        too long, the files left out are listed with their added and removed line counts). Reply \
        with ONLY the commit message, in the Conventional Commits style: a subject line \
        "type(optional scope): summary" of at most 72 characters, in the imperative mood, without a \
        final period, where type is one of feat, fix, docs, style, refactor, perf, test, build, ci, \
        chore or revert; then, only when the change needs explaining, a blank line and a short body \
        wrapped at 72 characters saying what changed and why. No Markdown, no code fences, no quotes \
        around it.
        """

    static func commitMessageRequest(diff: String, allChanges: Bool, branch: String?, model: String) -> AIRequest {
        var user = allChanges
            ? "Nothing is staged: these are all the changes in the working tree.\n"
            : "These are the staged changes.\n"
        if let branch { user += "Branch: \(branch)\n" }
        user += """

            <diff>
            \(diff)
            </diff>

            Reply with only the commit message.
            """
        return AIRequest(purpose: .edit, model: model, system: commitSystem, user: user, maxTokens: AISettings.editMaxTokens)
    }

    /// A diff cut to `limit` characters: whole files while they fit (the first one cut if it
    /// alone is too long), then the files left out, with their counts from `numstat` (git's
    /// `--numstat`: added, removed, path, tab-separated) and `extraFiles` (untracked ones).
    static func cappedDiff(_ diff: String, numstat: String, extraFiles: [String] = [],
                           limit: Int = commitDiffCharacters) -> String {
        var counts: [String: String] = [:]
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            counts[String(parts[2])] = parts[0] == "-" ? "binary" : "+\(parts[0]) -\(parts[1])"
        }
        let extras = extraFiles.map { "\($0) (new, untracked)" }
        guard diff.count > limit else {
            return extras.isEmpty ? diff : diff + "\n[Untracked files, not in the diff:]\n" + extras.joined(separator: "\n")
        }
        // One chunk per file.
        var chunks: [String] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") || chunks.isEmpty { chunks.append("") }
            chunks[chunks.count - 1] += line + "\n"
        }
        var kept = "", length = 0
        var omitted: [String] = []
        for chunk in chunks {
            let size = chunk.count
            if length + size <= limit {
                kept += chunk
                length += size
            } else if length == 0 {
                kept = String(chunk.prefix(limit)) + "\n[… the rest of this file's diff is cut]\n"
                length = limit
            } else {
                omitted.append(path(ofDiffChunk: chunk))
            }
        }
        let listed = omitted.map { path in counts[path].map { "\(path) (\($0))" } ?? path } + extras
        guard !listed.isEmpty else { return kept }
        var summary = "\n[The diff is too long: \(listed.count) more changed file\(listed.count == 1 ? "" : "s"), not shown above:]\n"
        summary += listed.prefix(commitSummaryMaxFiles).joined(separator: "\n")
        if listed.count > commitSummaryMaxFiles { summary += "\n… and \(listed.count - commitSummaryMaxFiles) more" }
        return kept + summary
    }

    /// The path after " b/" on a chunk's `diff --git a/x b/x` line.
    private static func path(ofDiffChunk chunk: String) -> String {
        let header = chunk.prefix { $0 != "\n" }
        guard let range = header.range(of: " b/", options: .backwards) else { return String(header) }
        return String(header[range.upperBound...])
    }

    /// The reply as a commit message: no fences or surrounding quotes, a subject of at most 72
    /// characters (cut at a word), and a blank line before the body.
    static func sanitizeCommitMessage(_ reply: String) -> String {
        var text = stripFences(reply).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == text.last, "\"'`".contains(first) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" }.reversed())
        }
        guard !lines.isEmpty else { return "" }
        var subject = lines.removeFirst()
        if subject.count > commitSubjectMaxLength {
            let cut = subject.prefix(commitSubjectMaxLength)
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > commitSubjectMaxLength / 2 {
                subject = String(cut[..<space])
            } else {
                subject = String(cut)
            }
        }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.isEmpty ? subject : subject + "\n\n" + lines.joined(separator: "\n")
    }
}
