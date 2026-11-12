import Foundation

struct SearchOptions: Sendable, Equatable {
    var query = ""
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    /// Comma-separated globs, e.g. "*.swift, Sources/". Empty means everything.
    var include = ""
    var exclude = ""
}

struct SearchMatch: Sendable, Equatable, Identifiable {
    var id: String { "\(line):\(column)" }
    /// Zero-based line, and UTF-16 column/length within that line.
    let line: Int
    let column: Int
    let length: Int
    /// The line (possibly shortened around the match) and the match's range within it.
    let preview: String
    let previewRange: NSRange
}

struct SearchFileResult: Sendable, Identifiable {
    var id: String { path }
    let path: String
    let url: URL
    let matches: [SearchMatch]
}

/// Workspace-wide text search. Files are searched in parallel across all cores; literal queries
/// run as byte searches (memmem) over memory-mapped files, regex and non-ASCII case folding use
/// NSRegularExpression. Results stream in batches.
enum TextSearch {
    static let maxFileSize = 8 * 1024 * 1024
    static let maxResults = 20_000
    static let maxMatchesPerFile = 1_000
    static let previewLimit = 160

    enum SearchError: LocalizedError {
        case invalidRegex(String)
        var errorDescription: String? {
            switch self { case .invalidRegex(let message): "Invalid regular expression: \(message)" }
        }
    }

    /// Searches `files` (paths relative to `root`). `overrides` supplies text for files whose
    /// on-disk content is stale (unsaved editors). Batches of results arrive on `onBatch`.
    static func search(_ options: SearchOptions, root: URL, files: [String], overrides: [String: String],
                       onBatch: @escaping @Sendable ([SearchFileResult]) async -> Void) async throws {
        guard !options.query.isEmpty else { return }
        let matcher = try Matcher(options)
        let filter = PathFilter(include: options.include, exclude: options.exclude)
        let candidates = files.filter(filter.accepts)

        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let chunkSize = max(16, candidates.count / (workers * 4))
        let chunks = stride(from: 0, to: candidates.count, by: chunkSize).map {
            Array(candidates[$0..<min($0 + chunkSize, candidates.count)])
        }
        let budget = ResultBudget(limit: maxResults)

        try await withThrowingTaskGroup(of: [SearchFileResult].self) { group in
            var next = 0
            func addTask() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask {
                    var results: [SearchFileResult] = []
                    for path in chunk {
                        if Task.isCancelled || budget.isExhausted { break }
                        let url = root.appending(path: path)
                        let matches: [SearchMatch]
                        if let text = overrides[path] {
                            matches = matcher.matches(in: Data(text.utf8))
                        } else {
                            guard let data = Self.read(url) else { continue }
                            matches = matcher.matches(in: data)
                        }
                        if !matches.isEmpty, budget.take(matches.count) {
                            results.append(SearchFileResult(path: path, url: url, matches: matches))
                        }
                    }
                    return results
                }
            }
            for _ in 0..<min(workers, chunks.count) { addTask() }
            while let results = try await group.next() {
                try Task.checkCancellation()
                if !results.isEmpty { await onBatch(results) }
                addTask()
            }
        }
    }

    /// Memory-mapped contents, or nil for unreadable, huge or binary files.
    private static func read(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count <= maxFileSize, !data.prefix(8192).contains(0) else { return nil }
        return data
    }
}

/// Shared cap on the number of matches across workers.
private final class ResultBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(limit: Int) { remaining = limit }

    var isExhausted: Bool { lock.withLock { remaining <= 0 } }

    func take(_ count: Int) -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= count
            return true
        }
    }
}

/// Include/exclude globs. A pattern without "/" matches a file name or any folder name
/// ("*.swift", "build"); with "/" it matches the whole relative path ("Sources/*").
struct PathFilter: Sendable {
    let include: [String]
    let exclude: [String]

    init(include: String, exclude: String) {
        func split(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        self.include = split(include)
        self.exclude = split(exclude)
    }

    func accepts(_ path: String) -> Bool {
        if exclude.contains(where: { Self.matches($0, path) }) { return false }
        return include.isEmpty || include.contains { Self.matches($0, path) }
    }

    static func matches(_ pattern: String, _ path: String) -> Bool {
        var pattern = pattern
        if pattern.hasSuffix("/") { pattern += "*" }
        if pattern.contains("/") {
            let normalized = pattern.replacingOccurrences(of: "**/", with: "").replacingOccurrences(of: "**", with: "*")
            return fnmatch(normalized, path, 0) == 0 || fnmatch("*/" + normalized, path, 0) == 0
        }
        return path.split(separator: "/").contains { fnmatch(pattern, String($0), 0) == 0 }
    }
}

/// Finds matches in a file's bytes and reports them as line/UTF-16 column positions.
private struct Matcher: Sendable {
    private enum Mode: Sendable {
        case bytes([UInt8], foldCase: Bool)
        case regex(NSRegularExpression)
    }

    private let mode: Mode
    private let wholeWord: Bool

    init(_ options: SearchOptions) throws {
        wholeWord = options.wholeWord
        let isASCII = options.query.utf8.allSatisfy { $0 < 0x80 }
        if !options.regex && (options.caseSensitive || isASCII) {
            let bytes = Array(options.query.utf8)
            mode = .bytes(options.caseSensitive ? bytes : bytes.map(FuzzyMatcher.asciiLowercase),
                          foldCase: !options.caseSensitive)
        } else {
            var pattern = options.regex ? options.query : NSRegularExpression.escapedPattern(for: options.query)
            if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
            do {
                mode = .regex(try NSRegularExpression(
                    pattern: pattern, options: options.caseSensitive ? [.anchorsMatchLines] : [.caseInsensitive, .anchorsMatchLines]))
            } catch {
                throw TextSearch.SearchError.invalidRegex(options.query)
            }
        }
    }

    func matches(in data: Data) -> [SearchMatch] {
        switch mode {
        case .bytes(let needle, let foldCase): byteMatches(data, needle: needle, foldCase: foldCase)
        case .regex(let regex): regexMatches(data, regex: regex)
        }
    }

    private func byteMatches(_ data: Data, needle: [UInt8], foldCase: Bool) -> [SearchMatch] {
        data.withUnsafeBytes { raw -> [SearchMatch] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count >= needle.count else { return [] }
            let count = raw.count
            // Case-insensitive: search a lowercased copy (one vectorizable pass). Positions are
            // identical in both buffers; line text is always taken from the original.
            if foldCase {
                let folded = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
                    for i in 0..<count { buffer[i] = FuzzyMatcher.asciiLowercase(base[i]) }
                    initialized = count
                }
                return folded.withUnsafeBufferPointer { scan(original: base, haystack: $0.baseAddress!, count: count, needle: needle) }
            }
            return scan(original: base, haystack: base, count: count, needle: needle)
        }
    }

    private func scan(original base: UnsafePointer<UInt8>, haystack: UnsafePointer<UInt8>, count: Int,
                      needle: [UInt8]) -> [SearchMatch] {
        var results: [SearchMatch] = []
        var lineNumber = 0
        var lineStart = 0
        var scanned = 0 // newlines are counted up to here
        var position = 0
        while position <= count - needle.count, results.count < TextSearch.maxMatchesPerFile {
            guard let found = memmem(haystack + position, count - position, needle, needle.count) else { break }
            let offset = haystack.distance(to: found.assumingMemoryBound(to: UInt8.self))
            position = offset + max(1, needle.count)
            if wholeWord && !isWordBoundary(base, count: count, start: offset, end: offset + needle.count) { continue }
            while scanned < offset {
                if base[scanned] == 0x0A { lineNumber += 1; lineStart = scanned + 1 }
                scanned += 1
            }
            var lineEnd = offset
            while lineEnd < count && base[lineEnd] != 0x0A { lineEnd += 1 }
            results.append(makeMatch(base, line: lineNumber, lineStart: lineStart, lineEnd: lineEnd,
                                     matchStart: offset, matchEnd: offset + needle.count))
        }
        return results
    }

    private func isWordBoundary(_ bytes: UnsafePointer<UInt8>, count: Int, start: Int, end: Int) -> Bool {
        func isWord(_ byte: UInt8) -> Bool {
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95 || byte >= 0x80
        }
        return (start == 0 || !isWord(bytes[start - 1])) && (end >= count || !isWord(bytes[end]))
    }

    private func regexMatches(_ data: Data, regex: NSRegularExpression) -> [SearchMatch] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let string = text as NSString
        let lineIndex = LineIndex(string: string)
        var results: [SearchMatch] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) { result, _, stop in
            guard let range = result?.range, range.length > 0 else { return }
            let line = lineIndex.line(containing: range.location)
            let lineStart = lineIndex.lineStarts[line]
            let lineEnd = line + 1 < lineIndex.lineCount ? lineIndex.lineStarts[line + 1] - 1 : string.length
            let lineText = string.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            let column = range.location - lineStart
            let length = min(range.length, lineEnd - range.location) // multi-line matches: first line
            let (preview, previewRange) = Self.preview(lineText, column: column, length: length)
            results.append(SearchMatch(line: line, column: column, length: length, preview: preview, previewRange: previewRange))
            if results.count >= TextSearch.maxMatchesPerFile { stop.pointee = true }
        }
        return results
    }

    private func makeMatch(_ bytes: UnsafePointer<UInt8>, line: Int, lineStart: Int, lineEnd: Int,
                           matchStart: Int, matchEnd: Int) -> SearchMatch {
        func string(_ from: Int, _ to: Int) -> String {
            String(decoding: UnsafeBufferPointer(start: bytes + from, count: to - from), as: UTF8.self)
        }
        let before = string(lineStart, matchStart)
        let matched = string(matchStart, matchEnd)
        var lineText = string(lineStart, lineEnd)
        if lineText.hasSuffix("\r") { lineText.removeLast() }
        let column = before.utf16.count
        let length = matched.utf16.count
        let (preview, previewRange) = Self.preview(lineText, column: column, length: length)
        return SearchMatch(line: line, column: column, length: length, preview: preview, previewRange: previewRange)
    }

    /// Trims long lines to a window around the match, and leading indentation.
    static func preview(_ line: String, column: Int, length: Int) -> (String, NSRange) {
        let text = line as NSString
        var start = 0
        while start < column, start < text.length,
              let scalar = Unicode.Scalar(text.character(at: start)), scalar == " " || scalar == "\t" { start += 1 }
        if column - start > 40 { start = column - 40 }
        let end = min(text.length, max(column + length, start + TextSearch.previewLimit))
        var preview = text.substring(with: NSRange(location: start, length: end - start))
        var location = column - start
        if start > 0 && start != Self.indentation(of: text) {
            preview = "…" + preview
            location += 1
        }
        return (preview, NSRange(location: location, length: min(length, (preview as NSString).length - location)))
    }

    private static func indentation(of text: NSString) -> Int {
        var count = 0
        while count < text.length, let scalar = Unicode.Scalar(text.character(at: count)),
              scalar == " " || scalar == "\t" { count += 1 }
        return count
    }
}
