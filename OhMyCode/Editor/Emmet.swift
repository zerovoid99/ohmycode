import Foundation

/// Emmet abbreviations (`ul>li.item$*3`, `m10-20`) turned into snippet bodies the editor's
/// snippet engine inserts, so Tab then steps through the empty attributes and elements.
/// Written here rather than run from Emmet's JavaScript: only the parts people use every day
/// (see `EmmetTests` for what's covered), in the same output style.
enum Emmet {
    /// What kind of output: HTML, XML (no void elements or snippets), JSX (`className`,
    /// `<br />`) or CSS properties.
    enum Syntax: Equatable, Sendable {
        case html, xml, jsx, css
    }

    // MARK: Markup

    /// The snippet body for a markup abbreviation, nil when it isn't one. `wrapping` is put in
    /// the deepest last element (one line per copy of an element repeated with a bare `*`).
    static func expandMarkup(_ abbreviation: String, syntax: Syntax = .html, wrapping: [String]? = nil) -> String? {
        guard let root = parseMarkup(abbreviation, syntax: syntax) else { return nil }
        var expander = Expander(syntax: syntax, wrapping: wrapping)
        var nodes = expander.expand(root.children, parentName: nil, numbering: nil)
        if let wrapping, !expander.usedWrapping {
            insert(wrapping, intoDeepestOf: &nodes)
        }
        var renderer = Renderer(syntax: syntax)
        renderer.render(nodes, level: 0, parent: nil)
        return renderer.output
    }

    /// Whether Tab may expand `abbreviation` without asking: it starts like one, and every tag
    /// it names is one people mean (an HTML element, a snippet, a custom element, a JSX
    /// component). "hello" in a paragraph stays a word.
    static func isConfidentMarkup(_ abbreviation: String, syntax: Syntax) -> Bool {
        guard let first = abbreviation.unicodeScalars.first,
              CharacterSet.letters.contains(first) || "!([#.{".unicodeScalars.contains(first),
              let root = parseMarkup(abbreviation, syntax: syntax) else { return false }
        var names: [String] = []
        func collect(_ node: Node) {
            if let name = node.name { names.append(name) }
            node.children.forEach(collect)
        }
        root.children.forEach(collect)
        let isPlainWord = abbreviation.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        return names.allSatisfy { name in
            let bare = name.replacingOccurrences(of: "$", with: "")
            if syntax == .xml { return !isPlainWord }
            if knownTags.contains(bare.lowercased()) || markupSnippets[name] != nil || isLorem(name) != nil { return true }
            if bare.contains("-"), bare.first?.isLetter == true { return true } // custom element
            return syntax == .jsx && bare.first?.isUppercase == true && !isPlainWord
        }
    }

    /// The abbreviation that ends at the end of `line` (the text before the cursor), and where
    /// it starts in it (UTF-16), as Emmet finds it: back to a space outside `[…]`/`{…}`, or to
    /// the end of a tag (`<p>a>b` → `a>b`).
    static func extractMarkup(beforeCursor line: String) -> (abbreviation: String, start: Int)? {
        let units = Array(line.utf16)
        var index = units.count
        var brackets: [UInt16] = [] // closing brackets seen, innermost last
        var quote: UInt16?
        while index > 0 {
            let unit = units[index - 1]
            if let open = quote {
                if unit == open { quote = nil }
                index -= 1
                continue
            }
            if let last = brackets.last {
                if last == 0x7D { // in {text}: only braces count
                    if unit == 0x7D { brackets.append(unit) } else if unit == 0x7B { brackets.removeLast() }
                } else if unit == 0x22 || unit == 0x27 { // in [attr="…"]
                    quote = unit
                } else if unit == 0x5D {
                    brackets.append(unit)
                } else if unit == 0x5B {
                    brackets.removeLast()
                }
                index -= 1
                continue
            }
            if unit == 0x5D || unit == 0x7D { brackets.append(unit); index -= 1; continue }
            if unit == 0x3E, isTagEnd(units, at: index - 1) { break } // ">" closing "<p>"
            guard let scalar = Unicode.Scalar(unit), isAbbreviationCharacter(scalar) else { break }
            index -= 1
        }
        guard brackets.isEmpty, quote == nil else { return nil }
        // Operators can't start one ("+a" after "x"): what follows them is the abbreviation.
        while index < units.count, let scalar = Unicode.Scalar(units[index]), ">+^*)".unicodeScalars.contains(scalar) { index += 1 }
        guard index < units.count else { return nil }
        return (String(decoding: units[index...], as: UTF16.self), index)
    }

    private static func isAbbreviationCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || "_-:.#*+^>$@!%()/".unicodeScalars.contains(scalar)
    }

    /// Whether the `>` at `index` ends an HTML tag (`<a href="x">`), not a child operator.
    private static func isTagEnd(_ units: [UInt16], at index: Int) -> Bool {
        var cursor = index - 1
        var quote: UInt16?
        while cursor >= 0 {
            let unit = units[cursor]
            if let open = quote {
                if unit == open { quote = nil }
            } else if unit == 0x22 || unit == 0x27 {
                quote = unit
            } else if unit == 0x3E {
                return false
            } else if unit == 0x3C {
                guard cursor + 1 < index, let next = Unicode.Scalar(units[cursor + 1]) else { return false }
                return CharacterSet.letters.contains(next) || next == "/" || next == "!"
            }
            cursor -= 1
        }
        return false
    }

    // MARK: Parsing

    /// A parsed abbreviation's element, group (`(…)`) or text (`{…}`).
    final class Node {
        var name: String?
        var isGroup = false
        var attributes: [Attribute] = []
        var text: String?
        /// nil: once; 0: `*` alone (once per wrapped line).
        var repeatCount: Int?
        var selfClosing = false
        var children: [Node] = []

        init(group: Bool = false) { isGroup = group }

        var isTextOnly: Bool { name == nil && !isGroup && attributes.isEmpty && text != nil }

        func copy() -> Node {
            let node = Node(group: isGroup)
            node.name = name
            node.attributes = attributes
            node.text = text
            node.repeatCount = repeatCount
            node.selfClosing = selfClosing
            node.children = children.map { $0.copy() }
            return node
        }
    }

    struct Attribute: Equatable {
        var name: String
        var value: String?
        /// `[onClick={handle}]`: written as an expression in JSX.
        var isExpression = false
    }

    /// The text that marks a snippet's default value (`input[type=|text]`) as a placeholder.
    static let placeholderMark: Character = "\u{E000}"

    static func parseMarkup(_ abbreviation: String, syntax: Syntax = .html, placeholders: Bool = false) -> Node? {
        guard !abbreviation.isEmpty, abbreviation.count <= 2000 else { return nil }
        var parser = Parser(Array(abbreviation), placeholders: placeholders, syntax: syntax)
        guard let root = parser.parseSequence(inGroup: false), parser.index == parser.characters.count else { return nil }
        return root
    }

    private struct Parser {
        let characters: [Character]
        let placeholders: Bool
        let syntax: Syntax
        var index = 0

        init(_ characters: [Character], placeholders: Bool, syntax: Syntax) {
            self.characters = characters
            self.placeholders = placeholders
            self.syntax = syntax
        }

        private func peek(_ offset: Int = 0) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }

        mutating func parseSequence(inGroup: Bool) -> Node? {
            let root = Node(group: true)
            var context = root
            var parents: [Node] = []
            while true {
                guard let item = parseItem() else { return nil }
                context.children.append(item)
                guard let character = peek() else { return inGroup ? nil : root }
                switch character {
                case ">":
                    index += 1
                    parents.append(context)
                    context = item
                case "+":
                    index += 1
                case "^":
                    while peek() == "^" {
                        index += 1
                        if let parent = parents.popLast() { context = parent }
                    }
                case ")":
                    return inGroup ? root : nil
                default:
                    return nil
                }
            }
        }

        private mutating func parseItem() -> Node? {
            if peek() == "(" {
                index += 1
                guard let group = parseSequence(inGroup: true), peek() == ")" else { return nil }
                index += 1
                if peek() == "*" { group.repeatCount = readRepeat() }
                return group
            }
            return parseElement()
        }

        private mutating func parseElement() -> Node? {
            let node = Node()
            let name = readName(allowingSnippetPlus: true)
            if !name.isEmpty { node.name = name }
            loop: while let character = peek() {
                switch character {
                case "#":
                    index += 1
                    let id = readName(allowingSnippetPlus: false)
                    guard !id.isEmpty else { return nil }
                    node.attributes.removeAll { $0.name == "id" }
                    node.attributes.append(Attribute(name: "id", value: id))
                case ".":
                    index += 1
                    let name = readName(allowingSnippetPlus: false)
                    guard !name.isEmpty else { return nil }
                    if let existing = node.attributes.firstIndex(where: { $0.name == "class" }) {
                        let value = node.attributes[existing].value ?? ""
                        node.attributes[existing].value = value.isEmpty ? name : value + " " + name
                    } else {
                        node.attributes.append(Attribute(name: "class", value: name))
                    }
                case "[":
                    index += 1
                    guard let attributes = readAttributes() else { return nil }
                    for attribute in attributes {
                        if let existing = node.attributes.firstIndex(where: { $0.name == attribute.name }) {
                            node.attributes[existing] = attribute
                        } else {
                            node.attributes.append(attribute)
                        }
                    }
                case "{":
                    index += 1
                    guard let text = readBraced() else { return nil }
                    node.text = (node.text ?? "") + placeholder(text)
                case "*":
                    node.repeatCount = readRepeat()
                case "/":
                    index += 1
                    node.selfClosing = true
                default:
                    break loop
                }
            }
            guard node.name != nil || !node.attributes.isEmpty || node.text != nil else { return nil }
            return node
        }

        private mutating func readRepeat() -> Int {
            index += 1 // "*"
            var digits = ""
            while let character = peek(), character.isASCII, character.isNumber { digits.append(character); index += 1 }
            return min(Int(digits) ?? 0, 1000)
        }

        private func isNameCharacter(_ character: Character) -> Bool {
            (character.isLetter || character.isNumber) || "-_:$@!".contains(character)
        }

        /// A tag name, id or class; `ul+` (a snippet ending in "+") when that's one.
        private mutating func readName(allowingSnippetPlus: Bool) -> String {
            var name = ""
            while let character = peek(), isNameCharacter(character) {
                name.append(character)
                index += 1
            }
            if allowingSnippetPlus, peek() == "+", syntax != .xml, Emmet.markupSnippets[name + "+"] != nil,
               peek(1).map({ ">^+)*".contains($0) }) ?? true {
                index += 1
                name += "+"
            }
            return name
        }

        /// `{text}` (after the "{"), with nested braces and `\}` kept.
        private mutating func readBraced() -> String? {
            var depth = 0
            var text = ""
            while let character = peek() {
                index += 1
                if character == "\\", let next = peek() {
                    index += 1
                    // `\$` stays escaped until numbering, which turns it into a "$".
                    if next == "$" { text.append("\\") }
                    text.append(next)
                    continue
                }
                if character == "{" { depth += 1 }
                if character == "}" {
                    if depth == 0 { return text }
                    depth -= 1
                }
                text.append(character)
            }
            return nil
        }

        /// `[a=1 b="x y" c]` (after the "[").
        private mutating func readAttributes() -> [Attribute]? {
            var attributes: [Attribute] = []
            while true {
                while peek() == " " { index += 1 }
                guard let character = peek() else { return nil }
                if character == "]" { index += 1; return attributes }
                var name = ""
                if character == "\"" || character == "'" {
                    index += 1
                    while let next = peek(), next != character { name.append(next); index += 1 }
                    guard peek() == character else { return nil }
                    index += 1
                } else {
                    while let next = peek(), next != " ", next != "=", next != "]" { name.append(next); index += 1 }
                }
                guard !name.isEmpty else { return nil }
                var attribute = Attribute(name: name, value: nil)
                if peek() == "=" {
                    index += 1
                    switch peek() {
                    case "\"", "'":
                        let quote = peek()!
                        index += 1
                        var value = ""
                        while let next = peek(), next != quote {
                            if next == "\\", let escaped = peek(1) { value.append(escaped); index += 2; continue }
                            value.append(next)
                            index += 1
                        }
                        guard peek() == quote else { return nil }
                        index += 1
                        attribute.value = placeholder(value)
                    case "{":
                        index += 1
                        guard let value = readBraced() else { return nil }
                        attribute.value = value
                        attribute.isExpression = true
                    default:
                        var value = ""
                        while let next = peek(), next != " ", next != "]" { value.append(next); index += 1 }
                        attribute.value = placeholder(value)
                    }
                }
                attributes.append(attribute)
            }
        }

        /// A snippet's `|default` becomes a placeholder's default.
        private func placeholder(_ value: String) -> String {
            guard placeholders, value.hasPrefix("|") else { return value }
            return String(Emmet.placeholderMark) + value.dropFirst()
        }
    }

    // MARK: Expanding

    /// An element, text or raw markup (`<!DOCTYPE html>`, a comment) ready to be written out.
    final class Output {
        enum Kind { case element, text, raw, comment }
        var kind: Kind
        var name = ""
        var attributes: [Attribute] = []
        var selfClosing = false
        var text: String?
        var children: [Output] = []

        init(_ kind: Kind) { self.kind = kind }
    }

    private struct Numbering {
        var index: Int
        var count: Int
    }

    private struct Expander {
        let syntax: Syntax
        let wrapping: [String]?
        var usedWrapping = false
        var expanding: Set<String> = []

        init(syntax: Syntax, wrapping: [String]?) {
            self.syntax = syntax
            self.wrapping = wrapping
        }

        mutating func expand(_ nodes: [Node], parentName: String?, numbering: Numbering?) -> [Output] {
            nodes.flatMap { expand($0, parentName: parentName, numbering: numbering) }
        }

        private mutating func expand(_ node: Node, parentName: String?, numbering: Numbering?) -> [Output] {
            var count = node.repeatCount ?? 1
            var lines: [String]?
            if node.repeatCount == 0 {
                // One copy per wrapped line, without its indentation; blank lines don't count.
                let wrapped = wrapping?.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
                if !wrapped.isEmpty, !usedWrapping {
                    lines = wrapped
                    count = wrapped.count
                    usedWrapping = true
                } else {
                    count = 1
                }
            }
            var result: [Output] = []
            for copy in 0..<count {
                let numbering = node.repeatCount != nil ? Numbering(index: copy + 1, count: count) : numbering
                var outputs = expandOnce(node, parentName: parentName, numbering: numbering)
                if let lines { Emmet.insert([lines[copy]], intoDeepestOf: &outputs) }
                result += outputs
            }
            return result
        }

        private mutating func expandOnce(_ node: Node, parentName: String?, numbering: Numbering?) -> [Output] {
            func number(_ text: String) -> String { Emmet.number(text, numbering) }
            if node.isGroup { return expand(node.children, parentName: parentName, numbering: numbering) }
            if node.isTextOnly {
                let output = Output(.text)
                output.text = number(node.text ?? "")
                return [output]
            }
            let name = node.name.map(number)
            if let name, let words = Emmet.isLorem(name) {
                let output = Output(.text)
                output.text = Emmet.lorem(words: words, variant: (numbering?.index ?? 1) - 1)
                return [output]
            }
            // A snippet: its abbreviation in place of the name, with what was written added.
            if let name, syntax != .xml, !expanding.contains(name), let snippet = Emmet.markupSnippets[name] {
                switch snippet {
                case .raw(let text):
                    let output = Output(.raw)
                    output.text = text
                    return [output]
                case .comment:
                    return [Output(.comment)]
                case .abbreviation(let abbreviation):
                    guard let parsed = Emmet.parseMarkup(abbreviation, syntax: syntax, placeholders: true) else { break }
                    let merged = Emmet.merge(node, into: parsed)
                    expanding.insert(name)
                    defer { expanding.remove(name) }
                    return expand(merged.children, parentName: parentName, numbering: numbering)
                }
            }
            let output = Output(.element)
            output.name = name ?? Emmet.implicitTag(in: parentName)
            output.attributes = node.attributes.map { attribute in
                var attribute = attribute
                attribute.name = number(attribute.name)
                attribute.value = attribute.value.map(number)
                return attribute
            }
            output.selfClosing = node.selfClosing
            output.text = node.text.map(number)
            output.children += expand(node.children, parentName: output.name, numbering: numbering)
            return [output]
        }
    }

    /// `node` written with a snippet's name (`a` → `a[href]`): its attributes after the
    /// snippet's (replacing ones of the same name), its text and children in the snippet's
    /// deepest last element.
    fileprivate static func merge(_ node: Node, into snippet: Node) -> Node {
        let root = snippet.copy()
        guard let first = firstElement(in: root) else { return root }
        for attribute in node.attributes {
            if let existing = first.attributes.firstIndex(where: { $0.name == attribute.name }) {
                if attribute.value != nil { first.attributes[existing] = attribute }
            } else {
                first.attributes.append(attribute)
            }
        }
        if node.selfClosing { first.selfClosing = true }
        var deepest = root
        while let last = deepest.children.last(where: { !$0.isTextOnly }) { deepest = last }
        if let text = node.text {
            deepest.text = text
            deepest.selfClosing = false
        }
        if !node.children.isEmpty {
            deepest.children += node.children
            deepest.selfClosing = false
        }
        return root
    }

    private static func firstElement(in node: Node) -> Node? {
        for child in node.children {
            if child.isGroup { if let element = firstElement(in: child) { return element } } else if !child.isTextOnly { return child }
        }
        return nil
    }

    /// Puts `lines` in the deepest last element of `nodes` (or after them, when there's none).
    fileprivate static func insert(_ lines: [String], intoDeepestOf nodes: inout [Output]) {
        let text = Output(.text)
        text.text = lines.joined(separator: "\n")
        guard var target = nodes.last(where: { $0.kind == .element }) else {
            nodes.append(text)
            return
        }
        while let last = target.children.last(where: { $0.kind == .element }) { target = last }
        target.selfClosing = false
        target.children.append(text)
    }

    /// `$`, `$$`, `$@-`, `$@3`, `$@-3` replaced by the nearest repeated element's number.
    static func number(_ text: String, _ numbering: (index: Int, count: Int)?) -> String {
        guard text.contains("$") else { return text }
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "$" {
                result.append("$")
                index += 2
                continue
            }
            guard character == "$" else { result.append(character); index += 1; continue }
            var width = 0
            while index < characters.count, characters[index] == "$" { width += 1; index += 1 }
            var reverse = false
            var base = 1
            if index < characters.count, characters[index] == "@" {
                var cursor = index + 1
                if cursor < characters.count, characters[cursor] == "-" { reverse = true; cursor += 1 }
                var digits = ""
                while cursor < characters.count, characters[cursor].isASCII, characters[cursor].isNumber {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                base = Int(digits) ?? 1
                index = cursor
            }
            let position = numbering?.index ?? 1
            let count = numbering?.count ?? 1
            let value = reverse ? count - position + base : position + base - 1
            let digits = String(value)
            result += String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return result
    }

    private static func number(_ text: String, _ numbering: Numbering?) -> String {
        number(text, numbering.map { ($0.index, $0.count) })
    }

    /// The tag for an element written without one (`.a`), from its parent's.
    static func implicitTag(in parent: String?) -> String {
        switch parent?.lowercased() {
        case "ul", "ol": "li"
        case "table", "tbody", "thead", "tfoot": "tr"
        case "tr": "td"
        case "select", "optgroup", "datalist": "option"
        case "map": "area"
        case "colgroup": "col"
        case "audio", "video", "picture": "source"
        case let name? where inlineElements.contains(name): "span"
        default: "div"
        }
    }

    // MARK: Writing

    private struct Renderer {
        let syntax: Syntax
        var output = ""
        var stop = 0

        init(syntax: Syntax) { self.syntax = syntax }

        private func indent(_ level: Int) -> String { String(repeating: "\t", count: level) }

        private mutating func nextStop(_ placeholder: String = "") -> String {
            stop += 1
            return placeholder.isEmpty ? "${\(stop)}" : "${\(stop):\(Emmet.escape(placeholder))}"
        }

        /// A value: a snippet's placeholder becomes a stop with it as the default.
        private mutating func value(_ text: String) -> String {
            if text.first == Emmet.placeholderMark { return nextStop(String(text.dropFirst())) }
            return Emmet.escape(text)
        }

        private func isInline(_ node: Output) -> Bool {
            switch node.kind {
            case .text: !(node.text ?? "").contains("\n")
            case .element: Emmet.inlineElements.contains(node.name.lowercased())
            case .raw, .comment: false
            }
        }

        private func isInlineElement(_ node: Output?) -> Bool {
            guard let node, node.kind == .element else { return false }
            return isInline(node)
        }

        /// Emmet's rule for whether a node starts on its own line.
        private func shouldFormat(_ node: Output, at index: Int, in items: [Output], parent: Output?) -> Bool {
            if index == 0, parent == nil { return false }
            guard isInline(node) else { return true }
            if index == 0 {
                if items.contains(where: { !isInline($0) }) { return true }
            } else if !isInline(items[index - 1]) {
                return true
            }
            if node.kind == .element {
                var adjacent = 1
                var before = index - 1, after = index + 1
                while before >= 0, isInlineElement(items[before]) { adjacent += 1; before -= 1 }
                while after < items.count, isInlineElement(items[after]) { adjacent += 1; after += 1 }
                if adjacent >= 3 { return true }
            }
            return node.children.enumerated().contains { shouldFormat($1, at: $0, in: node.children, parent: node) }
        }

        mutating func render(_ items: [Output], level: Int, parent: Output?) {
            for (index, node) in items.enumerated() {
                if shouldFormat(node, at: index, in: items, parent: parent) { output += "\n" + indent(level) }
                render(node, level: level)
            }
        }

        private mutating func render(_ node: Output, level: Int) {
            switch node.kind {
            case .text:
                let text = node.text ?? ""
                if text.first == Emmet.placeholderMark {
                    output += nextStop(String(text.dropFirst()))
                } else {
                    output += text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { Emmet.escape(String($0)) }.joined(separator: "\n" + indent(level))
                }
            case .raw:
                output += Emmet.escape(node.text ?? "")
            case .comment:
                output += "<!-- " + nextStop() + " -->"
            case .element:
                renderElement(node, level: level)
            }
        }

        private mutating func renderElement(_ node: Output, level: Int) {
            let name = node.name
            output += "<" + name
            for attribute in node.attributes { output += self.attribute(attribute) }
            let isVoid = syntax != .xml && Emmet.voidElements.contains(name.lowercased())
            if node.children.isEmpty, node.text == nil, node.selfClosing || isVoid {
                let end = switch syntax {
                case .html, .css: ">"
                case .jsx: " />"
                case .xml: "/>"
                }
                output += end
                return
            }
            output += ">"
            let skip = Emmet.formatSkip.contains(name.lowercased())
            let force = Emmet.formatForce.contains(name.lowercased())
            let childLevel = skip ? level : level + 1
            // Its own text (`p{…}`) right after the tag, before any children.
            if let text = node.text { output += value(text) }
            if node.children.isEmpty {
                if node.text == nil {
                    output += force ? "\n" + indent(childLevel) + nextStop() + "\n" + indent(level) : nextStop()
                }
            } else {
                render(node.children, level: childLevel, parent: node)
                let formatted = force || node.children.enumerated().contains { shouldFormat($1, at: $0, in: node.children, parent: node) }
                if formatted { output += "\n" + indent(level) }
            }
            output += "</" + name + ">"
        }

        private mutating func attribute(_ attribute: Attribute) -> String {
            var name = attribute.name
            if syntax == .jsx { name = Emmet.jsxAttributeNames[name] ?? name }
            if attribute.isExpression {
                let expression = Emmet.escape(attribute.value ?? "")
                return syntax == .jsx ? " \(name)={\(expression)}" : " \(name)=\"{\(expression)}\""
            }
            let value = attribute.value ?? ""
            if value.isEmpty, syntax != .xml, attribute.value == nil, Emmet.booleanAttributes.contains(name.lowercased()) {
                return " " + name
            }
            return " \(name)=\"" + (value.isEmpty ? nextStop() : self.value(value)) + "\""
        }
    }

    /// Text as literal snippet text.
    static func escape(_ text: String) -> String {
        guard text.contains(where: { $0 == "$" || $0 == "}" || $0 == "\\" }) else { return text }
        var result = ""
        for character in text {
            if character == "$" || character == "}" || character == "\\" { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: Lorem ipsum

    /// The number of words `lorem`, `lorem10`, `lipsum5` asks for (nil: not lorem).
    static func isLorem(_ name: String) -> Int? {
        for prefix in ["lorem", "lipsum"] where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            if rest.isEmpty { return 30 }
            if rest.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(rest) { return min(max(count, 1), 1000) }
        }
        return nil
    }

    private static let loremWords = """
    lorem ipsum dolor sit amet consectetur adipisicing elit sed do eiusmod tempor incididunt ut labore et dolore magna \
    aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat duis aute \
    irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat cupidatat non \
    proident sunt culpa qui officia deserunt mollit anim id est laborum perspiciatis unde omnis iste natus error \
    voluptatem accusantium doloremque laudantium totam rem aperiam eaque ipsa quae ab illo inventore veritatis quasi \
    architecto beatae vitae dicta explicabo nemo ipsam quia voluptas aspernatur aut odit fugit consequuntur magni dolores
    """.split(separator: " ").map(String.init)

    /// `count` words of placeholder Latin, in sentences; the first copy starts "Lorem ipsum".
    static func lorem(words count: Int, variant: Int = 0) -> String {
        var words: [String] = []
        let offset = variant == 0 ? 0 : (variant * 17) % loremWords.count
        for index in 0..<count { words.append(loremWords[(offset + index) % loremWords.count]) }
        var sentences: [String] = []
        var start = 0
        let lengths = [8, 11, 6, 13, 9, 7, 12]
        var turn = variant
        while start < words.count {
            let length = min(lengths[turn % lengths.count], words.count - start)
            turn += 1
            var sentence = Array(words[start..<start + length])
            sentence[0] = sentence[0].prefix(1).uppercased() + sentence[0].dropFirst()
            if sentence.count > 5 { sentence[sentence.count / 2] += "," }
            sentences.append(sentence.joined(separator: " ") + ".")
            start += length
        }
        return sentences.joined(separator: " ")
    }

    // MARK: Tables

    enum Snippet {
        case abbreviation(String)
        case raw(String)
        case comment
    }

    /// Emmet's HTML snippets: names that stand for a fuller abbreviation (`|x`: a placeholder).
    static let markupSnippets: [String: Snippet] = {
        var table: [String: Snippet] = ["!!!": .raw("<!DOCTYPE html>"), "doctype": .raw("<!DOCTYPE html>"), "c": .comment]
        let abbreviations: [String: String] = [
            "!": "!!!+html[lang=en]>(head>meta[charset=UTF-8]+meta[name=viewport content=\"width=device-width, initial-scale=1.0\"]+title{|Document})+body",
            "a": "a[href]", "a:link": "a[href=|https://]", "a:mail": "a[href=|mailto:]", "a:tel": "a[href=|tel:+]",
            "abbr": "abbr[title]", "acr": "acronym[title]", "base": "base[href]/", "basefont": "basefont/", "br": "br/", "frame": "frame/",
            "hr": "hr/", "bdo": "bdo[dir]", "bdo:r": "bdo[dir=rtl]", "bdo:l": "bdo[dir=ltr]", "col": "col/",
            "link": "link[rel=stylesheet href]/", "link:css": "link[rel=stylesheet href=|style.css]/",
            "link:print": "link[rel=stylesheet href=|print.css media=print]/",
            "link:favicon": "link[rel=\"shortcut icon\" type=image/x-icon href=|favicon.ico]/",
            "link:touch": "link[rel=apple-touch-icon href=|favicon.png]/", "link:rss": "link[rel=alternate type=application/rss+xml title=RSS href=|rss.xml]/",
            "link:atom": "link[rel=alternate type=application/atom+xml title=Atom href=|atom.xml]/",
            "link:import": "link[rel=import href=|component.html]/", "link:im": "link[rel=import href=|component.html]/",
            "meta": "meta/", "meta:utf": "meta[http-equiv=Content-Type content=\"text/html;charset=UTF-8\"]/",
            "meta:vp": "meta[name=viewport content=\"width=device-width, initial-scale=1.0\"]/",
            "meta:compat": "meta[http-equiv=X-UA-Compatible content=\"IE=edge\"]/", "meta:edge": "meta[http-equiv=X-UA-Compatible content=\"IE=edge\"]/",
            "meta:redirect": "meta[http-equiv=refresh content=\"0; url=|http://example.com\"]/",
            "meta:kw": "meta[name=keywords content]/", "meta:desc": "meta[name=description content]/",
            "style": "style", "script": "script", "script:src": "script[src]",
            "img": "img[src alt]/", "img:s": "img[srcset src alt]/", "img:z": "img[sizes srcset src alt]/",
            "pic": "picture", "src": "source/", "src:sc": "source[src type]/", "picture+": "picture>source[srcset media]+img[src alt]",
            "iframe": "iframe[src frameborder=0]", "embed": "embed[src type]/", "object": "object[data type]",
            "param": "param[name value]/", "map": "map[name]", "area": "area[shape coords href alt]/",
            "area:d": "area[shape=default href alt]/", "area:c": "area[shape=circle coords href alt]/",
            "area:r": "area[shape=rect coords href alt]/", "area:p": "area[shape=poly coords href alt]/",
            "form": "form[action]", "form:get": "form[action method=get]", "form:post": "form[action method=post]",
            "label": "label[for]", "input": "input[type=|text]/", "inp": "input[name id]",
            "input:hidden": "input[type=hidden name]", "input:h": "input[type=hidden name]",
            "input:text": "input[type=text name id]", "input:t": "input[type=text name id]", "input:search": "input[type=search name id]",
            "input:email": "input[type=email name id]", "input:url": "input[type=url name id]", "input:password": "input[type=password name id]",
            "input:p": "input[type=password name id]", "input:datetime": "input[type=datetime name id]", "input:date": "input[type=date name id]",
            "input:datetime-local": "input[type=datetime-local name id]", "input:month": "input[type=month name id]", "input:week": "input[type=week name id]",
            "input:time": "input[type=time name id]", "input:tel": "input[type=tel name id]", "input:color": "input[type=color name id]",
            "input:number": "input[type=number name id]", "input:range": "input[type=range name id]", "input:checkbox": "input[type=checkbox name id]",
            "input:c": "input[type=checkbox name id]", "input:radio": "input[type=radio name id]", "input:r": "input[type=radio name id]",
            "input:file": "input[type=file name id]", "input:f": "input[type=file name id]", "input:submit": "input[type=submit value]",
            "input:s": "input[type=submit value]", "input:image": "input[type=image src alt]", "input:i": "input[type=image src alt]",
            "input:button": "input[type=button value]", "input:b": "input[type=button value]",
            "input:reset": "input[type=reset value]",
            "isindex": "isindex/", "select": "select[name id]", "select:disabled": "select[name id disabled]",
            "select:d": "select[name id disabled]", "select+": "select[name id]>option[value]",
            "option": "option[value]", "textarea": "textarea[name id cols=30 rows=10]",
            "marquee": "marquee[behavior direction]", "menu:context": "menu[type=context]", "menu:c": "menu[type=context]",
            "menu:toolbar": "menu[type=toolbar]", "menu:t": "menu[type=toolbar]",
            "video": "video[src]", "audio": "audio[src]", "html:xml": "html[xmlns=http://www.w3.org/1999/xhtml]",
            "keygen": "keygen/", "command": "command/", "btn:s": "button[type=submit]", "button:s": "button[type=submit]",
            "btn:r": "button[type=reset]", "button:r": "button[type=reset]", "btn:d": "button[disabled]",
            "button:d": "button[disabled]", "btn:b": "button[type=button]", "button:b": "button[type=button]",
            "fst:d": "fieldset[disabled]", "fset:d": "fieldset[disabled]", "fieldset:d": "fieldset[disabled]",
            "bq": "blockquote", "fig": "figure", "figc": "figcaption", "ifr": "iframe[src frameborder=0]",
            "emb": "embed[src type]/", "obj": "object[data type]", "cap": "caption", "colg": "colgroup",
            "fst": "fieldset", "fset": "fieldset", "btn": "button", "optg": "optgroup", "tarea": "textarea[name id cols=30 rows=10]",
            "leg": "legend", "sect": "section", "art": "article", "hdr": "header", "ftr": "footer", "adr": "address",
            "dlg": "dialog", "str": "strong", "prog": "progress", "mn": "main", "tem": "template", "datag": "datagrid",
            "datal": "datalist", "kg": "keygen", "out": "output", "det": "details", "sum": "summary", "cmd": "command",
            "ri:d": "img[srcset src alt]/", "ri:dpr": "img[srcset src alt]/", "ri:v": "picture>source[media srcset]+img[src alt]",
            "ri:vp": "picture>source[media srcset]+img[src alt]", "ri:t": "picture>source[srcset type]+img[src alt]",
            "ri:type": "picture>source[srcset type]+img[src alt]",
            "ul+": "ul>li", "ol+": "ol>li", "dl+": "dl>dt+dd", "map+": "map>area", "table+": "table>tr>td",
            "colgroup+": "colgroup>col", "colg+": "colgroup>col", "tr+": "tr>td", "optgroup+": "optgroup>option", "optg+": "optgroup>option",
        ]
        for (name, abbreviation) in abbreviations { table[name] = .abbreviation(abbreviation) }
        table["html:5"] = table["!"]
        table["doc"] = .abbreviation("html[lang=en]>(head>meta[charset=UTF-8]+meta[name=viewport content=\"width=device-width, initial-scale=1.0\"]+title{|Document})+body")
        return table
    }()

    static let voidElements: Set<String> = [
        "area", "base", "basefont", "br", "col", "command", "embed", "frame", "hr", "img", "input", "isindex", "keygen",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    static let inlineElements: Set<String> = [
        "a", "abbr", "acronym", "applet", "b", "basefont", "bdo", "big", "br", "button", "cite", "code", "del", "dfn", "em",
        "font", "i", "iframe", "img", "input", "ins", "kbd", "label", "map", "object", "q", "s", "samp", "select", "small",
        "span", "strike", "strong", "sub", "sup", "textarea", "tt", "u", "var",
    ]

    static let booleanAttributes: Set<String> = [
        "contenteditable", "seamless", "async", "autofocus", "autoplay", "checked", "controls", "defer", "disabled",
        "formnovalidate", "hidden", "ismap", "loop", "multiple", "muted", "novalidate", "readonly", "required", "reversed",
        "selected", "typemustmatch",
    ]

    /// Elements whose children aren't indented (`html`), and ones always on their own lines.
    static let formatSkip: Set<String> = ["html"]
    static let formatForce: Set<String> = ["body"]

    static let jsxAttributeNames = ["class": "className", "for": "htmlFor", "tabindex": "tabIndex", "readonly": "readOnly",
                                    "maxlength": "maxLength", "contenteditable": "contentEditable"]

    /// Every HTML element (what a plain word must be for Tab to expand it).
    static let knownTags: Set<String> = [
        "a", "abbr", "address", "area", "article", "aside", "audio", "b", "base", "bdi", "bdo", "blockquote", "body", "br",
        "button", "canvas", "caption", "cite", "code", "col", "colgroup", "data", "datalist", "dd", "del", "details", "dfn",
        "dialog", "div", "dl", "dt", "em", "embed", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html", "i", "iframe", "img", "input", "ins", "kbd", "label",
        "legend", "li", "link", "main", "map", "mark", "menu", "meta", "meter", "nav", "noscript", "object", "ol", "optgroup",
        "option", "output", "p", "param", "picture", "pre", "progress", "q", "rp", "rt", "ruby", "s", "samp", "script",
        "search", "section", "select", "slot", "small", "source", "span", "strong", "style", "sub", "summary", "sup", "svg",
        "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track", "u", "ul",
        "var", "video", "wbr", "math", "path", "circle", "rect", "line", "polygon", "polyline", "ellipse", "g", "defs", "use",
    ]
}
