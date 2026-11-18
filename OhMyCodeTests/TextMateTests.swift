import AppKit
import SwiftTreeSitter
import Testing
@testable import Oh_My_Code

private final class TextMateBundleToken {}

private func grammar(_ json: String) throws -> TextMateRawGrammar {
    try TextMateRawGrammar.parse(Data(json.utf8), isJSON: true)
}

private func fixtureGrammar(_ name: String) throws -> TextMateRawGrammar {
    let url = try #require(Bundle(for: TextMateBundleToken.self).resourceURL?.appending(path: "Fixtures/textmate/\(name)"))
    return try TextMateRawGrammar.load(url)
}

/// Tokenizes `lines` with the first grammar (the others are there to be included or injected).
private func tokenize(_ lines: [String], _ grammars: [TextMateRawGrammar], injections: [String: [String]] = [:])
    -> [[TextMateToken]] {
    let tokenizer = TextMateTokenizer(scopeName: grammars[0].scopeName, source: .fixed(grammars, injections: injections))!
    var state: TextMateState?
    var result: [[TextMateToken]] = []
    for line in lines {
        let (tokens, end) = tokenizer.tokenize(line: line as NSString, state: state)
        result.append(tokens)
        state = end
    }
    return result
}

/// The scopes (without the grammar's own) of the token at `text` in a line.
private func scopes(_ tokens: [TextMateToken], _ line: String, at text: String, occurrence: Int = 0) -> [String] {
    var searchRange = NSRange(location: 0, length: (line as NSString).length)
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0...occurrence {
        found = (line as NSString).range(of: text, options: .literal, range: searchRange)
        guard found.location != NSNotFound else { return ["<not found>"] }
        searchRange = NSRange(location: NSMaxRange(found), length: (line as NSString).length - NSMaxRange(found))
    }
    let token = tokens.first { $0.start <= found.location && found.location < $0.end }
    return Array((token?.scopes ?? []).dropFirst())
}

@Suite struct TextMateTokenizerTests {
    @Test func matchWithCapturesAndNames() throws {
        let g = try grammar(#"""
        { "scopeName": "source.t", "patterns": [
          { "match": "\\b(let)\\s+(\\w+)", "name": "meta.declaration.t",
            "captures": { "1": { "name": "keyword.other.let.t" }, "2": { "name": "variable.other.t" } } },
          { "match": "\\b(\\w+)!", "name": "support.macro.${1:/downcase}.t" }
        ] }
        """#)
        let line = "let answer = Print!"
        let tokens = tokenize([line], [g])[0]
        #expect(scopes(tokens, line, at: "let") == ["meta.declaration.t", "keyword.other.let.t"])
        #expect(scopes(tokens, line, at: "answer") == ["meta.declaration.t", "variable.other.t"])
        #expect(scopes(tokens, line, at: " = ") == [])
        #expect(scopes(tokens, line, at: "Print") == ["support.macro.print.t"])
        // The tokens cover the line without gaps.
        #expect(tokens.first?.start == 0 && tokens.last?.end == (line as NSString).length)
        for (a, b) in zip(tokens, tokens.dropFirst()) { #expect(a.end == b.start) }
    }

    @Test func beginEndAcrossLinesWithContentName() throws {
        let g = try grammar(#"""
        { "scopeName": "source.t", "patterns": [
          { "begin": "/\\*", "end": "\\*/", "name": "comment.block.t", "contentName": "comment.body.t",
            "beginCaptures": { "0": { "name": "punctuation.definition.comment.begin.t" } },
            "endCaptures": { "0": { "name": "punctuation.definition.comment.end.t" } } },
          { "match": "\\bx\\b", "name": "variable.t" }
        ] }
        """#)
        let lines = ["x /* a", "still x", "end */ x"]
        let tokens = tokenize(lines, [g])
        #expect(scopes(tokens[0], lines[0], at: "x") == ["variable.t"])
        #expect(scopes(tokens[0], lines[0], at: "/*") == ["comment.block.t", "punctuation.definition.comment.begin.t"])
        #expect(scopes(tokens[0], lines[0], at: "a") == ["comment.block.t", "comment.body.t"])
        #expect(scopes(tokens[1], lines[1], at: "x") == ["comment.block.t", "comment.body.t"])
        #expect(scopes(tokens[2], lines[2], at: "*/") == ["comment.block.t", "punctuation.definition.comment.end.t"])
        #expect(scopes(tokens[2], lines[2], at: "x") == ["variable.t"])
    }

    @Test func backReferencesInEnd() throws {
        let g = try grammar(#"""
        { "scopeName": "source.t", "patterns": [
          { "begin": "<<(\\w+)", "end": "^\\1$", "name": "string.unquoted.heredoc.t" }
        ] }
        """#)
        let lines = ["x = <<EOF", "EOT", "body", "EOF", "after"]
        let tokens = tokenize(lines, [g])
        #expect(scopes(tokens[1], lines[1], at: "EOT") == ["string.unquoted.heredoc.t"]) // not the terminator
        #expect(scopes(tokens[3], lines[3], at: "EOF") == ["string.unquoted.heredoc.t"])
        #expect(tokens[4].allSatisfy { $0.scopes == ["source.t"] }) // closed
    }

    @Test func gAnchorMatchesOnlyWhereThePreviousMatchEnded() throws {
        let g = try grammar(#"""
        { "scopeName": "source.t", "patterns": [
          { "begin": "\\[", "end": "\\]", "name": "meta.list.t",
            "patterns": [{ "match": "\\G\\s*(\\w+)", "captures": { "1": { "name": "entity.name.first.t" } } },
                         { "match": "\\w+", "name": "variable.t" }] }
        ] }
        """#)
        let line = "[ head tail ]"
        let tokens = tokenize([line], [g])[0]
        #expect(scopes(tokens, line, at: "head") == ["meta.list.t", "entity.name.first.t"])
        #expect(scopes(tokens, line, at: "tail") == ["meta.list.t", "variable.t"])
    }

    @Test func aAnchorMatchesOnlyOnTheFirstLine() throws {
        let g = try grammar(#"""
        { "scopeName": "source.t", "patterns": [{ "match": "\\A#!.*$", "name": "comment.line.shebang.t" }] }
        """#)
        let lines = ["#!/usr/bin/env toy", "#!not a shebang"]
        let tokens = tokenize(lines, [g])
        #expect(scopes(tokens[0], lines[0], at: "#!") == ["comment.line.shebang.t"])
        #expect(scopes(tokens[1], lines[1], at: "#!") == [])
    }

    @Test func whileContinuesWhileLinesMatch() throws {
        let g = try grammar(#"""
        { "scopeName": "source.t", "patterns": [
          { "begin": "^(>)", "while": "^(>)", "name": "markup.quote.t",
            "beginCaptures": { "1": { "name": "punctuation.definition.quote.begin.t" } },
            "whileCaptures": { "1": { "name": "punctuation.definition.quote.continue.t" } },
            "patterns": [{ "match": "\\*\\w+\\*", "name": "markup.bold.t" }] }
        ] }
        """#)
        let lines = ["> one", "> *two*", "three"]
        let tokens = tokenize(lines, [g])
        #expect(scopes(tokens[0], lines[0], at: ">") == ["markup.quote.t", "punctuation.definition.quote.begin.t"])
        #expect(scopes(tokens[0], lines[0], at: "one") == ["markup.quote.t"])
        #expect(scopes(tokens[1], lines[1], at: ">") == ["markup.quote.t", "punctuation.definition.quote.continue.t"])
        #expect(scopes(tokens[1], lines[1], at: "*two*") == ["markup.quote.t", "markup.bold.t"])
        #expect(scopes(tokens[2], lines[2], at: "three") == [])
    }

    @Test func capturesWithPatternsAreTokenizedAgain() throws {
        let g = try grammar(#"""
        { "scopeName": "source.t", "patterns": [
          { "match": "(\")([^\"]*)(\")", "name": "string.quoted.t",
            "captures": { "1": { "name": "punctuation.definition.string.t" },
                          "2": { "name": "meta.content.t", "patterns": [{ "match": "\\\\.", "name": "constant.character.escape.t" }] },
                          "3": { "name": "punctuation.definition.string.t" } } }
        ] }
        """#)
        let line = #"say "a\nb" now"#
        let tokens = tokenize([line], [g])[0]
        #expect(scopes(tokens, line, at: "a", occurrence: 1) == ["string.quoted.t", "meta.content.t"])
        #expect(scopes(tokens, line, at: #"\n"#) == ["string.quoted.t", "meta.content.t", "constant.character.escape.t"])
        #expect(scopes(tokens, line, at: "\"", occurrence: 1) == ["string.quoted.t", "punctuation.definition.string.t"])
        #expect(scopes(tokens, line, at: "now") == [])
    }

    @Test func includesRepositorySelfBaseAndOtherGrammars() throws {
        let host = try grammar(#"""
        { "scopeName": "source.host", "patterns": [{ "include": "#parens" }, { "include": "source.other#numbers" }],
          "repository": {
            "parens": { "begin": "\\(", "end": "\\)", "name": "meta.parens.host", "patterns": [{ "include": "$self" }] },
            "missing": { "patterns": [{ "include": "#nowhere" }] }
          } }
        """#)
        let other = try grammar(#"""
        { "scopeName": "source.other", "patterns": [],
          "repository": { "numbers": { "match": "\\d+", "name": "constant.numeric.other" },
                          "base": { "match": "@", "name": "keyword.base.other" } } }
        """#)
        let line = "(1 (2)) 3"
        let tokens = tokenize([line], [host, other])[0]
        #expect(scopes(tokens, line, at: "1") == ["meta.parens.host", "constant.numeric.other"])
        #expect(scopes(tokens, line, at: "2") == ["meta.parens.host", "meta.parens.host", "constant.numeric.other"])
        #expect(scopes(tokens, line, at: "3") == ["constant.numeric.other"])
    }

    @Test func baseIncludesTheRootGrammarFromAnEmbeddedOne() throws {
        let host = try grammar(#"""
        { "scopeName": "source.host", "patterns": [
          { "begin": "<js>", "end": "</js>", "contentName": "meta.embedded.block.js", "patterns": [{ "include": "source.js" }] },
          { "match": "@\\w+", "name": "entity.name.tag.host" }
        ] }
        """#)
        let js = try grammar(#"""
        { "scopeName": "source.js", "patterns": [
          { "match": "\\bfunction\\b", "name": "storage.type.function.js" },
          { "begin": "\\{", "end": "\\}", "name": "meta.block.js", "patterns": [{ "include": "$base" }] }
        ] }
        """#)
        let lines = ["@top <js>function {", "@inner } function", "</js> function"]
        let tokens = tokenize(lines, [host, js])
        #expect(scopes(tokens[0], lines[0], at: "@top") == ["entity.name.tag.host"])
        #expect(scopes(tokens[0], lines[0], at: "function") == ["meta.embedded.block.js", "storage.type.function.js"])
        // $base is the document's grammar (host), even inside the embedded one.
        #expect(scopes(tokens[1], lines[1], at: "@inner") == ["meta.embedded.block.js", "meta.block.js", "entity.name.tag.host"])
        #expect(scopes(tokens[1], lines[1], at: "function") == ["meta.embedded.block.js", "storage.type.function.js"])
        #expect(scopes(tokens[2], lines[2], at: "function") == [])
    }

    @Test func injectionsFromTheGrammarAndFromInjectTo() throws {
        let host = try grammar(#"""
        { "scopeName": "source.t", "patterns": [
          { "begin": "#", "end": "$", "name": "comment.line.t" },
          { "begin": "\"", "end": "\"", "name": "string.quoted.t" }
        ],
          "injections": { "L:source.t comment": { "patterns": [{ "match": "TODO", "name": "keyword.todo.t" }] } } }
        """#)
        let injected = try grammar(#"""
        { "scopeName": "inject.url", "injectionSelector": "L:string.quoted",
          "patterns": [{ "match": "https?://\\S+?(?=\")", "name": "markup.underline.link.url" }] }
        """#)
        let line = #"# TODO fix "see http://x.y" TODO"#
        let tokens = tokenize([line], [host, injected], injections: ["source.t": ["inject.url"]])[0]
        #expect(scopes(tokens, line, at: "TODO") == ["comment.line.t", "keyword.todo.t"])
        #expect(scopes(tokens, line, at: "fix") == ["comment.line.t"])
        let line2 = #"x "http://a.b" TODO"#
        let tokens2 = tokenize([line2], [host, injected], injections: ["source.t": ["inject.url"]])[0]
        #expect(scopes(tokens2, line2, at: "http") == ["string.quoted.t", "markup.underline.link.url"])
        #expect(scopes(tokens2, line2, at: "TODO") == []) // not in a comment
    }

    @Test func aRuleThatDoesNotAdvanceStopsTheLine() throws {
        let g = try grammar(#"""
        { "scopeName": "source.t", "patterns": [{ "begin": "(?=x)", "end": "(?=x)", "name": "meta.stuck.t" }] }
        """#)
        let tokens = tokenize(["axb"], [g])
        #expect(tokens[0].last?.end == 3) // finished, no endless loop
    }

    @Test func pathologicalLinesAreLeftPlain() throws {
        let g = try grammar(#"""
        { "scopeName": "source.t", "patterns": [{ "match": "(a*)*b", "name": "keyword.t" }, { "match": "c", "name": "constant.t" }] }
        """#)
        let tokenizer = try #require(TextMateTokenizer(scopeName: "source.t", source: .fixed([g])))
        tokenizer.timeLimit = .milliseconds(30)
        let line = String(repeating: "a", count: 40) + "c"
        let start = ContinuousClock.now
        let (tokens, state) = tokenizer.tokenize(line: line as NSString, state: nil)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(tokens == [TextMateToken(start: 0, end: 41, scopes: ["source.t"])])
        #expect(state == tokenizer.initialState)

        tokenizer.lineLengthLimit = 10
        let (long, _) = tokenizer.tokenize(line: "c c c c c c c" as NSString, state: nil)
        #expect(long.count == 1)
    }

    @Test func realWorldJSONGrammar() throws {
        let json = try fixtureGrammar("json.tmLanguage.json")
        let lines = [#"{ "name": "omc", // note"#, #"  "tags": [true, -1.5e3, "a\"b"],"#, "  /* block", "  */ \"n\": null }"]
        let tokens = tokenize(lines, [json])
        #expect(scopes(tokens[0], lines[0], at: "name") == ["meta.structure.dictionary.json", "string.json", "support.type.property-name.json"])
        #expect(scopes(tokens[0], lines[0], at: "omc") == ["meta.structure.dictionary.json", "meta.structure.dictionary.value.json", "string.quoted.double.json"])
        #expect(scopes(tokens[0], lines[0], at: "note").last == "comment.line.double-slash.js")
        #expect(scopes(tokens[1], lines[1], at: "true").last == "constant.language.json")
        #expect(scopes(tokens[1], lines[1], at: "-1.5e3").last == "constant.numeric.json")
        #expect(scopes(tokens[1], lines[1], at: #"\""#).last == "constant.character.escape.json")
        #expect(scopes(tokens[2], lines[2], at: "block").last == "comment.block.json")
        #expect(scopes(tokens[3], lines[3], at: "null").last == "constant.language.json")
    }

    @Test func propertyListGrammar() throws {
        let ini = try fixtureGrammar("ini.tmLanguage")
        let lines = ["; settings", "[core]", "name = Oh My Code"]
        let tokens = tokenize(lines, [ini])
        #expect(scopes(tokens[0], lines[0], at: ";") == ["comment.line.ini", "punctuation.definition.comment.ini"])
        #expect(scopes(tokens[1], lines[1], at: "core") == ["entity.name.section.group-title.ini"])
        #expect(scopes(tokens[2], lines[2], at: "name") == ["keyword.other.definition.ini"])
        #expect(scopes(tokens[2], lines[2], at: "Oh My") == ["string.unquoted.value.ini"])
    }

    @Test func yamlGrammarsAreRefusedWithAReason() {
        #expect(throws: TextMateRawGrammar.LoadError.self) {
            try TextMateRawGrammar.load(URL(fileURLWithPath: "/tmp/x.tmLanguage.yaml"))
        }
    }
}

@Suite struct OnigurumaTranslationTests {
    @Test(arguments: [
        (#"\h+"#, #"[0-9a-fA-F]+"#),
        (#"[\h_]"#, #"[0-9a-fA-F_]"#),
        (#"\H"#, #"[^0-9a-fA-F]"#),
        ("(?m).", "(?s)."),
        ("(?mi:a.)", "(?si:a.)"),
        ("(?i:ab)", "(?i:ab)"),
        ("(?x) a b # comment\n c", "abc"),
        ("(?x)[a b]", #"[a\x{20}b]"#),
        ("a{,3}", "a{0,3}"),
        ("a{2}", "a{2}"),
        ("{", #"\{"#),
        ("a}", #"a\}"#),
        (#"\p{^Alpha}"#, #"\P{Alpha}"#),
        (#"\x{41}\p{Lu}\P{L}"#, #"\x{41}\p{Lu}\P{L}"#),
        ("(?<var_name>x)\\k<var_name>", "(?<varname>x)\\k<varname>"),
        ("(?<a>x)|(?<a>y)", "(?<a>x)|(?<a2>y)"),
        ("[[:alpha:]_]", "[[:alpha:]_]"),
        ("[a[]", #"[a\[]"#),
        ("[a-z&&[^aeiou]]", "[a-z&&[^aeiou]]"),
        ("[]a]", #"[\]a]"#),
        ("(?<=x)y(?!z)", "(?<=x)y(?!z)"),
        ("a++b*+(?>c)", "a++b*+(?>c)"),
        (#"\z\Z\b"#, #"\z\Z\b"#),
    ])
    func translates(_ pair: (String, String)) {
        #expect(OnigurumaRegex.translate(pair.0) == pair.1)
    }

    @Test(arguments: [#"a\Kb"#, #"(?<p>a)\g<p>"#, "(?(1)a|b)", "(?~abc)"])
    func unsupportedConstructsAreRefused(_ pattern: String) {
        #expect(OnigurumaRegex.translate(pattern) == nil)
        #expect(OnigurumaRegex.compile(pattern) == nil)
    }

    @Test func translatedPatternsMatchLikeOniguruma() throws {
        func first(_ pattern: String, _ text: String) throws -> String? {
            let regex = try #require(OnigurumaRegex.compile(pattern))
            let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            return match.map { (text as NSString).substring(with: $0.range) }
        }
        #expect(try first(#"\h+"#, "zz0fAx") == "0fA")
        #expect(try first("(?x) foo \\s+ bar  # words", "a foo  bar") == "foo  bar")
        #expect(try first("(?m)a.b", "a\nb") == "a\nb")
        #expect(try first(#"\p{^Alpha}+"#, "ab12c") == "12")
        #expect(try first("x{,2}", "xxx") == "xx")
        #expect(try first("[[:upper:]]+", "abCDe") == "CD")
    }

    @Test func anchorsThatCantMatchAreReplaced() {
        #expect(TextMateTokenizer.anchorVariant(#"\Ga\Ab"#, allowA: true, allowG: false) == #"\x{FFFF}a\Ab"#)
        #expect(TextMateTokenizer.anchorVariant(#"\\G\G"#, allowA: false, allowG: true) == #"\\G\G"#)
        #expect(TextMateTokenizer.hasBackReferences(#"^\1$"#))
        #expect(!TextMateTokenizer.hasBackReferences(#"\\1\d"#))
    }
}

/// Edits re-tokenize from the edited line until the state is what it was.
@Suite struct TextMateIncrementalTests {
    private let grammarJSON = #"""
    { "scopeName": "source.t", "patterns": [
      { "begin": "/\\*", "end": "\\*/", "name": "comment.block.t" },
      { "match": "\\blet\\b", "name": "keyword.t" }
    ] }
    """#

    private func document(_ text: String) throws -> TextMateDocument {
        let g = try grammar(grammarJSON)
        let document = TextMateDocument(tokenizer: TextMateTokenizer(scopeName: "source.t", source: .fixed([g]))!)
        document.update(text: text as NSString, edits: [])
        return document
    }

    /// Replaces `range` in `text` with `replacement`, telling `document` (rows as tree-sitter gives them).
    private func edit(_ document: TextMateDocument, _ text: inout String, _ range: NSRange, _ replacement: String) {
        let old = text as NSString
        func row(_ string: NSString, _ offset: Int) -> UInt32 {
            UInt32(string.substring(to: offset).filter { $0 == "\n" }.count)
        }
        let new = old.replacingCharacters(in: range, with: replacement) as NSString
        let newEnd = range.location + (replacement as NSString).length
        let edit = InputEdit(startByte: UInt32(range.location * 2), oldEndByte: UInt32(NSMaxRange(range) * 2), newEndByte: UInt32(newEnd * 2),
                             startPoint: Point(row: row(old, range.location), column: 0),
                             oldEndPoint: Point(row: row(old, NSMaxRange(range)), column: 0),
                             newEndPoint: Point(row: row(new, newEnd), column: 0))
        text = new as String
        document.update(text: new, edits: [edit])
    }

    private func allHighlights(_ document: TextMateDocument) -> [NamedRange] {
        document.highlights(in: NSRange(location: 0, length: document.text.length))
    }

    @Test func editingALineRetokenizesOnlyThatLine() throws {
        var text = (0..<200).map { "let x\($0) = \($0)" }.joined(separator: "\n")
        let doc = try document(text)
        _ = allHighlights(doc)
        #expect(doc.tokenizedLineCount == 200)
        let line100 = (text as NSString).range(of: "let x100")
        edit(doc, &text, NSRange(location: line100.location + 4, length: 0), "y")
        _ = allHighlights(doc)
        #expect(doc.tokenizedLineCount == 201) // the edited line; the rest converged
        let fresh = try document(text)
        #expect(allHighlights(doc) == allHighlights(fresh))
    }

    @Test func openingACommentRetokenizesUntilItCloses() throws {
        var text = (0..<50).map { "let a\($0)" }.joined(separator: "\n")
        let doc = try document(text)
        _ = allHighlights(doc)
        // Open a comment at line 10, then close it at line 20.
        let line10 = (text as NSString).range(of: "let a10")
        edit(doc, &text, NSRange(location: line10.location, length: 0), "/* ")
        _ = allHighlights(doc)
        #expect(doc.tokenizedLineCount == 50 + 40) // everything after it is in the comment now
        let line20 = (text as NSString).range(of: "let a20")
        edit(doc, &text, NSRange(location: NSMaxRange(line20), length: 0), " */")
        let before = doc.tokenizedLineCount
        _ = allHighlights(doc)
        #expect(doc.tokenizedLineCount - before == 30) // line 20 and after: back to code
        #expect(allHighlights(doc) == allHighlights(try document(text)))
        #expect(doc.scopes(at: (text as NSString).range(of: "let a15").location) == ["source.t", "comment.block.t"])
        #expect(doc.scopes(at: (text as NSString).range(of: "let a25").location) == ["source.t", "keyword.t"])
    }

    @Test func insertingAndDeletingLinesKeepsTheRestInPlace() throws {
        var text = (0..<30).map { "let a\($0)" }.joined(separator: "\n")
        let doc = try document(text)
        _ = allHighlights(doc)
        let line5 = (text as NSString).range(of: "let a5\n")
        edit(doc, &text, NSRange(location: line5.location, length: 0), "x\ny\nz /* q */\n")
        #expect(allHighlights(doc) == allHighlights(try document(text)))
        let removed = (text as NSString).range(of: "let a10\nlet a11\n")
        edit(doc, &text, removed, "")
        #expect(allHighlights(doc) == allHighlights(try document(text)))
        #expect(doc.tokenizedLineCount < 30 + 10)
    }

    @Test func onlyWhatIsAskedForIsTokenized() throws {
        let text = (0..<1000).map { "let a\($0)" }.joined(separator: "\n")
        let doc = try document(text)
        _ = doc.highlights(in: NSRange(location: 0, length: 100))
        #expect(doc.tokenizedLineCount < 20)
    }
}

@MainActor @Suite struct TextMateThemeTests {
    private func rules(_ entries: [(String, UInt32)]) -> TextMateThemeRules {
        var rules = TextMateThemeRules()
        for (selector, color) in entries { rules.add(selector: selector, color: EditorTheme.hex(color)) }
        return rules
    }

    private func color(_ rules: TextMateThemeRules, _ scopes: String) -> UInt32? {
        rules.match(scopes.split(separator: " ").map(String.init)).map { VSCodeTheme.rgb($0.color) }
    }

    @Test func innermostScopeAndSpecificityDecide() {
        let theme = rules([("string", 0x00FF00), ("string.quoted.double", 0x0000FF), ("comment", 0x777777),
                           ("meta.tag string", 0xFF0000), ("string", 0x00EE00), ("punctuation.definition.string", 0x111111),
                           ("source.t -comment keyword", 0xABCDEF), ("keyword", 0x123456)])
        // The longer selector wins; among equals, the later rule.
        #expect(color(theme, "source.t string.quoted.double.t") == 0x0000FF)
        #expect(color(theme, "source.t string.quoted.single.t") == 0x00EE00)
        // An ancestor in the selector makes it more specific.
        #expect(color(theme, "source.t meta.tag.t string.quoted.single.t") == 0xFF0000)
        // The innermost scope with a rule decides: punctuation inside a string.
        #expect(color(theme, "source.t string.quoted.double.t punctuation.definition.string.begin.t") == 0x111111)
        // A scope without rules takes its parent's.
        #expect(color(theme, "source.t comment.line.t meta.unknown.t") == 0x777777)
        // Exclusions.
        #expect(color(theme, "source.t keyword.control.t") == 0xABCDEF)
        #expect(color(theme, "source.t comment.line.t keyword.todo.t") == 0x123456)
        #expect(color(theme, "source.t meta.nothing.t") == nil)
    }

    @Test func vsCodeThemesKeepDescendantSelectors() throws {
        let theme = try VSCodeTheme.parse(Data(#"""
        { "name": "T", "type": "dark", "colors": { "editor.background": "#000000" },
          "tokenColors": [ { "scope": "string", "settings": { "foreground": "#00ff00" } },
                           { "scope": ["meta.embedded string", "keyword.control"], "settings": { "foreground": "#ff0000" } } ] }
        """#.utf8), fallbackName: "T")
        let rules = try #require(theme.textMateRules)
        #expect(color(rules, "source.x meta.embedded.block string.quoted") == 0xFF0000)
        #expect(color(rules, "source.x string.quoted") == 0x00FF00)
        #expect(theme.syntax["string"].map(VSCodeTheme.rgb) == 0x00FF00) // roles still come from simple selectors
    }

    @Test func builtInThemesMapCommonScopesToTheirRoles() {
        #expect(TextMateScopes.captureName(for: ["source.t", "keyword.control.t"]) == "keyword")
        #expect(TextMateScopes.captureName(for: ["source.t", "string.quoted.t", "constant.character.escape.t"]) == "escape")
        #expect(TextMateScopes.captureName(for: ["source.t", "string.quoted.t", "punctuation.definition.string.begin.t"]) == "string")
        #expect(TextMateScopes.captureName(for: ["source.t", "meta.function.t", "entity.name.function.t"]) == "function")
        #expect(TextMateScopes.captureName(for: ["source.t", "storage.type.t"]) == "keyword")
        #expect(TextMateScopes.captureName(for: ["source.t", "constant.numeric.integer.t"]) == "number")
        #expect(TextMateScopes.captureName(for: ["source.t", "comment.line.t", "meta.x"]) == "comment")
        #expect(TextMateScopes.captureName(for: ["source.t", "meta.x"]) == nil)
        let theme = EditorTheme.monokai
        #expect(EditorTheme.color(forScopes: ["source.t", "keyword.control.t"], in: theme) == theme.syntax["keyword"])
        #expect(EditorTheme.color(forScopes: ["source.t", "string.quoted.t"], in: theme) == theme.syntax["string"])
        #expect(EditorTheme.color(forScopes: ["source.t", "entity.name.type.t"], in: theme) == theme.syntax["type"])
        #expect(TextMateScopes.isNonCode("source.t string.quoted.t") && !TextMateScopes.isNonCode("source.t keyword.t"))
    }

    @Test func scopeSelectorsParse() {
        let selector = ScopeSelector("L:source.t comment, R:(string | markup) -string.unquoted")
        #expect(selector.alternatives.map(\.priority) == [-1, 1])
        #expect(selector.alternatives[0].matcher.matches(["source.t", "comment.line"]))
        #expect(!selector.alternatives[0].matcher.matches(["source.u", "comment.line"]))
        #expect(selector.alternatives[1].matcher.matches(["source.t", "markup.bold"]))
        #expect(selector.alternatives[1].matcher.matches(["source.t", "string.quoted"]))
        #expect(!selector.alternatives[1].matcher.matches(["source.t", "string.unquoted"]))
    }
}
