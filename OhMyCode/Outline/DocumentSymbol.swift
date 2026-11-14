import Foundation
import SwiftTreeSitter

/// A declaration in a file (a class, a function, a heading…), with those inside it: the
/// Outline panel, breadcrumbs and Go to Symbol.
struct DocumentSymbol: Identifiable, Equatable, Sendable {
    /// LSP's SymbolKind numbers.
    enum Kind: Int, Sendable {
        case file = 1, module, namespace, package, `class`, method, property, field, constructor, `enum`,
             interface, function, variable, constant, string, number, boolean, array, object, key, null,
             enumMember, `struct`, event, `operator`, typeParameter

        var icon: String {
            switch self {
            case .file: "doc"
            case .module, .namespace, .package: "shippingbox"
            case .class: "c.square"
            case .struct: "s.square"
            case .interface: "p.square"
            case .enum: "e.square"
            case .enumMember: "list.bullet"
            case .method, .function, .constructor, .operator: "f.square"
            case .property, .field: "circle.grid.2x1"
            case .variable: "v.square"
            case .constant: "k.square"
            case .typeParameter: "t.square"
            case .string: "textformat"
            case .key, .object, .array, .number, .boolean, .null: "curlybraces"
            case .event: "bolt"
            }
        }

        var name: String { String(describing: self).capitalized }
    }

    var name: String
    var detail: String?
    var kind: Kind
    /// The whole declaration, and its name (UTF-16, in the document).
    var range: NSRange
    var selectionRange: NSRange
    var children: [DocumentSymbol] = []
    /// Unique in the file: the names of the symbols it's in, and its position among them.
    var id: String = ""

    init(name: String, detail: String? = nil, kind: Kind, range: NSRange, selectionRange: NSRange? = nil,
         children: [DocumentSymbol] = []) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange ?? range
        self.children = children
    }

    /// Ids for a tree (and children sorted by position).
    static func identified(_ symbols: [DocumentSymbol], parent: String = "") -> [DocumentSymbol] {
        symbols.sorted { $0.range.location < $1.range.location }.enumerated().map { index, symbol in
            var symbol = symbol
            symbol.id = parent + "/" + symbol.name + "#\(index)"
            symbol.children = identified(symbol.children, parent: symbol.id)
            return symbol
        }
    }

    /// Every symbol, depth first, with the names of those it's in.
    static func flattened(_ symbols: [DocumentSymbol], container: [String] = []) -> [(symbol: DocumentSymbol, container: [String])] {
        symbols.flatMap { symbol in [(symbol, container)] + flattened(symbol.children, container: container + [symbol.name]) }
    }

    /// The symbols containing `offset`, outermost first.
    static func path(to offset: Int, in symbols: [DocumentSymbol]) -> [DocumentSymbol] {
        guard let inner = symbols.last(where: { NSLocationInRange(offset, $0.range) || NSMaxRange($0.range) == offset && $0.range.length > 0 && offset > $0.range.location })
        else { return [] }
        return [inner] + path(to: offset, in: inner.children)
    }

    // MARK: Language server

    /// From a `textDocument/documentSymbol` result: DocumentSymbol[] (nested) or
    /// SymbolInformation[] (flat, nested here by containment). `range` converts LSP ranges.
    static func fromLSP(_ result: Any?, range: (LSPRange) -> NSRange) -> [DocumentSymbol] {
        guard let list = result as? [[String: Any]] else { return [] }
        func symbol(_ object: [String: Any]) -> DocumentSymbol? {
            guard let name = object["name"] as? String,
                  let lspRange = LSPRange(json: object["range"]) ?? LSPRange(json: (object["location"] as? [String: Any])?["range"])
            else { return nil }
            let kind = (object["kind"] as? Int).flatMap(Kind.init) ?? .variable
            let selection = LSPRange(json: object["selectionRange"]).map(range)
            let children = (object["children"] as? [[String: Any]] ?? []).compactMap(symbol)
            return DocumentSymbol(name: name, detail: object["detail"] as? String ?? object["containerName"] as? String,
                                  kind: kind, range: range(lspRange), selectionRange: selection, children: children)
        }
        let symbols = list.compactMap(symbol)
        let isFlat = list.first?["location"] != nil
        return identified(isFlat ? nest(symbols) : symbols)
    }

    /// Flat symbols as a tree: each inside the smallest one containing it.
    static func nest(_ flat: [DocumentSymbol]) -> [DocumentSymbol] {
        let sorted = flat.sorted { ($0.range.location, -$0.range.length) < ($1.range.location, -$1.range.length) }
        var roots: [DocumentSymbol] = []
        func insert(_ symbol: DocumentSymbol, into list: inout [DocumentSymbol]) {
            if let index = list.lastIndex(where: { NSIntersectionRange($0.range, symbol.range) == symbol.range && $0.range != symbol.range }) {
                insert(symbol, into: &list[index].children)
            } else {
                list.append(symbol)
            }
        }
        for symbol in sorted {
            var symbol = symbol
            symbol.detail = nil
            insert(symbol, into: &roots)
        }
        return roots
    }

    // MARK: Markdown

    /// Headings, nested by level (outside fenced code).
    static func markdown(_ text: NSString) -> [DocumentSymbol] {
        var flat: [(level: Int, symbol: DocumentSymbol)] = []
        var inFence = false
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = text.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return }
            guard !inFence, line.hasPrefix("#") else { return }
            let level = line.prefix { $0 == "#" }.count
            guard level <= 6, line.count == level || line.dropFirst(level).first == " " else { return }
            let title = line.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
            guard !title.isEmpty else { return }
            flat.append((level, DocumentSymbol(name: title, kind: .string, range: lineRange)))
        }
        // Each heading's section runs to the next heading of its level or above.
        var symbols: [(level: Int, symbol: DocumentSymbol)] = []
        for (index, entry) in flat.enumerated() {
            let end = flat[(index + 1)...].first { $0.level <= entry.level }?.symbol.range.location ?? text.length
            var symbol = entry.symbol
            symbol.selectionRange = entry.symbol.range
            symbol.range = NSRange(location: entry.symbol.range.location, length: end - entry.symbol.range.location)
            symbols.append((entry.level, symbol))
        }
        return identified(nest(symbols.map(\.symbol)))
    }
}

// MARK: Tree-sitter

extension SyntaxEngine {
    /// The declarations in the parsed file (when no language server gives them).
    func outline(for language: SourceLanguage) -> [DocumentSymbol] {
        guard let root = currentRoot else { return [] }
        let text = currentText
        var symbols: [DocumentSymbol] = []
        Outline.walk(root, language: language, text: text, into: &symbols)
        return DocumentSymbol.identified(symbols)
    }
}

/// Which syntax nodes are declarations, per language.
enum Outline {
    typealias Kind = DocumentSymbol.Kind

    private static func text(_ node: Node?, _ text: NSString) -> String? {
        guard let node, NSMaxRange(node.range) <= text.length else { return nil }
        return text.substring(with: node.range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The node's symbol (name, kind, name node), if it's a declaration.
    private static func declaration(_ node: Node, language: SourceLanguage, text source: NSString) -> (String, Kind, Node?)? {
        guard let type = node.nodeType else { return nil }
        let name = node.child(byFieldName: "name")
        func named(_ kind: Kind) -> (String, Kind, Node?)? { text(name, source).map { ($0, kind, name) } }
        switch language {
        case .swift:
            switch type {
            case "class_declaration":
                let keyword = node.child(byFieldName: "declaration_kind").flatMap { text($0, source) } ?? "class"
                let kind: Kind = switch keyword { case "struct": .struct; case "enum": .enum; case "extension": .namespace; default: .class }
                return named(kind)
            case "protocol_declaration": return named(.interface)
            case "function_declaration", "protocol_function_declaration":
                let parent = node.parent?.nodeType ?? ""
                return named(parent.hasSuffix("_body") ? .method : .function)
            case "init_declaration": return ("init", .constructor, nil)
            case "deinit_declaration": return ("deinit", .constructor, nil)
            case "subscript_declaration": return ("subscript", .method, nil)
            case "typealias_declaration": return named(.typeParameter)
            case "enum_entry": return named(.enumMember)
            case "property_declaration", "protocol_property_declaration":
                // Members and globals, not locals inside functions.
                let parent = node.parent?.nodeType ?? ""
                guard parent.hasSuffix("_body") && !parent.contains("function") || parent == "source_file" else { return nil }
                let pattern = node.child(byFieldName: "name")
                return text(pattern, source).map { ($0, parent == "source_file" ? .variable : .property, pattern) }
            default: return nil
            }
        case .python:
            switch type {
            case "class_definition": return named(.class)
            case "function_definition":
                return named(node.parent?.parent?.nodeType == "class_definition" ? .method : .function)
            default: return nil
            }
        case .javascript, .typescript, .tsx:
            switch type {
            case "class_declaration", "abstract_class_declaration", "class": return named(.class)
            case "function_declaration", "generator_function_declaration": return named(.function)
            case "method_definition", "method_signature", "abstract_method_signature": return named(.method)
            case "interface_declaration": return named(.interface)
            case "type_alias_declaration": return named(.typeParameter)
            case "enum_declaration": return named(.enum)
            case "module", "internal_module": return named(.module)
            case "public_field_definition", "field_definition", "property_signature":
                let field = node.child(byFieldName: "name") ?? node.child(byFieldName: "property")
                return text(field, source).map { ($0, .property, field) }
            case "variable_declarator":
                // const handler = () => {} : a function; top-level constants too.
                let value = node.child(byFieldName: "value")?.nodeType ?? ""
                if value.contains("function") { return named(.function) }
                let declaration = node.parent
                guard declaration?.parent?.nodeType == "program" || declaration?.parent?.nodeType == "export_statement" else { return nil }
                return named(.constant)
            default: return nil
            }
        case .rust:
            switch type {
            case "function_item", "function_signature_item":
                // In an impl or a trait: a method (a mod's body is a declaration list too).
                let owner = node.parent?.nodeType == "declaration_list" ? node.parent?.parent?.nodeType : nil
                return named(owner == "impl_item" || owner == "trait_item" ? .method : .function)
            case "struct_item": return named(.struct)
            case "enum_item": return named(.enum)
            case "union_item": return named(.struct)
            case "trait_item": return named(.interface)
            case "mod_item": return named(.module)
            case "const_item", "static_item": return named(.constant)
            case "type_item": return named(.typeParameter)
            case "macro_definition": return named(.function)
            case "impl_item":
                let trait = text(node.child(byFieldName: "trait"), source)
                let target = text(node.child(byFieldName: "type"), source) ?? "impl"
                return (trait.map { "impl \($0) for \(target)" } ?? "impl \(target)", .namespace, node.child(byFieldName: "type"))
            case "enum_variant": return named(.enumMember)
            case "field_declaration": return named(.field)
            default: return nil
            }
        case .go:
            switch type {
            case "function_declaration": return named(.function)
            case "method_declaration":
                let receiver = node.child(byFieldName: "receiver").flatMap { text($0, source) } ?? ""
                let type = receiver.split(whereSeparator: { " *()".contains($0) }).last.map(String.init)
                return text(name, source).map { (type.map { "(\($0)) " } ?? "") + $0 }.map { ($0, .method, name) }
            case "type_spec":
                let body = node.child(byFieldName: "type")?.nodeType ?? ""
                return named(body == "struct_type" ? .struct : body == "interface_type" ? .interface : .typeParameter)
            case "const_spec": return named(.constant)
            case "var_spec": return node.parent?.parent?.nodeType == "source_file" ? named(.variable) : nil
            case "field_declaration": return named(.field)
            case "method_spec", "method_elem": return named(.method)
            default: return nil
            }
        default:
            return nil
        }
    }

    static func walk(_ node: Node, language: SourceLanguage, text: NSString, into symbols: inout [DocumentSymbol]) {
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index) else { continue }
            // Swift's `case north, south`: one entry, a symbol per name.
            if language == .swift, child.nodeType == "enum_entry" {
                for nameIndex in 0..<child.childCount where child.fieldNameForChild(at: nameIndex) == "name" {
                    guard let name = child.child(at: nameIndex) else { continue }
                    symbols.append(DocumentSymbol(name: self.text(name, text) ?? "", kind: .enumMember, range: child.range,
                                                  selectionRange: name.range))
                }
                continue
            }
            if let (name, kind, nameNode) = declaration(child, language: language, text: text) {
                var symbol = DocumentSymbol(name: name, kind: kind, range: child.range, selectionRange: nameNode?.range ?? child.range)
                walk(child, language: language, text: text, into: &symbol.children)
                symbols.append(symbol)
            } else {
                walk(child, language: language, text: text, into: &symbols)
            }
        }
    }
}
