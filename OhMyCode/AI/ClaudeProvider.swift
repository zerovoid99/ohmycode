import Foundation

/// The Claude API's Messages endpoint, over plain HTTP (there's no Swift SDK), streamed.
struct ClaudeProvider: AIProvider {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let defaultSuggestionModel = "claude-haiku-5-5"
    static let defaultEditModel = "claude-opus-5-5"
    /// Models that can fall back to another server-side when they decline a request.
    static let fallbackModels: Set<String> = [
        "claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1", "claude-opus-5",
    ]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    let apiKey: String
    var session: URLSession = .shared

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AIHTTP.stream(urlRequest(for: request), session: session, provider: .claude, decoder: ClaudeStreamDecoder())
    }

    func urlRequest(for request: AIRequest) -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if Self.fallbackModels.contains(request.model) {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(for: request))
        return urlRequest
    }

    /// The request's JSON. No sampling parameters (this API version turns them down) and no
    /// assistant prefill: the system prompt asks for exactly what's wanted instead.
    static func body(for request: AIRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "stream": true,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
        ]
        switch request.purpose {
        case .suggestion:
            // Fast and short: no thinking.
            body["thinking"] = ["type": "disabled"]
            body["output_config"] = ["effort": "low"]
        case .edit:
            // Thinking is adaptive on the edit models (and can't be turned off there).
            body["output_config"] = ["effort": "medium"]
        }
        if fallbackModels.contains(request.model) { body["fallbacks"] = "default" }
        return body
    }
}

/// The Messages API's server-sent events: text deltas of text blocks; thinking and other blocks
/// are skipped.
struct ClaudeStreamDecoder: AIStreamDecoder {
    private(set) var isDone = false
    private(set) var stopReason: String?
    /// Content block types by index.
    private var blockTypes: [Int: String] = [:]

    mutating func decode(line: String) throws -> String? {
        guard let data = AIHTTP.eventData(line), let event = AIHTTP.json(data) else { return nil }
        switch event["type"] as? String {
        case "content_block_start":
            if let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] {
                blockTypes[index] = block["type"] as? String
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
            if let index = event["index"] as? Int, let type = blockTypes[index], type != "text" { return nil }
            return delta["text"] as? String
        case "message_delta":
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
                if reason == "refusal" { throw AIError.refusal }
            }
        case "message_stop":
            isDone = true
        case "error":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "The Claude API reported an error."
            let type = error?["type"] as? String
            throw AIError.api(type == "overloaded_error" ? "Claude is overloaded right now: \(message)" : message)
        default:
            break // message_start, content_block_stop, ping
        }
        return nil
    }

    func finish() throws {
        if stopReason == "refusal" { throw AIError.refusal }
    }
}
