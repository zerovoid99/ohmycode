import Foundation
import SwiftTreeSitter
import Testing
@testable import Oh_My_Code

/// The outline read with a tree cursor is the one read node by node (`namedChild(at:)` and
/// `parent`, kept below as it was): same symbols, kinds, ranges and nesting.
struct OutlineEquivalenceTests {
    private static let samples: [(SourceLanguage, String)] = [
        (.python, """
        import os

        class Greeter(Base):
            \"\"\"Says hello.\"\"\"
            def __init__(self, name):
                self.name = name

            @property
            def greet(self):
                def shout(text):
                    class Local:
                        def inner(self): pass
                    return text.upper()
                return shout(self.name)

        def main():
            items = [lambda x: x for _ in range(3)]
            if True:
                def conditional(): pass

        async def fetch(url): ...
        """),
        (.javascript, """
        export default class Store extends Base {
          #items = [];
          static count = 0;
          add(item) { this.#items.push(item); }
          get size() { return this.#items.length; }
        }
        export const handler = () => { const inner = 1; function nested() {} };
        const LIMIT = 10, other = function named() {};
        let mutable = 1;
        function* generate() { yield 1; }
        describe("suite", () => {
          function helper() {}
          const local = () => {};
          it("works", function () { class Inside {} });
        });
        const object = { method() {}, arrow: () => {} };
        """),
        (.typescript, """
        export interface Point { x: number; y?: number; move(dx: number): void }
        export abstract class Shape<T> implements Drawable {
          private items: string[] = [];
          abstract area(): number;
          constructor(readonly name: string) { super(); }
          add(item: string) { this.items.push(item); }
        }
        export const handler = async () => { const inner = 1; };
        declare module "lib" { export function f(): void; }
        namespace Inner { export const value = 1; class Hidden {} }
        enum Color { Red, Green = 2 }
        type Id = string | number;
        function overloaded(a: string): void;
        function overloaded(a: any) {}
        """),
        (.tsx, """
        import React from "react";
        export function App({ title }: Props) {
          const [state, setState] = React.useState(0);
          const onClick = () => setState(state + 1);
          return <div onClick={onClick}>{title}</div>;
        }
        export default class Old extends React.Component { render() { return <span/>; } }
        const Styled = styled.div`color: red;`;
        """),
        (.rust, """
        pub struct Stack<T> { items: Vec<T>, pub count: usize }
        pub enum Op { Push(i32), Pop, Named { value: i32 } }
        union Bits { i: u32, f: f32 }
        impl<T> Stack<T> {
            pub const MAX: usize = 10;
            pub fn push(&mut self, value: T) { fn local() {} self.items.push(value); }
        }
        trait Shape { fn area(&self) -> f64; type Output; }
        impl Shape for Stack<i32> { fn area(&self) -> f64 { 0.0 } type Output = (); }
        mod tests {
            use super::*;
            fn helper() {}
            mod deeper { static COUNT: i32 = 0; }
        }
        macro_rules! square { ($x:expr) => { $x * $x }; }
        type Alias = Vec<u8>;
        fn main() { let closure = |x| { x + 1 }; }
        """),
        (.go, """
        package calc

        import "fmt"

        type Calculator struct { total int; name string }
        type Shape interface { Area() float64; fmt.Stringer }
        type ID = string
        const Pi = 3.14
        const (
            A = iota
            B
        )
        var global = 1
        var (
            x, y int
        )
        func (c *Calculator) Add(n int) { var local = n; c.total += local }
        func (Calculator) Name() string { return "" }
        func New() *Calculator { f := func() {}; f(); return &Calculator{} }
        """),
        (.swift, """
        enum Direction { case north, south; case east(Int), west }
        struct S { var a = 1, b = 2; let (c, d) = (1, 2); subscript(i: Int) -> Int { i } }
        protocol P { var value: Int { get }; func f(); associatedtype T; init() }
        actor A { deinit {} ; nonisolated func g() {} }
        extension Array where Element: P { func h() { struct Local { func deep() {} } } }
        func outer() { func inner() { func innermost() {} } ; let closure = { func inClosure() {} } }
        typealias Alias = [Int]
        @MainActor final class C<T>: NSObject { @objc dynamic var x = 0; override init() {} }
        var computed: Int { get { 1 } set {} }
        """),
    ]

    /// Every Swift file of the app and its tests, and the samples.
    private static func corpus() throws -> [(SourceLanguage, String, String)] {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var files: [(SourceLanguage, String, String)] = samples.enumerated().map { ($0.element.0, "sample \($0.offset)", $0.element.1) }
        for folder in ["OhMyCode", "OhMyCodeTests", "ExtensionAPI"] {
            let enumerator = FileManager.default.enumerator(at: repository.appending(path: folder), includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let language = SourceLanguage(fileExtension: url.pathExtension)
                guard GrammarRegistry.treeSitterLanguage(for: language) != nil,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                files.append((language, url.lastPathComponent, text))
            }
        }
        return files
    }

    @Test func cursorWalkFindsTheSameSymbolsAsTheNodeWalk() throws {
        var parsers: [SourceLanguage: Parser] = [:]
        var symbolCount = 0, fileCount = 0
        var languages = Set<SourceLanguage>()
        for (language, name, text) in try Self.corpus() {
            let parser = try parsers[language] ?? {
                let parser = Parser()
                try parser.setLanguage(try #require(GrammarRegistry.treeSitterLanguage(for: language)))
                parsers[language] = parser
                return parser
            }()
            let root = try #require(parser.parse(text)?.rootNode)
            var expected: [DocumentSymbol] = [], actual: [DocumentSymbol] = []
            ReferenceOutline.walk(root, language: language, text: text as NSString, into: &expected)
            Outline.walk(root, language: language, text: text as NSString, into: &actual)
            #expect(actual == expected, "\(name)")
            symbolCount += DocumentSymbol.flattened(expected).count
            fileCount += 1
            languages.insert(language)
        }
        // The corpus is what it should be: the app's sources, every language.
        #expect(fileCount > 200 && symbolCount > 5_000)
        #expect(languages.isSuperset(of: [.swift, .python, .javascript, .typescript, .tsx, .rust, .go]))
    }
}

// MARK: The outline as it was read before (node by node)

/// Which syntax nodes are declarations, per language (the node-by-node walk).
enum ReferenceOutline {
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
