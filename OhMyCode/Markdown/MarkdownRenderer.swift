import Foundation

/// Markdown (CommonMark with GitHub's tables, task lists, strikethrough and bare links) to
/// HTML for the preview. Block elements carry `data-line` (their zero-based source line) so the
/// preview can scroll with the editor; fenced code blocks are listed for highlighting later.
struct MarkdownRenderer {
    struct CodeBlock: Equatable {
        let id: Int
        let language: String
        let code: String
    }

    struct Result {
        var html: String
        var codeBlocks: [CodeBlock]
    }

    /// Turns a link or image target into what the page loads (relative files → local URLs).
    var resolveURL: (String) -> String = { $0 }

    private typealias Line = (text: String, number: Int)
    private var references: [String: (url: String, title: String?)] = [:]
    private var codeBlocks: [CodeBlock] = []

    init(resolveURL: @escaping (String) -> String = { $0 }) {
        self.resolveURL = resolveURL
    }

    mutating func render(_ markdown: String) -> Result {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [Line] = text.components(separatedBy: "\n").enumerated().map { ($1, $0) }
        lines = collectReferences(lines)
        codeBlocks = []
        let html = renderBlocks(lines)
        return Result(html: html, codeBlocks: codeBlocks)
    }

    // MARK: Blocks

    private static func indentation(_ text: String) -> Int {
        var width = 0
        for character in text {
            if character == " " { width += 1 } else if character == "\t" { width += 4 - width % 4 } else { break }
        }
        return width
    }

    private static func isBlank(_ text: String) -> Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

    /// `text` without its first `count` columns of indentation.
    private static func dedent(_ text: String, by count: Int) -> String {
        var width = 0
        var index = text.startIndex
        while index < text.endIndex, width < count {
            let character = text[index]
            if character == " " { width += 1 } else if character == "\t" { width += 4 - width % 4 } else { break }
            index = text.index(after: index)
        }
        return String(text[index...])
    }

    private mutating func collectReferences(_ lines: [Line]) -> [Line] {
        let pattern = try! NSRegularExpression(pattern: #"^ {0,3}\[([^\]]+)\]:\s*(?:<([^>]*)>|(\S+))(?:\s+["'(](.+)["')])?\s*$"#)
        var kept: [Line] = []
        var inFence = false
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            let range = NSRange(line.text.startIndex..., in: line.text)
            if !inFence, let match = pattern.firstMatch(in: line.text, range: range),
               let label = Range(match.range(at: 1), in: line.text),
               let url = Range(match.range(at: 2), in: line.text) ?? Range(match.range(at: 3), in: line.text) {
                let key = line.text[label].lowercased()
                if references[key] == nil {
                    references[key] = (String(line.text[url]), Range(match.range(at: 4), in: line.text).map { String(line.text[$0]) })
                }
                continue
            }
            kept.append(line)
        }
        return kept
    }

    private static let atxHeading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"#)
    private static let thematicBreak = try! NSRegularExpression(pattern: #"^ {0,3}((\*[ \t]*){3,}|(-[ \t]*){3,}|(_[ \t]*){3,})$"#)
    private static let fence = try! NSRegularExpression(pattern: #"^( {0,3})(`{3,}|~{3,})[ \t]*([^`]*?)[ \t]*$"#)
    private static let listItem = try! NSRegularExpression(pattern: #"^( {0,3})([-+*]|\d{1,9}[.)])([ \t]+|$)"#)
    private static let tableDelimiter = try! NSRegularExpression(pattern: #"^ {0,3}\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)

    private static func match(_ regex: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    private func attribute(_ line: Int) -> String { " data-line=\"\(line)\"" }

    private mutating func renderBlocks(_ lines: [Line], tight: Bool = false) -> String {
        var html = ""
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let text = line.text
            if Self.isBlank(text) { index += 1; continue }

            // Fenced code.
            if let fence = Self.match(Self.fence, text) {
                let indent = Self.group(fence, 1, in: text)?.count ?? 0
                let marker = Self.group(fence, 2, in: text) ?? "```"
                let info = Self.group(fence, 3, in: text) ?? ""
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let body = lines[index].text
                    let trimmed = body.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix(String(marker.first!)), trimmed.allSatisfy({ $0 == marker.first }), trimmed.count >= marker.count {
                        index += 1
                        break
                    }
                    code.append(Self.dedent(body, by: indent))
                    index += 1
                }
                let language = info.split(separator: " ").first.map(String.init) ?? ""
                let id = codeBlocks.count
                let source = code.joined(separator: "\n")
                codeBlocks.append(CodeBlock(id: id, language: language, code: source))
                let languageClass = language.isEmpty ? "" : " class=\"language-\(Self.escape(language))\""
                html += "<pre\(attribute(line.number))><code id=\"code-\(id)\"\(languageClass)>\(Self.escape(source))\n</code></pre>\n"
                continue
            }

            // Indented code.
            if Self.indentation(text) >= 4 {
                var code: [String] = []
                var end = index
                while end < lines.count, Self.isBlank(lines[end].text) || Self.indentation(lines[end].text) >= 4 {
                    code.append(Self.dedent(lines[end].text, by: 4))
                    end += 1
                }
                while let last = code.last, Self.isBlank(last) { code.removeLast(); end -= 1 }
                html += "<pre\(attribute(line.number))><code>\(Self.escape(code.joined(separator: "\n")))\n</code></pre>\n"
                index = end
                continue
            }

            // ATX heading.
            if let heading = Self.match(Self.atxHeading, text) {
                let level = Self.group(heading, 1, in: text)?.count ?? 1
                let content = Self.group(heading, 2, in: text) ?? ""
                html += "<h\(level)\(attribute(line.number)) id=\"\(Self.slug(content))\">\(inline(content))</h\(level)>\n"
                index += 1
                continue
            }

            // Thematic break.
            if Self.match(Self.thematicBreak, text) != nil {
                html += "<hr\(attribute(line.number))>\n"
                index += 1
                continue
            }

            // Block quote.
            if text.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var quoted: [Line] = []
                while index < lines.count, !Self.isBlank(lines[index].text) {
                    var body = lines[index].text.trimmingCharacters(in: .whitespaces)
                    if body.hasPrefix(">") {
                        body.removeFirst()
                        if body.hasPrefix(" ") { body.removeFirst() }
                    }
                    quoted.append((body, lines[index].number))
                    index += 1
                    // A blank line ends it unless the quote goes on after it.
                }
                html += "<blockquote\(attribute(line.number))>\n\(renderBlocks(quoted))</blockquote>\n"
                continue
            }

            // List.
            if Self.match(Self.listItem, text) != nil {
                let (listHTML, next) = renderList(lines, from: index)
                html += listHTML
                index = next
                continue
            }

            // Raw HTML block.
            if text.hasPrefix("<"), text.count > 1, let second = text.dropFirst().first, second.isLetter || second == "/" || second == "!" {
                var block: [String] = []
                while index < lines.count, !Self.isBlank(lines[index].text) {
                    block.append(lines[index].text)
                    index += 1
                }
                html += Self.neutralizingUnsafeTags(block.joined(separator: "\n")) + "\n"
                continue
            }

            // Table: a header row, then a delimiter row.
            if text.contains("|"), index + 1 < lines.count, Self.match(Self.tableDelimiter, lines[index + 1].text) != nil,
               lines[index + 1].text.contains("-") {
                let header = Self.cells(text)
                let alignments = Self.cells(lines[index + 1].text).map { cell -> String in
                    let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
                    return left && right ? "center" : right ? "right" : left ? "left" : ""
                }
                if header.count == alignments.count {
                    func align(_ column: Int) -> String {
                        column < alignments.count && !alignments[column].isEmpty ? " style=\"text-align:\(alignments[column])\"" : ""
                    }
                    html += "<table\(attribute(line.number))>\n<thead><tr>"
                    for (column, cell) in header.enumerated() { html += "<th\(align(column))>\(inline(cell))</th>" }
                    html += "</tr></thead>\n<tbody>\n"
                    index += 2
                    while index < lines.count, !Self.isBlank(lines[index].text), lines[index].text.contains("|") {
                        let row = Self.cells(lines[index].text)
                        html += "<tr\(attribute(lines[index].number))>"
                        for column in 0..<header.count {
                            html += "<td\(align(column))>\(column < row.count ? inline(row[column]) : "")</td>"
                        }
                        html += "</tr>\n"
                        index += 1
                    }
                    html += "</tbody></table>\n"
                    continue
                }
            }

            // Paragraph (or a setext heading).
            var paragraph: [String] = [String(text.drop { $0 == " " || $0 == "\t" })]
            index += 1
            var setextLevel: Int?
            while index < lines.count {
                let next = lines[index].text
                let trimmed = next.trimmingCharacters(in: .whitespaces)
                if Self.isBlank(next) { break }
                if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }), Self.indentation(next) < 4 { setextLevel = 1; index += 1; break }
                if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "-" }), Self.indentation(next) < 4 { setextLevel = 2; index += 1; break }
                if Self.startsBlock(next) { break }
                paragraph.append(next)
                index += 1
            }
            let content = paragraph.joined(separator: "\n")
            if let level = setextLevel {
                html += "<h\(level)\(attribute(line.number)) id=\"\(Self.slug(content))\">\(inline(content))</h\(level)>\n"
            } else if tight {
                html += inline(content) + "\n"
            } else {
                html += "<p\(attribute(line.number))>\(inline(content))</p>\n"
            }
        }
        return html
    }

    /// Whether a line interrupts a paragraph.
    private static func startsBlock(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return true }
        if match(atxHeading, text) != nil || match(thematicBreak, text) != nil { return true }
        if let item = match(listItem, text), let marker = group(item, 2, in: text) {
            // An ordered list interrupts only when it starts at 1, as in CommonMark.
            return marker.first?.isNumber != true || marker.hasPrefix("1")
        }
        return false
    }

    private mutating func renderList(_ lines: [Line], from start: Int) -> (String, Int) {
        guard let first = Self.match(Self.listItem, lines[start].text),
              let firstMarker = Self.group(first, 2, in: lines[start].text) else { return ("", start + 1) }
        let ordered = firstMarker.first?.isNumber == true
        let delimiter = firstMarker.last!
        var items: [(lines: [Line], number: Int)] = []
        var index = start
        var loose = false
        var sawBlank = false
        while index < lines.count {
            let text = lines[index].text
            guard let match = Self.match(Self.listItem, text), let marker = Self.group(match, 2, in: text),
                  (marker.first?.isNumber == true) == ordered, marker.last == delimiter else { break }
            if sawBlank { loose = true }
            let markerEnd = match.range.location + match.range.length
            let prefix = String((text as NSString).substring(to: markerEnd))
            let contentIndent = max(Self.indentation(prefix.replacingOccurrences(of: marker, with: String(repeating: " ", count: marker.count))),
                                    (Self.group(match, 1, in: text)?.count ?? 0) + marker.count + 1)
            var itemLines: [Line] = [((text as NSString).substring(from: markerEnd), lines[index].number)]
            index += 1
            sawBlank = false
            while index < lines.count {
                let next = lines[index].text
                if Self.isBlank(next) {
                    sawBlank = true
                    itemLines.append(("", lines[index].number))
                    index += 1
                    continue
                }
                if Self.indentation(next) >= contentIndent {
                    // Content after a blank line inside an item: the list is loose.
                    if sawBlank { loose = true }
                    itemLines.append((Self.dedent(next, by: contentIndent), lines[index].number))
                    sawBlank = false
                    index += 1
                    continue
                }
                // Lazy continuation of the item's paragraph.
                if !sawBlank, Self.match(Self.listItem, next) == nil, !Self.startsBlock(next) {
                    itemLines.append((next.trimmingCharacters(in: .whitespaces), lines[index].number))
                    index += 1
                    continue
                }
                break
            }
            while let last = itemLines.last, Self.isBlank(last.text), itemLines.count > 1 { itemLines.removeLast() }
            items.append((itemLines, lines[start].number))
            if sawBlank, index < lines.count, Self.match(Self.listItem, lines[index].text) == nil { break }
        }
        var startAttribute = ""
        if ordered, let number = Int(firstMarker.dropLast()), number != 1 { startAttribute = " start=\"\(number)\"" }
        let tag = ordered ? "ol" : "ul"
        let isTaskList = items.contains { Self.taskState($0.lines.first?.text ?? "") != nil }
        var html = "<\(tag)\(attribute(lines[start].number))\(startAttribute)\(isTaskList ? " class=\"contains-task-list\"" : "")>\n"
        for item in items {
            var itemLines = item.lines
            var checkbox = ""
            if let state = Self.taskState(itemLines[0].text) {
                checkbox = "<input type=\"checkbox\" disabled\(state ? " checked" : "")> "
                itemLines[0].text = String(itemLines[0].text.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            let content = renderBlocks(itemLines, tight: !loose)
            let itemClass = checkbox.isEmpty ? "" : " class=\"task-list-item\""
            html += "<li\(attribute(itemLines[0].number))\(itemClass)>\(checkbox)\(content.hasSuffix("\n") ? String(content.dropLast()) : content)</li>\n"
        }
        html += "</\(tag)>\n"
        return (html, index)
    }

    /// `[ ] task` → false, `[x] task` → true.
    private static func taskState(_ text: String) -> Bool? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.hasPrefix("[") else { return nil }
        let characters = Array(trimmed.prefix(4))
        guard characters[2] == "]", characters.count == 3 || characters[3] == " " else { return nil }
        switch characters[1] {
        case " ": return false
        case "x", "X": return true
        default: return nil
        }
    }

    private static func cells(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = [], current = "", inCode = false
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                if let next = iterator.next() {
                    if next == "|" { current.append("|") } else { current.append(character); current.append(next) }
                }
                continue
            }
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// An id for a heading, as GitHub makes them (for `#anchor` links).
    static func slug(_ text: String) -> String {
        let plain = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        return plain.replacingOccurrences(of: " ", with: "-")
    }

    /// Tags raw HTML may not use: a <meta http-equiv="refresh"> or a <form> navigates the preview
    /// to a page without its Content-Security-Policy (where scripts run), <base> retargets its
    /// links, and the rest load or run content. Their `<` becomes text, so they show as written.
    private static let unsafeTag = try! NSRegularExpression(
        pattern: #"<(/?(?:meta|base|form|script|iframe|frame|frameset|object|embed|link|portal)(?=[\s/>]|$))"#,
        options: [.caseInsensitive])

    static func neutralizingUnsafeTags(_ html: String) -> String {
        guard html.contains("<") else { return html }
        return unsafeTag.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "&lt;$1")
    }

    // MARK: Inline

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    private static let punctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    func inline(_ text: String) -> String {
        let characters = Array(text)
        return renderInline(characters, 0, characters.count)
    }

    private func renderInline(_ c: [Character], _ from: Int, _ to: Int) -> String {
        var html = ""
        var i = from
        func starts(_ string: String, at index: Int) -> Bool {
            let s = Array(string)
            guard index + s.count <= to else { return false }
            return Array(c[index..<index + s.count]) == s
        }
        while i < to {
            let character = c[i]
            switch character {
            case "\\":
                if i + 1 < to, c[i + 1] == "\n" { html += "<br>\n"; i += 2; continue }
                if i + 1 < to, Self.punctuation.contains(c[i + 1]) { html += Self.escape(String(c[i + 1])); i += 2; continue }
            case "`":
                var run = 0
                while i + run < to, c[i + run] == "`" { run += 1 }
                if let close = closingBackticks(c, run, i + run, to) {
                    var code = String(c[(i + run)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    html += "<code>\(Self.escape(code))</code>"
                    i = close + run
                } else {
                    html += String(repeating: "`", count: run)
                    i += run
                }
                continue
            case "!" where i + 1 < to && c[i + 1] == "[":
                if let (label, url, title, end) = link(c, i + 1, to) {
                    let titleAttribute = title.map { " title=\"\(Self.escape($0))\"" } ?? ""
                    html += "<img src=\"\(Self.escape(resolveURL(url)))\" alt=\"\(Self.escape(String(c[label])))\"\(titleAttribute)>"
                    i = end
                    continue
                }
            case "[":
                if let (label, url, title, end) = link(c, i, to) {
                    let titleAttribute = title.map { " title=\"\(Self.escape($0))\"" } ?? ""
                    html += "<a href=\"\(Self.escape(resolveURL(url)))\"\(titleAttribute)>\(renderInline(c, label.lowerBound, label.upperBound))</a>"
                    i = end
                    continue
                }
            case "<":
                if let close = c[(i + 1)..<to].firstIndex(of: ">") {
                    let inner = String(c[(i + 1)..<close])
                    if inner.range(of: #"^[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*$"#, options: .regularExpression) != nil {
                        html += "<a href=\"\(Self.escape(inner))\">\(Self.escape(inner))</a>"
                        i = close + 1
                        continue
                    }
                    if inner.range(of: #"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$"#, options: .regularExpression) != nil {
                        html += "<a href=\"mailto:\(Self.escape(inner))\">\(Self.escape(inner))</a>"
                        i = close + 1
                        continue
                    }
                    if inner.range(of: #"^(/?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?|!--[\s\S]*--)$"#, options: .regularExpression) != nil {
                        html += Self.neutralizingUnsafeTags("<" + inner + ">") // inline HTML
                        i = close + 1
                        continue
                    }
                }
            case "*", "_", "~":
                var run = 0
                while i + run < to, c[i + run] == character { run += 1 }
                let before: Character? = i > from ? c[i - 1] : nil
                let after: Character? = i + run < to ? c[i + run] : nil
                let opens = after.map { !$0.isWhitespace } ?? false
                    && (character != "_" || before.map { !$0.isLetter && !$0.isNumber } ?? true)
                if character == "~" && run != 2 { break }
                if opens, let (length, close) = closingDelimiter(c, character, run, i + run, to) {
                    let inner = renderInline(c, i + length, close)
                    if character == "~" {
                        html += "<del>\(inner)</del>"
                    } else if length >= 2 {
                        html += "<strong>\(length == 3 ? "<em>\(inner)</em>" : inner)</strong>"
                    } else {
                        html += "<em>\(inner)</em>"
                    }
                    // Unused opening markers (e.g. `***a**`) are plain text.
                    if run > length, character != "~" { html = String(repeating: character, count: run - length) + html }
                    i = close + length
                    continue
                }
                html += String(repeating: character, count: run)
                i += run
                continue
            case "&":
                if let semicolon = c[i..<min(to, i + 12)].firstIndex(of: ";"),
                   String(c[i...semicolon]).range(of: #"^&(#\d+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);$"#, options: .regularExpression) != nil {
                    html += String(c[i...semicolon])
                    i = semicolon + 1
                    continue
                }
            case "\n":
                if html.hasSuffix("  ") {
                    while html.hasSuffix(" ") { html.removeLast() }
                    html += "<br>\n"
                } else {
                    html += "\n"
                }
                i += 1
                continue
            case "h", "w":
                // Bare links (GitHub): http(s):// or www.
                let atWordStart = i == from || !(c[i - 1].isLetter || c[i - 1].isNumber)
                if atWordStart, starts("https://", at: i) || starts("http://", at: i) || starts("www.", at: i) {
                    var end = i
                    while end < to, !c[end].isWhitespace, c[end] != "<" { end += 1 }
                    while end > i, ".,:;!?\"')".contains(c[end - 1]) {
                        if c[end - 1] == ")", c[i..<end].filter({ $0 == "(" }).count >= c[i..<end].filter({ $0 == ")" }).count { break }
                        end -= 1
                    }
                    let url = String(c[i..<end])
                    if end > i + 8 || (url.hasPrefix("www.") && end > i + 5) {
                        let href = url.hasPrefix("www.") ? "http://" + url : url
                        html += "<a href=\"\(Self.escape(href))\">\(Self.escape(url))</a>"
                        i = end
                        continue
                    }
                }
            default:
                break
            }
            html += Self.escape(String(character))
            i += 1
        }
        return html
    }

    /// Where a run of `run` backticks closes a code span opened before `start`.
    private func closingBackticks(_ c: [Character], _ run: Int, _ start: Int, _ to: Int) -> Int? {
        var j = start
        while j < to {
            guard c[j] == "`" else { j += 1; continue }
            var closing = 0
            while j + closing < to, c[j + closing] == "`" { closing += 1 }
            if closing == run { return j }
            j += closing
        }
        return nil
    }

    /// The closing run for an emphasis opened at `start` with `run` markers: (markers used, its index).
    private func closingDelimiter(_ c: [Character], _ marker: Character, _ run: Int, _ start: Int, _ to: Int) -> (Int, Int)? {
        var j = start
        var inCode = false
        while j < to {
            if c[j] == "`" { inCode.toggle() }
            if c[j] == "\\" { j += 2; continue }
            if !inCode, c[j] == marker, j > start, !c[j - 1].isWhitespace {
                var closing = 0
                while j + closing < to, c[j + closing] == marker { closing += 1 }
                let after: Character? = j + closing < to ? c[j + closing] : nil
                let flanking = marker != "_" || after.map { !$0.isLetter && !$0.isNumber } ?? true
                if flanking {
                    let length = min(run, closing, marker == "~" ? 2 : 3)
                    if marker == "~" ? closing == 2 : true { return (length, j) }
                }
                j += closing
                continue
            }
            j += 1
        }
        return nil
    }

    /// A link at `[`: its label range, destination, title and where it ends.
    private func link(_ c: [Character], _ open: Int, _ to: Int) -> (Range<Int>, String, String?, Int)? {
        var depth = 0
        var close = open
        var inCode = false
        while close < to {
            let character = c[close]
            if character == "\\" { close += 2; continue }
            if character == "`" { inCode.toggle() }
            if !inCode {
                if character == "[" { depth += 1 }
                if character == "]" { depth -= 1; if depth == 0 { break } }
            }
            close += 1
        }
        guard close < to else { return nil }
        let label = (open + 1)..<close
        // Inline: [text](url "title")
        if close + 1 < to, c[close + 1] == "(" {
            var depth = 0
            var end = close + 1
            while end < to {
                if c[end] == "\\" { end += 2; continue }
                if c[end] == "(" { depth += 1 }
                if c[end] == ")" { depth -= 1; if depth == 0 { break } }
                end += 1
            }
            guard end < to else { return nil }
            var inside = String(c[(close + 2)..<end]).trimmingCharacters(in: .whitespaces)
            var title: String?
            if let quote = inside.last, quote == "\"" || quote == "'",
               let start = inside.dropLast().lastIndex(of: quote), start > inside.startIndex,
               inside[inside.index(before: start)].isWhitespace {
                title = String(inside[inside.index(after: start)..<inside.index(before: inside.endIndex)])
                inside = String(inside[..<start]).trimmingCharacters(in: .whitespaces)
            }
            if inside.hasPrefix("<"), inside.hasSuffix(">") { inside = String(inside.dropFirst().dropLast()) }
            return (label, inside, title, end + 1)
        }
        // Reference: [text][id], [text][], [text]
        var key = String(c[label]).lowercased()
        var end = close + 1
        if close + 1 < to, c[close + 1] == "[", let refClose = c[(close + 2)..<to].firstIndex(of: "]") {
            let explicit = String(c[(close + 2)..<refClose]).lowercased()
            if !explicit.isEmpty { key = explicit }
            end = refClose + 1
        }
        guard let reference = references[key] else { return nil }
        return (label, reference.url, reference.title, end)
    }
}
