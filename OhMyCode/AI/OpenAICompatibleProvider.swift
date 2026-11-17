import Foundation

/// Any server with OpenAI's Chat Completions API: OpenAI, OpenRouter, and local ones (Ollama,
/// LM Studio), which usually need no key.
struct OpenAICompatibleProvider: AIProvider {
    struct Preset: Identifiable, Hashable {
        let name: String
        let baseURL: String
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Ollama", baseURL: "http://localhost:11434/v1"),
        Preset(name: "LM Studio", baseURL: "http://localhost:1234/v1"),
        Preset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
        Preset(name: "OpenAI", baseURL: "https://api.openai.com/v1"),
    ]

    let baseURL: URL
    let apiKey: String
    var session: URLSession = .shared

    /// The base URL as typed (trailing slashes are fine); nil if it isn't an http(s) URL.
    static func baseURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        AIHTTP.stream(urlRequest(for: request), session: session, provider: .openAICompatible, decoder: OpenAIStreamDecoder())
    }

    func urlRequest(for request: AIRequest) -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: Self.body(for: request))
        return urlRequest
    }

    static func body(for request: AIRequest) -> [String: Any] {
        [
            "model": request.model,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": request.user],
            ],
            "stream": true,
            "max_tokens": request.maxTokens,
        ]
    }
}

/// `data: {...}` lines with `choices[0].delta.content`, until `data: [DONE]`.
struct OpenAIStreamDecoder: AIStreamDecoder {
    private(set) var isDone = false

    mutating func decode(line: String) throws -> String? {
        guard let data = AIHTTP.eventData(line) else { return nil }
        if data == "[DONE]" {
            isDone = true
            return nil
        }
        guard let event = AIHTTP.json(data) else { return nil }
        if let error = event["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? (error as? String) ?? "The server reported an error."
            throw AIError.api(message)
        }
        guard let choice = (event["choices"] as? [[String: Any]])?.first else { return nil }
        if choice["finish_reason"] as? String == "content_filter" { throw AIError.refusal }
        return (choice["delta"] as? [String: Any])?["content"] as? String
    }

    func finish() throws {}
}
