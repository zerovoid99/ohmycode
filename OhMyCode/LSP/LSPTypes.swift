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
        var output = ""
        var first: (order: Int, range: NSRange)?
        var index = snippet.startIndex

        func record(_ order: Int, start: Int, length: Int) {
            let order = order == 0 ? Int.max : order // $0 is the final position: lowest priority
            if first == nil || order < first!.order { first = (order, NSRange(location: start, length: length)) }
        }

        while index < snippet.endIndex {
            let character = snippet[index]
            if character == "\\", snippet.index(after: index) < snippet.endIndex {
                output.append(snippet[snippet.index(after: index)])
                index = snippet.index(index, offsetBy: 2)
                continue
            }
            if character == "$" {
                let next = snippet.index(after: index)
                if next < snippet.endIndex, snippet[next] == "{",
                   let close = matchingBrace(in: snippet, from: next) {
                    let body = snippet[snippet.index(after: next)..<close]
                    let parts = body.split(separator: ":", maxSplits: 1)
                    let placeholder = parts.count == 2 ? expand(String(parts[1])).text : ""
                    let start = (output as NSString).length
                    output += placeholder
                    record(Int(parts[0]) ?? 0, start: start, length: (placeholder as NSString).length)
                    index = snippet.index(after: close)
                    continue
                }
                var end = next
                while end < snippet.endIndex, snippet[end].isNumber { end = snippet.index(after: end) }
                if end > next {
                    record(Int(snippet[next..<end]) ?? 0, start: (output as NSString).length, length: 0)
                    index = end
                    continue
                }
            }
            output.append(character)
            index = snippet.index(after: index)
        }
        return (output, first?.range)
    }

    private static func matchingBrace(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
