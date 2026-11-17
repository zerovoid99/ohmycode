import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A response tab: the status line, time and size, then the body, headers, cookies, timeline
/// and the request as sent.
struct HTTPResponseView: View {
    let tab: HTTPResponseTab
    let workspace: Workspace

    enum Section: String, CaseIterable, Identifiable {
        case body = "Body", headers = "Headers", cookies = "Cookies", timeline = "Timeline", request = "Request"
        var id: String { rawValue }
    }

    @State private var section = Section.body

    var body: some View {
        VStack(spacing: 0) {
            HTTPResponseHeaderBar(tab: tab, workspace: workspace)
            Divider()
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .editorBackground()
    }

    @ViewBuilder private var content: some View {
        switch tab.state {
        case .sending where tab.response == nil:
            VStack(spacing: 8) {
                ProgressView()
                Text("Sending \(tab.request.map { "\($0.method) \($0.url.absoluteString)" } ?? "")…")
                    .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                Button("Cancel") { tab.task?.cancel() }
            }
            .padding()
        case .failed(let message):
            ContentUnavailableView {
                Label("No response", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Send Again") { workspace.http.rerun(tab) }
            }
        case .cancelled where tab.response == nil:
            ContentUnavailableView {
                Label("Cancelled", systemImage: "stop.circle")
            } actions: {
                Button("Send Again") { workspace.http.rerun(tab) }
            }
        default:
            if let response = tab.response {
                switch section {
                case .body: HTTPResponseBodyView(tab: tab, response: response, workspace: workspace)
                case .headers: HTTPHeadersView(request: tab.request, response: response)
                case .cookies: HTTPCookiesView(response: response, jar: workspace.http.cookieJar)
                case .timeline: HTTPTimelineView(timings: response.timings)
                case .request: HTTPRequestTextView(request: tab.request)
                }
            }
        }
    }
}

/// Status, time, size, and the tab's buttons.
private struct HTTPResponseHeaderBar: View {
    let tab: HTTPResponseTab
    let workspace: Workspace

    private func color(_ status: Int) -> Color {
        switch status {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        default: .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let response = tab.response {
                Text("\(response.statusCode) \(response.reason)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color(response.statusCode), in: RoundedRectangle(cornerRadius: 4))
                let timings = response.timings
                Text([HTTPResponseFormat.duration(timings.total),
                      timings.timeToFirstByte.map { "TTFB \(HTTPResponseFormat.duration($0))" },
                      HTTPResponseFormat.size(response.bodySize),
                      timings.protocolName].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if let request = tab.request {
                Text("\(request.method) \(request.url.absoluteString)").font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if tab.isSending { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if tab.isSending {
                Button { tab.task?.cancel() } label: { Image(systemName: "stop.circle") }.help("Cancel Request")
            }
            Button { workspace.http.rerun(tab) } label: { Image(systemName: "arrow.clockwise") }
                .help("Send the request again")
            Button { tab.isPinned.toggle() } label: { Image(systemName: tab.isPinned ? "pin.fill" : "pin") }
                .help(tab.isPinned ? "Unpin: the next send of this request shows here again"
                                   : "Pin: keep this response; the next send opens a new tab")
            if tab.response != nil {
                Menu {
                    Button("Copy Body") { copyBody() }
                    Button("Save Body…") { saveBody() }
                    Button("Open Body in Editor") { openBody() }
                    if let request = tab.request {
                        Divider()
                        Button("Copy Request as cURL") { copy(HTTPCurl.command(for: request)) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Copy, save or open the body")
                Button {
                    workspace.explainHTTPResponse(tab)
                } label: {
                    Image(systemName: "sparkles")
                }
                .disabled(!AISettings.shared.isConfigured)
                .help(AISettings.shared.isConfigured ? "Explain Response with AI" : AIActions.notConfiguredHelp)
                .popover(item: Binding(get: { tab.explanation }, set: { tab.explanation = $0 }), arrowEdge: .bottom) { model in
                    AIExplainView(model: model) { tab.explanation?.stop(); tab.explanation = nil }
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var kind: HTTPResponseFormat.BodyKind {
        tab.response.map { HTTPResponseFormat.kind(contentType: $0.contentType, body: $0.body) } ?? .empty
    }

    private func copyBody() {
        guard let response = tab.response else { return }
        let body = response.fullBody()
        if kind == .image, let image = NSImage(data: body) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        } else {
            copy(String(decoding: body, as: UTF8.self))
        }
    }

    private func saveBody() {
        guard let response = tab.response else { return }
        let panel = NSSavePanel()
        let ext = kind.fileExtension(contentType: response.contentType)
        let last = response.url.lastPathComponent
        panel.nameFieldStringValue = last.isEmpty || last == "/" ? "response.\(ext)" : (last.contains(".") ? last : "\(last).\(ext)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let file = response.bodyFile {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: file, to: url)
            } else {
                try response.body.write(to: url)
            }
        } catch {
            workspace.errorMessage = error.localizedDescription
        }
    }

    private func openBody() {
        guard let response = tab.response else { return }
        let ext = kind.fileExtension(contentType: response.contentType)
        let name = tab.requestName ?? "response"
        if kind == .json || kind == .xml {
            workspace.http.openScratch(HTTPResponseFormat.displayText(response.fullBody(), kind: kind, pretty: true), name: name, fileExtension: ext)
        } else {
            workspace.http.openScratch(data: response.fullBody(), name: name, fileExtension: ext)
        }
    }
}

// MARK: Body

private struct HTTPResponseBodyView: View {
    let tab: HTTPResponseTab
    let response: HTTPResponse
    let workspace: Workspace

    enum Mode: String, CaseIterable, Identifiable {
        case pretty = "Pretty", raw = "Raw", preview = "Preview"
        var id: String { rawValue }
    }

    @State private var mode = Mode.pretty

    /// Text past this is shown cut (the whole body is a Save or Open away).
    static let displayLimit = 2 * 1024 * 1024

    private var kind: HTTPResponseFormat.BodyKind { HTTPResponseFormat.kind(contentType: response.contentType, body: response.body) }

    var body: some View {
        VStack(spacing: 0) {
            if kind != .empty, kind != .image, kind != .binary {
                HStack {
                    Picker("", selection: $mode) {
                        ForEach(kind == .html ? Mode.allCases : [.pretty, .raw]) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    if !response.isBodyComplete || response.body.count > Self.displayLimit {
                        Text("Showing the first \(HTTPResponseFormat.size(min(response.body.count, Self.displayLimit))) of \(HTTPResponseFormat.size(response.bodySize))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .empty:
            ContentUnavailableView("No body", systemImage: "doc", description: Text("The response has no body."))
        case .image:
            HTTPImageView(data: response.fullBody())
        case .binary:
            VStack(spacing: 0) {
                HTTPHighlightedText(text: HTTPResponseFormat.hexPreview(response.body), language: nil)
                Divider()
                HStack {
                    Text("Binary · \(HTTPResponseFormat.size(response.bodySize))" + (response.bodySize > 4096 ? " · first 4 KB shown" : ""))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10).frame(height: 28)
            }
        case .html where mode == .preview:
            HTTPWebPreview(html: String(decoding: response.body, as: UTF8.self), baseURL: response.url)
        default:
            let body = response.body.count > Self.displayLimit ? response.body.prefix(Self.displayLimit) : response.body
            let pretty = mode == .pretty && response.isBodyComplete && response.body.count <= Self.displayLimit
            HTTPHighlightedText(text: HTTPResponseFormat.displayText(Data(body), kind: kind, pretty: pretty),
                                language: kind == .json ? .json : kind == .xml || kind == .html ? .xml : nil)
        }
    }
}

/// Read-only text in the editor's font and colors, highlighted as JSON or XML.
struct HTTPHighlightedText: NSViewRepresentable {
    enum Language { case json, xml }

    let text: String
    let language: Language?

    final class Coordinator {
        var text: String?
        var task: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.isRichText = false
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.isAutomaticLinkDetectionEnabled = false
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, context.coordinator.text != text else { return }
        context.coordinator.text = text
        context.coordinator.task?.cancel()
        let storage = NSTextStorage(string: text, attributes: EditorTheme.baseAttributes)
        textView.textStorage?.setAttributedString(storage)
        guard let language, (text as NSString).length <= 1_000_000 else { return }
        let text = self.text
        context.coordinator.task = Task { @MainActor in
            let highlights = await Self.highlights(text, language: language)
            guard !Task.isCancelled, let textStorage = textView.textStorage, textStorage.string == text else { return }
            textStorage.beginEditing()
            for (range, capture) in highlights {
                guard NSMaxRange(range) <= textStorage.length, let color = EditorTheme.color(forCapture: capture) else { continue }
                textStorage.addAttribute(.foregroundColor, value: color, range: range)
            }
            textStorage.endEditing()
        }
    }

    /// The colors: JSON by its tree-sitter grammar, XML line by line.
    static func highlights(_ text: String, language: Language) async -> [(NSRange, String)] {
        switch language {
        case .json:
            guard let highlighter = SyntaxHighlighter(language: .json, textStorage: NSTextStorage(string: text)) else { return [] }
            return await highlighter.highlights(in: NSRange(location: 0, length: (text as NSString).length)).map { ($0.range, $0.name) }
        case .xml:
            let string = text as NSString
            var result: [(NSRange, String)] = []
            string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines]) { line, range, _, _ in
                guard let line else { return }
                result += HTTPSyntax.lineTokens(line, at: range.location, state: .body(.xml)).map { ($0.range, $0.capture) }
            }
            return result
        }
    }
}

private struct HTTPImageView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> ImageScrollView { ImageScrollView() }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        guard let image = NSImage(data: data) else { return }
        if let rep = image.representations.first, rep.pixelsWide > 0 { image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        view.show(image)
    }
}

/// An HTML body rendered (scripts off; links don't navigate).
private struct HTTPWebPreview: NSViewRepresentable {
    let html: String
    let baseURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.loadHTMLString(html, baseURL: baseURL)
    }
}

// MARK: Headers, cookies, timeline, request

private struct HTTPHeaderList: View {
    let title: String
    let headers: [HTTPHeader]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if headers.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    GridRow {
                        Text(header.name).fontWeight(.medium).gridColumnAlignment(.trailing)
                        Text(header.value).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
        }
    }
}

private struct HTTPHeadersView: View {
    let request: HTTPPreparedRequest?
    let response: HTTPResponse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HTTPHeaderList(title: "Response Headers", headers: response.headers)
                if let request { HTTPHeaderList(title: "Request Headers", headers: request.headers) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

private struct HTTPCookiesView: View {
    let response: HTTPResponse
    let jar: HTTPCookieJar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Set by this response").font(.headline)
                if response.cookies.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        GridRow {
                            ForEach(["Name", "Value", "Domain", "Path", "Expires", ""], id: \.self) { Text($0).foregroundStyle(.secondary) }
                        }
                        ForEach(Array(response.cookies.enumerated()), id: \.offset) { _, cookie in
                            GridRow {
                                Text(cookie.name).fontWeight(.medium)
                                Text(cookie.value).lineLimit(1).truncationMode(.middle)
                                Text(cookie.domain)
                                Text(cookie.path)
                                Text(cookie.expires?.formatted(date: .abbreviated, time: .shortened) ?? "Session")
                                Text([cookie.isSecure ? "Secure" : nil, cookie.isHTTPOnly ? "HttpOnly" : nil].compactMap { $0 }.joined(separator: " "))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                }
                let stored = jar.cookies(for: response.url)
                Text("\(stored.count) cookie\(stored.count == 1 ? "" : "s") in this workspace's jar for \(response.url.host ?? "this host") (REST: Clear Cookies empties it)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

private struct HTTPTimelineView: View {
    let timings: HTTPTimings

    private var rows: [(String, TimeInterval?)] {
        [("DNS lookup", timings.dns), ("Connect", timings.connect), ("TLS handshake", timings.tls),
         ("Request sent", timings.request), ("Waiting (TTFB)", timings.waiting), ("Download", timings.download)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(rows, id: \.0) { name, value in
                        GridRow {
                            Text(name)
                            GeometryReader { geometry in
                                let share = timings.total > 0 ? (value ?? 0) / timings.total : 0
                                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(value == nil ? 0 : 2, geometry.size.width * min(1, share)))
                            }
                            .frame(width: 240, height: 10)
                            Text(value.map(HTTPResponseFormat.duration) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("Total").fontWeight(.semibold)
                        Color.clear.frame(width: 240, height: 1)
                        Text(HTTPResponseFormat.duration(timings.total)).monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let protocolName = timings.protocolName { Text("Protocol: \(protocolName)") }
                    if let remote = timings.remoteAddress { Text("Remote address: \(remote)") }
                    if timings.reusedConnection { Text("Reused an open connection") }
                    if timings.redirects > 0 { Text("Followed \(timings.redirects) redirect\(timings.redirects == 1 ? "" : "s")") }
                }
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

private struct HTTPRequestTextView: View {
    let request: HTTPPreparedRequest?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("The request as sent, variables filled in").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let request {
                    Button("Copy as cURL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(HTTPCurl.command(for: request), forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            HTTPHighlightedText(text: request?.text ?? "", language: nil)
        }
    }
}

// MARK: Settings

struct HTTPClientSettingsView: View {
    @Bindable var settings = HTTPClientSettings.shared

    var body: some View {
        Form {
            Stepper("Timeout: \(Int(settings.timeout)) s", value: $settings.timeout, in: 1...600, step: 5)
            Toggle("Follow redirects (a request's “# @no-redirect” turns it off for that request)", isOn: $settings.followRedirects)
            Toggle("Accept self-signed certificates from localhost", isOn: $settings.allowSelfSignedLocalhost)
            Text("Requests in .http and .rest files are sent with ⌥⌘R or the “Send Request” lens. Environments come from rest-client.environmentVariables in .vscode/settings.json or .omc/settings.json, and from http-client.env.json (with http-client.private.env.json).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
    }
}
