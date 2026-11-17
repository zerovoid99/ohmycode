import Foundation

/// A header as written (or as sent): its name keeps the file's spelling, lookups ignore case.
struct HTTPHeader: Equatable, Hashable, Codable, Sendable {
    var name: String
    var value: String
}

extension Array where Element == HTTPHeader {
    /// The first header named `name` (any case).
    func value(for name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func contains(named name: String) -> Bool { value(for: name) != nil }

    mutating func remove(named name: String) {
        removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// `@name = value` outside a request: usable as `{{name}}` anywhere in the file.
struct HTTPFileVariable: Equatable, Sendable {
    var name: String
    var value: String
    /// Zero-based.
    var line: Int
}

/// `# @prompt name description`: asked for before the request is sent.
struct HTTPPrompt: Equatable, Sendable {
    var name: String
    var description: String?
}

/// Something wrong with a line of the file (a request line that isn't one, a stray line among
/// the headers), shown as a problem.
struct HTTPIssue: Equatable, Sendable {
    /// Zero-based line, and UTF-16 columns in it.
    var line: Int
    var columns: Range<Int>
    var message: String
    var isError = true
}

/// One request of a `.http` file, as written: variables are still `{{…}}`.
struct HTTPRequestBlock: Equatable, Sendable {
    /// Its position among the file's requests.
    var index: Int
    /// The text after `###` that starts it, if any.
    var title: String?
    /// `# @name` (what request variables refer to it by).
    var metadataName: String?
    var noRedirect = false
    var noCookieJar = false
    /// `# @note`: confirm before sending (the text, possibly empty).
    var note: String?
    var prompts: [HTTPPrompt] = []
    var method = "GET"
    var url = ""
    var httpVersion: String?
    var headers: [HTTPHeader] = []
    /// Lines of the headers (zero-based), one per header.
    var headerLines: [Int] = []
    /// The body as written (lines joined with "\n", trailing blank lines dropped); nil if none.
    var body: String?
    /// Zero-based lines: the `###` line (if any) up to the line before the next one.
    var lines: Range<Int>
    var requestLine: Int
    /// The first line of the body, if there is one.
    var bodyLine: Int?
    /// The last line with text.
    var lastLine: Int
    /// The block's text from its first line (after `###`) to its last line with text.
    var source: String

    /// The name request variables use: `# @name`, else the `###` title when it's one word.
    var name: String? {
        if let metadataName { return metadataName }
        guard let title, !title.isEmpty, !title.contains(where: \.isWhitespace) else { return nil }
        return title
    }

    /// What it's called in tabs and history: its name or title, else method and URL.
    var displayName: String {
        if let name = metadataName ?? title, !name.isEmpty { return name }
        return "\(method) \(url)"
    }
}

/// A `.http` / `.rest` file, read the way VS Code's REST Client and JetBrains' HTTP Client read
/// them: requests separated by `###`, each a request line (`METHOD URL [HTTP/x]`, the method
/// optional), `?`/`&` query lines, headers up to a blank line, then the body. `#` and `//`
/// lines are comments (but not in a body), `@name = value` lines define file variables.
struct HTTPFile: Equatable, Sendable {
    var requests: [HTTPRequestBlock] = []
    var variables: [HTTPFileVariable] = []
    var issues: [HTTPIssue] = []

    static let methods: Set<String> = [
        "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "CONNECT", "TRACE",
        "LOCK", "UNLOCK", "PROPFIND", "PROPPATCH", "COPY", "MOVE", "MKCOL", "MKCALENDAR", "ACL", "SEARCH",
    ]

    /// The file's lines without their line breaks (CRLF and LF alike).
    static func lines(of text: String) -> [String] {
        // By UTF-16 unit: "\r\n" is one Character, so splitting Characters at "\n" misses it.
        text.components(separatedBy: "\n").map { line in
            line.utf16.last == 0x0D ? String(line.utf16.dropLast())! : line
        }
    }

    static func isSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("###")
    }

    static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#") || trimmed.hasPrefix("//")
    }

    /// `@name = value` (a file variable), or nil.
    static func fileVariable(_ line: String) -> (name: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let name = trimmed[trimmed.index(after: trimmed.startIndex)..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "_-.$".contains($0) }) else { return nil }
        return (name, trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    }

    /// `# @key value` / `// @key value`, or nil.
    static func metadata(_ line: String) -> (key: String, value: String)? {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("//") { trimmed = trimmed.dropFirst(2) } else if trimmed.hasPrefix("#") { trimmed = trimmed.dropFirst() } else { return nil }
        trimmed = trimmed.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("@") else { return nil }
        trimmed = trimmed.dropFirst()
        let key = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !key.isEmpty else { return nil }
        return (String(key).lowercased(), trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces))
    }

    /// A request line's method, URL and HTTP version. Without a known method first, the whole
    /// line is the URL of a GET.
    static func requestLine(_ line: String) -> (method: String, url: String, version: String?, knownMethod: Bool) {
        var rest = line.trimmingCharacters(in: .whitespaces)
        var method = "GET"
        var known = false
        if let space = rest.firstIndex(where: { $0 == " " || $0 == "\t" }), methods.contains(rest[..<space].uppercased()) {
            method = rest[..<space].uppercased()
            rest = rest[space...].trimmingCharacters(in: .whitespaces)
            known = true
        } else if methods.contains(rest.uppercased()) {
            return (rest.uppercased(), "", nil, true)
        }
        var version: String?
        if let range = rest.range(of: #"\s+HTTP/[0-9.]+$"#, options: [.regularExpression, .caseInsensitive]) {
            version = rest[range].trimmingCharacters(in: .whitespaces).uppercased()
            rest = String(rest[..<range.lowerBound])
        }
        return (method, rest, version, known)
    }

    /// Whether `name` can be a header name (an HTTP token, or a variable).
    static func isToken(_ name: Substring) -> Bool {
        if name.hasPrefix("{{") && name.hasSuffix("}}") { return true }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+.^_`|~-".contains($0)) }
    }

    /// The text with `{{…}}` taken out (variables may hold spaces).
    static func withoutVariables(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{\{.*?\}\}"#, with: "x", options: .regularExpression)
    }

    init(text: String) {
        let lines = Self.lines(of: text)
        // Blocks: from each `###` line (or the file's start) to the next one.
        var starts = [0]
        for (index, line) in lines.enumerated() where index > 0 && Self.isSeparator(line) { starts.append(index) }
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : lines.count
            parseBlock(lines, start..<end)
        }
    }

    private mutating func parseBlock(_ lines: [String], _ range: Range<Int>) {
        var line = range.lowerBound
        var title: String?
        if line < range.upperBound, Self.isSeparator(lines[line]) {
            let text = lines[line].trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            title = text.isEmpty ? nil : text
            line += 1
        }
        let contentStart = line
        var block = HTTPRequestBlock(index: requests.count, title: title, lines: range, requestLine: 0, lastLine: 0, source: "")
        // Before the request line: blank lines, comments (with metadata) and file variables.
        var requestLine: Int?
        while line < range.upperBound {
            let text = lines[line]
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                line += 1
            } else if let (key, value) = Self.metadata(text) {
                switch key {
                case "name": block.metadataName = value.split(whereSeparator: \.isWhitespace).first.map(String.init)
                case "no-redirect": block.noRedirect = true
                case "no-cookie-jar": block.noCookieJar = true
                case "note": block.note = value
                case "prompt":
                    let parts = value.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
                    if let name = parts.first {
                        block.prompts.append(HTTPPrompt(name: name, description: parts.count > 1 ? parts[1] : nil))
                    }
                default: break
                }
                line += 1
            } else if Self.isComment(text) {
                line += 1
            } else if let variable = Self.fileVariable(text) {
                variables.append(HTTPFileVariable(name: variable.name, value: variable.value, line: line))
                line += 1
            } else {
                requestLine = line
                break
            }
        }
        guard let requestLine else { return } // only comments and variables
        let parsed = Self.requestLine(lines[requestLine])
        block.method = parsed.method
        block.url = parsed.url
        block.httpVersion = parsed.version
        block.requestLine = requestLine
        let length = lines[requestLine].utf16.count
        if parsed.url.isEmpty {
            issues.append(HTTPIssue(line: requestLine, columns: 0..<length, message: "The request line has no URL."))
        } else if Self.withoutVariables(parsed.url).contains(where: \.isWhitespace) {
            let message = parsed.knownMethod
                ? "Malformed request line: expected “METHOD URL [HTTP/version]”."
                : "Unknown method “\(lines[requestLine].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")”: expected “METHOD URL [HTTP/version]”."
            issues.append(HTTPIssue(line: requestLine, columns: 0..<length, message: message))
        }
        line = requestLine + 1
        // Query lines carry on the URL.
        while line < range.upperBound {
            let trimmed = lines[line].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("?") || trimmed.hasPrefix("&") else { break }
            block.url += trimmed
            line += 1
        }
        // Headers, up to a blank line.
        var bodyStart: Int?
        while line < range.upperBound {
            let text = lines[line]
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { bodyStart = line + 1; break }
            if Self.isComment(text) { line += 1; continue }
            if let colon = trimmed.firstIndex(of: ":"), colon != trimmed.startIndex, Self.isToken(trimmed[..<colon]) {
                block.headers.append(HTTPHeader(name: String(trimmed[..<colon]),
                                                value: trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                block.headerLines.append(line)
                line += 1
                continue
            }
            // A body without the blank line before it ({, [, <, a file): taken as one.
            if let first = trimmed.first, "{[<".contains(first) { bodyStart = line; break }
            issues.append(HTTPIssue(line: line, columns: 0..<text.utf16.count,
                                    message: "Expected a header (“Name: value”) or a blank line before the body."))
            line += 1
        }
        var lastLine = max(requestLine, block.headerLines.last ?? requestLine)
        if let bodyStart, bodyStart < range.upperBound {
            var bodyEnd = range.upperBound
            while bodyEnd > bodyStart, lines[bodyEnd - 1].trimmingCharacters(in: .whitespaces).isEmpty { bodyEnd -= 1 }
            if bodyEnd > bodyStart {
                block.body = lines[bodyStart..<bodyEnd].joined(separator: "\n")
                block.bodyLine = bodyStart
                lastLine = bodyEnd - 1
            }
        }
        block.lastLine = lastLine
        block.source = lines[contentStart...lastLine].joined(separator: "\n")
        requests.append(block)
    }

    /// File variables by name (a later definition wins, as in REST Client).
    var variableValues: [String: String] {
        Dictionary(variables.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 })
    }

    /// The request whose block holds `line` (zero-based); in a block without one, nil.
    func request(atLine line: Int) -> HTTPRequestBlock? {
        requests.first { $0.lines.contains(line) }
    }

    func request(named name: String) -> HTTPRequestBlock? {
        requests.first { $0.name == name }
    }

    /// Names of the requests that have one.
    var requestNames: Set<String> { Set(requests.compactMap(\.name)) }
}
