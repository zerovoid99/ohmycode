import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct EditorConfigTests {
    private func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-ec-\(UUID().uuidString)").resolvingSymlinksInPath()
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func globs() {
        let cases: [(String, String, Bool)] = [
            ("*", "a.py", true), ("*", "sub/deep/a.py", true),
            ("*.py", "sub/a.py", true), ("*.py", "a.pyc", false),
            ("*.{js,ts}", "web/app.ts", true), ("*.{js,ts}", "app.tsx", false),
            ("/src/*.go", "src/a.go", true), ("/src/*.go", "x/src/a.go", false), ("/src/*.go", "src/x/a.go", false),
            ("src/*.go", "src/a.go", true), ("lib/**.js", "lib/a/b.js", true), ("lib/**/*.js", "lib/b.js", true),
            ("[!a]*.txt", "b.txt", true), ("[!a]*.txt", "a.txt", false), ("file?.md", "file1.md", true),
            ("{1..3}.md", "2.md", true), ("{1..3}.md", "4.md", false),
            ("Makefile", "tools/Makefile", true), ("Makefile", "Makefile.am", false),
            ("{package.json,.travis.yml}", "package.json", true),
        ]
        for (glob, path, expected) in cases {
            #expect(EditorConfig.matches(glob, relative: path) == expected, "\(glob) vs \(path)")
        }
    }

    @Test func parsesSections() {
        let file = EditorConfig.File(parsing: """
            # comment
            root = true

            [*]
            Indent_Style = space
            indent_size = 2
            ; another comment
            [*.go]
            indent_style = tab
            """)
        #expect(file.isRoot)
        #expect(file.sections.map(\.glob) == ["*", "*.go"])
        #expect(file.sections[0].properties == ["indent_style": "space", "indent_size": "2"])
    }

    @Test func nearerFilesWinUpToTheRoot() throws {
        let outer = try makeTree([
            ".editorconfig": "[*]\nindent_size = 8\nend_of_line = crlf\n",
            "project/.editorconfig": "root = true\n[*]\nindent_style = space\nindent_size = 2\n[*.go]\nindent_style = tab\ntab_width = 8\n[Makefile]\nindent_style = tab\n",
            "project/sub/.editorconfig": "[*.py]\nindent_size = 4\ntrim_trailing_whitespace = true\n[*.md]\nindent_size = unset\n",
        ])
        let project = outer.appending(path: "project")
        let js = EditorConfig.resolve(for: project.appending(path: "web/a.js"))
        // The folder above the root one doesn't count.
        #expect(js.indentStyle == .space && js.indentSize == 2 && js.tabWidth == 2 && js.endOfLine == nil)
        #expect(js.sources == [project.appending(path: ".editorconfig")])
        let go = EditorConfig.resolve(for: project.appending(path: "b.go"))
        #expect(go.indentStyle == .tab && go.tabWidth == 8)
        let python = EditorConfig.resolve(for: project.appending(path: "sub/c.py"))
        #expect(python.indentSize == 4 && python.trimTrailingWhitespace == true)
        #expect(python.sources.map(\.lastPathComponent) == [".editorconfig", ".editorconfig"] && python.sources[0].path.contains("/sub/"))
        #expect(EditorConfig.resolve(for: project.appending(path: "sub/notes.md")).indentSize == nil)
        #expect(EditorConfig.resolve(for: outer.appending(path: "x.txt")).endOfLine == .crlf)
        #expect(EditorConfig.resolve(for: FileManager.default.temporaryDirectory.appending(path: "none-\(UUID()).txt")).isEmpty)
    }

    @Test func savingAppliesItAndIndentationFollowsIt() throws {
        let root = try makeTree([
            ".editorconfig": "root = true\n[*.py]\nindent_style = space\nindent_size = 4\ntrim_trailing_whitespace = true\ninsert_final_newline = true\nend_of_line = lf\n[*.txt]\nindent_style = tab\n",
            "c.py": "def f():  \n\treturn 1\t\r\nx = 1   ",
            "t.txt": "  a\n  b\n",
        ])
        let original = "def f():  \n\treturn 1\t\r\nx = 1   "
        let document = try EditorDocument(url: root.appending(path: "c.py"))
        #expect(document.indentation == (4, true))
        // The text indents with tabs: the config decides.
        #expect(document.guessedIndentation.insertSpaces == false)
        #expect(document.lineEnding == .lf)

        try document.save()
        let saved = "def f():\n\treturn 1\nx = 1\n"
        #expect(try String(contentsOf: root.appending(path: "c.py"), encoding: .utf8) == saved)
        #expect(document.textStorage.string == saved && !document.isDirty)
        // One undo brings the text back.
        document.undoManager.undo()
        #expect(document.textStorage.string == original)

        let text = try EditorDocument(url: root.appending(path: "t.txt"))
        #expect(text.indentation == (4, false))
        let controller = EditorController(document: text)
        #expect(controller.indentUnit == "\t")

        // The config changes: documents read it again.
        try "root = true\n[*.txt]\nindent_style = space\nindent_size = 3\n".write(to: root.appending(path: ".editorconfig"), atomically: true, encoding: .utf8)
        text.reloadEditorConfig()
        #expect(text.indentation == (3, true) && controller.indentUnit == "   ")
    }

    @Test func lineEndingsWholeFile() throws {
        let lines = (0..<2_500).map { "line \($0)  " }
        let root = try makeTree([
            ".editorconfig": "root = true\n[*]\nend_of_line = crlf\ntrim_trailing_whitespace = true\ninsert_final_newline = true\n",
            "big.txt": lines.joined(separator: "\n"),
            "small.txt": "a\nb\r\nc",
        ])
        let big = try EditorDocument(url: root.appending(path: "big.txt"))
        try big.save()
        let expected = (0..<2_500).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n"
        #expect(try String(contentsOf: root.appending(path: "big.txt"), encoding: .utf8) == expected)
        #expect(big.lineEnding == .crlf)
        let small = try EditorDocument(url: root.appending(path: "small.txt"))
        try small.save()
        #expect(try String(contentsOf: root.appending(path: "small.txt"), encoding: .utf8) == "a\r\nb\r\nc\r\n")
    }

    @Test func savingTheConfigInTheEditorAppliesItToOpenFiles() throws {
        let root = try makeTree([".editorconfig": "root = true\n[*]\nindent_size = 2\nindent_style = space\n", "a.swift": "x\n"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "a.swift"))
        let file = try #require(workspace.activeDocument)
        #expect(file.indentation == (2, true))
        workspace.open(fileAt: root.appending(path: ".editorconfig"))
        let config = try #require(workspace.activeDocument)
        try config.apply([TextReplacement(range: NSRange(location: 0, length: config.textStorage.length),
                                          text: "root = true\n[*]\nindent_style = tab\ntab_width = 6\n")], actionName: "Edit")
        #expect(workspace.save(config))
        #expect(file.indentation == (6, false))
        #expect(file.editorConfig.sources.first?.lastPathComponent == ".editorconfig")
    }
}
