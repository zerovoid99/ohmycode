import Foundation
import SwiftTreeSitter

/// Editor support for `.http` / `.rest` files without a tree-sitter grammar: a line-based
/// highlighter (run by `SyntaxEngine` like a grammar's query), completion, problems, folding,
/// the outline and the Send Request lenses.
enum HTTPSyntax {
    /// Where a line is in its request.
    enum State: Equatable {
        case preamble, headers
        case body(BodyKind)
    }

    enum BodyKind: Equatable { case json, xml, text }

    /// How far back a highlight looks for the `###` its request starts at.
    static let maxLookBehind = 256 * 1024

    private static let xmlTag = try! NSRegularExpression(pattern: #"<!--.*?(-->|$)|<[^<>]*>?"#)
    private static let xmlName = try! NSRegularExpression(pattern: #"^</?\s*([\w:.-]+)"#)
    private static let xmlAttribute = try! NSRegularExpression(pattern: #"([\w:.-]+)\s*=\s*("[^"]*"?|'[^']*'?)"#)

    /// Where the request holding `offset` starts (its `###` line, or the file's start).
    static func blockStart(in text: NSString, before offset: Int) -> Int {
        var lineStart = text.lineRange(for: NSRange(location: min(offset, text.length), length: 0)).location
        let limit = max(0, offset - maxLookBehind)
        while lineStart > limit {
            if isSeparatorLine(text, at: lineStart) { return lineStart }
            lineStart = text.lineRange(for: NSRange(location: lineStart - 1, length: 0)).location
        }
        return lineStart
    }

    private static func isSeparatorLine(_ text: NSString, at lineStart: Int) -> Bool {
        var position = lineStart
        while position < text.length, text.character(at: position) == 0x20 || text.character(at: position) == 0x09 { position += 1 }
        return position + 3 <= text.length && text.substring(with: NSRange(location: position, length: 3)) == "###"
    }

    /// Each line from `start` (a block start) through `end`: its range (without the line
    /// break), its text, and the state it's in.
    static func walk(_ text: NSString, from start: Int, through end: Int,
                     _ visit: (NSRange, String, State, inout Bool) -> Void) {
        var state = State.preamble
        var contentType = ""
        var position = start
        var stop = false
        while position <= text.length, !stop {
            let full = text.lineRange(for: NSRange(location: position, length: 0))
            var contentEnd = NSMaxRange(full)
            while contentEnd > full.location, [0x0A, 0x0D].contains(text.character(at: contentEnd - 1)) { contentEnd -= 1 }
            let range = NSRange(location: full.location, length: contentEnd - full.location)
            let line = text.substring(with: range)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if HTTPFile.isSeparator(line) {
                state = .preamble
                contentType = ""
                visit(range, line, .preamble, &stop)
            } else {
                // An untyped body is JSON or XML by its first character.
                if state == .body(.text), let first = trimmed.first {
                    state = .body(first == "{" || first == "[" ? .json : first == "<" && HTTPRequestBuilder.fileReference(line) == nil ? .xml : .text)
                }
                visit(range, line, state, &stop)
                switch state {
                case .preamble:
                    if !trimmed.isEmpty, !HTTPFile.isComment(line), HTTPFile.fileVariable(line) == nil { state = .headers }
                case .headers:
                    if trimmed.isEmpty {
                        state = .body(contentType.contains("json") ? .json : contentType.contains("xml") || contentType.contains("html") ? .xml : .text)
                    } else if trimmed.lowercased().hasPrefix("content-type:") {
                        contentType = trimmed.lowercased()
                    } else if trimmed.lowercased().hasPrefix("x-request-type:") && trimmed.lowercased().contains("graphql") {
                        contentType = "graphql"
                    }
                case .body: break
                }
            }
            // On to the next line (the empty one after a final line break included).
            let next = NSMaxRange(full)
            if next == full.location || next > end { break }
            if next >= text.length, text.length == 0 || text.character(at: text.length - 1) != 0x0A { break }
            position = next
        }
    }

    /// The state of the line at `lineStart`.
    static func state(in text: NSString, atLine lineStart: Int) -> State {
        var result = State.preamble
        walk(text, from: blockStart(in: text, before: lineStart), through: lineStart) { range, _, state, stop in
            if range.location >= lineStart { result = state; stop = true }
        }
        return result
    }

    // MARK: Highlighting

    /// Highlights for the lines `range` touches (capture names as the editor's theme knows them).
    static func highlights(in text: NSString, range: NSRange) -> [NamedRange] {
        tokens(in: text, range: range).map { NamedRange(name: $0.capture, range: $0.range) }
    }

    static func tokens(in text: NSString, range: NSRange) -> [(range: NSRange, capture: String)] {
        var tokens: [(range: NSRange, capture: String)] = []
        let end = NSMaxRange(range)
        walk(text, from: blockStart(in: text, before: range.location), through: end) { lineRange, line, state, stop in
            if lineRange.location > end { stop = true; return }
            guard NSMaxRange(lineRange) >= range.location else { return }
            tokens += lineTokens(line, at: lineRange.location, state: state)
        }
        return tokens
    }

    /// One line's tokens (UTF-16 ranges in the document, the line starting at `offset`).
    static func lineTokens(_ line: String, at offset: Int, state: State) -> [(range: NSRange, capture: String)] {
        let string = line as NSString
        var tokens: [(range: NSRange, capture: String)] = []
        func add(_ location: Int, _ length: Int, _ capture: String) {
            if length > 0 { tokens.append((NSRange(location: offset + location, length: length), capture)) }
        }
        let indent = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let trimmedLength = (trimmed as NSString).length
        if HTTPFile.isSeparator(line) {
            let hashes = trimmed.prefix { $0 == "#" }.utf16.count
            add(indent, hashes, "comment")
            add(indent + hashes, string.length - indent - hashes, "function")
            return tokens
        }
        switch state {
        case .preamble, .headers:
            if trimmed.isEmpty { return tokens }
            if HTTPFile.isComment(line) {
                add(indent, trimmedLength, "comment")
                if HTTPFile.metadata(line) != nil {
                    let at = string.range(of: "@")
                    let keyLength = (string.substring(from: at.location + 1) as NSString)
                        .rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted).location
                    add(at.location, keyLength == NSNotFound ? string.length - at.location : keyLength + 1, "attribute")
                }
                return tokens
            }
            if state == .preamble, HTTPFile.fileVariable(line) != nil {
                let equals = string.range(of: "=").location
                let name = string.substring(to: equals).trimmingCharacters(in: .whitespaces) as NSString
                add(indent, name.length, "attribute")
                var valueStart = equals + 1
                while valueStart < string.length, string.character(at: valueStart) == 0x20 { valueStart += 1 }
                add(valueStart, string.length - valueStart, "string")
            } else if state == .preamble {
                let parsed = HTTPFile.requestLine(line)
                var position = indent
                if parsed.knownMethod {
                    let methodLength = trimmed.prefix { !$0.isWhitespace }.utf16.count
                    add(indent, methodLength, "keyword")
                    position = indent + methodLength
                    while position < string.length, string.character(at: position) == 0x20 || string.character(at: position) == 0x09 { position += 1 }
                }
                let urlLength = (parsed.url as NSString).length
                add(position, urlLength, "string.special.url")
                if let version = parsed.version {
                    let found = string.range(of: version, options: [.backwards, .caseInsensitive])
                    if found.location != NSNotFound { add(found.location, found.length, "constant") }
                }
            } else if trimmed.hasPrefix("?") || trimmed.hasPrefix("&") {
                add(indent, trimmedLength, "string.special.url")
            } else if let colon = trimmed.firstIndex(of: ":"), colon != trimmed.startIndex {
                add(indent, trimmed[..<colon].utf16.count, "property")
            }
        case .body(let kind):
            if let reference = HTTPRequestBuilder.fileReference(line) {
                let marker = reference.substitutesVariables ? 2 + (reference.encoding?.utf16.count ?? 0) : 1
                add(indent, marker, "keyword")
                let pathStart = string.range(of: reference.path, options: .backwards).location
                if pathStart != NSNotFound { add(pathStart, (reference.path as NSString).length, "string") }
            } else {
                switch kind {
                case .json: tokens += jsonTokens(string, at: offset)
                case .xml: tokens += xmlTokens(string, at: offset)
                case .text: break
                }
            }
        }
        // Variables last: over whatever they're in.
        for reference in HTTPVariableResolver.references(in: line) {
            add(reference.range.location, reference.range.length, "type")
        }
        return tokens
    }

    private static func jsonTokens(_ line: NSString, at offset: Int) -> [(range: NSRange, capture: String)] {
        var tokens: [(range: NSRange, capture: String)] = []
        var index = 0
        let length = line.length
        while index < length {
            let unit = line.character(at: index)
            if unit == 0x22 { // "
                var end = index + 1
                while end < length, line.character(at: end) != 0x22 { end += line.character(at: end) == 0x5C ? 2 : 1 }
                end = min(end + 1, length)
                var after = end
                while after < length, line.character(at: after) == 0x20 { after += 1 }
                let isKey = after < length && line.character(at: after) == 0x3A
                tokens.append((NSRange(location: offset + index, length: end - index), isKey ? "property" : "string"))
                index = end
            } else if unit == 0x2D || (unit >= 0x30 && unit <= 0x39) {
                var end = index + 1
                while end < length, let scalar = Unicode.Scalar(line.character(at: end)), "0123456789.eE+-".unicodeScalars.contains(scalar) { end += 1 }
                tokens.append((NSRange(location: offset + index, length: end - index), "number"))
                index = end
            } else if unit >= 0x61 && unit <= 0x7A {
                var end = index + 1
                while end < length, line.character(at: end) >= 0x61 && line.character(at: end) <= 0x7A { end += 1 }
                let word = line.substring(with: NSRange(location: index, length: end - index))
                if ["true", "false", "null"].contains(word) { tokens.append((NSRange(location: offset + index, length: end - index), "constant.builtin")) }
                index = end
            } else if unit == 0x7B, index + 1 < length, line.character(at: index + 1) == 0x7B { // {{ … }} (a variable)
                let close = line.range(of: "}}", options: .literal, range: NSRange(location: index, length: length - index))
                index = close.location == NSNotFound ? length : NSMaxRange(close)
            } else {
                index += 1
            }
        }
        return tokens
    }

    private static func xmlTokens(_ line: NSString, at offset: Int) -> [(range: NSRange, capture: String)] {
        var tokens: [(range: NSRange, capture: String)] = []
        let whole = NSRange(location: 0, length: line.length)
        for match in xmlTag.matches(in: line as String, range: whole) {
            let tag = match.range
            if line.substring(with: tag).hasPrefix("<!--") {
                tokens.append((NSRange(location: offset + tag.location, length: tag.length), "comment"))
                continue
            }
            let text = line.substring(with: tag) as NSString
            if let name = xmlName.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) {
                tokens.append((NSRange(location: offset + tag.location, length: NSMaxRange(name.range(at: 1))), "tag"))
            }
            if text.hasSuffix(">") {
                let closing = text.hasSuffix("/>") ? 2 : 1
                tokens.append((NSRange(location: offset + NSMaxRange(tag) - closing, length: closing), "tag"))
            }
            for attribute in xmlAttribute.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let name = attribute.range(at: 1), value = attribute.range(at: 2)
                tokens.append((NSRange(location: offset + tag.location + name.location, length: name.length), "attribute"))
                tokens.append((NSRange(location: offset + tag.location + value.location, length: value.length), "string"))
            }
        }
        return tokens
    }

    // MARK: Structure

    /// A request's lines as a character range, from its first line to the end of its last.
    static func range(of block: HTTPRequestBlock, lineIndex: LineIndex, length: Int) -> NSRange {
        let first = block.lines.lowerBound
        let start = first < lineIndex.lineCount ? lineIndex.lineStarts[first] : length
        let endLine = block.lastLine + 1
        let end = endLine < lineIndex.lineCount ? lineIndex.lineStarts[endLine] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// One fold per request: its `###` line (or first line) to its last line with text.
    static func foldRegions(_ file: HTTPFile) -> [FoldRegion] {
        file.requests.compactMap { block in
            let start = block.title != nil || block.lines.lowerBound > 0 ? block.lines.lowerBound : block.requestLine
            return block.lastLine > start ? FoldRegion(start: start, end: block.lastLine, kind: .region) : nil
        }
    }

    /// The outline: each request by its name, or its method and URL.
    static func symbols(_ file: HTTPFile, lineIndex: LineIndex, length: Int) -> [DocumentSymbol] {
        DocumentSymbol.identified(file.requests.map { block in
            let line = block.requestLine
            let start = line < lineIndex.lineCount ? lineIndex.lineStarts[line] : length
            let end = line + 1 < lineIndex.lineCount ? lineIndex.lineStarts[line + 1] - 1 : length
            let named = block.metadataName ?? block.title
            return DocumentSymbol(name: named ?? "\(block.method) \(block.url)", detail: named == nil ? nil : "\(block.method) \(block.url)",
                                  kind: .method, range: range(of: block, lineIndex: lineIndex, length: length),
                                  selectionRange: NSRange(location: start, length: max(0, end - start)))
        })
    }

    static let commandPrefix = "omc.http."
    static let problemSource = "http"
    static let sendCommand = "omc.http.send"
    static let copyCurlCommand = "omc.http.copyCurl"

    /// "Send Request" and "Copy as cURL" on each request line, by zero-based line.
    static func codeLenses(_ file: HTTPFile) -> [Int: [CodeLens]] {
        var result: [Int: [CodeLens]] = [:]
        for block in file.requests {
            let range: [String: Any] = ["start": ["line": block.requestLine, "character": 0], "end": ["line": block.requestLine, "character": 0]]
            result[block.requestLine] = [("Send Request", sendCommand), ("Copy as cURL", copyCurlCommand)].compactMap { title, command in
                CodeLens(json: ["range": range, "command": ["title": title, "command": command, "arguments": [block.requestLine]]])
            }
        }
        return result
    }

    // MARK: Problems

    /// Unknown variables, request lines that aren't, stray header lines, and files a body sends
    /// that aren't there. `otherEnvironments` are the variables of environments not chosen
    /// (a variable only they have is a warning: choose one of them).
    static func diagnostics(text: String, file: HTTPFile, resolver: HTTPVariableResolver,
                            otherEnvironments: [String: Set<String>] = [:], baseDirectory: URL?) -> [Diagnostic] {
        func range(_ line: Int, _ columns: Range<Int>) -> LSPRange {
            LSPRange(start: LSPPosition(line: line, character: columns.lowerBound), end: LSPPosition(line: line, character: columns.upperBound))
        }
        var result = file.issues.map {
            Diagnostic(range: range($0.line, $0.columns), severity: $0.isError ? .error : .warning, message: $0.message, source: "http")
        }
        let lines = HTTPFile.lines(of: text)
        let bodyLines = Set(file.requests.flatMap { block in block.bodyLine.map { Array($0...block.lastLine) } ?? [] })
        for (number, line) in lines.enumerated() {
            let inBody = bodyLines.contains(number)
            if !inBody, HTTPFile.isComment(line) || HTTPFile.isSeparator(line) { continue }
            let block = file.request(atLine: number)
            let prompts = Set(block?.prompts.map(\.name) ?? [])
            for reference in HTTPVariableResolver.references(in: line) where !resolver.isDefined(reference.name, prompts: prompts) {
                let columns = reference.range.location..<NSMaxRange(reference.range)
                let elsewhere = otherEnvironments.filter { $0.value.contains(reference.name) }.keys.sorted()
                if !elsewhere.isEmpty {
                    result.append(Diagnostic(range: range(number, columns), severity: .warning,
                                             message: "“\(reference.name)” is only defined in the environment\(elsewhere.count > 1 ? "s" : "") \(elsewhere.map { "“\($0)”" }.joined(separator: ", ")): choose one (REST: Switch Environment).",
                                             source: "http"))
                } else if reference.name.hasPrefix("$") {
                    result.append(Diagnostic(range: range(number, columns), severity: .error,
                                             message: "Unknown system variable “\(reference.name.split(separator: " ").first ?? "")”.", source: "http"))
                } else {
                    result.append(Diagnostic(range: range(number, columns), severity: .error,
                                             message: "Unknown variable “\(reference.name)”: define it with “@\(reference.name) = …” or in an environment.",
                                             source: "http"))
                }
            }
            if inBody, let reference = HTTPRequestBuilder.fileReference(line), !reference.path.contains("{{") {
                let url = HTTPRequestBuilder.resolvePath(reference.path, base: baseDirectory)
                if !FileManager.default.fileExists(atPath: url.path) {
                    let start = (line as NSString).range(of: reference.path, options: .backwards).location
                    result.append(Diagnostic(range: range(number, start..<(start + (reference.path as NSString).length)), severity: .error,
                                             message: "The file “\(reference.path)” doesn't exist.", source: "http"))
                }
            }
        }
        return result
    }
}

// MARK: Completion

enum HTTPCompletion {
    static let headerNames = [
        "Accept", "Accept-Charset", "Accept-Encoding", "Accept-Language", "Authorization", "Cache-Control", "Connection",
        "Content-Disposition", "Content-Encoding", "Content-Length", "Content-Type", "Cookie", "Date", "Expect", "Forwarded",
        "From", "Host", "If-Match", "If-Modified-Since", "If-None-Match", "If-Range", "If-Unmodified-Since", "Origin",
        "Pragma", "Prefer", "Range", "Referer", "TE", "Upgrade", "User-Agent", "Via", "X-API-Key", "X-Correlation-ID",
        "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Request-ID", "X-Request-Type", "X-Requested-With",
    ]

    static let mimeTypes = [
        "application/json", "application/xml", "application/x-www-form-urlencoded", "multipart/form-data",
        "application/graphql", "application/javascript", "application/octet-stream", "application/pdf",
        "application/problem+json", "application/vnd.api+json", "application/ld+json", "application/x-ndjson",
        "text/plain", "text/html", "text/css", "text/csv", "text/xml", "text/javascript", "text/event-stream",
        "image/png", "image/jpeg", "image/gif", "image/svg+xml", "image/webp", "*/*",
    ]

    static let systemVariables: [(insert: String, detail: String)] = [
        ("$guid", "A random UUID"), ("$randomInt 1 100", "A random integer: min (included) to max"),
        ("$timestamp", "Unix time in seconds (optional offset: 1 d)"),
        ("$datetime iso8601", "UTC date: rfc1123, iso8601 or \"format\""), ("$localDatetime iso8601", "Local date and time"),
        ("$processEnv NAME", "An environment variable of the app"), ("$dotenv NAME", "A value from the .env file"),
    ]

    enum Kind { static let keyword = 14, variable = 6, property = 10, value = 12, reference = 18 }

    /// Items for the caret at `cursor` on zero-based `line` (which starts at `lineStart`):
    /// methods, header names, MIME types, and variables after `{{`.
    static func items(text: NSString, cursor: Int, line: Int, lineStart: Int, variables: [(name: String, detail: String)],
                      requestNames: [String], firstID: Int) -> [CompletionItem] {
        let before = text.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        var nextID = firstID
        func item(_ label: String, _ detail: String?, _ kind: Int, insert: String? = nil, from column: Int, sort: String? = nil) -> CompletionItem {
            var item = CompletionItem(id: nextID, label: label, detail: detail, kind: kind, sortText: sort, insertText: insert ?? label, isSnippet: false)
            item.editRange = LSPRange(start: LSPPosition(line: line, character: column),
                                      end: LSPPosition(line: line, character: cursor - lineStart))
            nextID += 1
            return item
        }
        // Inside {{ … }}.
        let beforeNS = before as NSString
        let open = beforeNS.range(of: "{{", options: .backwards)
        if open.location != NSNotFound, beforeNS.range(of: "}}", options: .literal, range: NSRange(location: open.location, length: beforeNS.length - open.location)).location == NSNotFound {
            var column = NSMaxRange(open)
            while column < beforeNS.length, beforeNS.character(at: column) == 0x20 { column += 1 }
            let after = text.substring(from: cursor)
            let closing = after.trimmingCharacters(in: .whitespaces).hasPrefix("}}") ? "" : "}}"
            var result = variables.map { item($0.name, $0.detail, Kind.variable, insert: $0.name + closing, from: column) }
            for name in requestNames {
                for (path, detail) in [("response.body.$.", "A value from its response's JSON"), ("response.body.*", "Its whole response body"),
                                       ("response.headers.", "A header of its response"), ("request.body.*", "Its request body"),
                                       ("request.headers.", "A header it sent")] {
                    result.append(item("\(name).\(path)", detail, Kind.reference, insert: "\(name).\(path)" + (path.hasSuffix(".") ? "" : closing),
                                       from: column, sort: "~" + name))
                }
            }
            result += systemVariables.map { item($0.insert, $0.detail, Kind.value, insert: $0.insert + closing, from: column, sort: "~~" + $0.insert) }
            return result
        }
        let state = HTTPSyntax.state(in: text, atLine: lineStart)
        let trimmedBefore = before.trimmingCharacters(in: .whitespaces)
        let indent = (before as NSString).length - (before.drop { $0 == " " || $0 == "\t" } as Substring).utf16.count
        switch state {
        case .preamble:
            guard !trimmedBefore.contains(" "), trimmedBefore.allSatisfy(\.isLetter) else { return [] }
            return HTTPFile.methods.sorted().map { item($0, "HTTP method", Kind.keyword, insert: $0 + " ", from: indent) }
        case .headers:
            if let colon = before.firstIndex(of: ":") {
                let name = before[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                var column = before[...colon].utf16.count
                while column < beforeNS.length, beforeNS.character(at: column) == 0x20 { column += 1 }
                switch name {
                case "content-type", "accept":
                    return mimeTypes.map { item($0, nil, Kind.value, from: column) }
                case "authorization":
                    return [item("Basic ", "Basic user:password (encoded when sent)", Kind.value, from: column),
                            item("Bearer ", "Bearer token", Kind.value, from: column)]
                case "x-request-type":
                    return [item("GraphQL", "Send the body as a GraphQL query", Kind.value, from: column)]
                default:
                    return []
                }
            }
            guard !trimmedBefore.hasPrefix("?"), !trimmedBefore.hasPrefix("&"), !trimmedBefore.hasPrefix("#") else { return [] }
            return headerNames.map { item($0, "Header", Kind.property, insert: $0 + ": ", from: indent) }
        case .body:
            return []
        }
    }
}
