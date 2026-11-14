import AppKit
import Testing
@testable import Oh_My_Code

/// "name kind" lines, indented by depth.
private func describe(_ symbols: [DocumentSymbol], depth: Int = 0) -> [String] {
    symbols.flatMap { [String(repeating: "  ", count: depth) + "\($0.name) \($0.kind)"] + describe($0.children, depth: depth + 1) }
}

@MainActor
struct OutlineTests {
    private func outline(_ text: String, _ language: SourceLanguage) async -> [DocumentSymbol] {
        let storage = NSTextStorage(string: text)
        guard let highlighter = SyntaxHighlighter(language: language, textStorage: storage) else { return [] }
        return await highlighter.outline(for: language)
    }

    @Test func readsSwiftDeclarations() async {
        let symbols = await outline("""
        import Foundation

        let globalValue = 1

        protocol Shape {
            func area() -> Double
        }

        struct Circle: Shape {
            var radius: Double
            init(radius: Double) { self.radius = radius }
            func area() -> Double {
                let local = radius * radius
                func helper() {}
                return local
            }
        }

        enum Direction { case north, south }

        extension Circle {
            static func unit() -> Circle { Circle(radius: 1) }
        }

        func main() {}
        """, .swift)
        #expect(describe(symbols) == [
            "globalValue variable",
            "Shape interface", "  area method",
            "Circle struct", "  radius property", "  init constructor", "  area method", "    helper function",
            "Direction enum", "  north enumMember", "  south enumMember",
            "Circle namespace", "  unit method",
            "main function",
        ])
        // The name is selected; the whole declaration is the range.
        let circle = symbols[2]
        #expect(circle.selectionRange.length == 6 && circle.range.length > 50)
        #expect(Set(DocumentSymbol.flattened(symbols).map(\.symbol.id)).count == DocumentSymbol.flattened(symbols).count)
    }

    @Test func readsOtherLanguages() async {
        let python = describe(await outline("""
        class Greeter:
            def __init__(self, name):
                self.name = name

            def greet(self):
                def shout(text):
                    return text.upper()
                return shout(self.name)

        def main():
            pass
        """, .python))
        #expect(python == ["Greeter class", "  __init__ method", "  greet method", "    shout function", "main function"])

        let typeScript = describe(await outline("""
        export interface Point { x: number; y: number }
        export class Store {
          items: string[] = [];
          add(item: string) { this.items.push(item); }
        }
        export const handler = () => { const inner = 1; };
        const LIMIT = 10;
        function helper() {}
        enum Color { Red }
        type Id = string;
        """, .typescript))
        #expect(typeScript == ["Point interface", "  x property", "  y property", "Store class", "  items property", "  add method",
                                "handler function", "LIMIT constant", "helper function", "Color enum", "Id typeParameter"])

        let rust = describe(await outline("""
        pub struct Stack { items: Vec<i32> }
        impl Stack {
            pub fn push(&mut self, value: i32) { self.items.push(value); }
        }
        trait Shape { fn area(&self) -> f64; }
        impl Shape for Stack { fn area(&self) -> f64 { 0.0 } }
        mod tests {
            fn helper() {}
        }
        """, .rust))
        #expect(rust == ["Stack struct", "  items field", "impl Stack namespace", "  push method", "Shape interface", "  area method",
                          "impl Shape for Stack namespace", "  area method", "tests module", "  helper function"])

        let go = describe(await outline("""
        package calc

        type Calculator struct { total int }
        type Shape interface { Area() float64 }
        const Pi = 3.14
        func (c *Calculator) Add(n int) { c.total += n }
        func New() *Calculator { return &Calculator{} }
        """, .go))
        #expect(go == ["Calculator struct", "  total field", "Shape interface", "  Area method", "Pi constant",
                        "(Calculator) Add method", "New function"])
    }

    @Test func readsMarkdownHeadings() {
        let symbols = DocumentSymbol.markdown("""
        # Title
        text
        ## Install
        ```
        # not a heading
        ```
        ### From source
        ## Use
        #nospace
        # Appendix
        """ as NSString)
        #expect(describe(symbols) == ["Title string", "  Install string", "    From source string", "  Use string", "Appendix string"])
        // A section runs to the next heading at its level or above.
        let install = symbols[0].children[0]
        #expect(install.range.location == 13 && NSMaxRange(install.range) == symbols[0].children[1].range.location)
    }

    @Test func readsLanguageServerSymbols() {
        let ranges: (LSPRange) -> NSRange = { NSRange(location: $0.start.line * 100 + $0.start.character, length: ($0.end.line - $0.start.line) * 100 + $0.end.character - $0.start.character) }
        func range(_ startLine: Int, _ endLine: Int) -> [String: Any] {
            ["start": ["line": startLine, "character": 0], "end": ["line": endLine, "character": 0]]
        }
        let nested: [[String: Any]] = [["name": "Store", "kind": 5, "range": range(0, 9), "selectionRange": range(0, 0),
                                         "children": [["name": "add", "kind": 6, "detail": "(String)", "range": range(2, 4), "selectionRange": range(2, 2)]]]]
        let symbols = DocumentSymbol.fromLSP(nested, range: ranges)
        #expect(describe(symbols) == ["Store class", "  add method"] && symbols[0].children[0].detail == "(String)")

        // SymbolInformation (flat): nested by where they are.
        let flat: [[String: Any]] = [
            ["name": "add", "kind": 6, "location": ["uri": "file:///a", "range": range(2, 4)], "containerName": "Store"],
            ["name": "Store", "kind": 5, "location": ["uri": "file:///a", "range": range(0, 9)]],
            ["name": "main", "kind": 12, "location": ["uri": "file:///a", "range": range(10, 12)]],
        ]
        #expect(describe(DocumentSymbol.fromLSP(flat, range: ranges)) == ["Store class", "  add method", "main function"])
        #expect(DocumentSymbol.fromLSP(nil, range: ranges).isEmpty)

        // The path to an offset: the symbols containing it.
        #expect(DocumentSymbol.path(to: 250, in: symbols).map(\.name) == ["Store", "add"])
        #expect(DocumentSymbol.path(to: 950, in: symbols).isEmpty)
    }

    @Test func documentsKeepTheirSymbolsCurrent() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(text: "func alpha() {}\nfunc beta() {}\n")
        // From the server (the syntax tree's list comes first, without details).
        #expect(try await LanguageClientTests.eventually { document.symbols.map(\.name) == ["alpha", "beta"] && document.symbols[0].detail == "fake" })
        // An edit: the list follows.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "func zero() {}\n")
        #expect(try await LanguageClientTests.eventually { document.symbols.map(\.name) == ["zero", "alpha", "beta"] })

        // The cursor in beta: breadcrumbs and the outline know.
        controller.textView.setSelectedRange(NSRange(location: 36, length: 0))
        #expect(document.symbolPathAtCursor.map(\.name) == ["beta"])

        // Go to Symbol (@): matching names; choosing one selects its name.
        workspace.showPalette(.symbols)
        let palette = try #require(workspace.palette)
        #expect(palette.items.map(\.title) == ["zero", "alpha", "beta"])
        palette.query = "@alp"
        #expect(palette.items.map(\.title) == ["alpha"])
        palette.acceptSelection()
        #expect(controller.textView.selectedRange() == NSRange(location: 20, length: 5))
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func filesWithoutAServerUseTheSyntaxTree() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-outline-\(UUID().uuidString).py")
        try "def one():\n    pass\n".write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        await document.waitForSymbols()
        #expect(document.symbols.map(\.name) == ["one"])
        document.textStorage.replaceCharacters(in: NSRange(location: document.textStorage.length, length: 0), with: "\nclass Two:\n    pass\n")
        let deadline = ContinuousClock.now + .seconds(5)
        while document.symbols.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(document.symbols.map(\.name) == ["one", "Two"])
    }
}
