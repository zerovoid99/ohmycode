import Foundation

/// How a response body is shown, and the text the response tab puts on screen.
enum HTTPResponseFormat {
    enum BodyKind: Equatable {
        case json, xml, html, image, text, binary, empty

        /// The extension for "Open in Editor" and "Save Body…".
        func fileExtension(contentType: String?) -> String {
            switch self {
            case .json: return "json"
            case .xml: return "xml"
            case .html: return "html"
            case .text, .empty: return contentType?.lowercased().contains("css") == true ? "css"
                : contentType?.lowercased().contains("javascript") == true ? "js" : "txt"
            case .image:
                let type = contentType?.lowercased() ?? ""
                for (key, ext) in [("png", "png"), ("jpeg", "jpg"), ("jpg", "jpg"), ("gif", "gif"), ("svg", "svg"), ("webp", "webp"),
                                   ("tiff", "tiff"), ("bmp", "bmp"), ("icon", "ico")] where type.contains(key) {
                    return ext
                }
                return "png"
            case .binary:
                let type = contentType?.lowercased() ?? ""
                if type.contains("pdf") { return "pdf" }
                if type.contains("zip") { return "zip" }
                return "bin"
            }
        }
    }

    static func kind(contentType: String?, body: Data) -> BodyKind {
        if body.isEmpty { return .empty }
        let type = (contentType ?? "").lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if type.contains("json") { return .json }
        if type == "text/html" || type.contains("xhtml") { return .html }
        if type.contains("xml") { return type.contains("svg") ? .image : .xml }
        if type.hasPrefix("image/") { return .image }
        if type.hasPrefix("text/") || type.contains("javascript") || type.contains("x-www-form-urlencoded") || type.contains("graphql") {
            return .text
        }
        // Unknown or missing type: sniff.
        let sample = body.prefix(FileKind.sniffLength)
        if sample.contains(0) || String(data: sample, encoding: .utf8) == nil && body.count <= FileKind.sniffLength { return .binary }
        if let first = String(decoding: sample.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).first {
            if first == "{" || first == "[" , (try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)) != nil { return .json }
            if first == "<" { return String(decoding: sample.prefix(512), as: UTF8.self).lowercased().contains("<html") ? .html : .xml }
        }
        return .text
    }

    /// JSON re-indented by two spaces, keys in their order and numbers as written; nil when it
    /// isn't JSON.
    static func prettyJSON(_ text: String) -> String? {
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) != nil else { return nil }
        var result = ""
        var depth = 0
        var inString = false
        var escaped = false
        let characters = Array(text)
        func newline() { result += "\n" + String(repeating: "  ", count: depth) }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if inString {
                result.append(character)
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                inString = true
                result.append(character)
            case "{", "[":
                // An empty object or array stays on one line.
                var next = index
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == (character == "{" ? "}" : "]") {
                    result += character == "{" ? "{}" : "[]"
                    index = next + 1
                } else {
                    result.append(character)
                    depth += 1
                    newline()
                }
            case "}", "]":
                depth = max(0, depth - 1)
                newline()
                result.append(character)
            case ",":
                result.append(character)
                newline()
            case ":":
                result += ": "
            case _ where character.isWhitespace:
                continue
            default:
                result.append(character)
            }
        }
        return result
    }

    /// XML indented, or nil when it doesn't parse.
    static func prettyXML(_ text: String) -> String? {
        guard let document = try? XMLDocument(xmlString: text, options: [.nodePreserveCDATA]) else { return nil }
        return document.xmlString(options: [.nodePrettyPrint, .nodePreserveCDATA])
    }

    /// The body as text to show: pretty-printed when asked for and possible.
    static func displayText(_ body: Data, kind: BodyKind, pretty: Bool) -> String {
        let text = String(decoding: body, as: UTF8.self)
        guard pretty else { return text }
        switch kind {
        case .json: return prettyJSON(text) ?? text
        case .xml: return prettyXML(text) ?? text
        default: return text
        }
    }

    /// "1.2 KB".
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "245 ms", "1.24 s".
    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    /// The first part of a binary body as a hex dump.
    static func hexPreview(_ body: Data, limit: Int = 4096) -> String {
        let bytes = [UInt8](body.prefix(limit))
        return stride(from: 0, to: bytes.count, by: HexDump.bytesPerRow).map { offset in
            HexDump.row(offset: offset, bytes: bytes[offset..<min(offset + HexDump.bytesPerRow, bytes.count)])
        }.joined(separator: "\n")
    }

    /// What Explain Response sends: the status line, headers and the start of the body.
    static func explanationText(request: HTTPPreparedRequest, response: HTTPResponse, bodyLimit: Int = 4000) -> String {
        var lines = ["\(request.method) \(request.url.absoluteString)", "",
                     "HTTP \(response.statusCode) \(response.reason)"]
        lines += response.headers.map { "\($0.name): \(HTTPHistory.isSecretHeader($0.name) ? HTTPHistory.redacted : $0.value)" }
        let body = String(decoding: response.body.prefix(bodyLimit), as: UTF8.self)
        if !body.isEmpty {
            lines.append("")
            lines.append(body + (response.bodySize > bodyLimit ? "\n… (\(size(response.bodySize)) in all)" : ""))
        }
        return lines.joined(separator: "\n")
    }
}
