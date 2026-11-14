import Foundation

/// LSP position: zero-based line and UTF-16 column (the default encoding, same as NSString).
struct LSPPosition: Equatable, Sendable {
    var line: Int
    var character: Int

    var json: [String: Any] { ["line": line, "character": character] }

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let line = object["line"] as? Int,
              let character = object["character"] as? Int else { return nil }
        self.init(line: line, character: character)
    }
}

struct LSPRange: Equatable, Sendable {
    var start: LSPPosition
    var end: LSPPosition

    var json: [String: Any] { ["start": start.json, "end": end.json] }

    init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let start = LSPPosition(json: object["start"]),
              let end = LSPPosition(json: object["end"]) else { return nil }
        self.init(start: start, end: end)
    }
}

struct LSPLocation: Equatable, Sendable {
    var url: URL
    var range: LSPRange

    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        // Location or LocationLink.
        let uri = (object["uri"] ?? object["targetUri"]) as? String
        let range = LSPRange(json: object["targetSelectionRange"] ?? object["range"] ?? object["targetRange"])
        guard let uri, let url = URL(string: uri), let range else { return nil }
        self.url = url
        self.range = range
    }
}

struct Diagnostic: Equatable, Sendable {
    enum Severity: Int, Sendable { case error = 1, warning, information, hint }
    var range: LSPRange
    var severity: Severity
    var message: String
    var source: String?

    init(range: LSPRange, severity: Severity, message: String, source: String?) {
        self.range = range
        self.severity = severity
        self.message = message
        self.source = source
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let range = LSPRange(json: object["range"]),
              let message = object["message"] as? String else { return nil }
        self.range = range
        self.severity = (object["severity"] as? Int).flatMap(Severity.init) ?? .error
        self.message = message
        self.source = object["source"] as? String
    }
}

struct CompletionItem: Identifiable, Sendable {
    let id: Int
    var label: String
    var detail: String?
    var kind: Int?
    var filterText: String
    var sortText: String
    /// Text to insert; may contain snippet placeholders when `isSnippet`.
    var insertText: String
    var isSnippet: Bool
    /// Replacement range from the server, if it gave a text edit.
    var editRange: LSPRange?

    init(id: Int, label: String, detail: String?, kind: Int?, filterText: String? = nil, sortText: String? = nil,
         insertText: String, isSnippet: Bool) {
        self.id = id
        self.label = label
        self.detail = detail
        self.kind = kind
        self.filterText = filterText ?? label
        self.sortText = sortText ?? label
        self.insertText = insertText
        self.isSnippet = isSnippet
    }

    init?(json: Any?, id: Int) {
        guard let object = json as? [String: Any], let label = object["label"] as? String else { return nil }
        self.id = id
        self.label = label
        self.detail = object["detail"] as? String
        self.kind = object["kind"] as? Int
        self.filterText = object["filterText"] as? String ?? label
        self.sortText = object["sortText"] as? String ?? label
        let textEdit = object["textEdit"] as? [String: Any]
        self.insertText = textEdit?["newText"] as? String ?? object["insertText"] as? String ?? label
        self.isSnippet = (object["insertTextFormat"] as? Int) == 2
        self.editRange = LSPRange(json: textEdit?["range"] ?? (textEdit?["replace"]))
    }

    /// SF Symbol for the LSP CompletionItemKind.
    var icon: String {
        switch kind {
        case 2, 3, 4: "function"                    // method, function, constructor
        case 5, 10: "circle.grid.2x1"               // field, property
        case 6: "x.squareroot"                      // variable
        case 7, 22: "cube"                          // class, struct
        case 8: "puzzlepiece"                       // interface
        case 9: "shippingbox"                       // module
        case 13, 20: "list.bullet"                  // enum, enum member
        case 14: "textformat"                       // keyword
        case 15: "text.badge.plus"                  // snippet
        case 21: "number"                           // constant
        case 25: "t.square"                         // type parameter
        default: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Expands LSP snippet syntax (`${1:name}`, `$1`, `$0`) to plain text, returning where the
/// first placeholder is so it can be selected after insertion.
enum Snippet {
    static func expand(_ snippet: String) -> (text: String, firstPlaceholder: NSRange?) {
        let parsed = ParsedSnippet(snippet, variables: { _ in "" })
        let explicit = parsed.stops.count > 1 || snippet.contains("$0") || snippet.contains("${0")
        return (parsed.text, explicit ? parsed.stops.first?.ranges.first : nil)
    }
}

struct LSPTextEdit: Equatable, Sendable {
    var range: LSPRange
    var newText: String

    init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }

    /// TextEdit or AnnotatedTextEdit.
    init?(json: Any?) {
        guard let object = json as? [String: Any], let range = LSPRange(json: object["range"]),
              let newText = object["newText"] as? String else { return nil }
        self.init(range: range, newText: newText)
    }
}

/// Text edits per file. File create/rename/delete operations are not supported and skipped.
struct WorkspaceEdit: Equatable, Sendable {
    var changes: [URL: [LSPTextEdit]] = [:]

    init(changes: [URL: [LSPTextEdit]]) {
        self.changes = changes
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        if let documentChanges = object["documentChanges"] as? [Any] {
            for change in documentChanges {
                guard let change = change as? [String: Any],
                      let document = change["textDocument"] as? [String: Any],
                      let uri = document["uri"] as? String, let url = URL(string: uri),
                      let edits = change["edits"] as? [Any] else { continue }
                changes[url, default: []] += edits.compactMap(LSPTextEdit.init(json:))
            }
        } else if let map = object["changes"] as? [String: Any] {
            for (uri, edits) in map {
                guard let url = URL(string: uri), let edits = edits as? [Any] else { continue }
                changes[url, default: []] += edits.compactMap(LSPTextEdit.init(json:))
            }
        }
    }

    var editCount: Int { changes.values.reduce(0) { $0 + $1.count } }
}

/// Hover contents (MarkupContent, MarkedString or MarkedString[]) normalized to Markdown.
enum HoverContent {
    static func markdown(from json: Any?) -> String? {
        guard let object = json as? [String: Any] else { return nil }
        let text = markdown(contents: object["contents"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func markdown(contents: Any?) -> String {
        switch contents {
        case let text as String:
            return text
        case let list as [Any]:
            return list.map { markdown(contents: $0) }.filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")
        case let object as [String: Any]:
            let value = object["value"] as? String ?? ""
            if let language = object["language"] as? String { return "```\(language)\n\(value)\n```" }
            if object["kind"] as? String == "plaintext" { return "```\n\(value)\n```" }
            return value
        default:
            return ""
        }
    }

    enum Block: Equatable {
        case code(String)
        case text(String)
        case rule
    }

    /// Splits Markdown into fenced code blocks, horizontal rules and prose paragraphs
    /// (SwiftUI renders inline Markdown only).
    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var prose: [Substring] = []
        var code: [Substring]?

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            prose.removeAll()
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    let text = lines.joined(separator: "\n")
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.code(text)) }
                    code = nil
                } else {
                    flushProse()
                    code = []
                }
            } else if code != nil {
                code!.append(line)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushProse()
                if !blocks.isEmpty, blocks.last != .rule { blocks.append(.rule) }
            } else {
                prose.append(line)
            }
        }
        if let lines = code, !lines.isEmpty { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushProse()
        if blocks.last == .rule { blocks.removeLast() }
        return blocks
    }
}
