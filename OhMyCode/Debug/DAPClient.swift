import Foundation

/// A debug adapter (lldb-dap, …) spoken to with the Debug Adapter Protocol: JSON messages with
/// `Content-Length` framing over stdio, like a language server.
@MainActor
final class DAPClient {
    struct AdapterError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let connection: LanguageServerConnection
    private var nextSeq = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// Events (`stopped`, `output`, …) with their bodies.
    var onEvent: ((String, JSONValue) -> Void)?
    /// Requests from the adapter (`runInTerminal`, …): answer with a body, or nil for an error.
    var onReverseRequest: ((String, JSONValue) -> JSONValue?)?
    var onExit: ((Int32) -> Void)?
    private(set) var isClosed = false

    init(command: [String], directory: URL, environment: [String: String]) throws {
        connection = try LanguageServerConnection(command: command, directory: directory, environment: environment)
        connection.onMessage = { [weak self] data in self?.receive(data) }
        connection.onExit = { [weak self] status in self?.closed(status) }
    }

    /// Sends a request and waits for its response's body (throws the adapter's message on failure).
    @discardableResult
    func request(_ command: String, _ arguments: JSONValue = .object([:])) async throws -> JSONValue {
        guard !isClosed else { throw AdapterError(message: "The debugger has stopped.") }
        let seq = nextSeq
        nextSeq += 1
        let message = JSONValue.object(["seq": .number(Double(seq)), "type": .string("request"),
                                        "command": .string(command), "arguments": arguments])
        return try await withCheckedThrowingContinuation { continuation in
            pending[seq] = continuation
            connection.send(Data(message.json.utf8))
        }
    }

    func terminate() {
        connection.terminate()
        closed(0)
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        switch message["type"]?.string {
        case "response":
            guard let seq = message["request_seq"]?.integer, let continuation = pending.removeValue(forKey: seq) else { return }
            if message["success"]?.bool == true {
                continuation.resume(returning: message["body"] ?? .null)
            } else {
                let detail = message["body"]?["error"]?["format"]?.string ?? message["message"]?.string ?? "The request failed."
                continuation.resume(throwing: AdapterError(message: detail))
            }
        case "event":
            onEvent?(message["event"]?.string ?? "", message["body"] ?? .null)
        case "request":
            let command = message["command"]?.string ?? ""
            let body = onReverseRequest?(command, message["arguments"] ?? .null)
            var reply: [String: JSONValue] = [
                "seq": .number(Double(nextSeq)), "type": .string("response"), "command": .string(command),
                "request_seq": message["seq"] ?? .number(0), "success": .bool(body != nil),
            ]
            if let body { reply["body"] = body } else { reply["message"] = .string("Not supported") }
            nextSeq += 1
            connection.send(Data(JSONValue.object(reply).json.utf8))
        default:
            break
        }
    }

    private func closed(_ status: Int32) {
        guard !isClosed else { return }
        isClosed = true
        for continuation in pending.values { continuation.resume(throwing: AdapterError(message: "The debugger has stopped.")) }
        pending = [:]
        onExit?(status)
    }
}
