import Foundation

/// Where AI suggestions and edits come from.
enum AIProviderKind: String, CaseIterable, Identifiable, Sendable {
    case claude, openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude API"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
}

/// One request to a model: a system prompt and one user message, streamed back as text.
struct AIRequest: Sendable, Equatable {
    enum Purpose: Sendable { case suggestion, edit }

    var purpose: Purpose
    var model: String
    var system: String
    var user: String
    var maxTokens: Int
}

/// A model behind an HTTP API. `stream` yields the reply's text as it arrives; cancelling the
/// consuming task cancels the request.
protocol AIProvider: Sendable {
    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error>
}

enum AIError: LocalizedError, Equatable {
    /// Something's missing in Settings ▸ AI.
    case notConfigured(String)
    /// A non-2xx answer, with a message for people.
    case http(status: Int, message: String)
    /// An error the API reported in the middle of the stream.
    case api(String)
    /// The model declined the request.
    case refusal

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message): message
        case .http(_, let message): message
        case .api(let message): message
        case .refusal: "The model declined this request."
        }
    }

    /// A readable error for a non-2xx answer: the JSON body's `error.message` when there is one.
    static func http(status: Int, body: Data, retryAfter: String?, provider: AIProviderKind) -> AIError {
        var detail = ""
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                detail = message
            } else if let message = json["error"] as? String {
                detail = message
            } else if let message = json["message"] as? String {
                detail = message
            }
        } else if let text = String(data: body.prefix(300), encoding: .utf8) {
            detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        let message: String
        switch status {
        case 401:
            message = "The API key was rejected (401)\(suffix). Check the key in Settings ▸ AI."
        case 403:
            message = "Access denied (403)\(suffix)."
        case 404:
            message = provider == .openAICompatible
                ? "Not found (404)\(suffix). Check the base URL and the model in Settings ▸ AI."
                : "Not found (404)\(suffix). Check the model in Settings ▸ AI."
        case 429:
            let wait = retryAfter.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            message = "Rate limited (429)\(suffix)." + (wait.map { " Try again in \($0) s." } ?? "")
        default:
            message = "\(provider.title) error (\(status))\(suffix)."
        }
        return .http(status: status, message: message)
    }
}

/// Reads an event stream line by line into text.
protocol AIStreamDecoder: Sendable {
    /// The text one line adds (nil: none). Throws for an error event.
    mutating func decode(line: String) throws -> String?
    /// The stream said it's finished.
    var isDone: Bool { get }
    /// After the last line: throws when the stream ended badly.
    func finish() throws
}

enum AIHTTP {
    /// Sends `request` and streams what `decoder` makes of the answer's lines.
    static func stream<Decoder: AIStreamDecoder>(_ request: URLRequest, session: URLSession, provider: AIProviderKind,
                                                 decoder: Decoder) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AIError.api("No HTTP response.") }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64_000 { break }
                        }
                        throw AIError.http(status: http.statusCode, body: body,
                                           retryAfter: http.value(forHTTPHeaderField: "retry-after"), provider: provider)
                    }
                    var decoder = decoder
                    for try await line in bytes.lines {
                        if let text = try decoder.decode(line: line), !text.isEmpty { continuation.yield(text) }
                        if decoder.isDone { break }
                    }
                    try Task.checkCancellation()
                    try decoder.finish()
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The JSON after `data:` on an event stream line (nil for other lines).
    static func eventData(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }

    static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
