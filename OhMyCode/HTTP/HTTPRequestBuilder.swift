import Foundation

/// A request ready to send: variables filled in, the body built (files read, forms joined,
/// GraphQL wrapped), `Basic` credentials encoded.
struct HTTPPreparedRequest: Equatable, Sendable {
    var method: String
    var url: URL
    var headers: [HTTPHeader]
    var body: Data?
    var followRedirects = true
    var useCookieJar = true
    /// What the response tab is called.
    var displayName: String
    /// The request's `@name`, for request variables.
    var name: String?

    var bodyText: String? { body.map { String(decoding: $0, as: UTF8.self) } }

    /// As `.http` text (the Request tab, history): request line, headers, body.
    var text: String {
        var lines = ["\(method) \(url.absoluteString)"] + headers.map { "\($0.name): \($0.value)" }
        if let body, !body.isEmpty {
            lines.append("")
            lines.append(String(data: body, encoding: .utf8) ?? "<\(body.count) bytes of binary data>")
        }
        return lines.joined(separator: "\n")
    }
}

enum HTTPBuildError: LocalizedError, Equatable {
    case missingFile(String)
    case unreadableFile(String)
    case invalidURL(String)
    case badGraphQLVariables(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path): "The file “\(path)” doesn't exist."
        case .unreadableFile(let path): "The file “\(path)” can't be read with that encoding."
        case .invalidURL(let url): "“\(url)” isn't a valid URL."
        case .badGraphQLVariables(let why): "The GraphQL variables aren't valid JSON: \(why)"
        }
    }
}

struct HTTPRequestBuilder {
    var resolver: HTTPVariableResolver
    /// The `.http` file's folder: what `< ./file` paths are relative to.
    var baseDirectory: URL?

    /// A body line that sends a file: `< path` (as is) or `<@[encoding] path` (with variables).
    struct FileReference: Equatable {
        var path: String
        var substitutesVariables: Bool
        var encoding: String?
    }

    static func fileReference(_ line: String) -> FileReference? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<") else { return nil }
        var rest = trimmed.dropFirst()
        if rest.first == "@" {
            rest = rest.dropFirst()
            let encoding = rest.prefix { !$0.isWhitespace }
            rest = rest.dropFirst(encoding.count)
            guard rest.first?.isWhitespace == true else { return nil }
            let path = rest.trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : FileReference(path: path, substitutesVariables: true,
                                                      encoding: encoding.isEmpty ? nil : String(encoding))
        }
        guard rest.first?.isWhitespace == true else { return nil } // "<tag>" is XML, not a file
        let path = rest.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : FileReference(path: path, substitutesVariables: false, encoding: nil)
    }

    /// A referenced file's location: absolute, `~/…`, or relative to the `.http` file.
    static func resolvePath(_ path: String, base: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(filePath: expanded) }
        return (base ?? URL(filePath: FileManager.default.currentDirectoryPath)).appending(path: expanded).standardizedFileURL
    }

    static func encoding(named name: String?) -> String.Encoding {
        switch name?.lowercased().replacingOccurrences(of: "-", with: "") {
        case "latin1", "iso88591", "binary": .isoLatin1
        case "ascii": .ascii
        case "utf16", "utf16le": .utf16LittleEndian
        case "utf16be": .utf16BigEndian
        default: .utf8
        }
    }

    func build(_ block: HTTPRequestBlock) throws -> HTTPPreparedRequest {
        var headers = try block.headers.map {
            HTTPHeader(name: try resolver.resolve($0.name), value: try resolver.resolve($0.value))
        }
        let rawURL = try resolver.resolve(block.url).trimmingCharacters(in: .whitespaces)
        let url = try Self.url(rawURL, host: headers.value(for: "Host"))
        var body: Data?
        if let text = block.body {
            body = try buildBody(text, headers: &headers)
        }
        if let index = headers.firstIndex(where: { $0.name.caseInsensitiveCompare("Authorization") == .orderedSame }) {
            headers[index].value = Self.encodeBasicAuth(headers[index].value)
        }
        return HTTPPreparedRequest(method: block.method, url: url, headers: headers, body: body,
                                   followRedirects: !block.noRedirect, useCookieJar: !block.noCookieJar,
                                   displayName: block.displayName, name: block.name)
    }

    /// A URL from what's written: percent-encoded where it needs to be; a path alone goes to the
    /// `Host` header's host; no scheme means http.
    static func url(_ raw: String, host: String?) throws -> URL {
        var text = raw
        if text.hasPrefix("/"), let host, !host.isEmpty {
            text = (host.hasSuffix(":443") ? "https://" : "http://") + host + text
        } else if !text.contains("://") {
            text = "http://" + text
        }
        if let url = URL(string: text), url.host != nil { return url }
        var allowed = CharacterSet.urlFragmentAllowed
        allowed.insert(charactersIn: "#%")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: encoded), url.host != nil else { throw HTTPBuildError.invalidURL(raw) }
        return url
    }

    /// `Basic user:pass` and `Basic user pass` are encoded; anything else (already encoded,
    /// Bearer, …) is sent as written.
    static func encodeBasicAuth(_ value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Basic") == .orderedSame else { return value }
        let credentials = parts[1].trimmingCharacters(in: .whitespaces)
        let plain: String
        if credentials.contains(":") {
            plain = credentials
        } else {
            let pieces = credentials.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard pieces.count == 2 else { return value } // a single token: already encoded
            plain = pieces[0] + ":" + pieces[1].trimmingCharacters(in: .whitespaces)
        }
        return "Basic " + Data(plain.utf8).base64EncodedString()
    }

    private func readFile(_ reference: FileReference) throws -> Data {
        let url = Self.resolvePath(reference.path, base: baseDirectory)
        guard let data = try? Data(contentsOf: url) else { throw HTTPBuildError.missingFile(reference.path) }
        guard reference.substitutesVariables else { return data }
        guard let text = String(data: data, encoding: Self.encoding(named: reference.encoding)) else {
            throw HTTPBuildError.unreadableFile(reference.path)
        }
        return Data(try resolver.resolve(text).utf8)
    }

    private func buildBody(_ text: String, headers: inout [HTTPHeader]) throws -> Data {
        let contentType = headers.value(for: "Content-Type")?.lowercased() ?? ""
        let lines = HTTPFile.lines(of: text)
        if let requestType = headers.value(for: "X-Request-Type"), requestType.caseInsensitiveCompare("GraphQL") == .orderedSame {
            headers.remove(named: "X-Request-Type")
            if !headers.contains(named: "Content-Type") { headers.append(HTTPHeader(name: "Content-Type", value: "application/json")) }
            return try Self.graphQLBody(try resolver.resolve(text))
        }
        if contentType.hasPrefix("multipart/form-data") {
            // Parts' files are read in place; lines end with CRLF, as the format wants.
            var data = Data()
            for line in lines {
                if let reference = Self.fileReference(line) {
                    data.append(try readFile(reference))
                } else {
                    data.append(Data(try resolver.resolve(line).utf8))
                }
                data.append(Data("\r\n".utf8))
            }
            return data
        }
        if lines.count == 1, let reference = Self.fileReference(lines[0]) {
            return try readFile(reference)
        }
        if contentType.hasPrefix("application/x-www-form-urlencoded") {
            // Each line after the first starts with "&": joined back into one.
            let joined = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined()
            return Data(try resolver.resolve(joined).utf8)
        }
        return Data(try resolver.resolve(text).utf8)
    }

    /// `{query, variables, operationName}` from a query and, after a blank line, its variables.
    static func graphQLBody(_ text: String) throws -> Data {
        let lines = HTTPFile.lines(of: text)
        var query = lines
        var variablesText: String?
        if let blank = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            query = Array(lines[..<blank])
            let rest = lines[(blank + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { variablesText = rest }
        }
        var object: [String: Any] = ["query": query.joined(separator: "\n")]
        if let variablesText {
            do {
                object["variables"] = try JSONSerialization.jsonObject(with: Data(variablesText.utf8))
            } catch {
                throw HTTPBuildError.badGraphQLVariables(error.localizedDescription)
            }
        }
        let joined = query.joined(separator: " ")
        if let match = joined.range(of: #"^\s*(query|mutation|subscription)\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) {
            let words = joined[match].split(whereSeparator: \.isWhitespace)
            if words.count >= 2 { object["operationName"] = String(words[1]) }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
