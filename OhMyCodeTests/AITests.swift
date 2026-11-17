import AppKit
import Foundation
import Testing
@testable import Oh_My_Code

// MARK: Fakes

/// Answers every request with a canned HTTP response (status, headers, body). Tests that use it
/// are in one serialized suite: the response is shared.
final class StubURLProtocol: URLProtocol {
    struct Response {
        var status = 200
        var headers: [String: String] = ["content-type": "text/event-stream"]
        var body = Data()
    }

    nonisolated(unsafe) static var response = Response()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let stub = Self.response
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In pieces, as a stream arrives.
        var offset = 0
        while offset < stub.body.count {
            let end = min(stub.body.count, offset + 37)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A provider that answers with a fixed reply and records what it was asked.
final class FakeAIProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AIRequest] = []
    private var replyText: String

    init(reply: String) { replyText = reply }

    var requests: [AIRequest] { lock.withLock { recorded } }
    var reply: String {
        get { lock.withLock { replyText } }
        set { lock.withLock { replyText = newValue } }
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        let reply = lock.withLock { recorded.append(request); return replyText }
        return AsyncThrowingStream { continuation in
            // In two pieces.
            let middle = reply.index(reply.startIndex, offsetBy: reply.count / 2)
            continuation.yield(String(reply[..<middle]))
            continuation.yield(String(reply[middle...]))
            continuation.finish()
        }
    }
}

private func json(_ data: Data?) -> [String: Any] {
    (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

private func events(_ lines: [String]) -> Data {
    Data(lines.map { "data: \($0)\n\n" }.joined().utf8)
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var text = ""
    for try await piece in stream { text += piece }
    return text
}

// MARK: Requests and streams

@Suite(.serialized)
struct AIProviderTests {
    private let suggestion = AIRequest(purpose: .suggestion, model: "claude-haiku-5-5", system: "sys", user: "hi", maxTokens: 256)
    private let edit = AIRequest(purpose: .edit, model: "claude-opus-5-5", system: "sys", user: "hi", maxTokens: 16_000)

    @Test func claudeRequestsHaveTheRightShape() throws {
        let provider = ClaudeProvider(apiKey: "sk-test")
        let request = provider.urlRequest(for: suggestion)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages" && request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let body = json(request.httpBody)
        #expect(body["model"] as? String == "claude-haiku-5-5" && body["max_tokens"] as? Int == 256 && body["stream"] as? Bool == true)
        #expect(body["system"] as? String == "sys")
        let messages = try #require(body["messages"] as? [[String: Any]])
        // One user message, no assistant prefill.
        #expect(messages.count == 1 && messages[0]["role"] as? String == "user" && messages[0]["content"] as? String == "hi")
        #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        for banned in ["temperature", "top_p", "top_k", "fallbacks", "budget_tokens"] { #expect(body[banned] == nil, "\(banned)") }

        // Edits: no thinking setting, medium effort, and server-side fallback on the models that have it.
        let editRequest = provider.urlRequest(for: edit)
        let editBody = json(editRequest.httpBody)
        #expect(editBody["thinking"] == nil && editBody["max_tokens"] as? Int == 16_000)
        #expect((editBody["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(editBody["fallbacks"] as? String == "default")
        #expect(editRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        for banned in ["temperature", "top_p", "top_k"] { #expect(editBody[banned] == nil) }
        for model in ["claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1", "claude-opus-5"] {
            var other = edit
            other.model = model
            #expect(json(provider.urlRequest(for: other).httpBody)["fallbacks"] as? String == "default", "\(model)")
        }
        var unlisted = edit
        unlisted.model = "claude-haiku-5-5"
        let unlistedRequest = provider.urlRequest(for: unlisted)
        #expect(json(unlistedRequest.httpBody)["fallbacks"] == nil && unlistedRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func openAICompatibleRequestsHaveTheRightShape() throws {
        let url = try #require(OpenAICompatibleProvider.baseURL(from: " http://localhost:11434/v1/ "))
        let local = OpenAICompatibleProvider(baseURL: url, apiKey: "")
        let request = local.urlRequest(for: suggestion)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "authorization") == nil) // no key: no header
        let body = json(request.httpBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(body["stream"] as? Bool == true && body["max_tokens"] as? Int == 256 && body["model"] as? String == "claude-haiku-5-5")
        #expect(body["temperature"] == nil)
        let keyed = OpenAICompatibleProvider(baseURL: try #require(OpenAICompatibleProvider.baseURL(from: "https://openrouter.ai/api/v1")),
                                             apiKey: "or-key")
        #expect(keyed.urlRequest(for: suggestion).value(forHTTPHeaderField: "authorization") == "Bearer or-key")
        #expect(OpenAICompatibleProvider.baseURL(from: "localhost:11434") == nil && OpenAICompatibleProvider.baseURL(from: "") == nil)
    }

    @Test func claudeStreamsTextAndSkipsThinking() async throws {
        StubURLProtocol.response = .init(body: events([
            #"{"type":"message_start","message":{"id":"m","role":"assistant","content":[]}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":", wörld 👋"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ]))
        let provider = ClaudeProvider(apiKey: "sk-test", session: StubURLProtocol.session())
        #expect(try await collect(provider.stream(suggestion)) == "Hello, wörld 👋")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(json(StubURLProtocol.lastBody)["stream"] as? Bool == true)
    }

    @Test func claudeRefusalsAndErrorEventsThrow() async throws {
        let provider = ClaudeProvider(apiKey: "sk-test", session: StubURLProtocol.session())
        StubURLProtocol.response = .init(body: events([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#,
            #"{"type":"message_stop"}"#,
        ]))
        await #expect(throws: AIError.refusal) { _ = try await collect(provider.stream(suggestion)) }
        #expect(AIError.refusal.localizedDescription == "The model declined this request.")

        StubURLProtocol.response = .init(body: events([
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ]))
        await #expect(throws: AIError.api("Claude is overloaded right now: Overloaded")) { _ = try await collect(provider.stream(suggestion)) }
    }

    @Test func httpErrorsAreReadable() async throws {
        let provider = ClaudeProvider(apiKey: "bad", session: StubURLProtocol.session())
        StubURLProtocol.response = .init(status: 401, headers: ["content-type": "application/json"], body: Data(
            #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        do {
            _ = try await collect(provider.stream(suggestion))
            Issue.record("no error")
        } catch let error as AIError {
            guard case .http(let status, let message) = error else { Issue.record("\(error)"); return }
            #expect(status == 401 && message.contains("invalid x-api-key") && message.contains("API key"))
        }

        StubURLProtocol.response = .init(status: 429, headers: ["content-type": "application/json", "retry-after": "30"], body: Data(
            #"{"type":"error","error":{"type":"rate_limit_error","message":"Slow down"}}"#.utf8))
        do {
            _ = try await collect(provider.stream(suggestion))
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription == "Rate limited (429): Slow down. Try again in 30 s.")
        }

        let openAI = OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:1234/v1")!, apiKey: "", session: StubURLProtocol.session())
        StubURLProtocol.response = .init(status: 404, headers: ["content-type": "application/json"],
                                         body: Data(#"{"error":{"message":"model 'nope' not found"}}"#.utf8))
        do {
            _ = try await collect(openAI.stream(suggestion))
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription.contains("model 'nope' not found") && error.localizedDescription.contains("base URL"))
        }
    }

    @Test func openAIStreamsUntilDone() async throws {
        StubURLProtocol.response = .init(body: events([
            #"{"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"foo"}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"(bar)"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]",
            #"{"choices":[{"index":0,"delta":{"content":"after done"}}]}"#,
        ]))
        let provider = OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: "",
                                                session: StubURLProtocol.session())
        #expect(try await collect(provider.stream(suggestion)) == "foo(bar)")
        #expect(StubURLProtocol.lastRequest?.url?.path == "/v1/chat/completions")

        StubURLProtocol.response = .init(body: events([#"{"error":{"message":"out of memory"}}"#]))
        await #expect(throws: AIError.api("out of memory")) { _ = try await collect(provider.stream(suggestion)) }
    }
}

// MARK: Prompts, sanitizing, settings

@MainActor
struct AIPromptTests {
    @Test func suggestionsAreSanitized() {
        // Fences, and the current line repeated.
        #expect(AIPrompts.sanitizeSuggestion("```swift\n    let total = 42 + 1\n```", before: "func f() {\n    let total = 42", after: "\n}")
                == " + 1")
        #expect(AIPrompts.sanitizeSuggestion("let total = 4", before: "    let total = ", after: "") == "4")
        // What's after the cursor isn't repeated.
        #expect(AIPrompts.sanitizeSuggestion("bar, baz)", before: "foo(", after: ")\n") == "bar, baz")
        #expect(AIPrompts.sanitizeSuggestion("x }\n}", before: "{ ", after: " }\n}") == "x")
        // Leading spaces are kept; trailing blank lines aren't; 12 lines at most.
        #expect(AIPrompts.sanitizeSuggestion(" = 1\n\n", before: "let a", after: "") == " = 1")
        let long = (1...20).map { "line\($0)" }.joined(separator: "\n")
        #expect(AIPrompts.sanitizeSuggestion(long, before: "", after: "").split(separator: "\n").count == 12)
        #expect(AIPrompts.sanitizeSuggestion("  \n ", before: "a", after: "") == "")
        #expect(AIPrompts.stripFences("```\nabc") == "abc") // still streaming
    }

    @Test func editsAreSanitizedAndDiffed() {
        #expect(AIPrompts.sanitizeEdit("```python\nx = 2\n```\n", original: "x = 1\n") == "x = 2\n")
        #expect(AIPrompts.sanitizeEdit("x = 2\n\n", original: "x = 1") == "x = 2")
        let rows = AIEditDiff.rows(old: "a\nb\nc\n", new: "a\nB\nc\n")
        #expect(rows.map(\.kind) == [.same, .removed, .added, .same] && rows.map(\.text) == ["a", "b", "B", "c"])
        #expect(AIEditDiff.rows(old: "", new: "x\ny").map(\.kind) == [.added, .added])
    }

    @Test func contextIsAWindowAroundTheCaret() {
        let text = String(repeating: "a", count: 10_000) + "|" + String(repeating: "b", count: 5_000)
        let context = AIPrompts.suggestionContext(text: text as NSString, caret: 10_000, path: "src/a.swift", languageId: "swift")
        #expect(context.before.count == 6_000 && context.after.count == 2_000 && context.after.hasPrefix("|"))
        let user = AIPrompts.suggestionUser(context)
        #expect(user.contains("File: src/a.swift") && user.contains("Language: swift"))
        let request = AIPrompts.suggestionRequest(context, model: "m")
        #expect(request.purpose == .suggestion && request.maxTokens == 256 && request.system.contains("ONLY"))

        let source = "one\ntwo\nthree\nfour\n" as NSString
        let edit = AIPrompts.editRequest(text: source, range: NSRange(location: 4, length: 4), instruction: "Uppercase",
                                         path: "a.txt", languageId: "plaintext", model: "m")
        #expect(edit.purpose == .edit && edit.maxTokens == 16_000)
        #expect(edit.user.contains("<selection>\ntwo\n</selection>") && edit.user.contains("<context_before>\none\n</context_before>")
                && edit.user.contains("<context_after>\nthree\nfour\n</context_after>") && edit.user.contains("Instruction: Uppercase"))
    }

    @Test func settingsKeepKeysOutOfTheDefaults() throws {
        let defaults = ScratchDefaults.named("ai-settings-\(UUID().uuidString)")
        let keys = InMemoryKeyStore()
        let settings = AISettings(defaults: defaults, keys: keys)
        #expect(!settings.inlineSuggestionsEnabled && settings.debounceMilliseconds == 350 && settings.provider == .claude)
        #expect(!settings.isConfigured && settings.suggestionModel == "claude-haiku-5-5" && settings.editModel == "claude-opus-5-5")
        try settings.saveKey("sk-secret")
        #expect(settings.isConfigured && keys.key(for: .claude) == "sk-secret" && settings.hasKey(for: .claude))
        #expect(try settings.makeProvider() is ClaudeProvider)
        // Nothing in the defaults holds the key.
        let stored = defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        #expect(!stored.contains("sk-secret"))
        // Read again: the key is known to be saved without reading it.
        let again = AISettings(defaults: defaults, keys: keys)
        #expect(again.hasKey(for: .claude) && again.isConfigured)

        settings.provider = .openAICompatible
        settings.baseURL = "http://localhost:1234/v1"
        #expect(settings.configurationProblem?.contains("model") == true)
        settings.openAISuggestionModel = "qwen"
        #expect(settings.isConfigured && settings.editModel == "qwen") // no key needed
        try settings.removeKey(for: .claude)
        #expect(keys.key(for: .claude) == nil && !settings.hasKey(for: .claude))
        // The shared settings use memory, not the Keychain, under tests.
        #expect(AppSettings.isRunningTests)
    }
}

// MARK: Ghost text and ⌘I in the editor

@MainActor
struct InlineSuggestionTests {
    private func makeEditor(_ text: String, ext: String = "swift", reply: String) throws
        -> (EditorDocument, EditorController, NSWindow, FakeAIProvider, AISettings) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-ai-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.attach(controller)
        document.editor = controller
        let settings = AISettings(defaults: ScratchDefaults.named("ai-editor-\(UUID().uuidString)"), keys: InMemoryKeyStore())
        let provider = FakeAIProvider(reply: reply)
        settings.providerOverride = provider
        settings.inlineSuggestionsEnabled = true
        settings.debounceMilliseconds = 100
        controller.inlineSuggestions.settings = settings
        controller.inlineEdit.settings = settings
        document.undoManager.groupsByEvent = false
        return (document, controller, window, provider, settings)
    }

    /// One key press, as AppKit sends it: one undo group.
    private func press(_ controller: EditorController, _ action: () -> Void) {
        let undo = controller.document.undoManager
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    private func type(_ controller: EditorController, _ text: String) {
        for character in text {
            press(controller) { controller.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }

    private func command(_ controller: EditorController, _ selector: Selector) {
        press(controller) {
            if controller.textView.delegate?.textView?(controller.textView, doCommandBy: selector) != true {
                controller.textView.doCommand(by: selector)
            }
        }
    }

    private func waitForGhost(_ controller: EditorController) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.inlineSuggestions.ghost == nil, ContinuousClock.now < deadline {
            await controller.inlineSuggestions.waitForRequest()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func debouncesTypingThenTabAcceptsAsOneUndoStep() async throws {
        let (document, controller, window, provider, settings) = try makeEditor(
            "func f() {\n    let total = \n}\n", reply: "    let total = 42 + 1\n    print(total)")
        controller.textView.setSelectedRange(NSRange(location: 27, length: 0))
        type(controller, "42")
        try await waitForGhost(controller)
        // Typing quickly: one request, for the text after the pause.
        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.user.contains("<prefix>func f() {\n    let total = 42</prefix>") == true)
        #expect(controller.inlineSuggestions.ghost?.text == " + 1\n    print(total)")
        #expect(settings.lastError == nil && settings.requestsInFlight == 0)

        // Typing what it starts with keeps the rest, without asking again.
        type(controller, " +")
        #expect(controller.inlineSuggestions.ghost?.text == " 1\n    print(total)")
        #expect(document.textStorage.string == "func f() {\n    let total = 42 +\n}\n")
        try await Task.sleep(for: .milliseconds(250))
        #expect(provider.requests.count == 1 && controller.inlineSuggestions.ghost != nil)

        command(controller, #selector(NSResponder.insertTab(_:)))
        #expect(document.textStorage.string == "func f() {\n    let total = 42 + 1\n    print(total)\n}\n")
        #expect(controller.textView.selectedRange() == NSRange(location: ("func f() {\n    let total = 42 + 1\n    print(total)" as NSString).length, length: 0))
        #expect(controller.inlineSuggestions.ghost == nil)
        // Nothing of the suggestion's room is left in the text.
        #expect(document.textStorage.attribute(.paragraphStyle, at: 12, effectiveRange: nil) == nil)
        document.undoManager.undo()
        #expect(document.textStorage.string == "func f() {\n    let total = 42 +\n}\n")
        withExtendedLifetime(window) {}
    }

    @Test func showingASuggestionDoesntTouchTheDocument() throws {
        let (document, controller, window, _, _) = try makeEditor("let a = foo(\nlet b = 2\n", reply: "")
        let text = document.textStorage.string
        let version = document.editVersion
        controller.textView.setSelectedRange(NSRange(location: 12, length: 0))
        controller.textView.layoutSubtreeIfNeeded()
        let below = try #require(controller.rect(for: NSRange(location: 13, length: 1)))
        controller.inlineSuggestions.show(GhostText(anchor: 12, text: "x,\n    y,\n    z", editVersion: version))
        controller.textView.layoutSubtreeIfNeeded()
        // Not dirty, nothing to undo, no edit (the language server hears of edits).
        #expect(document.textStorage.string == text && !document.isDirty && !document.undoManager.canUndo && document.editVersion == version)
        // Room below the line for the other two lines.
        let moved = try #require(controller.rect(for: NSRange(location: 13, length: 1)))
        #expect(moved.minY >= below.minY + 2 * below.height - 1)
        let lines = controller.inlineSuggestions.drawables()
        #expect(lines.map(\.text) == ["x,", "    y,", "    z"])
        #expect(lines[1].origin.y > lines[0].origin.y && lines[2].origin.y < moved.minY)

        // Esc takes it away, room and all.
        #expect(controller.textView.delegate?.textView?(controller.textView, doCommandBy: #selector(NSResponder.cancelOperation(_:))) == true)
        controller.textView.layoutSubtreeIfNeeded()
        #expect(controller.inlineSuggestions.ghost == nil && controller.inlineSuggestions.drawables().isEmpty)
        #expect(abs(try #require(controller.rect(for: NSRange(location: 13, length: 1))).minY - below.minY) < 0.5)
        #expect(!document.isDirty && !document.undoManager.canUndo && document.editVersion == version)
        withExtendedLifetime(window) {}
    }

    @Test func roomBelowALineWithTabs() throws {
        // Lines with tabs get their paragraph style from the content storage's delegate (tab stops):
        // the room is kept there too.
        let (document, controller, window, _, _) = try makeEditor("\tif x {\n\t\ty()\n}\n", reply: "")
        controller.textView.setSelectedRange(NSRange(location: 7, length: 0))
        controller.textView.layoutSubtreeIfNeeded()
        let below = try #require(controller.rect(for: NSRange(location: 8, length: 1)))
        controller.inlineSuggestions.show(GhostText(anchor: 7, text: "\n\t\tz()", editVersion: document.editVersion))
        controller.textView.layoutSubtreeIfNeeded()
        let moved = try #require(controller.rect(for: NSRange(location: 8, length: 1)))
        #expect(moved.minY >= below.minY + below.height - 1)
        controller.inlineSuggestions.dismiss()
        withExtendedLifetime(window) {}
    }

    @Test func aGapOpensBeforeClosingBrackets() throws {
        let (document, controller, window, _, _) = try makeEditor("print()\n", reply: "")
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0))
        controller.textView.layoutSubtreeIfNeeded()
        let closer = try #require(controller.rect(for: NSRange(location: 6, length: 1)))
        controller.inlineSuggestions.show(GhostText(anchor: 6, text: "total", editVersion: document.editVersion))
        controller.textView.layoutSubtreeIfNeeded()
        let width = GhostTextStyle.width(of: "total", tabWidth: 4)
        #expect(document.textStorage.attribute(.kern, at: 5, effectiveRange: nil) as? CGFloat == width)
        // TextKit's caret would sit in the gap's middle: it's hidden, and drawn at the gap's start
        // with the suggestion after it.
        let drawing = controller.inlineSuggestions.drawing()
        let first = try #require(drawing.lines.first)
        #expect(abs(first.origin.x - closer.minX) < 1 && first.text == "total")
        #expect(abs((drawing.caret?.minX ?? 0) - closer.minX) < 1 && controller.textView.insertionPointColor == .clear)
        #expect(!document.isDirty && !document.undoManager.canUndo)
        // ⌘→ takes its next word; typing something else drops it.
        controller.inlineSuggestions.show(GhostText(anchor: 6, text: "total, count", editVersion: document.editVersion))
        command(controller, #selector(NSResponder.moveToRightEndOfLine(_:)))
        #expect(document.textStorage.string == "print(total)\n" && controller.inlineSuggestions.ghost?.text == ", count")
        type(controller, "x")
        #expect(controller.inlineSuggestions.ghost == nil && document.textStorage.string == "print(totalx)\n")
        #expect(controller.textView.insertionPointColor == EditorTheme.current.cursor)
        #expect(document.textStorage.attribute(.kern, at: 10, effectiveRange: nil) == nil)
        withExtendedLifetime(window) {}
    }

    @Test func onlyWhereASuggestionFits() async throws {
        let (document, controller, window, provider, settings) = try makeEditor("let a = 1\nlet b = foo(x)\n", reply: "zzz")
        let suggestions = controller.inlineSuggestions
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        #expect(suggestions.canSuggest(manual: false))
        // Text after the caret that isn't closers.
        controller.textView.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(!suggestions.canSuggest(manual: false))
        // A selection, or other cursors.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(!suggestions.canSuggest(manual: true))
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        controller.extraSelections = [NSRange(location: 20, length: 0)]
        #expect(!suggestions.canSuggest(manual: true))
        controller.extraSelections = []
        // Turned off: only ⌥\ asks.
        settings.inlineSuggestionsEnabled = false
        #expect(!suggestions.canSuggest(manual: false) && suggestions.canSuggest(manual: true))
        type(controller, "0")
        try await Task.sleep(for: .milliseconds(200))
        #expect(provider.requests.isEmpty && suggestions.ghost == nil)
        suggestions.trigger()
        try await waitForGhost(controller)
        #expect(provider.requests.count == 1 && suggestions.ghost?.text == "zzz")
        // Moving the caret drops it.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(suggestions.ghost == nil)
        #expect(document.textStorage.string == "let a = 10\nlet b = foo(x)\n")
        withExtendedLifetime(window) {}
    }

    @Test func notWhileTheCompletionListShows() async throws {
        let (_, controller, window, _, _) = try makeEditor("", ext: "md", reply: "zzz")
        type(controller, "tab")
        controller.completion.triggerManually()
        let deadline = ContinuousClock.now + .seconds(5)
        while !controller.completion.isVisible, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(controller.completion.isVisible)
        #expect(!controller.inlineSuggestions.canSuggest(manual: true))
        // With a suggestion shown too, Tab is the list's.
        controller.inlineSuggestions.show(GhostText(anchor: 3, text: "zzz", editVersion: controller.document.editVersion))
        #expect(!controller.inlineSuggestions.handle(#selector(NSResponder.insertTab(_:))))
        controller.completion.dismiss()
        withExtendedLifetime(window) {}
    }

    @Test func editReplacesExactlyTheSelectionInOneUndoStep() async throws {
        let (document, controller, window, provider, _) = try makeEditor(
            "func a() {}\nlet x = 1\nlet y = 2\nfunc b() {}\n", reply: "```swift\nlet x = 10\nlet y = 20\n```")
        let selection = NSRange(location: 12, length: 20) // "let x = 1\nlet y = 2\n"
        controller.textView.setSelectedRange(selection)
        let edit = controller.inlineEdit
        edit.begin()
        let model = try #require(edit.model)
        #expect(model.original == "let x = 1\nlet y = 2\n" && model.phase == .prompting)
        model.instruction = "Multiply by ten"
        edit.submit()
        await edit.waitForReply()
        #expect(model.phase == .done && model.output == "let x = 10\nlet y = 20\n")
        let request = try #require(provider.requests.first)
        #expect(request.purpose == .edit && request.user.contains("Instruction: Multiply by ten"))
        #expect(model.diff.map(\.kind) == [.removed, .removed, .added, .added])
        press(controller) { #expect(edit.accept()) }
        #expect(document.textStorage.string == "func a() {}\nlet x = 10\nlet y = 20\nfunc b() {}\n")
        #expect(edit.model == nil)
        document.undoManager.undo()
        #expect(document.textStorage.string == "func a() {}\nlet x = 1\nlet y = 2\nfunc b() {}\n")

        // Changed under it meanwhile: refused.
        controller.textView.setSelectedRange(selection)
        edit.begin()
        edit.model?.instruction = "Again"
        edit.submit()
        await edit.waitForReply()
        document.textStorage.replaceCharacters(in: NSRange(location: 16, length: 1), with: "z")
        #expect(!edit.accept())
        if case .failed = edit.model?.phase {} else { Issue.record("not refused") }
        edit.cancel()
        #expect(edit.model == nil)
        withExtendedLifetime(window) {}
    }

    @Test func editWithoutASelectionWritesOnTheBlankLine() {
        let text = "a\n    \nb" as NSString
        let index = LineIndex(string: text)
        #expect(InlineEditController.editRange(selection: NSRange(location: 4, length: 0), text: text, lineIndex: index)
                == NSRange(location: 2, length: 4))
        #expect(InlineEditController.editRange(selection: NSRange(location: 1, length: 0), text: text, lineIndex: index)
                == NSRange(location: 0, length: 1))
        #expect(InlineSuggestionController.nextWord(of: "foo(bar)") == "foo")
        #expect(InlineSuggestionController.nextWord(of: "(bar)") == "(")
        #expect(InlineSuggestionController.nextWord(of: "\n    return x") == "\n    return")
    }
}
