import AppKit

/// A snippet body (TextMate/VS Code syntax) turned into text and tab stops:
/// `$1`, `${1}`, `${1:placeholder ${2:nested}}`, `${1|one,two|}` (the first choice),
/// `$TM_FILENAME`, `${TM_SELECTED_TEXT:default}` and `\$`, `\}`, `\\` escapes. A stop used
/// several times is mirrored (every copy gets the same text); `$0` is where the cursor ends,
/// the end of the snippet if it's not given.
struct ParsedSnippet: Equatable {
    struct Stop: Equatable {
        /// 0 for the final position.
        var index: Int
        /// Every place it occurs (UTF-16, in the snippet's text), in order.
        var ranges: [NSRange]
        /// `${1|a,b|}`'s choices.
        var choices: [String]?
    }

    var text: String
    /// In visiting order: 1, 2, 3 … then 0.
    var stops: [Stop]

    /// How text is laid out when inserted: lines after the first get `indent`, tabs become
    /// `indentUnit`.
    struct Layout {
        var indent = ""
        var indentUnit = "\t"
    }

    init(text: String, stops: [Stop]) {
        self.text = text
        self.stops = stops
    }

    init(_ body: String, layout: Layout = Layout(), variables: @escaping (String) -> String? = { _ in nil }) {
        var parser = Parser(Array(body))
        let nodes = parser.parse(until: nil)
        var renderer = Renderer(layout: layout, variables: variables)
        renderer.collectDefaults(nodes)
        renderer.render(nodes)
        text = renderer.output as String
        var stops = renderer.stops.keys.sorted().filter { $0 > 0 }.map { index in
            Stop(index: index, ranges: renderer.stops[index]!, choices: renderer.choices[index])
        }
        let end = NSRange(location: renderer.output.length, length: 0)
        stops.append(Stop(index: 0, ranges: renderer.stops[0] ?? [end], choices: nil))
        self.stops = stops
    }

    // MARK: Parsing

    private indirect enum Node {
        case text(String)
        case stop(Int, placeholder: [Node]?, choices: [String]?)
        case variable(String, fallback: [Node]?)
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) { self.characters = characters }

        private func peek(_ offset: Int = 0) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        /// Nodes up to `terminator` (consumed), or to the end.
        mutating func parse(until terminator: Character?) -> [Node] {
            var nodes: [Node] = []
            var text = ""
            func flush() { if !text.isEmpty { nodes.append(.text(text)); text = "" } }
            while let character = peek() {
                if character == terminator { index += 1; flush(); return nodes }
                if character == "\\", let next = peek(1), next == "$" || next == "}" || next == "\\" {
                    text.append(next)
                    index += 2
                    continue
                }
                if character == "$", let node = parseDollar() {
                    flush()
                    nodes.append(node)
                    continue
                }
                text.append(character)
                index += 1
            }
            flush()
            return nodes
        }

        private mutating func parseDollar() -> Node? {
            let start = index
            index += 1
            if let next = peek(), next.isNumber {
                return .stop(readNumber(), placeholder: nil, choices: nil)
            }
            if let next = peek(), next.isLetter || next == "_" {
                return .variable(readName(), fallback: nil)
            }
            guard peek() == "{" else { index = start; return nil }
            index += 1
            if let next = peek(), next.isNumber {
                let number = readNumber()
                switch peek() {
                case "}":
                    index += 1
                    return .stop(number, placeholder: nil, choices: nil)
                case ":":
                    index += 1
                    return .stop(number, placeholder: parse(until: "}"), choices: nil)
                case "|":
                    index += 1
                    if let choices = readChoices() { return .stop(number, placeholder: nil, choices: choices) }
                case "/":
                    skipTransform()
                    return .stop(number, placeholder: nil, choices: nil)
                default: break
                }
            } else if let next = peek(), next.isLetter || next == "_" {
                let name = readName()
                switch peek() {
                case "}":
                    index += 1
                    return .variable(name, fallback: nil)
                case ":":
                    index += 1
                    return .variable(name, fallback: parse(until: "}"))
                case "/":
                    skipTransform()
                    return .variable(name, fallback: nil)
                default: break
                }
            }
            index = start
            return nil
        }

        private mutating func readNumber() -> Int {
            var digits = ""
            while let character = peek(), character.isNumber { digits.append(character); index += 1 }
            return Int(digits) ?? 0
        }

        private mutating func readName() -> String {
            var name = ""
            while let character = peek(), character.isLetter || character.isNumber || character == "_" { name.append(character); index += 1 }
            return name
        }

        /// `a,b,c|}` → ["a", "b", "c"].
        private mutating func readChoices() -> [String]? {
            var choices: [String] = [], current = ""
            while let character = peek() {
                if character == "\\", let next = peek(1), next == "," || next == "|" || next == "\\" {
                    current.append(next)
                    index += 2
                } else if character == ",", peek(1) != nil {
                    choices.append(current)
                    current = ""
                    index += 1
                } else if character == "|", peek(1) == "}" {
                    choices.append(current)
                    index += 2
                    return choices
                } else {
                    current.append(character)
                    index += 1
                }
            }
            return nil
        }

        /// `/regex/format/options}`: transforms aren't applied; the value is used as it is.
        private mutating func skipTransform() {
            var slashes = 0, depth = 0
            while let character = peek() {
                index += 1
                if character == "\\" { index += 1; continue }
                if character == "{" { depth += 1; continue }
                if character == "}" {
                    if depth > 0 { depth -= 1; continue }
                    if slashes >= 3 { return }
                }
                if character == "/", depth == 0 { slashes += 1 }
            }
        }
    }

    // MARK: Rendering

    private struct Renderer {
        let layout: Layout
        let variables: (String) -> String?
        let output = NSMutableString()
        var stops: [Int: [NSRange]] = [:]
        var choices: [Int: [String]] = [:]
        /// Each stop's text: its first placeholder's, shared by its mirrors.
        var defaults: [Int: [Node]] = [:]
        private var rendering: Set<Int> = []

        init(layout: Layout, variables: @escaping (String) -> String?) {
            self.layout = layout
            self.variables = variables
        }

        mutating func collectDefaults(_ nodes: [Node]) {
            for node in nodes {
                switch node {
                case .stop(let index, let placeholder, let choices):
                    if let placeholder {
                        if defaults[index] == nil { defaults[index] = placeholder }
                        collectDefaults(placeholder)
                    } else if let first = choices?.first, defaults[index] == nil {
                        defaults[index] = [.text(first)]
                        self.choices[index] = choices
                    }
                case .variable(_, let fallback):
                    if let fallback { collectDefaults(fallback) }
                case .text:
                    break
                }
            }
        }

        mutating func render(_ nodes: [Node]) {
            for node in nodes {
                switch node {
                case .text(let text):
                    append(text)
                case .stop(let index, _, _):
                    let start = output.length
                    // A stop inside its own placeholder (`${1:a $1}`) would never end.
                    if !rendering.contains(index), let content = defaults[index] {
                        rendering.insert(index)
                        render(content)
                        rendering.remove(index)
                    }
                    stops[index, default: []].append(NSRange(location: start, length: output.length - start))
                case .variable(let name, let fallback):
                    if let value = variables(name), !value.isEmpty {
                        append(value)
                    } else if let fallback {
                        render(fallback)
                    } else if variables(name) == nil {
                        append(name) // unknown: its name, as other editors do
                    }
                }
            }
        }

        private func append(_ text: String) {
            var text = text
            if text.contains("\t") { text = text.replacingOccurrences(of: "\t", with: layout.indentUnit) }
            if text.contains("\n"), !layout.indent.isEmpty { text = text.replacingOccurrences(of: "\n", with: "\n" + layout.indent) }
            output.append(text)
        }
    }

    // MARK: Variables

    /// The variables snippets can use, for a document and the text being replaced.
    @MainActor
    static func variables(for document: EditorDocument, replacing range: NSRange,
                          now: Date = Date()) -> (String) -> String? {
        let text = document.textStorage.mutableString
        let line = document.lineIndex.line(containing: range.location)
        let lineStart = document.lineIndex.lineStarts[line]
        let lineEnd = line + 1 < document.lineIndex.lineCount ? document.lineIndex.lineStarts[line + 1] - 1 : text.length
        let selected = range.length > 0 ? text.substring(with: range) : ""
        let comment = document.language.lineComment
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        func two(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        let url = document.url
        return { name in
            switch name {
            case "TM_SELECTED_TEXT": selected
            case "TM_CURRENT_LINE": text.substring(with: NSRange(location: lineStart, length: max(0, lineEnd - lineStart)))
            case "TM_CURRENT_WORD":
                text.substring(with: NSRange(location: CompletionController.wordStart(in: text, before: range.location),
                                             length: range.location - CompletionController.wordStart(in: text, before: range.location)))
            case "TM_LINE_INDEX": String(line)
            case "TM_LINE_NUMBER": String(line + 1)
            case "TM_FILENAME": url.lastPathComponent
            case "TM_FILENAME_BASE": url.deletingPathExtension().lastPathComponent
            case "TM_DIRECTORY": url.deletingLastPathComponent().path
            case "TM_FILEPATH": url.path
            case "CLIPBOARD": NSPasteboard.general.string(forType: .string) ?? ""
            case "CURRENT_YEAR": String(parts.year ?? 0)
            case "CURRENT_YEAR_SHORT": String(String(parts.year ?? 0).suffix(2))
            case "CURRENT_MONTH": two(parts.month)
            case "CURRENT_MONTH_NAME": formatter.monthSymbols[(parts.month ?? 1) - 1]
            case "CURRENT_MONTH_NAME_SHORT": formatter.shortMonthSymbols[(parts.month ?? 1) - 1]
            case "CURRENT_DATE": two(parts.day)
            case "CURRENT_DAY_NAME": formatter.weekdaySymbols[(parts.weekday ?? 1) - 1]
            case "CURRENT_DAY_NAME_SHORT": formatter.shortWeekdaySymbols[(parts.weekday ?? 1) - 1]
            case "CURRENT_HOUR": two(parts.hour)
            case "CURRENT_MINUTE": two(parts.minute)
            case "CURRENT_SECOND": two(parts.second)
            case "CURRENT_SECONDS_UNIX": String(Int(now.timeIntervalSince1970))
            case "RANDOM": String(format: "%06d", Int.random(in: 0..<1_000_000))
            case "RANDOM_HEX": String(format: "%06x", Int.random(in: 0..<0x1000000))
            case "UUID": UUID().uuidString.lowercased()
            case "LINE_COMMENT": comment ?? ""
            case "BLOCK_COMMENT_START": document.language.blockComment?.start ?? ""
            case "BLOCK_COMMENT_END": document.language.blockComment?.end ?? ""
            default: nil
            }
        }
    }
}

/// Stepping through an inserted snippet's stops with Tab and ⇧Tab. The stops follow edits; a
/// mirrored stop is selected with a cursor in every copy, so typing changes them all.
@MainActor
final class SnippetSession {
    /// Each stop's ranges in the document, in visiting order (the final position last).
    private(set) var stops: [ParsedSnippet.Stop]
    private(set) var current = 0

    init(_ snippet: ParsedSnippet, at offset: Int) {
        stops = snippet.stops.map { stop in
            var stop = stop
            stop.ranges = stop.ranges.map { NSRange(location: $0.location + offset, length: $0.length) }
            return stop
        }
    }

    var currentRanges: [NSRange] { stops.indices.contains(current) ? stops[current].ranges : [] }
    var isAtFinalStop: Bool { current == stops.count - 1 }

    /// Moves to the next (`+1`) or previous (`-1`) stop; false when there's none that way.
    func move(_ direction: Int) -> Bool {
        let target = current + direction
        guard stops.indices.contains(target) else { return false }
        current = target
        return true
    }

    /// Follows an edit (`start..<oldEnd` replaced, length changed by `delta`). Returns false
    /// when it broke the snippet (it overlapped a stop's edge).
    func documentEdited(start: Int, oldEnd: Int, delta: Int) -> Bool {
        func contains(_ range: NSRange) -> Bool { start >= range.location && oldEnd <= NSMaxRange(range) }
        // The edit is typing into the current stop when one of its ranges holds it.
        let active = currentRanges.first(where: contains)
        var intact = true
        for stopIndex in stops.indices {
            var kept: [NSRange] = []
            for var range in stops[stopIndex].ranges {
                let end = NSMaxRange(range)
                if stopIndex == current, contains(range) {
                    range.length += delta
                } else if let active, range.location <= active.location, NSMaxRange(active) <= end, stopIndex != current {
                    range.length += delta // holds the stop being typed in
                } else if oldEnd <= range.location {
                    range.location += delta
                } else if start >= end {
                    // after: unchanged
                } else if start > range.location, oldEnd < end {
                    range.length += delta
                } else if start <= range.location, oldEnd >= end {
                    continue // replaced entirely (a nested stop typed over): it goes
                } else {
                    intact = false
                }
                kept.append(range)
            }
            stops[stopIndex].ranges = kept
        }
        // Stops typed over are gone (never the current one or the final position).
        let currentIndex = stops[current].index
        stops.removeAll { $0.ranges.isEmpty && $0.index != 0 && $0.index != currentIndex }
        current = stops.firstIndex { $0.index == currentIndex } ?? 0
        return intact
    }

    /// Whether `selection` is still in the snippet's current stop.
    func contains(_ selection: NSRange) -> Bool {
        currentRanges.contains { selection.location >= $0.location && NSMaxRange(selection) <= NSMaxRange($0) }
    }
}

extension EditorController {
    /// Inserts a snippet in place of `range` (one undo step) and selects its first stop.
    func insertSnippet(_ body: String, replacing range: NSRange) {
        let text = document.textStorage.mutableString
        let lineStart = document.lineIndex.lineStarts[document.lineIndex.line(containing: range.location)]
        var indentEnd = lineStart
        while indentEnd < range.location, let scalar = Unicode.Scalar(text.character(at: indentEnd)), scalar == " " || scalar == "\t" {
            indentEnd += 1
        }
        let layout = ParsedSnippet.Layout(indent: text.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart)),
                                          indentUnit: indentUnit)
        let snippet = ParsedSnippet(body, layout: layout, variables: ParsedSnippet.variables(for: document, replacing: range))

        snippetSession = nil
        textView.breakUndoCoalescing()
        textView.insertText(snippet.text, replacementRange: range)
        textView.breakUndoCoalescing()
        let session = SnippetSession(snippet, at: range.location)
        // Only an end position: nothing to step through.
        if session.stops.count == 1 {
            select(session.currentRanges)
            return
        }
        snippetSession = session
        select(session.currentRanges)
    }

    private func select(_ ranges: [NSRange]) {
        guard let first = ranges.first else { return }
        setSelections(main: first, extras: Array(ranges.dropFirst()))
        textView.scrollRangeToVisible(first)
    }

    /// Tab / ⇧Tab / Esc while a snippet is active; Tab after a snippet prefix expands it.
    func handleSnippetCommand(_ selector: Selector) -> Bool {
        if let session = snippetSession {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                if session.move(1) { select(session.currentRanges) }
                if session.isAtFinalStop { endSnippet() }
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                if session.move(-1) { select(session.currentRanges) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                endSnippet()
                clearExtraCursors()
                return true
            default:
                return false
            }
        }
        if selector == #selector(NSResponder.insertTab(_:)), !hasExtraCursors { return expandSnippetPrefix() }
        return false
    }

    func endSnippet() {
        snippetSession = nil
    }

    /// Tab right after a snippet's prefix (`for⇥`): the snippet replaces it.
    private func expandSnippetPrefix() -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let text = document.textStorage.mutableString
        var start = selection.location
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)),
              !CharacterSet.whitespacesAndNewlines.contains(scalar), !"([{,;\"'`".unicodeScalars.contains(scalar) {
            start -= 1
        }
        guard start < selection.location else { return false }
        let word = text.substring(with: NSRange(location: start, length: selection.location - start))
        guard let snippet = SnippetLibrary.shared.snippets(for: document.languageId, root: document.workspaceRoot)
            .first(where: { $0.prefixes.contains(word) }) else { return false }
        insertSnippet(snippet.body, replacing: NSRange(location: start, length: selection.location - start))
        return true
    }

    /// The document changed: the active snippet's stops follow (or it ends).
    func snippetDocumentEdited(start: Int, oldEnd: Int, delta: Int) {
        guard let session = snippetSession else { return }
        if !session.documentEdited(start: start, oldEnd: oldEnd, delta: delta) { endSnippet() }
    }

    /// The cursor left the current stop: the snippet is done.
    func snippetSelectionChanged() {
        guard let session = snippetSession else { return }
        if !session.contains(textView.selectedRange()) { endSnippet() }
    }
}

extension Workspace {
    /// Insert Snippet…: picks one of the active file's snippets and inserts it at the cursor.
    func insertSnippet() async {
        guard let document = activeDocument else { return }
        let snippets = SnippetLibrary.shared.snippets(for: document.languageId, root: rootURL)
        guard !snippets.isEmpty else {
            errorMessage = "There are no snippets for \(document.language.displayName) yet: Configure User Snippets adds some."
            return
        }
        let items = snippets.map { QuickPickItem(label: $0.name, description: $0.prefixes.joined(separator: ", ") + " · " + $0.source,
                                                 detail: $0.description == $0.name ? nil : $0.description) }
        guard let index = await showQuickPick(items, placeholder: "Snippet to insert"), snippets.indices.contains(index),
              let editor = document.editor else { return }
        editor.insertSnippet(snippets[index].body, replacing: editor.textView.selectedRange())
        editor.focus()
    }

    /// Opens the user's snippets file for the active file's language.
    func configureUserSnippets() {
        let language = activeDocument?.languageId ?? "plaintext"
        do {
            open(fileAt: try SnippetLibrary.shared.userFile(for: language))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
