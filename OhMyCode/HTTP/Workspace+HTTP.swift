import AppKit
import Observation

/// A response tab: the last answer to one request of a `.http` file (each send of the same
/// request shows here again, unless it's pinned).
@MainActor
@Observable
final class HTTPResponseTab: Identifiable {
    enum State: Equatable {
        case sending
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    /// Which request it answers: the file and the request's name (or position).
    let key: String
    private(set) var title: String
    var isPinned = false
    var state = State.sending
    var request: HTTPPreparedRequest?
    var response: HTTPResponse?
    /// Where the request is written (Rerun sends it from there again).
    var sourceFile: URL?
    var sourceLine = 0
    var requestName: String?
    var startedAt = Date()
    /// Explain Response's explanation, while its popover shows.
    var explanation: AIExplainModel?
    @ObservationIgnored var task: Task<Void, Never>?

    init(key: String, title: String) {
        self.key = key
        self.title = title
    }

    func rename(_ name: String) { title = "Response: \(name)" }

    var help: String { request.map { "\($0.method) \($0.url.absoluteString)" } ?? title }
    var isSending: Bool { state == .sending }
}

/// The window's REST client: sends requests from `.http` files, keeps their responses (for
/// request variables), the cookie jar, history and response tabs.
@MainActor
@Observable
final class HTTPWorkspaceClient {
    @ObservationIgnored private weak var workspace: Workspace?
    private(set) var responseTabs: [HTTPResponseTab] = []
    /// Sent requests' exchanges by file path, then request name.
    @ObservationIgnored private(set) var exchanges: [String: [String: HTTPExchangeRecord]] = [:]
    /// The last request sent (Rerun Last Request).
    @ObservationIgnored private(set) var lastSent: (file: URL?, line: Int, name: String?, text: String?)?
    /// Bumped when an environment is chosen (the status bar follows).
    private(set) var environmentVersion = 0

    // Swappable in tests.
    @ObservationIgnored var system = HTTPSystemContext()
    @ObservationIgnored var settings = HTTPClientSettings.shared
    @ObservationIgnored var askForPrompt: ((HTTPPrompt) async -> String?)?
    @ObservationIgnored var confirmNote: ((String) -> Bool)?
    @ObservationIgnored var quickPick: (([QuickPickItem], String) async -> Int?)?
    @ObservationIgnored var storageRoot: URL?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    // MARK: Storage

    private var storageKey: String {
        HTTPStorage.key(folders: workspace?.folders ?? [], workspaceFile: workspace?.workspaceFile)
    }

    private var storageFolder: URL { (storageRoot ?? HTTPStorage.root).appending(path: storageKey) }

    @ObservationIgnored private var jarCache: (key: String, jar: HTTPCookieJar)?
    @ObservationIgnored private var historyCache: (key: String, history: HTTPHistory)?

    /// This workspace's cookies (a window that opens other folders gets theirs).
    var cookieJar: HTTPCookieJar {
        let key = storageFolder.path
        if let jarCache, jarCache.key == key { return jarCache.jar }
        let jar = HTTPCookieJar(file: storageFolder.appending(path: "cookies.json"))
        jarCache = (key, jar)
        return jar
    }

    var history: HTTPHistory {
        let key = storageFolder.path
        if let historyCache, historyCache.key == key { return historyCache.history }
        let history = HTTPHistory(file: storageFolder.appending(path: "history.json"))
        historyCache = (key, history)
        return history
    }

    // MARK: Environments

    /// The folder a file's environment choice is kept for.
    private func environmentKey(for file: URL?) -> String {
        let folder = file.flatMap { workspace?.folder(containing: $0) } ?? workspace?.rootURL
        return HTTPStorage.key(folders: folder.map { [$0] } ?? [], workspaceFile: nil)
    }

    /// Read again at most every couple of seconds (the status bar asks on every redraw).
    @ObservationIgnored private var environmentCache: [String: (read: Date, environments: HTTPEnvironments)] = [:]

    func environments(for file: URL?) -> HTTPEnvironments {
        guard let file else { return HTTPEnvironments() }
        let key = file.deletingLastPathComponent().standardizedFileURL.path
        if let cached = environmentCache[key], Date().timeIntervalSince(cached.read) < 2 { return cached.environments }
        let environments = HTTPEnvironments.load(for: file, root: workspace?.folder(containing: file) ?? workspace?.rootURL)
        environmentCache[key] = (Date(), environments)
        return environments
    }

    /// The chosen environment for a file's folder (nil: none, or one that no longer exists).
    func environmentName(for file: URL?) -> String? {
        _ = environmentVersion
        guard let name = settings.environment(forKey: environmentKey(for: file)) else { return nil }
        return environments(for: file).environments[name] != nil ? name : nil
    }

    func setEnvironment(_ name: String?, for file: URL?) {
        settings.setEnvironment(name, forKey: environmentKey(for: file))
        environmentVersion += 1
        for document in workspace?.documents ?? [] where document.language == .http { document.refreshHTTPFeatures() }
    }

    /// REST: Switch Environment: a pick of "No Environment" and the file's environments.
    func switchEnvironment(for file: URL?) async {
        environmentCache.removeAll() // just edited, maybe
        let available = environments(for: file)
        let current = environmentName(for: file)
        let names = available.names
        var items = [QuickPickItem(label: "No Environment", description: current == nil ? "current" : nil,
                                   detail: available.shared.isEmpty ? nil : "Only the $shared variables")]
        items += names.map { name in
            QuickPickItem(label: name, description: name == current ? "current" : nil,
                          detail: (available.environments[name] ?? [:]).keys.sorted().joined(separator: ", "))
        }
        let placeholder = names.isEmpty
            ? "No environments: add rest-client.environmentVariables to .vscode/settings.json, or an http-client.env.json"
            : "Environment for requests in this folder"
        guard let index = await pick(items, placeholder: placeholder) else { return }
        setEnvironment(index == 0 ? nil : names[index - 1], for: file)
    }

    // MARK: Variables

    /// The resolver for a file's requests: its variables, the environment's, earlier
    /// responses, `.env`.
    func resolver(for file: HTTPFile, at url: URL?) -> HTTPVariableResolver {
        var system = self.system
        if let url {
            system.dotenv = DotEnv.load(for: url, root: workspace?.folder(containing: url) ?? workspace?.rootURL).merging(system.dotenv) { $1 }
        }
        return HTTPVariableResolver(fileVariables: file.variableValues,
                                    environment: environments(for: url).variables(for: environmentName(for: url)),
                                    exchanges: url.map { exchanges[$0.standardizedFileURL.path] ?? [:] } ?? [:],
                                    requestNames: file.requestNames, system: system)
    }

    /// Keeps an answer for request variables (`{{name.response…}}`).
    func record(_ exchange: HTTPExchangeRecord, name: String, file: URL?) {
        exchanges[file?.standardizedFileURL.path ?? "", default: [:]][name] = exchange
    }

    // MARK: Sending

    private func confirm(_ message: String) -> Bool {
        if let confirmNote { return confirmNote(message) }
        if let confirmation = workspace?.confirmation { return confirmation(message) }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func pick(_ items: [QuickPickItem], placeholder: String) async -> Int? {
        if let quickPick { return await quickPick(items, placeholder) }
        return await workspace?.showQuickPick(items, placeholder: placeholder)
    }

    private func answer(_ prompt: HTTPPrompt) async -> String? {
        if let askForPrompt { return await askForPrompt(prompt) }
        return await workspace?.showInputBox(prompt: prompt.description ?? "Value for “\(prompt.name)”", value: "", placeholder: prompt.name)
    }

    /// The request at `line` with its variables filled in (after asking its prompts and, with a
    /// `@note`, confirming); nil when cancelled. Errors are shown.
    func prepare(text: String, file: URL?, line: Int, confirmingNote: Bool = true) async -> (HTTPPreparedRequest, HTTPRequestBlock)? {
        let parsed = HTTPFile(text: text)
        guard let block = parsed.request(atLine: line) else {
            workspace?.errorMessage = "There's no request at line \(line + 1): put the cursor on a request (between “###” lines)."
            return nil
        }
        if confirmingNote, let note = block.note {
            let message = note.isEmpty ? "Send “\(block.displayName)”?" : "\(note)\n\nSend “\(block.displayName)”?"
            guard confirm(message) else { return nil }
        }
        var resolver = resolver(for: parsed, at: file)
        for prompt in block.prompts {
            guard let value = await answer(prompt) else { return nil }
            resolver.prompts[prompt.name] = value
        }
        let builder = HTTPRequestBuilder(resolver: resolver, baseDirectory: file?.deletingLastPathComponent())
        do {
            return (try builder.build(block), block)
        } catch {
            workspace?.errorMessage = "“\(block.displayName)” wasn't sent. \(error.localizedDescription)"
            return nil
        }
    }

    private static func key(file: URL?, block: HTTPRequestBlock) -> String {
        (file?.standardizedFileURL.path ?? "untitled") + "#" + (block.name ?? "\(block.method) \(block.url)")
    }

    /// Sends the request at `line` of `text` (the `.http` file at `file`): its response shows
    /// in its tab, beside `group` (the file's).
    @discardableResult
    func send(text: String, file: URL?, line: Int, beside group: EditorGroup? = nil) -> Task<HTTPResponseTab?, Never> {
        Task {
            guard let (request, block) = await prepare(text: text, file: file, line: line) else { return nil }
            lastSent = (file, line, block.name, file == nil ? text : nil)
            let tab = responseTab(for: Self.key(file: file, block: block), title: block.displayName, beside: group)
            tab.sourceFile = file
            tab.sourceLine = block.requestLine
            tab.requestName = block.name
            start(request, in: tab, source: block.source)
            await tab.task?.value
            return tab
        }
    }

    /// The tab for `key` (reused unless pinned), shown beside the request's group.
    private func responseTab(for key: String, title: String, beside group: EditorGroup?) -> HTTPResponseTab {
        let tab: HTTPResponseTab
        if let existing = responseTabs.last(where: { $0.key == key && !$0.isPinned }) {
            tab = existing
            tab.rename(title)
        } else {
            tab = HTTPResponseTab(key: key, title: "Response: \(title)")
            responseTabs.append(tab)
        }
        workspace?.showBeside(tab.id, of: group)
        return tab
    }

    private func start(_ request: HTTPPreparedRequest, in tab: HTTPResponseTab, source: String) {
        tab.task?.cancel()
        tab.request = request
        tab.response = nil
        tab.state = .sending
        tab.startedAt = Date()
        tab.explanation = nil
        let options = HTTPSendOptions(timeout: settings.timeout, followRedirects: settings.followRedirects,
                                      allowSelfSignedLocalhost: settings.allowSelfSignedLocalhost)
        let jar = cookieJar
        let started = Date()
        tab.task = Task { [weak self, weak tab] in
            let result: Result<HTTPResponse, Error>
            do {
                result = .success(try await HTTPTransfer.send(request, options: options, jar: jar))
            } catch {
                result = .failure(error)
            }
            guard let tab else { return }
            var entry = HTTPHistoryEntry(date: started, method: request.method, url: request.url.absoluteString, requestText: source,
                                         file: tab.sourceFile, name: tab.requestName)
            switch result {
            case .success(let response):
                tab.response = response
                tab.state = .done
                entry.status = response.statusCode
                entry.duration = response.timings.total > 0 ? response.timings.total : Date().timeIntervalSince(started)
                if let name = request.name ?? tab.requestName {
                    self?.record(HTTPExchangeRecord(requestHeaders: request.headers, requestBody: request.body, statusCode: response.statusCode,
                                                    responseHeaders: response.headers, responseBody: response.fullBody()),
                                 name: name, file: tab.sourceFile)
                }
            case .failure(let error):
                if (error as? HTTPSendError) == .cancelled {
                    tab.state = .cancelled
                    return
                }
                tab.state = .failed(error.localizedDescription)
            }
            entry.line = tab.sourceLine
            self?.history.add(entry)
        }
    }

    /// Rerun Last Request (from the file as it is now).
    func rerunLast() {
        guard let lastSent else { NSSound.beep(); return }
        rerun(file: lastSent.file, line: lastSent.line, name: lastSent.name, text: lastSent.text)
    }

    /// A response tab's Rerun.
    func rerun(_ tab: HTTPResponseTab) {
        rerun(file: tab.sourceFile, line: tab.sourceLine, name: tab.requestName, text: nil)
    }

    private func rerun(file: URL?, line: Int, name: String?, text: String?) {
        guard let text = text ?? file.flatMap(currentText(of:)) else { NSSound.beep(); return }
        let parsed = HTTPFile(text: text)
        let target = name.flatMap { parsed.request(named: $0) }?.requestLine ?? line
        send(text: text, file: file, line: target, beside: group(showing: file))
    }

    /// The text of a file: the editor's (with unsaved edits) when it's open.
    func currentText(of url: URL) -> String? {
        workspace?.document(matching: url)?.textStorage.string ?? (try? String(contentsOf: url, encoding: .utf8))
    }

    private func group(showing file: URL?) -> EditorGroup? {
        guard let file, let document = workspace?.document(matching: file) else { return nil }
        return workspace?.groups.first { $0.contains(document.id) }
    }

    /// Cancel Request: the active response tab's, else every one in flight.
    func cancel() {
        if let tab = workspace?.activeResponseTab, tab.isSending {
            tab.task?.cancel()
            return
        }
        responseTabs.filter(\.isSending).forEach { $0.task?.cancel() }
    }

    func responseTab(id: UUID?) -> HTTPResponseTab? {
        guard let id else { return nil }
        return responseTabs.first { $0.id == id }
    }

    func closeResponseTab(_ tab: HTTPResponseTab, in group: EditorGroup) {
        group.remove(tab.id)
        if !(workspace?.groups.contains { $0.contains(tab.id) } ?? false) {
            tab.task?.cancel()
            responseTabs.removeAll { $0 === tab }
        }
        workspace?.tabClosed(in: group)
    }

    // MARK: History

    func clearHistory() { history.clear() }

    /// REST: Show History: a pick of past requests, then Send Again or Open Request.
    func showHistory() async {
        let entries = history.entries
        guard !entries.isEmpty else {
            _ = await pick([QuickPickItem(label: "No requests sent yet")], placeholder: "History")
            return
        }
        let items = entries.map { entry in
            QuickPickItem(label: "\(entry.method) \(entry.url)",
                          description: [entry.status.map { "\($0)" } ?? "failed", entry.duration.map(HTTPResponseFormat.duration)].compactMap { $0 }.joined(separator: " · "),
                          detail: entry.date.formatted(date: .abbreviated, time: .shortened) + (entry.file.map { " — " + $0.lastPathComponent } ?? ""))
        }
        guard let index = await pick(items, placeholder: "Sent requests (newest first)") else { return }
        let entry = entries[index]
        guard let action = await pick([QuickPickItem(label: "Send Again"), QuickPickItem(label: "Open Request")],
                                      placeholder: "\(entry.method) \(entry.url)") else { return }
        if action == 0 { resend(entry) } else { open(entry) }
    }

    /// Sends a history entry again: from its file when it's still there, else as stored.
    func resend(_ entry: HTTPHistoryEntry) {
        if let file = entry.file, let text = currentText(of: file) {
            let parsed = HTTPFile(text: text)
            let block = entry.name.flatMap { parsed.request(named: $0) }
                ?? parsed.requests.first { HTTPHistory.redact($0.source) == entry.requestText }
                ?? entry.line.flatMap { parsed.request(atLine: $0) }
            if let block {
                send(text: text, file: file, line: block.requestLine, beside: group(showing: file))
                return
            }
        }
        send(text: entry.requestText, file: nil, line: HTTPFile(text: entry.requestText).requests.first?.requestLine ?? 0)
    }

    func open(_ entry: HTTPHistoryEntry) {
        if let file = entry.file, FileManager.default.fileExists(atPath: file.path) {
            workspace?.open(fileAt: file)
            if let line = entry.line { workspace?.activeDocument?.revealLine(line + 1) }
            return
        }
        openScratch(entry.requestText, name: "request", fileExtension: "http")
    }

    /// Opens text in an editor as a file in a temporary folder.
    @discardableResult
    func openScratch(_ text: String, name: String, fileExtension: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Oh My Code HTTP")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let url = folder.appending(path: "\(String(safe).prefix(40))-\(UUID().uuidString.prefix(6)).\(fileExtension)")
        do {
            try Data(text.utf8).write(to: url)
        } catch {
            workspace?.errorMessage = error.localizedDescription
            return nil
        }
        workspace?.open(fileAt: url)
        return url
    }

    func openScratch(data: Data, name: String, fileExtension: String) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Oh My Code HTTP")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name.prefix(40))-\(UUID().uuidString.prefix(6)).\(fileExtension)")
        do {
            try data.write(to: url)
            workspace?.open(fileAt: url)
        } catch {
            workspace?.errorMessage = error.localizedDescription
        }
    }
}

// MARK: Workspace

extension Workspace {
    /// The active document when it's a `.http` / `.rest` file.
    var activeHTTPDocument: EditorDocument? {
        activeDocument.flatMap { $0.language == .http ? $0 : nil }
    }

    var activeResponseTab: HTTPResponseTab? { http.responseTab(id: activeGroup.activeDocumentID) }

    /// The group a document is shown in (the active one when it's there).
    private func group(of document: EditorDocument) -> EditorGroup? {
        activeGroup.contains(document.id) ? activeGroup : groups.first { $0.contains(document.id) }
    }

    /// Send Request (⌥⌘R, the lens): the request at the caret.
    @discardableResult
    func sendHTTPRequest(in document: EditorDocument? = nil, line: Int? = nil) -> Task<HTTPResponseTab?, Never>? {
        guard let document = document ?? activeHTTPDocument else { NSSound.beep(); return nil }
        return http.send(text: document.textStorage.string, file: document.url, line: line ?? document.cursorLine - 1,
                         beside: group(of: document))
    }

    /// Copy Request as cURL: the request at the caret, variables filled in.
    func copyHTTPRequestAsCurl(in document: EditorDocument? = nil, line: Int? = nil) {
        guard let document = document ?? activeHTTPDocument else { NSSound.beep(); return }
        Task {
            guard let (request, _) = await http.prepare(text: document.textStorage.string, file: document.url,
                                                        line: line ?? document.cursorLine - 1, confirmingNote: false) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(HTTPCurl.command(for: request), forType: .string)
        }
    }

    /// Paste cURL as Request: the clipboard's cURL command, as `.http` text at the caret.
    func pasteCurlAsHTTPRequest() {
        guard let document = activeDocument, let editor = document.editor, let textView = editor.textView else { NSSound.beep(); return }
        guard let command = NSPasteboard.general.string(forType: .string) else { NSSound.beep(); return }
        let request: String
        do {
            request = try HTTPCurl.httpText(fromCurl: command)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let text = document.textStorage.mutableString
        let caret = textView.selectedRange()
        // A request of its own: separated from what's before it.
        let before = text.substring(to: caret.location).trimmingCharacters(in: .whitespacesAndNewlines)
        var insertion = request + "\n"
        if !before.isEmpty, document.language == .http {
            insertion = (text.substring(to: caret.location).hasSuffix("\n") ? "" : "\n") + "\n###\n" + insertion
        }
        textView.insertText(insertion, replacementRange: caret)
    }

    /// Generate Code Snippet: the request at the caret in another language, in a new editor.
    func generateHTTPCodeSnippet() {
        guard let document = activeHTTPDocument else { NSSound.beep(); return }
        let languages = HTTPCurl.SnippetLanguage.allCases
        Task {
            guard let index = await showQuickPick(languages.map { QuickPickItem(label: $0.rawValue) }, placeholder: "Generate code for the request at the cursor"),
                  let (request, block) = await http.prepare(text: document.textStorage.string, file: document.url,
                                                            line: document.cursorLine - 1, confirmingNote: false) else { return }
            let language = languages[index]
            http.openScratch(HTTPCurl.snippet(for: request, language: language), name: block.name ?? "request",
                             fileExtension: language.fileExtension)
        }
    }

    /// Explain Response: the active (or given) response explained by the AI provider.
    func explainHTTPResponse(_ tab: HTTPResponseTab? = nil) {
        guard let tab = tab ?? activeResponseTab ?? http.responseTabs.last(where: { $0.response != nil }),
              let request = tab.request, let response = tab.response else { NSSound.beep(); return }
        if let group = groups.first(where: { $0.contains(tab.id) }) {
            activeGroupID = group.id
            group.show(tab.id)
        } else {
            showBeside(tab.id, of: nil)
        }
        tab.explanation = outputExplanation(HTTPResponseFormat.explanationText(request: request, response: response),
                                            source: "HTTP Response", command: "\(request.method) \(request.url.absoluteString)")
    }

    /// Runs a Send Request / Copy as cURL lens.
    func runHTTPLens(_ lens: CodeLens, in document: EditorDocument) {
        let line = (lens.command?["arguments"] as? [Any])?.first as? Int ?? lens.range.start.line
        switch lens.commandName {
        case HTTPSyntax.sendCommand: sendHTTPRequest(in: document, line: line)
        case HTTPSyntax.copyCurlCommand: copyHTTPRequestAsCurl(in: document, line: line)
        default: NSSound.beep()
        }
    }

    /// The status bar's environment item, for a `.http` file.
    var httpEnvironmentLabel: String? {
        guard let document = activeHTTPDocument else { return nil }
        return http.environmentName(for: document.url) ?? "No Environment"
    }

    static let httpPaletteCommands: [PaletteCommand] = [
        PaletteCommand(id: "rest.send", title: "REST: Send Request", icon: "paperplane", key: "alt+cmd+r",
                       isAvailable: { $0.activeHTTPDocument != nil }, perform: { $0.sendHTTPRequest() }),
        PaletteCommand(id: "rest.rerun", title: "REST: Rerun Last Request", icon: "arrow.clockwise", key: nil,
                       isAvailable: { $0.http.lastSent != nil }, perform: { $0.http.rerunLast() }),
        PaletteCommand(id: "rest.cancel", title: "REST: Cancel Request", icon: "stop.circle", key: nil,
                       isAvailable: { $0.http.responseTabs.contains(where: \.isSending) }, perform: { $0.http.cancel() }),
        PaletteCommand(id: "rest.copyCurl", title: "REST: Copy Request as cURL", icon: "doc.on.clipboard", key: nil,
                       isAvailable: { $0.activeHTTPDocument != nil }, perform: { $0.copyHTTPRequestAsCurl() }),
        PaletteCommand(id: "rest.pasteCurl", title: "REST: Paste cURL as Request", icon: "doc.on.clipboard.fill", key: nil,
                       isAvailable: { $0.activeDocument != nil }, perform: { $0.pasteCurlAsHTTPRequest() }),
        PaletteCommand(id: "rest.codeSnippet", title: "REST: Generate Code Snippet", icon: "chevron.left.forwardslash.chevron.right", key: nil,
                       isAvailable: { $0.activeHTTPDocument != nil }, perform: { $0.generateHTTPCodeSnippet() }),
        PaletteCommand(id: "rest.switchEnvironment", title: "REST: Switch Environment", icon: "globe", key: nil,
                       isAvailable: { $0.activeHTTPDocument != nil || $0.rootURL != nil },
                       perform: { workspace in
                           // Without a .http file open: the first folder's environments.
                           let file = workspace.activeHTTPDocument?.url ?? workspace.rootURL.map { $0.appending(path: "requests.http") }
                           Task { await workspace.http.switchEnvironment(for: file) }
                       }),
        PaletteCommand(id: "rest.showHistory", title: "REST: Show History", icon: "clock.arrow.circlepath", key: nil,
                       isAvailable: { _ in true }, perform: { workspace in Task { await workspace.http.showHistory() } }),
        PaletteCommand(id: "rest.clearHistory", title: "REST: Clear History", icon: "trash", key: nil,
                       isAvailable: { _ in true }, perform: { $0.http.clearHistory() }),
        PaletteCommand(id: "rest.clearCookies", title: "REST: Clear Cookies", icon: "trash.circle", key: nil,
                       isAvailable: { _ in true }, perform: { $0.http.cookieJar.clear() }),
        PaletteCommand(id: "rest.explainResponse", title: "REST: Explain Response", icon: "sparkles", key: nil,
                       isAvailable: { $0.http.responseTabs.contains { $0.response != nil } && AISettings.shared.isConfigured },
                       perform: { $0.explainHTTPResponse() }),
    ]
}

// MARK: Editor

extension EditorDocument {
    /// The lenses and problems of a `.http` file (after edits, and when its environment changes).
    func refreshHTTPFeatures() {
        guard language == .http else { return }
        let text = textStorage.string
        let file = HTTPFile(text: text)
        let showsLenses = projectSettings.showsCodeLens ?? AppSettings.shared.showsCodeLens
        setCodeLenses(showsLenses ? HTTPSyntax.codeLenses(file) : [:])
        guard let workspace else { return }
        let client = workspace.http
        let resolver = client.resolver(for: file, at: url)
        let environments = client.environments(for: url)
        let chosen = client.environmentName(for: url)
        var others: [String: Set<String>] = [:]
        for name in environments.names where name != chosen { others[name] = Set(environments.variables(for: name).keys) }
        let diagnostics = HTTPSyntax.diagnostics(text: text, file: file, resolver: resolver, otherEnvironments: others,
                                                 baseDirectory: url.deletingLastPathComponent())
        setExtensionDiagnostics(diagnostics, collection: HTTPSyntax.problemSource)
        workspace.problems.set(diagnostics, for: workspace.workspaceURL(for: url), source: HTTPSyntax.problemSource)
    }

    /// Completion items for a `.http` file at `cursor`.
    func httpCompletions(at cursor: Int, firstID: Int) -> [CompletionItem] {
        let text = textStorage.mutableString
        let line = lineIndex.line(containing: cursor)
        let file = HTTPFile(text: textStorage.string)
        var variables: [(name: String, detail: String)] = []
        if let workspace {
            let environment = workspace.http.environments(for: url).variables(for: workspace.http.environmentName(for: url))
            variables += environment.keys.sorted().map { ($0, "Environment: \(environment[$0] ?? "")") }
        }
        variables += file.variables.map { ($0.name, "File: \($0.value)") }
        if let block = file.request(atLine: line) { variables += block.prompts.map { ($0.name, "Prompt") } }
        var seen = Set<String>()
        variables = variables.filter { seen.insert($0.name).inserted }
        return HTTPCompletion.items(text: text, cursor: cursor, line: line, lineStart: lineIndex.lineStarts[line], variables: variables,
                                    requestNames: file.requestNames.sorted(), firstID: firstID)
    }
}
