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

    /// How a node type's declarations are read. Chosen once per node type (`rule(for:)`), then
    /// applied to each node of that type (`declaration`).
    enum Rule {
        /// Named by its "name" field.
        case named(Kind)
        /// The same name for all.
        case fixed(String, Kind)
        case swiftType, swiftFunction, swiftProperty
        case pythonFunction
        case scriptField, scriptVariable
        case rustFunction, rustImpl
        case goMethod, goType, goVariable
    }

    /// The rule for nodes of `type`; nil when they're never declarations.
    static func rule(for type: String, language: SourceLanguage) -> Rule? {
        switch language {
        case .swift:
            switch type {
            case "class_declaration": .swiftType
            case "protocol_declaration": .named(.interface)
            case "function_declaration", "protocol_function_declaration": .swiftFunction
            case "init_declaration": .fixed("init", .constructor)
            case "deinit_declaration": .fixed("deinit", .constructor)
            case "subscript_declaration": .fixed("subscript", .method)
            case "typealias_declaration": .named(.typeParameter)
            case "enum_entry": .named(.enumMember)
            case "property_declaration", "protocol_property_declaration": .swiftProperty
            default: nil
            }
        case .python:
            switch type {
            case "class_definition": .named(.class)
            case "function_definition": .pythonFunction
            default: nil
            }
        case .javascript, .typescript, .tsx:
            switch type {
            case "class_declaration", "abstract_class_declaration", "class": .named(.class)
            case "function_declaration", "generator_function_declaration": .named(.function)
            case "method_definition", "method_signature", "abstract_method_signature": .named(.method)
            case "interface_declaration": .named(.interface)
            case "type_alias_declaration": .named(.typeParameter)
            case "enum_declaration": .named(.enum)
            case "module", "internal_module": .named(.module)
            case "public_field_definition", "field_definition", "property_signature": .scriptField
            case "variable_declarator": .scriptVariable
            default: nil
            }
        case .rust:
            switch type {
            case "function_item", "function_signature_item": .rustFunction
            case "struct_item": .named(.struct)
            case "enum_item": .named(.enum)
            case "union_item": .named(.struct)
            case "trait_item": .named(.interface)
            case "mod_item": .named(.module)
            case "const_item", "static_item": .named(.constant)
            case "type_item": .named(.typeParameter)
            case "macro_definition": .named(.function)
            case "impl_item": .rustImpl
            case "enum_variant": .named(.enumMember)
            case "field_declaration": .named(.field)
            default: nil
            }
        case .go:
            switch type {
            case "function_declaration": .named(.function)
            case "method_declaration": .goMethod
            case "type_spec": .goType
            case "const_spec": .named(.constant)
            case "var_spec": .goVariable
            case "field_declaration": .named(.field)
            case "method_spec", "method_elem": .named(.method)
            default: nil
            }
        default:
            nil
        }
    }

    /// The node's symbol (name, kind, name node), if it's a declaration. `parent` and
    /// `grandparent` are the types of the nodes it's in (the walk knows them: `Node.parent`
    /// searches down from the root).
    static func declaration(_ node: Node, rule: Rule, parent: String?, grandparent: String?,
                            text source: NSString) -> (String, Kind, Node?)? {
        // Looked up for declarations only: a field lookup goes through the node's children.
        func named(_ kind: Kind) -> (String, Kind, Node?)? {
            let name = node.child(byFieldName: "name")
            return text(name, source).map { ($0, kind, name) }
        }
        switch rule {
        case .named(let kind):
            return named(kind)
        case .fixed(let name, let kind):
            return (name, kind, nil)
        case .swiftType:
            let keyword = node.child(byFieldName: "declaration_kind").flatMap { text($0, source) } ?? "class"
            let kind: Kind = switch keyword { case "struct": .struct; case "enum": .enum; case "extension": .namespace; default: .class }
            return named(kind)
        case .swiftFunction:
            return named((parent ?? "").hasSuffix("_body") ? .method : .function)
        case .swiftProperty:
            // Members and globals, not locals inside functions.
            let parent = parent ?? ""
            guard parent.hasSuffix("_body") && !parent.contains("function") || parent == "source_file" else { return nil }
            let pattern = node.child(byFieldName: "name")
            return text(pattern, source).map { ($0, parent == "source_file" ? .variable : .property, pattern) }
        case .pythonFunction:
            return named(grandparent == "class_definition" ? .method : .function)
        case .scriptField:
            let field = node.child(byFieldName: "name") ?? node.child(byFieldName: "property")
            return text(field, source).map { ($0, .property, field) }
        case .scriptVariable:
            // const handler = () => {} : a function; top-level constants too.
            let value = node.child(byFieldName: "value")?.nodeType ?? ""
            if value.contains("function") { return named(.function) }
            // Its declaration's parent.
            guard grandparent == "program" || grandparent == "export_statement" else { return nil }
            return named(.constant)
        case .rustFunction:
            // In an impl or a trait: a method (a mod's body is a declaration list too).
            let owner = parent == "declaration_list" ? grandparent : nil
            return named(owner == "impl_item" || owner == "trait_item" ? .method : .function)
        case .rustImpl:
            let trait = text(node.child(byFieldName: "trait"), source)
            let target = text(node.child(byFieldName: "type"), source) ?? "impl"
            return (trait.map { "impl \($0) for \(target)" } ?? "impl \(target)", .namespace, node.child(byFieldName: "type"))
        case .goMethod:
            let receiver = node.child(byFieldName: "receiver").flatMap { text($0, source) } ?? ""
            let type = receiver.split(whereSeparator: { " *()".contains($0) }).last.map(String.init)
            let name = node.child(byFieldName: "name")
            return text(name, source).map { (type.map { "(\($0)) " } ?? "") + $0 }.map { ($0, .method, name) }
        case .goType:
            let body = node.child(byFieldName: "type")?.nodeType ?? ""
            return named(body == "struct_type" ? .struct : body == "interface_type" ? .interface : .typeParameter)
        case .goVariable:
            return grandparent == "source_file" ? named(.variable) : nil
        }
    }

    /// What the walk knows of a node type (tree-sitter's symbol number): its name, and how
    /// its declarations are read. Looked up once per type: a type's name is a C string, and
    /// matching it against the rules' names took most of the walk.
    private struct NodeType {
        let name: String
        let rule: Rule?
        /// Swift's `case north, south`.
        let isSwiftEnumEntry: Bool
        /// Nothing under nodes of this type can be a declaration: the walk doesn't go in.
        let isOpaque: Bool
    }

    /// Node types nothing under which can be a declaration, where it's worth knowing (a big
    /// share of the tree). Not expressions where they may hold a closure with a function in it
    /// (Swift, JavaScript, Rust, Go), nor types where they may hold fields (TypeScript, Go).
    private static func isOpaque(_ type: String, language: SourceLanguage) -> Bool {
        switch language {
        case .swift:
            // Types, a member's name after a dot, an argument's label.
            ["type_annotation", "user_type", "optional_type", "array_type", "dictionary_type", "tuple_type", "function_type",
             "inheritance_specifier", "type_arguments", "type_parameters", "type_constraints", "navigation_suffix",
             "value_argument_label", "import_declaration"].contains(type)
        case .python:
            // `def` and `class` are statements: an expression (a lambda is one) has none inside.
            ["expression_statement", "return_statement", "decorator", "parameters", "argument_list", "import_statement",
             "import_from_statement", "assert_statement", "raise_statement", "delete_statement"].contains(type)
        default:
            false
        }
    }

    /// The declarations in `node`, nested (into `symbols`).
    static func walk(_ node: Node, language: SourceLanguage, text: NSString, into symbols: inout [DocumentSymbol]) {
        // With a cursor: `namedChild(at:)` counts from the first child each time (k² for k
        // children), and `parent` searches down from the root.
        var types: [Int: NodeType] = [:]
        walkChildren(node.treeCursor, parent: node.nodeType, grandparent: node.parent?.nodeType,
                     language: language, text: text, types: &types, into: &symbols)
    }

    /// The named children of the cursor's node, and theirs. The cursor is back on the node after.
    private static func walkChildren(_ cursor: TreeCursor, parent: String?, grandparent: String?, language: SourceLanguage,
                                     text: NSString, types: inout [Int: NodeType], into symbols: inout [DocumentSymbol]) {
        guard cursor.goToFirstChild() else { return }
        defer { _ = cursor.gotoParent() }
        repeat {
            guard let child = cursor.currentNode, child.isNamed else { continue }
            let symbol = child.symbol
            let type: NodeType
            if let known = types[symbol] {
                type = known
            } else {
                let name = child.nodeType ?? ""
                type = NodeType(name: name, rule: rule(for: name, language: language), isSwiftEnumEntry: language == .swift && name == "enum_entry",
                                isOpaque: isOpaque(name, language: language))
                types[symbol] = type
            }
            if type.isOpaque { continue }
            // Swift's `case north, south`: one entry, a symbol per name.
            if type.isSwiftEnumEntry {
                for nameIndex in 0..<child.childCount where child.fieldNameForChild(at: nameIndex) == "name" {
                    guard let name = child.child(at: nameIndex) else { continue }
                    symbols.append(DocumentSymbol(name: self.text(name, text) ?? "", kind: .enumMember, range: child.range,
                                                  selectionRange: name.range))
                }
                continue
            }
            if let rule = type.rule,
               let (name, kind, nameNode) = declaration(child, rule: rule, parent: parent, grandparent: grandparent, text: text) {
                var symbol = DocumentSymbol(name: name, kind: kind, range: child.range, selectionRange: nameNode?.range ?? child.range)
                walkChildren(cursor, parent: type.name, grandparent: parent, language: language, text: text, types: &types,
                             into: &symbol.children)
                symbols.append(symbol)
            } else {
                walkChildren(cursor, parent: type.name, grandparent: parent, language: language, text: text, types: &types,
                             into: &symbols)
            }
        } while cursor.gotoNextSibling()
    }
}
