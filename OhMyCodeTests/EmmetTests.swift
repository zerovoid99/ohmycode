import AppKit
import Testing
@testable import Oh_My_Code

struct EmmetMarkupTests {
    /// The text an abbreviation expands to (the snippet's stops left empty).
    private func html(_ abbreviation: String, _ syntax: Emmet.Syntax = .html) -> String? {
        Emmet.expandMarkup(abbreviation, syntax: syntax).map { ParsedSnippet($0).text }
    }

    @Test(arguments: [
        // Tags, children, siblings, climbing, multiplying, groups.
        ("div", "<div></div>"),
        ("p", "<p></p>"),
        ("custom-el", "<custom-el></custom-el>"),
        ("div>p", "<div>\n\t<p></p>\n</div>"),
        ("div+p", "<div></div>\n<p></p>"),
        ("div>p>span", "<div>\n\t<p><span></span></p>\n</div>"),
        ("div>p^h1", "<div>\n\t<p></p>\n</div>\n<h1></h1>"),
        ("div>div>p^^h1", "<div>\n\t<div>\n\t\t<p></p>\n\t</div>\n</div>\n<h1></h1>"),
        ("ul>li*3", "<ul>\n\t<li></li>\n\t<li></li>\n\t<li></li>\n</ul>"),
        ("div>(header>nav)+footer", "<div>\n\t<header>\n\t\t<nav></nav>\n\t</header>\n\t<footer></footer>\n</div>"),
        ("(dt+dd)*2", "<dt></dt>\n<dd></dd>\n<dt></dt>\n<dd></dd>"),
        // Ids, classes, attributes, text.
        ("div#main", "<div id=\"main\"></div>"),
        ("div.a.b", "<div class=\"a b\"></div>"),
        ("div#x.y", "<div id=\"x\" class=\"y\"></div>"),
        ("p[title=hi data-x=\"a b\"]", "<p title=\"hi\" data-x=\"a b\"></p>"),
        ("td[colspan=2]", "<td colspan=\"2\"></td>"),
        ("p{Hello world}", "<p>Hello world</p>"),
        ("a{Click}", "<a href=\"\">Click</a>"),
        ("{just text}", "just text"),
        ("p>{Click }+a{here}+{ now}", "<p>Click <a href=\"\">here</a> now</p>"),
        // Numbering.
        ("li.item$*3", "<li class=\"item1\"></li>\n<li class=\"item2\"></li>\n<li class=\"item3\"></li>"),
        ("li.item$$*2", "<li class=\"item01\"></li>\n<li class=\"item02\"></li>"),
        ("li{$@-}*3", "<li>3</li>\n<li>2</li>\n<li>1</li>"),
        ("li{$@3}*2", "<li>3</li>\n<li>4</li>"),
        ("li{$@-5}*2", "<li>6</li>\n<li>5</li>"),
        ("h$*2", "<h1></h1>\n<h2></h2>"),
        ("ul>li.i$*2>a{Item $}", "<ul>\n\t<li class=\"i1\"><a href=\"\">Item 1</a></li>\n\t<li class=\"i2\"><a href=\"\">Item 2</a></li>\n</ul>"),
        // Implicit tags.
        (".a", "<div class=\"a\"></div>"),
        ("#x", "<div id=\"x\"></div>"),
        ("ul>.item", "<ul>\n\t<li class=\"item\"></li>\n</ul>"),
        ("ol>.a*2", "<ol>\n\t<li class=\"a\"></li>\n\t<li class=\"a\"></li>\n</ol>"),
        ("table>.row>.cell", "<table>\n\t<tr class=\"row\">\n\t\t<td class=\"cell\"></td>\n\t</tr>\n</table>"),
        ("select>.o", "<select name=\"\" id=\"\">\n\t<option class=\"o\"></option>\n</select>"),
        ("span>.x", "<span><span class=\"x\"></span></span>"),
        ("em>.x", "<em><span class=\"x\"></span></em>"),
        // Void elements and snippets.
        ("br", "<br>"),
        ("img", "<img src=\"\" alt=\"\">"),
        ("input", "<input type=\"text\">"),
        ("input:email", "<input type=\"email\" name=\"\" id=\"\">"),
        ("input:c", "<input type=\"checkbox\" name=\"\" id=\"\">"),
        ("input[disabled]", "<input type=\"text\" disabled>"),
        ("hr/", "<hr>"),
        ("div/", "<div>"),
        ("a", "<a href=\"\"></a>"),
        ("a.btn", "<a href=\"\" class=\"btn\"></a>"),
        ("a[href=/home]", "<a href=\"/home\"></a>"),
        ("a:mail", "<a href=\"mailto:\"></a>"),
        ("link:css", "<link rel=\"stylesheet\" href=\"style.css\">"),
        ("link", "<link rel=\"stylesheet\" href=\"\">"),
        ("script:src", "<script src=\"\"></script>"),
        ("form", "<form action=\"\"></form>"),
        ("form:post", "<form action=\"\" method=\"post\"></form>"),
        ("label", "<label for=\"\"></label>"),
        ("btn:s", "<button type=\"submit\"></button>"),
        ("textarea", "<textarea name=\"\" id=\"\" cols=\"30\" rows=\"10\"></textarea>"),
        ("meta:vp", "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"),
        ("bq", "<blockquote></blockquote>"),
        ("ul+", "<ul>\n\t<li></li>\n</ul>"),
        ("ul+>.x", "<ul>\n\t<li>\n\t\t<div class=\"x\"></div>\n\t</li>\n</ul>"),
        ("dl+", "<dl>\n\t<dt></dt>\n\t<dd></dd>\n</dl>"),
        ("table+", "<table>\n\t<tr>\n\t\t<td></td>\n\t</tr>\n</table>"),
        ("c", "<!--  -->"),
        // Inline elements stay on one line; three or more inline siblings break.
        ("p>a+span", "<p><a href=\"\"></a><span></span></p>"),
        ("p>span*3", "<p>\n\t<span></span>\n\t<span></span>\n\t<span></span>\n</p>"),
        ("p>b+div", "<p>\n\t<b></b>\n\t<div></div>\n</p>"),
        ("a>div", "<a href=\"\">\n\t<div></div>\n</a>"),
        ("div{t}>p", "<div>t\n\t<p></p>\n</div>"),
        ("nav>ul>li*2>a", "<nav>\n\t<ul>\n\t\t<li><a href=\"\"></a></li>\n\t\t<li><a href=\"\"></a></li>\n\t</ul>\n</nav>"),
    ])
    func expandsMarkup(_ abbreviation: String, _ expected: String) {
        #expect(html(abbreviation) == expected, "\(abbreviation)")
    }

    @Test func documentSkeleton() {
        let expected = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        \t<meta charset="UTF-8">
        \t<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \t<title>Document</title>
        </head>
        <body>
        \t
        </body>
        </html>
        """
        #expect(html("!") == expected)
        #expect(html("html:5") == expected)
        // Stops: the title, then the body.
        let body = try? #require(Emmet.expandMarkup("!"))
        #expect(body?.contains("<title>${1:Document}</title>") == true)
        #expect(body?.contains("<body>\n\t${2}\n</body>") == true)
    }

    @Test func stopsForEmptyAttributesAndElements() {
        #expect(Emmet.expandMarkup("a") == "<a href=\"${1}\">${2}</a>")
        #expect(Emmet.expandMarkup("ul>li*2") == "<ul>\n\t<li>${1}</li>\n\t<li>${2}</li>\n</ul>")
        #expect(Emmet.expandMarkup("input") == "<input type=\"${1:text}\">")
        #expect(Emmet.expandMarkup("img") == "<img src=\"${1}\" alt=\"${2}\">")
        #expect(Emmet.expandMarkup("p{Cost: \\$5}") == "<p>Cost: \\$5</p>") // a literal "$", escaped for the snippet
        #expect(Emmet.expandMarkup("p{a\\}b}") == "<p>a\\}b</p>")
        #expect(Emmet.expandMarkup("br") == "<br>")
    }

    @Test func loremIpsum() throws {
        let text = try #require(html("lorem"))
        #expect(text.hasPrefix("Lorem ipsum dolor sit amet"))
        #expect(text.split(separator: " ").count == 30)
        #expect(text.hasSuffix("."))
        let five = try #require(html("p>lorem5"))
        #expect(five.hasPrefix("<p>Lorem ipsum") && five.hasSuffix("</p>"))
        #expect(five.dropFirst(3).dropLast(4).split(separator: " ").count == 5)
        let paragraphs = try #require(html("p*2>lorem4"))
        let lines = paragraphs.components(separatedBy: "\n")
        #expect(lines.count == 2 && lines[0] != lines[1])
    }

    @Test func jsxAndXML() {
        #expect(html("div.a", .jsx) == "<div className=\"a\"></div>")
        #expect(html("label[for=x]", .jsx) == "<label htmlFor=\"x\"></label>")
        #expect(html("img", .jsx) == "<img src=\"\" alt=\"\" />")
        #expect(html("br", .jsx) == "<br />")
        #expect(html("button[onClick={handle}]", .jsx) == "<button onClick={handle}></button>")
        #expect(html("Foo.bar", .jsx) == "<Foo className=\"bar\"></Foo>")
        #expect(html("item>name+value/", .xml) == "<item>\n\t<name></name>\n\t<value/>\n</item>")
        #expect(html("br", .xml) == "<br></br>")
    }

    @Test func wrapsTextAndLines() {
        func wrap(_ abbreviation: String, _ lines: [String]) -> String? {
            Emmet.expandMarkup(abbreviation, wrapping: lines).map { ParsedSnippet($0).text }
        }
        #expect(wrap("div", ["hello"]) == "<div>hello</div>")
        #expect(wrap("div.w>p", ["hello"]) == "<div class=\"w\">\n\t<p>hello</p>\n</div>")
        #expect(wrap("div", ["<p>a</p>", "<p>b</p>"]) == "<div>\n\t<p>a</p>\n\t<p>b</p>\n</div>")
        #expect(wrap("ul>li*", ["One", "  Two", "", "Three"]) == "<ul>\n\t<li>One</li>\n\t<li>Two</li>\n\t<li>Three</li>\n</ul>")
        #expect(wrap("ul>li.i$*>a", ["x", "y"]) == "<ul>\n\t<li class=\"i1\"><a href=\"\">x</a></li>\n\t<li class=\"i2\"><a href=\"\">y</a></li>\n</ul>")
        #expect(wrap("a", ["$5"]) == "<a href=\"\">$5</a>")
        #expect(Emmet.dedent("<p>a</p>\n    <p>b</p>", firstLineIndent: "    ") == ["<p>a</p>", "<p>b</p>"])
    }

    @Test(arguments: ["", "div>", "div+", "(div", "div)", "div[", "div{x", "div..a", "div#", ">div", "div*x"])
    func rejectsInvalid(_ abbreviation: String) {
        #expect(Emmet.expandMarkup(abbreviation) == nil, "\(abbreviation)")
    }

    @Test func confidentAbbreviations() {
        for yes in ["div", "ul>li*3", ".item", "#main", "p.lead", "a", "lorem", "lorem10", "!", "input:email", "my-el", "h2", "(a+b)*2", "{x}"] {
            #expect(Emmet.isConfidentMarkup(yes, syntax: .html), "\(yes)")
        }
        for no in ["hello", "word", "foo.bar", "e.g.", "3", "*2", "x>y", "Foo"] {
            #expect(!Emmet.isConfidentMarkup(no, syntax: .html), "\(no)")
        }
        #expect(Emmet.isConfidentMarkup("Card.x", syntax: .jsx))
        #expect(!Emmet.isConfidentMarkup("Card", syntax: .jsx))
        #expect(Emmet.isConfidentMarkup("item>name", syntax: .xml))
        #expect(!Emmet.isConfidentMarkup("item", syntax: .xml))
    }

    @Test func extractsFromALine() {
        func extract(_ line: String) -> String? { Emmet.extractMarkup(beforeCursor: line)?.abbreviation }
        #expect(extract("ul>li*3") == "ul>li*3")
        #expect(extract("    div.a") == "div.a")
        #expect(extract("some text p") == "p")
        #expect(extract("<p>a>b") == "a>b")
        #expect(extract("<div class=\"x\">span.y") == "span.y")
        #expect(extract("<p>") == nil)
        #expect(extract("x a[title=\"hello world\"]") == "a[title=\"hello world\"]")
        #expect(extract("p{some text here}") == "p{some text here}")
        #expect(extract("text p>{a b}+span") == "p>{a b}+span")
        #expect(extract("(ul>li)*2") == "(ul>li)*2")
        #expect(extract("x +div") == "div")
        #expect(extract("   ") == nil)
        #expect(extract("") == nil)
        #expect(extract("a]") == nil)
        #expect(Emmet.extractMarkup(beforeCursor: "  😀 div")?.start == 5) // UTF-16
    }
}

struct EmmetCSSTests {
    private func css(_ abbreviation: String) -> String? {
        Emmet.expandCSS(abbreviation).map { ParsedSnippet($0).text }
    }

    @Test(arguments: [
        ("m10", "margin: 10px;"),
        ("m10-20", "margin: 10px 20px;"),
        ("m10-20-30-40", "margin: 10px 20px 30px 40px;"),
        ("m-10", "margin: -10px;"),
        ("m10--20", "margin: 10px -20px;"),
        ("m0", "margin: 0;"),
        ("m0-a", "margin: 0 auto;"),
        ("m1.5", "margin: 1.5em;"),
        ("mt5", "margin-top: 5px;"),
        ("p10p", "padding: 10%;"),
        ("pl2e", "padding-left: 2em;"),
        ("pr1r", "padding-right: 1rem;"),
        ("pb3x", "padding-bottom: 3ex;"),
        ("w100p", "width: 100%;"),
        ("h100vh", "height: 100vh;"),
        ("maw960", "max-width: 960px;"),
        ("mah50p", "max-height: 50%;"),
        ("t0", "top: 0;"),
        ("l10", "left: 10px;"),
        ("z10", "z-index: 10;"),
        ("op.5", "opacity: .5;"),
        ("lh1.5", "line-height: 1.5;"),
        ("fw700", "font-weight: 700;"),
        ("fz16", "font-size: 16px;"),
        ("fz1.2r", "font-size: 1.2rem;"),
        ("bdrs4", "border-radius: 4px;"),
        ("gap8", "gap: 8px;"),
        ("c#f", "color: #fff;"),
        ("c#e0", "color: #e0e0e0;"),
        ("c#fc0", "color: #fc0;"),
        ("bgc#ffcc00", "background-color: #fc0;"),
        ("bd1-s-#000", "border: 1px solid #000;"),
        ("dn", "display: none;"),
        ("db", "display: block;"),
        ("dib", "display: inline-block;"),
        ("df", "display: flex;"),
        ("dg", "display: grid;"),
        ("posa", "position: absolute;"),
        ("posr", "position: relative;"),
        ("posf", "position: fixed;"),
        ("fwb", "font-weight: bold;"),
        ("tac", "text-align: center;"),
        ("jcsb", "justify-content: space-between;"),
        ("aic", "align-items: center;"),
        ("fxdc", "flex-direction: column;"),
        ("ovh", "overflow: hidden;"),
        ("cup", "cursor: pointer;"),
        ("bxzbb", "box-sizing: border-box;"),
        ("bd+", "border: 1px solid #000;"),
        ("m", "margin: ;"),
        ("pos", "position: ;"),
        ("c", "color: ;"),
        ("color", "color: ;"),
        ("bgi", "background-image: url();"),
        ("trs", "transition: prop time;"),
        ("p10!", "padding: 10px !important;"),
        ("dn!", "display: none !important;"),
        ("m10+p5", "margin: 10px;\npadding: 5px;"),
        ("dn+posa", "display: none;\nposition: absolute;"),
        ("df+jcc+aic", "display: flex;\njustify-content: center;\nalign-items: center;"),
    ])
    func expandsCSS(_ abbreviation: String, _ expected: String) {
        #expect(css(abbreviation) == expected, "\(abbreviation)")
    }

    @Test func stopsAndInvalid() {
        #expect(Emmet.expandCSS("m") == "margin: ${1};")
        #expect(Emmet.expandCSS("w+h") == "width: ${1};\nheight: ${2};")
        #expect(Emmet.expandCSS("m+trs") == "margin: ${1};\ntransition: ${2:prop} ${3:time};")
        for invalid in ["", "xyz", "m10-", "hello", "m1x2y"] {
            #expect(Emmet.expandCSS(invalid) == nil, "\(invalid)")
        }
        #expect(Emmet.extractCSS(beforeCursor: "  m10-20")?.abbreviation == "m10-20")
        #expect(Emmet.extractCSS(beforeCursor: "a { p10!")?.abbreviation == "p10!")
        #expect(Emmet.extractCSS(beforeCursor: "color: red")?.abbreviation == "red")
        #expect(Emmet.extractCSS(beforeCursor: "  ") == nil)
    }
}

struct EmmetContextTests {
    private func expansion(_ text: String, _ syntax: Emmet.Syntax?, confident: Bool = true) -> String? {
        // "|" marks the cursor.
        let cursor = (text as NSString).range(of: "|").location
        let string = text.replacingOccurrences(of: "|", with: "") as NSString
        return Emmet.expansion(in: string, at: cursor, languageSyntax: syntax, confident: confident)?.abbreviation
    }

    @Test func languages() {
        #expect(Emmet.syntax(languageId: "html", fileExtension: "html") == .html)
        #expect(Emmet.syntax(languageId: "vue", fileExtension: "vue") == .html)
        #expect(Emmet.syntax(languageId: "plaintext", fileExtension: "svelte") == .html)
        #expect(Emmet.syntax(languageId: "php", fileExtension: "php") == .html)
        #expect(Emmet.syntax(languageId: "css", fileExtension: "scss") == .css)
        #expect(Emmet.syntax(languageId: "plaintext", fileExtension: "less") == .css)
        #expect(Emmet.syntax(languageId: "typescriptreact", fileExtension: "tsx") == .jsx)
        #expect(Emmet.syntax(languageId: "javascript", fileExtension: "jsx") == .jsx)
        #expect(Emmet.syntax(languageId: "plaintext", fileExtension: "xml") == .xml)
        #expect(Emmet.syntax(languageId: "javascript", fileExtension: "js") == nil)
        #expect(Emmet.syntax(languageId: "markdown", fileExtension: "md") == nil)
    }

    @Test func htmlContexts() {
        #expect(expansion("<body>\n  ul>li*3|\n</body>", .html) == "ul>li*3")
        #expect(expansion("<p>Some text hello|</p>", .html) == nil) // a plain word
        #expect(expansion("<p>Some text span|</p>", .html) == "span")
        #expect(expansion("<div class=\"a div|", .html) == nil) // in a tag
        #expect(expansion("<div title=x p|>", .html) == nil)
        #expect(expansion("<!-- div| -->", .html) == nil) // in a comment
        #expect(expansion("<!-- x -->\ndiv|", .html) == "div")
        #expect(expansion("<script>\n  a.b|\n</script>", .html) == nil)
        #expect(expansion("<?php echo div| ?>", .html) == nil)
        #expect(expansion("{{ div| }}", .html) == nil)
        #expect(expansion("<style>\n  .a { m10|\n</style>", .html) == "m10")
        #expect(expansion("<style>\n  m10|\n</style>", .html) == nil) // not in a rule
        #expect(expansion("|", .html) == nil)
        #expect(expansion("    |", .html) == nil)
        // The palette's Expand takes any abbreviation, also in other languages.
        #expect(expansion("hello|", .html, confident: false) == "hello")
        #expect(expansion("x.y|", nil, confident: false) == "x.y")
        #expect(expansion("x.y|", nil) == nil)
    }

    @Test func cssContexts() {
        #expect(expansion(".a {\n  m10|\n}", .css) == "m10")
        #expect(expansion(".a { color: red; p5|", .css) == "p5")
        #expect(expansion(".a { color: red|", .css) == nil) // a value
        #expect(expansion("m10|", .css) == nil) // a selector
        #expect(expansion(".a { /* m10| */ }", .css) == nil)
        #expect(expansion(".a { content: \"{\"; } dn|", .css) == nil)
        #expect(expansion("@media x { .a { .b { dn|", .css) == "dn")
    }

    @Test func jsxContexts() {
        #expect(expansion("return (\n  <div>\n    ul>li.item*2|", .jsx) == "ul>li.item*2")
        #expect(expansion("const x = (\n  div.card|", .jsx) == "div.card")
        #expect(expansion("return div.card|", .jsx) == "div.card")
        #expect(expansion("const a = obj.prop|", .jsx) == nil)
        #expect(expansion("const f = () => div.x|", .jsx) == nil)
        #expect(expansion("foo(a.b|", .jsx) == nil) // "a.b" after "(": not tags people write in calls
        #expect(expansion("<div className=\"p.x|", .jsx) == nil)
        #expect(expansion("// div.x|", .jsx) == nil)
        #expect(expansion("<div>\n  {items.map(i => li|", .jsx) == nil)
    }
}

@MainActor
struct EmmetEditorTests {
    private func makeEditor(_ text: String, ext: String = "html") throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-emmet-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.attach(controller)
        document.editor = controller
        return (document, controller, window)
    }

    private func tab(_ controller: EditorController) {
        let selector = #selector(NSResponder.insertTab(_:))
        if controller.textView.delegate?.textView?(controller.textView, doCommandBy: selector) != true {
            controller.textView.doCommand(by: selector)
        }
    }

    private func type(_ controller: EditorController, _ text: String) {
        for character in text {
            controller.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func selected(_ controller: EditorController) -> [String] {
        let text = controller.document.textStorage.string as NSString
        return controller.allSelections.sorted { $0.location < $1.location }.map { text.substring(with: $0) }
    }

    @Test func tabExpandsWithStopsAndTheFilesIndentation() throws {
        let (document, controller, window) = try makeEditor("<body>\n  <p></p>\n  \n</body>\n")
        controller.completion.dismiss()
        controller.textView.setSelectedRange(NSRange(location: 19, length: 0))
        controller.textView.insertText("ul>li.item$*2>a", replacementRange: controller.textView.selectedRange())
        tab(controller)
        #expect(document.textStorage.string == """
        <body>
          <p></p>
          <ul>
            <li class="item1"><a href=""></a></li>
            <li class="item2"><a href=""></a></li>
          </ul>
        </body>

        """)
        // Tab goes through the empty attributes and contents, then to the end.
        #expect(controller.snippetSession != nil)
        #expect(selected(controller) == [""])
        let firstHref = (document.textStorage.string as NSString).range(of: "href=\"\"").location + 6
        #expect(controller.textView.selectedRange().location == firstHref)
        type(controller, "/a")
        tab(controller)
        type(controller, "One")
        #expect(document.textStorage.string.contains("<a href=\"/a\">One</a>"))
        withExtendedLifetime(window) {}
    }

    @Test func tabDoesntStealIndentingOrSnippetsOrWords() throws {
        let (document, controller, window) = try makeEditor("<p>\nhello\n</p>\n")
        // At the start of a line: Tab indents.
        controller.textView.setSelectedRange(NSRange(location: 4, length: 0))
        tab(controller)
        #expect(document.textStorage.string.hasPrefix("<p>\n\thello") || document.textStorage.string.hasPrefix("<p>\n    hello")
                || document.textStorage.string.hasPrefix("<p>\n  hello"))
        // After a plain word: Tab is a tab.
        let afterHello = (document.textStorage.string as NSString).range(of: "hello").location + 5
        controller.textView.setSelectedRange(NSRange(location: afterHello, length: 0))
        tab(controller)
        #expect(!document.textStorage.string.contains("<hello>"))
        // In a snippet session, Tab moves to the next stop even after an abbreviation.
        let end = document.textStorage.length
        controller.insertSnippet("$1 ${2:x}", replacing: NSRange(location: end, length: 0))
        type(controller, "div")
        tab(controller)
        #expect(selected(controller) == ["x"])
        #expect(!document.textStorage.string.contains("<div>"))
        withExtendedLifetime(window) {}
    }

    @Test func settingsTurnItOff() throws {
        let (document, controller, window) = try makeEditor("")
        let settings = AppSettings.shared
        let saved = (settings.emmetEnabled, settings.emmetExpandOnTab)
        defer { settings.emmetEnabled = saved.0; settings.emmetExpandOnTab = saved.1 }
        settings.emmetExpandOnTab = false
        type(controller, "span.x")
        controller.completion.dismiss()
        tab(controller)
        #expect(!document.textStorage.string.contains("<span"))
        settings.emmetExpandOnTab = true
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        tab(controller)
        #expect(document.textStorage.string.hasPrefix("<span class=\"x\"></span>"))
        withExtendedLifetime(window) {}
    }

    @Test func jsxUsesClassName() throws {
        let (document, controller, window) = try makeEditor("export const A = () => (\n  \n);\n", ext: "jsx")
        controller.textView.setSelectedRange(NSRange(location: 27, length: 0))
        controller.textView.insertText("div.card>img", replacementRange: controller.textView.selectedRange())
        controller.completion.dismiss()
        tab(controller)
        #expect(document.textStorage.string.contains("<div className=\"card\">"))
        #expect(document.textStorage.string.contains("<img src=\"\" alt=\"\" />"))
        withExtendedLifetime(window) {}
    }

    @Test func completionOffersTheExpansion() async throws {
        let (document, controller, window) = try makeEditor(".a {\n  \n}\n", ext: "css")
        controller.textView.setSelectedRange(NSRange(location: 7, length: 0))
        type(controller, "m10")
        controller.completion.triggerManually()
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.completion.visibleItems.first?.detail != "Emmet Abbreviation", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try #require(controller.completion.visibleItems.first)
        #expect(item.label == "m10" && item.detail == "Emmet Abbreviation")
        #expect(item.documentation == "margin: 10px;")
        controller.completion.insert(item)
        #expect(document.textStorage.string == ".a {\n  margin: 10px;\n}\n")
        controller.completion.dismiss()
        withExtendedLifetime(window) {}
    }

    @Test func wrapBalanceAndRemoveTag() throws {
        let text = "<div>\n  <p>one <b>two</b></p>\n</div>" as NSString
        let pairs = Emmet.tagPairs(in: text)
        #expect(pairs.map(\.name) == ["div", "p", "b"])
        let insideB = NSRange(location: text.range(of: "two").location + 1, length: 0)
        let b = Emmet.balanceOutward(insideB, in: pairs)
        #expect(b.map(text.substring(with:)) == "two")
        let bOuter = Emmet.balanceOutward(b!, in: pairs)
        #expect(bOuter.map(text.substring(with:)) == "<b>two</b>")
        let pInner = Emmet.balanceOutward(bOuter!, in: pairs)
        #expect(pInner.map(text.substring(with:)) == "one <b>two</b>")
        let divOuter = NSRange(location: 0, length: text.length)
        let divInner = Emmet.balanceInward(divOuter, in: pairs)
        #expect(divInner.map(text.substring(with:)) == "\n  <p>one <b>two</b></p>\n")
        #expect(Emmet.balanceInward(divInner!, in: pairs).map(text.substring(with:)) == "<p>one <b>two</b></p>")
        // Void elements, comments and scripts don't confuse the matching.
        let mixed = "<ul><li><img src=x><br/><!-- <li> --></li><script>if (a<b) {}</script></ul>" as NSString
        #expect(Emmet.tagPairs(in: mixed).map(\.name) == ["ul", "li", "img", "br", "script"])

        let edits = try #require(Emmet.removeTagEdits(at: 2, in: text, indentUnit: "  "))
        #expect(try TextReplacement.apply(edits, to: text as String) == "<p>one <b>two</b></p>\n")
        let inline = try #require(Emmet.removeTagEdits(at: text.range(of: "two").location, in: text, indentUnit: "  "))
        #expect(try TextReplacement.apply(inline, to: text as String) == "<div>\n  <p>one two</p>\n</div>")
    }
}
