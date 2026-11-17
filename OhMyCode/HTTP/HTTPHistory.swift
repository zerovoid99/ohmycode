import Foundation

/// A request sent from a `.http` file, as History lists it.
struct HTTPHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var method: String
    var url: String
    /// Nil when it failed (no answer).
    var status: Int?
    /// Seconds.
    var duration: Double?
    /// The request as written in the file, with secrets (credentials, cookies, tokens) taken out.
    var requestText: String
    var file: URL?
    var name: String?
    /// The request line in the file (zero-based).
    var line: Int?
}

/// The last requests of a workspace (newest first), kept between launches.
@MainActor
final class HTTPHistory {
    static let limit = 50
    let file: URL?
    private(set) var entries: [HTTPHistoryEntry] = []

    init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HTTPHistoryEntry].self, from: data)) ?? []
    }

    func add(_ entry: HTTPHistoryEntry) {
        var entry = entry
        entry.requestText = Self.redact(entry.requestText)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Header names whose values are secrets.
    nonisolated static func isSecretHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ["authorization", "proxy-authorization", "cookie", "set-cookie"].contains(lower) { return true }
        return ["token", "secret", "password", "api-key", "apikey", "api_key", "session"].contains { lower.contains($0) }
    }

    nonisolated static let redacted = "•••"

    /// Secret header values replaced (variables, `{{token}}`, are kept: they hold no secret).
    nonisolated static func redact(_ text: String) -> String {
        HTTPFile.lines(of: text).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !HTTPFile.isComment(trimmed), let colon = trimmed.firstIndex(of: ":"), colon != trimmed.startIndex else { return line }
            let name = String(trimmed[..<colon])
            guard !name.contains(where: \.isWhitespace), isSecretHeader(name) else { return line }
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("{{"), value.hasSuffix("}}"), !value.dropFirst(2).contains("{{") { return line }
            // Keep the scheme ("Bearer", "Basic") so it's clear what was sent.
            let parts = value.split(separator: " ", maxSplits: 1)
            if name.lowercased().hasSuffix("authorization"), parts.count == 2 {
                let credential = String(parts[1])
                if credential.hasPrefix("{{"), credential.hasSuffix("}}") { return line }
                return "\(name): \(parts[0]) \(redacted)"
            }
            return "\(name): \(redacted)"
        }.joined(separator: "\n")
    }
}
