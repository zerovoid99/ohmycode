import AppKit
import Testing
import WebKit
@testable import Oh_My_Code

struct MarkdownRendererTests {
    private func html(_ markdown: String, resolve: @escaping (String) -> String = { $0 }) -> String {
        var renderer = MarkdownRenderer(resolveURL: resolve)
        return renderer.render(markdown).html
    }

    @Test func rendersBlocksWithTheirSourceLines() {
        let output = html("""
        # Title #

        Some *text* and **bold**,
        continued.

        Setext
        ------
        > quoted
        > still

        ---
        ```swift
        let x = 1 < 2
        ```

            indented code
        """)
        #expect(output.contains(#"<h1 data-line="0" id="title">Title</h1>"#))
        #expect(output.contains("<p data-line=\"2\">Some <em>text</em> and <strong>bold</strong>,\ncontinued.</p>"))
        #expect(output.contains(#"<h2 data-line="5" id="setext">Setext</h2>"#))
        #expect(output.contains("<blockquote data-line=\"7\">\n<p data-line=\"7\">quoted\nstill</p>\n</blockquote>"))
        #expect(output.contains(#"<hr data-line="10">"#))
        #expect(output.contains("<pre data-line=\"11\"><code id=\"code-0\" class=\"language-swift\">let x = 1 &lt; 2\n</code></pre>"))
        #expect(output.contains("<pre data-line=\"15\"><code>indented code\n</code></pre>"))
    }

    @Test func rendersListsAndTasks() {
        let tight = html("- one\n- two\n  - nested\n- [x] done\n- [ ] todo\n\n3. three\n4. four")
        #expect(tight.contains("<ul data-line=\"0\" class=\"contains-task-list\">\n<li data-line=\"0\">one</li>\n<li data-line=\"1\">two\n<ul data-line=\"2\">\n<li data-line=\"2\">nested</li>\n</ul></li>"))
        #expect(tight.contains(#"<li data-line="3" class="task-list-item"><input type="checkbox" disabled checked> done</li>"#))
        #expect(tight.contains(#"<input type="checkbox" disabled> todo"#))
        #expect(tight.contains("<ol data-line=\"6\" start=\"3\">\n<li data-line=\"6\">three</li>\n<li data-line=\"7\">four</li>\n</ol>"))

        let loose = html("* a\n\n* b\n  lazy")
        #expect(loose.contains("<li data-line=\"0\"><p data-line=\"0\">a</p></li>\n<li data-line=\"2\"><p data-line=\"2\">b\nlazy</p></li>"))
    }

    @Test func rendersTables() {
        let output = html("| Name | Count |\n|:-----|------:|\n| `a|b` | 2 |\n| c \\| d |\n")
        #expect(output.contains("<table data-line=\"0\">\n<thead><tr><th style=\"text-align:left\">Name</th><th style=\"text-align:right\">Count</th></tr></thead>"))
        #expect(output.contains("<tr data-line=\"2\"><td style=\"text-align:left\"><code>a|b</code></td><td style=\"text-align:right\">2</td></tr>"))
        #expect(output.contains("<td style=\"text-align:left\">c | d</td><td style=\"text-align:right\"></td>"))
    }

    @Test func rendersInlineElements() {
        #expect(html("a `x *y*` b") == "<p data-line=\"0\">a <code>x *y*</code> b</p>\n")
        #expect(html("``a ` b``") == "<p data-line=\"0\"><code>a ` b</code></p>\n")
        #expect(html("~~gone~~ snake_case_name __strong__ ***both***")
                == "<p data-line=\"0\"><del>gone</del> snake_case_name <strong>strong</strong> <strong><em>both</em></strong></p>\n")
        #expect(html(#"[site](https://x.dev "Title") ![logo](img/a.png)"#, resolve: { $0.hasPrefix("img/") ? "omc-file:///r/" + $0 : $0 })
                == "<p data-line=\"0\"><a href=\"https://x.dev\" title=\"Title\">site</a> <img src=\"omc-file:///r/img/a.png\" alt=\"logo\"></p>\n")
        #expect(html("[ref] and [text][r2]\n\n[ref]: /a\n[R2]: <b c> 'T'")
                == "<p data-line=\"0\"><a href=\"/a\">ref</a> and <a href=\"b c\" title=\"T\">text</a></p>\n")
        #expect(html("see https://example.com/a_(b). or <me@x.org> &amp; 1 < 2 \\*no\\*")
                == "<p data-line=\"0\">see <a href=\"https://example.com/a_(b)\">https://example.com/a_(b)</a>. or <a href=\"mailto:me@x.org\">me@x.org</a> &amp; 1 &lt; 2 *no*</p>\n")
        #expect(html("line  \nbreak<br/><span class=\"k\">x</span>") == "<p data-line=\"0\">line<br>\nbreak<br/><span class=\"k\">x</span></p>\n")
        #expect(html("**unclosed and * star") == "<p data-line=\"0\">**unclosed and * star</p>\n")
        #expect(html("[not a link] [x](") == "<p data-line=\"0\">[not a link] [x](</p>\n")
    }

    /// Raw HTML can't navigate the preview away (to a page without its CSP) or retarget it: those
    /// tags show as text. Harmless HTML stays.
    @Test func neutralizesTagsThatNavigateOrRun() {
        let block = html("<meta http-equiv=\"refresh\" content=\"0;url=https://evil.example\">\n<BASE href=\"https://evil.example/\">\n<div>ok</div>")
        #expect(block == "&lt;meta http-equiv=\"refresh\" content=\"0;url=https://evil.example\">\n&lt;BASE href=\"https://evil.example/\">\n<div>ok</div>\n")
        #expect(html("<form action=\"https://evil.example\"><button>go</button></form>")
                == "&lt;form action=\"https://evil.example\"><button>go</button>&lt;/form>\n")
        #expect(html("a <script>x()</script> <iframe src=x> <metadata> b")
                == "<p data-line=\"0\">a &lt;script>x()&lt;/script> &lt;iframe src=x> <metadata> b</p>\n")
    }

    @MainActor @Test func previewOnlyLoadsItsOwnPage() {
        typealias Preview = MarkdownPreviewController
        let page = LocalFileSchemeHandler.url(for: URL(filePath: "/r/", directoryHint: .isDirectory))
        let remote = URL(string: "https://evil.example/")!
        #expect(Preview.decision(for: page, type: .other, isMainFrame: true, page: page) == .allow)
        #expect(Preview.decision(for: URL(string: "about:blank"), type: .other, isMainFrame: true, page: page) == .allow)
        // A refresh, a form, a frame, another local page: cancelled.
        #expect(Preview.decision(for: remote, type: .other, isMainFrame: true, page: page) == .cancel)
        #expect(Preview.decision(for: remote, type: .formSubmitted, isMainFrame: true, page: page) == .cancel)
        #expect(Preview.decision(for: page, type: .other, isMainFrame: false, page: page) == .cancel)
        #expect(Preview.decision(for: LocalFileSchemeHandler.url(for: URL(filePath: "/r/x.html")), type: .other, isMainFrame: true, page: page) == .cancel)
        // Clicked links open elsewhere, by scheme.
        #expect(Preview.decision(for: remote, type: .linkActivated, isMainFrame: true, page: page) == .openInBrowser(remote))
        #expect(Preview.decision(for: URL(string: "mailto:a@b.c"), type: .linkActivated, isMainFrame: true, page: page)
                == .openInBrowser(URL(string: "mailto:a@b.c")!))
        #expect(Preview.decision(for: LocalFileSchemeHandler.url(for: URL(filePath: "/r/b.md")), type: .linkActivated, isMainFrame: true, page: page)
                == .openFile(URL(filePath: "/r/b.md")))
        #expect(Preview.decision(for: URL(string: "file:///Applications/Calculator.app"), type: .linkActivated, isMainFrame: true, page: page) == .cancel)
        #expect(Preview.decision(for: URL(string: "x-apple.systempreferences:"), type: .linkActivated, isMainFrame: true, page: page) == .cancel)
    }

    @Test func listsFencedCodeBlocks() {
        var renderer = MarkdownRenderer()
        let result = renderer.render("```py\nprint(1)\n```\n\n~~~\nplain\n~~~")
        #expect(result.codeBlocks == [MarkdownRenderer.CodeBlock(id: 0, language: "py", code: "print(1)"),
                                      MarkdownRenderer.CodeBlock(id: 1, language: "", code: "plain")])
    }
}

@MainActor
struct MarkdownPreviewTests {
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while try await !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(30))
        }
        return true
    }

    @Test func previewFollowsTheDocumentAndItsScrolling() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "img"), withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: folder.appending(path: "img/dot.png"))
        var text = "# Notes\n\n![dot](img/dot.png)\n\n<script>document.title = 'ran'</script>\n\n```swift\nlet x = \"hi\"\n```\n"
        for index in 0..<150 { text += "\nParagraph \(index)\n" }
        let url = folder.appending(path: "notes.md")
        try text.write(to: url, atomically: true, encoding: .utf8)

        let document = try EditorDocument(url: url)
        let editor = EditorController(document: document)
        let preview = MarkdownPreviewController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let split = NSSplitView(frame: window.contentView!.bounds)
        split.isVertical = true
        split.addArrangedSubview(editor.makeView())
        split.addArrangedSubview(preview.webView)
        window.contentView = split
        split.adjustSubviews()
        window.layoutIfNeeded()
        document.attach(editor)
        document.editor = editor
        await preview.waitUntilLoaded()

        #expect(try await preview.evaluate("document.querySelector('h1').textContent") as? String == "Notes")
        // The page's own scripts don't run; local images load.
        #expect(try await preview.evaluate("document.title") as? String != "ran")
        #expect(try await eventually { try await preview.evaluate("document.querySelector('img').naturalWidth") as? Int == 4 })
        // Code is colored by the editor's highlighter.
        #expect(try await eventually {
            (try await preview.evaluate("document.querySelectorAll('#code-0 span').length") as? Int ?? 0) > 0
        })

        // Edits show up.
        document.textStorage.replaceCharacters(in: NSRange(location: 2, length: 5), with: "Diary")
        #expect(try await eventually { try await preview.evaluate("document.querySelector('h1').textContent") as? String == "Diary" })
        #expect(try await preview.evaluate("document.querySelectorAll('#code-0 span').length") as? Int ?? 0 > 0)

        // The editor scrolls: the page follows to the same paragraph.
        editor.scroll(toLine: 200)
        #expect(try await eventually {
            let line = try await preview.evaluate("omc.lineAtTop()") as? Double ?? 0
            return abs(line - 200) < 3
        })
        // The page scrolls (after the synced scroll settles: echoes are ignored): the editor follows.
        try await Task.sleep(for: .milliseconds(300))
        _ = try await preview.evaluate("window.scrollTo(0, document.querySelector('[data-line=\"60\"]').getBoundingClientRect().top + window.scrollY - 12)")
        #expect(try await eventually { abs(editor.scrollPosition - 60) < 3 })
        withExtendedLifetime((window, preview)) {}
    }

    @Test func workspaceTogglesThePreviewForMarkdownOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-md-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# a".write(to: folder.appending(path: "a.md"), atomically: true, encoding: .utf8)
        try "a".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(folder)
        workspace.open(fileAt: folder.appending(path: "a.md"))
        let markdown = try #require(workspace.activeDocument)
        workspace.toggleMarkdownPreview()
        #expect(workspace.showsMarkdownPreview(markdown))
        workspace.open(fileAt: folder.appending(path: "a.txt"))
        let plain = try #require(workspace.activeDocument)
        workspace.toggleMarkdownPreview()
        #expect(!workspace.showsMarkdownPreview(plain))
        workspace.toggleMarkdownPreview(markdown)
        #expect(!workspace.showsMarkdownPreview(markdown))
    }
}
