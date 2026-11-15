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
    /// The server's own JSON for it (with its code and data): sent back when asking for fixes.
    var serverJSON: String?

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
        serverJSON = (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// As LSP JSON (the server's own when it sent it).
    var json: [String: Any] {
        if let serverJSON, let object = (try? JSONSerialization.jsonObject(with: Data(serverJSON.utf8))) as? [String: Any] { return object }
        var object: [String: Any] = ["range": range.json, "severity": severity.rawValue, "message": message]
        if let source { object["source"] = source }
        return object
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

/// A symbol from `workspace/symbol`: SymbolInformation, or WorkspaceSymbol (whose location may
/// have no range: then its start).
struct WorkspaceSymbol: Equatable, Sendable {
    var name: String
    var kind: Int
    var containerName: String?
    var url: URL
    var range: LSPRange

    init(name: String, kind: Int, containerName: String?, url: URL, range: LSPRange) {
        self.name = name
        self.kind = kind
        self.containerName = containerName
        self.url = url
        self.range = range
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, let location = json["location"] as? [String: Any],
              let uri = location["uri"] as? String, let url = URL(string: uri) else { return nil }
        let zero = LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0))
        self.init(name: name, kind: json["kind"] as? Int ?? 13, containerName: json["containerName"] as? String,
                  url: url, range: LSPRange(json: location["range"]) ?? zero)
    }
}

/// An item of a call hierarchy (a function, method…), kept as the server sent it: the server
/// may need its `data` back.
struct CallHierarchyItem: @unchecked Sendable, Equatable {
    let json: [String: Any]
    let name: String
    let kind: Int
    let detail: String?
    let url: URL
    let range: LSPRange
    let selectionRange: LSPRange

    init?(json: Any?) {
        guard let object = json as? [String: Any], let name = object["name"] as? String,
              let uri = object["uri"] as? String, let url = URL(string: uri),
              let range = LSPRange(json: object["range"]) else { return nil }
        self.json = object
        self.name = name
        self.kind = object["kind"] as? Int ?? 12
        self.detail = object["detail"] as? String
        self.url = url
        self.range = range
        self.selectionRange = LSPRange(json: object["selectionRange"]) ?? range
    }

    static func == (a: CallHierarchyItem, b: CallHierarchyItem) -> Bool {
        a.name == b.name && a.url == b.url && a.range == b.range && a.kind == b.kind
    }
}

/// A fix or refactoring a server offers (a CodeAction, or a bare Command).
struct CodeAction: @unchecked Sendable, Equatable {
    let json: [String: Any]
    let title: String
    /// "quickfix", "refactor.extract", "source.organizeImports"…
    let kind: String
    let isPreferred: Bool
    /// Why it can't run now (shown, not run).
    let disabledReason: String?
    let edit: WorkspaceEdit?
    /// A command to run on the server (after the edit), as sent.
    let command: [String: Any]?

    init?(json: Any?) {
        guard let object = json as? [String: Any], let title = object["title"] as? String else { return nil }
        self.json = object
        self.title = title
        if object["command"] is String {
            // A bare Command: running it is the action.
            kind = ""
            isPreferred = false
            disabledReason = nil
            edit = nil
            command = object
        } else {
            kind = object["kind"] as? String ?? ""
            isPreferred = object["isPreferred"] as? Bool ?? false
            disabledReason = (object["disabled"] as? [String: Any])?["reason"] as? String
            edit = WorkspaceEdit(json: object["edit"])
            command = object["command"] as? [String: Any]
        }
    }

    var isQuickFix: Bool { kind.hasPrefix("quickfix") }
    var isRefactor: Bool { kind.hasPrefix("refactor") }
    var isSource: Bool { kind.hasPrefix("source") }

    static func == (a: CodeAction, b: CodeAction) -> Bool { a.title == b.title && a.kind == b.kind }
}

/// `textDocument/signatureHelp`: the signatures of the call being typed, and where in it the cursor is.
struct SignatureHelp: Equatable, Sendable {
    struct Signature: Equatable, Sendable {
        var label: String
        var documentation: String?
        /// Each parameter's range in `label` (UTF-16) and its documentation.
        var parameters: [(range: NSRange, documentation: String?)]
        var activeParameter: Int?

        static func == (a: Signature, b: Signature) -> Bool {
            a.label == b.label && a.activeParameter == b.activeParameter && a.parameters.map(\.range) == b.parameters.map(\.range)
        }
    }

    var signatures: [Signature]
    var activeSignature: Int
    var activeParameter: Int

    /// The parameter to highlight in `signatures[activeSignature]` (its own index wins).
    var highlighted: NSRange? {
        guard signatures.indices.contains(activeSignature) else { return nil }
        let signature = signatures[activeSignature]
        let index = signature.activeParameter ?? activeParameter
        return signature.parameters.indices.contains(index) ? signature.parameters[index].range : nil
    }

    init(signatures: [Signature], activeSignature: Int, activeParameter: Int) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let list = object["signatures"] as? [[String: Any]], !list.isEmpty else { return nil }
        signatures = list.compactMap { entry in
            guard let label = entry["label"] as? String else { return nil }
            let text = label as NSString
            let parameters: [(range: NSRange, documentation: String?)] = (entry["parameters"] as? [[String: Any]] ?? []).compactMap { parameter in
                let documentation = HoverContent.markdown(from: parameter["documentation"])
                if let offsets = parameter["label"] as? [Int], offsets.count == 2 {
                    return (NSRange(location: offsets[0], length: offsets[1] - offsets[0]), documentation)
                }
                if let name = parameter["label"] as? String {
                    let range = text.range(of: name)
                    return range.location == NSNotFound ? nil : (range, documentation)
                }
                return nil
            }
            return Signature(label: label, documentation: HoverContent.markdown(from: entry["documentation"]),
                             parameters: parameters, activeParameter: entry["activeParameter"] as? Int)
        }
        guard !signatures.isEmpty else { return nil }
        activeSignature = min(object["activeSignature"] as? Int ?? 0, signatures.count - 1)
        activeParameter = object["activeParameter"] as? Int ?? 0
    }

    static func == (a: SignatureHelp, b: SignatureHelp) -> Bool {
        a.signatures == b.signatures && a.activeSignature == b.activeSignature && a.activeParameter == b.activeParameter
    }
}

/// A link the server found in a file (an import's path, a URL in a comment). Without a
/// target it's resolved when followed.
struct LSPDocumentLink: @unchecked Sendable {
    var range: LSPRange
    var target: URL?
    var tooltip: String?
    /// Sent back to resolve it.
    var json: [String: Any]

    init?(json: Any?) {
        guard let object = json as? [String: Any], let range = LSPRange(json: object["range"]) else { return nil }
        self.range = range
        target = (object["target"] as? String).flatMap(URL.init(string:))
        tooltip = object["tooltip"] as? String
        self.json = object
    }
}

/// A line's lens from the server ("3 references", "Run"): a command shown above (here: after)
/// the code. Without a command yet it's resolved later.
struct CodeLens: @unchecked Sendable {
    var range: LSPRange
    /// `{title, command, arguments}`, as sent.
    var command: [String: Any]?
    var json: [String: Any]

    var title: String? { (command?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var commandName: String { command?["command"] as? String ?? "" }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let range = LSPRange(json: object["range"]) else { return nil }
        self.range = range
        command = object["command"] as? [String: Any]
        self.json = object
    }
}

/// One place a symbol appears in its file (`textDocument/documentHighlight`).
struct DocumentHighlight: Equatable, Sendable {
    enum Kind: Int, Sendable { case text = 1, read, write }

    var range: LSPRange
    var kind: Kind

    init(range: LSPRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let range = LSPRange(json: object["range"]) else { return nil }
        self.range = range
        kind = (object["kind"] as? Int).flatMap(Kind.init(rawValue:)) ?? .text
    }
}

/// A label the server shows inside the code: a type (`: Int`) or a parameter name (`count:`).
struct InlayHint: Equatable, Sendable {
    enum Kind: Int, Sendable { case type = 1, parameter }

    var position: LSPPosition
    var label: String
    var kind: Kind?
    var paddingLeft: Bool
    var paddingRight: Bool

    init(position: LSPPosition, label: String, kind: Kind?, paddingLeft: Bool = false, paddingRight: Bool = false) {
        self.position = position
        self.label = label
        self.kind = kind
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
    }

    init?(json: Any?) {
        guard let object = json as? [String: Any], let position = LSPPosition(json: object["position"]) else { return nil }
        // A string, or parts with values.
        let label = object["label"] as? String
            ?? (object["label"] as? [[String: Any]])?.compactMap { $0["value"] as? String }.joined()
        guard let label, !label.isEmpty else { return nil }
        self.init(position: position, label: label, kind: (object["kind"] as? Int).flatMap(Kind.init),
                  paddingLeft: object["paddingLeft"] as? Bool ?? false, paddingRight: object["paddingRight"] as? Bool ?? false)
    }

    /// As drawn: with the spaces its padding asks for.
    var text: String { (paddingLeft ? " " : "") + label + (paddingRight ? " " : "") }
}
