import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SwiftTreeSitter
import WebKit

extension EditorController {
    static let didScrollNotification = Notification.Name("omcEditorDidScroll")

    /// The first visible line, with how far it's scrolled past (2.5: halfway through line 2).
    var scrollPosition: Double {
        let line = topVisibleLine
        guard let rect = rect(for: NSRange(location: document.lineIndex.lineStarts[line], length: 0)) else { return Double(line) }
        let fraction = (textView.visibleRect.minY - rect.minY) / max(1, lineHeight)
        return Double(line) + min(max(0, fraction), 0.99)
    }

    /// Scrolls so `line` (fractional, as `scrollPosition`) is at the top.
    func scroll(toLine line: Double) {
        let whole = Int(line.rounded(.down))
        scrollLineToTop(whole)
        let fraction = line - Double(whole)
        if fraction > 0 {
            textView.scroll(NSPoint(x: textView.visibleRect.minX, y: textView.visibleRect.minY + fraction * lineHeight))
        }
    }
}

/// Serves local files (`omc-file:///path`) to the preview: images and other files the
/// Markdown refers to.
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "omc-file"

    static func url(for fileURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = fileURL.path
        return components.url ?? fileURL
    }

    static func fileURL(for url: URL) -> URL { URL(filePath: url.path(percentEncoded: false)) }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file = Self.fileURL(for: url)
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// The rendered page beside a Markdown file: follows edits as you type, scrolls with the
/// editor (and the editor with it), opens links (web ones in the browser, files in the editor).
@MainActor
final class MarkdownPreviewController: NSObject {
    let document: EditorDocument
    let webView: WKWebView
    /// Opens a file the page links to (at a line, for double-clicks on the page itself).
    var openFile: (URL, Int?) -> Void = { _, _ in }
    private(set) var isLoaded = false
    /// What the page shows (for tests).
    private(set) var renderedHTML = ""
    private var renderTask: Task<Void, Never>?
    private var highlightCache: [String: String] = [:]
    /// The shown page's code blocks.
    private var codeBlocks: [MarkdownRenderer.CodeBlock] = []
    /// Scroll events caused by syncing the other side are ignored until then.
    private var ignoreEditorScrollUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    init(document: EditorDocument) {
        self.document = document
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                              in: .defaultClient))
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(WeakMessageHandler(self), contentWorld: .defaultClient, name: "omc")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: document.textStorage, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRender() } })
        observers.append(NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: EditorController.didScrollNotification, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let editor = note.object
            MainActor.assumeIsolated {
                guard let self, let editor = editor as? EditorController, editor.document === self.document else { return }
                self.editorDidScroll(editor)
            }
        })
        reload()
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        renderTask?.cancel()
    }

    // MARK: Rendering

    private var folder: URL { document.url.deletingLastPathComponent() }

    private func render() -> MarkdownRenderer.Result {
        var renderer = MarkdownRenderer()
        return renderer.render(document.textStorage.string)
    }

    /// Loads the whole page (first time, or when the theme changes).
    func reload() {
        let result = render()
        renderedHTML = result.html
        codeBlocks = result.codeBlocks
        isLoaded = false
        let page = Self.page(body: result.html, css: Self.css(appearance: webView.effectiveAppearance))
        let base = LocalFileSchemeHandler.url(for: folder.appending(path: "", directoryHint: .isDirectory))
        webView.loadHTMLString(page, baseURL: base)
        highlight(result.codeBlocks)
    }

    /// Edits re-render the page's content shortly after typing pauses.
    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    func update() {
        let result = render()
        guard result.html != renderedHTML else { return }
        renderedHTML = result.html
        codeBlocks = result.codeBlocks
        // Code blocks already highlighted go in with the content, in one script (no flash of
        // plain code).
        run("omc.setContent(\(Self.jsonString(result.html)));" + cachedCodeScript())
        highlight(result.codeBlocks.filter { highlightCache[Self.cacheKey($0)] == nil })
    }

    private func cachedCodeScript() -> String {
        codeBlocks.compactMap { block in
            highlightCache[Self.cacheKey(block)].map {
                "omc.setCode(\(block.id), \(Self.jsonString($0)), \(Self.jsonString(block.code)));"
            }
        }.joined()
    }

    private static func cacheKey(_ block: MarkdownRenderer.CodeBlock) -> String { block.language + "\u{0}" + block.code }

    /// Colors code blocks with the editor's highlighter, then puts them in the page.
    private func highlight(_ blocks: [MarkdownRenderer.CodeBlock]) {
        for block in blocks {
            guard let language = Self.language(for: block.language), language != .plaintext,
                  let highlighter = SyntaxHighlighter(language: language, textStorage: NSTextStorage(string: block.code)) else { continue }
            let key = Self.cacheKey(block)
            Task { [weak self] in
                let highlights = await highlighter.highlights(in: NSRange(location: 0, length: (block.code as NSString).length))
                guard let self else { return }
                let html = Self.highlightedHTML(block.code, highlights)
                highlightCache[key] = html
                if highlightCache.count > 200 { highlightCache.removeAll() }
                run("omc.setCode(\(block.id), \(Self.jsonString(html)), \(Self.jsonString(block.code)))")
            }
        }
    }

    static func language(for info: String) -> SourceLanguage? {
        switch info.lowercased() {
        case "": nil
        case "javascript", "node": .javascript
        case "typescript": .typescript
        case "python", "python3": .python
        case "rust": .rust
        case "golang": .go
        case "c++": .cpp
        case "objective-c", "objectivec": .objc
        case "bash", "zsh", "shell", "console": .shell
        case "markdown": .markdown
        default: SourceLanguage(fileExtension: info.lowercased())
        }
    }

    /// Code with each highlight as a colored span (later highlights win, as in the editor).
    static func highlightedHTML(_ code: String, _ highlights: [NamedRange]) -> String {
        let text = code as NSString
        var colors = [String?](repeating: nil, count: text.length)
        for highlight in highlights {
            guard let color = EditorTheme.color(forCapture: highlight.name).map(hex) else { continue }
            let range = NSIntersectionRange(highlight.range, NSRange(location: 0, length: text.length))
            for index in range.location..<NSMaxRange(range) { colors[index] = color }
        }
        var html = ""
        var start = 0
        while start < text.length {
            var end = start + 1
            while end < text.length, colors[end] == colors[start] { end += 1 }
            let piece = MarkdownRenderer.escape(text.substring(with: NSRange(location: start, length: end - start)))
            html += colors[start].map { "<span style=\"color:\($0)\">\(piece)</span>" } ?? piece
            start = end
        }
        return html
    }

    // MARK: Scrolling

    private func editorDidScroll(_ editor: EditorController) {
        guard isLoaded, Date() >= ignoreEditorScrollUntil else { return }
        run("omc.scrollToLine(\(editor.scrollPosition))")
    }

    /// The page scrolled (by the user): the editor follows.
    private func pageDidScroll(toLine line: Double) {
        guard let editor = document.editor else { return }
        ignoreEditorScrollUntil = Date().addingTimeInterval(0.15)
        editor.scroll(toLine: line)
    }

    private func run(_ script: String) {
        guard isLoaded else { return }
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
    }

    /// Returns once the page has loaded (tests).
    func waitUntilLoaded() async {
        guard !isLoaded else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    /// Runs script in the page (tests).
    func evaluate(_ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script, contentWorld: .defaultClient)
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "scroll":
            if let line = message["line"] as? Double { pageDidScroll(toLine: line) }
        case "reveal":
            if let line = message["line"] as? Int {
                openFile(document.url, line)
            }
        default:
            break
        }
    }

    // MARK: Page

    private static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    private static func css(appearance: NSAppearance) -> String {
        var colors: (background: String, foreground: String, border: String, code: String, link: String, muted: String) = ("", "", "", "", "", "")
        let theme = EditorTheme.current
        (theme.appearance ?? appearance).performAsCurrentDrawingAppearance {
            let background = theme.background.usingColorSpace(.sRGB) ?? theme.background
            let foreground = theme.foreground.usingColorSpace(.sRGB) ?? theme.foreground
            colors = (hex(background), hex(foreground),
                      hex(foreground.withAlphaComponent(1).blended(withFraction: 0.82, of: background) ?? foreground),
                      hex(foreground.blended(withFraction: 0.94, of: background) ?? background),
                      hex(NSColor.linkColor), hex(foreground.blended(withFraction: 0.4, of: background) ?? foreground))
        }
        let font = EditorTheme.font
        return """
        :root { color-scheme: light dark; }
        html { background: \(colors.background); }
        body { color: \(colors.foreground); background: \(colors.background); font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
               max-width: 900px; margin: 0 auto; padding: 16px 28px 40vh; word-wrap: break-word; }
        a { color: \(colors.link); text-decoration: none; } a:hover { text-decoration: underline; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.6em; font-weight: 600; }
        h1 { font-size: 2em; border-bottom: 1px solid \(colors.border); padding-bottom: .3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid \(colors.border); padding-bottom: .3em; }
        h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: \(colors.muted); }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        ul, ol { padding-left: 2em; } li + li { margin-top: .25em; }
        li.task-list-item { list-style: none; } li.task-list-item input { margin: 0 .3em 0 -1.4em; vertical-align: middle; }
        blockquote { padding: 0 1em; color: \(colors.muted); border-left: .25em solid \(colors.border); }
        code, pre { font-family: "\(font.familyName ?? "SF Mono")", ui-monospace, Menlo, monospace; font-size: \(max(11, font.pointSize - 1))px; }
        code { background: \(colors.code); padding: .15em .35em; border-radius: 4px; }
        pre { background: \(colors.code); padding: 12px 16px; border-radius: 6px; overflow-x: auto; line-height: 1.45; }
        pre code { background: none; padding: 0; }
        hr { border: 0; border-top: 2px solid \(colors.border); margin: 1.5em 0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid \(colors.border); padding: 6px 13px; } th { font-weight: 600; }
        tr:nth-child(2n) td { background: \(colors.code); }
        img { max-width: 100%; }
        """
    }

    private static func page(body: String, css: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src omc-file: https: http: data:; media-src omc-file: https:; style-src 'unsafe-inline'; font-src omc-file: data:">
        <style>\(css)</style></head>
        <body><div id="content">\(body)</div></body></html>
        """
    }

    /// Runs in its own content world: the page itself can't run scripts (see the CSP).
    private static let script = """
    (() => {
      let ignoreUntil = 0;
      const blocks = () => Array.from(document.querySelectorAll('[data-line]'))
        .map(el => ({ line: Number(el.dataset.line), top: el.getBoundingClientRect().top + window.scrollY, height: el.getBoundingClientRect().height }))
        .sort((a, b) => a.line - b.line || a.top - b.top);
      window.omc = {
        setContent(html) { document.getElementById('content').innerHTML = html; },
        setCode(id, html, code) {
          const el = document.getElementById('code-' + id);
          if (el && el.textContent === code + '\\n') { el.innerHTML = html + '\\n'; }
        },
        scrollToLine(line) {
          const list = blocks();
          if (!list.length) return;
          let before = list[0], after = null;
          for (const block of list) { if (block.line <= line) before = block; else { after = block; break; } }
          let y = before.top;
          if (line >= before.line) {
            const span = after ? after.line - before.line : 1;
            const end = after ? after.top : before.top + before.height;
            y = before.top + (end - before.top) * Math.min(1, (line - before.line) / Math.max(1, span));
          }
          ignoreUntil = Date.now() + 150;
          window.scrollTo(0, Math.max(0, y - 12));
        },
        lineAtTop() {
          const list = blocks();
          const top = window.scrollY + 12;
          let before = null, after = null;
          for (const block of list) { if (block.top <= top) before = block; else { after = block; break; } }
          if (!before) return 0;
          const end = after ? after.top : before.top + before.height;
          const span = after ? after.line - before.line : 1;
          return before.line + span * Math.min(1, (top - before.top) / Math.max(1, end - before.top));
        },
      };
      let pending = false;
      window.addEventListener('scroll', () => {
        if (Date.now() < ignoreUntil || pending) return;
        pending = true;
        setTimeout(() => {
          pending = false;
          window.webkit.messageHandlers.omc.postMessage({ type: 'scroll', line: omc.lineAtTop() });
        }, 16);
      });
      document.addEventListener('dblclick', event => {
        const el = event.target.closest('[data-line]');
        if (el) window.webkit.messageHandlers.omc.postMessage({ type: 'reveal', line: Number(el.dataset.line) });
      });
      document.addEventListener('click', event => {
        const link = event.target.closest('a[href^="#"]');
        if (!link) return;
        event.preventDefault();
        const target = document.getElementById(decodeURIComponent(link.getAttribute('href').slice(1)));
        if (target) target.scrollIntoView();
      });
    })();
    """
}

extension MarkdownPreviewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
        run(cachedCodeScript())
        if let editor = document.editor { run("omc.scrollToLine(\(editor.scrollPosition))") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
        if url.scheme == LocalFileSchemeHandler.scheme {
            let file = LocalFileSchemeHandler.fileURL(for: url)
            if FileManager.default.fileExists(atPath: file.path) { openFile(file, nil) }
        } else {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}

/// The content controller keeps its handlers: this doesn't keep the preview alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: MarkdownPreviewController?
    init(_ target: MarkdownPreviewController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.receive(body) }
    }
}

/// The preview beside a Markdown editor.
struct MarkdownPreviewView: NSViewRepresentable {
    let workspace: Workspace
    let document: EditorDocument

    func makeCoordinator() -> MarkdownPreviewController {
        let controller = MarkdownPreviewController(document: document)
        controller.openFile = { [weak workspace] url, line in
            guard let workspace else { return }
            workspace.open(fileAt: url)
            if let line, let document = workspace.document(matching: url) {
                document.revealLine(line + 1)
                document.editor?.focus()
            }
        }
        return controller
    }

    func makeNSView(context: Context) -> WKWebView { context.coordinator.webView }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
