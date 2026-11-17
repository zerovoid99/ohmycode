import Foundation

/// Copy as cURL, Paste cURL as Request, and Generate Code Snippet.
enum HTTPCurl {
    /// A shell word in single quotes (a quote inside as `'\''`).
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The request as a cURL command, one option per line.
    static func command(for request: HTTPPreparedRequest) -> String {
        var parts = ["curl"]
        if request.method != "GET" || request.body != nil && request.method != "POST" { parts.append("-X \(request.method)") }
        parts.append(quote(request.url.absoluteString))
        for header in request.headers { parts.append("-H " + quote("\(header.name): \(header.value)")) }
        if let body = request.body, !body.isEmpty {
            if let text = String(data: body, encoding: .utf8) {
                parts.append("--data-raw " + quote(text))
            } else {
                parts.append("--data-binary @-  # \(body.count) bytes of binary data")
            }
        }
        if !request.followRedirects { parts.append("--max-redirs 0") } else { parts.append("-L") }
        return parts.joined(separator: " \\\n  ")
    }

    // MARK: Import

    enum ImportError: LocalizedError, Equatable {
        case notCurl, noURL

        var errorDescription: String? {
            switch self {
            case .notCurl: "The clipboard doesn't hold a cURL command."
            case .noURL: "The cURL command has no URL."
            }
        }
    }

    /// Splits a shell command into words: single and double quotes, `$'…'`, backslash escapes,
    /// and backslash-newline continuations.
    static func words(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false
        var characters = Array(command)
        // Line continuations ("\" + newline) are dropped first.
        var index = 0
        var cleaned: [Character] = []
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == "\n" || characters[index + 1] == "\r\n" {
                index += 2
                continue
            }
            cleaned.append(characters[index])
            index += 1
        }
        characters = cleaned
        index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "'" {
                hasWord = true
                index += 1
                while index < characters.count, characters[index] != "'" { current.append(characters[index]); index += 1 }
                index += 1
            } else if character == "$", index + 1 < characters.count, characters[index + 1] == "'" {
                hasWord = true
                index += 2
                while index < characters.count, characters[index] != "'" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        let next = characters[index + 1]
                        switch next {
                        case "n": current.append("\n")
                        case "t": current.append("\t")
                        case "r": current.append("\r")
                        default: current.append(next)
                        }
                        index += 2
                    } else {
                        current.append(characters[index])
                        index += 1
                    }
                }
                index += 1
            } else if character == "\"" {
                hasWord = true
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count, "\"\\$`\n".contains(characters[index + 1]) {
                        current.append(characters[index + 1])
                        index += 2
                    } else {
                        current.append(characters[index])
                        index += 1
                    }
                }
                index += 1
            } else if character == "\\", index + 1 < characters.count {
                hasWord = true
                current.append(characters[index + 1])
                index += 2
            } else if character.isWhitespace {
                if hasWord { words.append(current); current = ""; hasWord = false }
                index += 1
            } else {
                hasWord = true
                current.append(character)
                index += 1
            }
        }
        if hasWord { words.append(current) }
        return words
    }

    /// A cURL command as `.http` text.
    static func httpText(fromCurl command: String) throws -> String {
        var words = words(command.trimmingCharacters(in: .whitespacesAndNewlines))
        guard words.first == "curl" else { throw ImportError.notCurl }
        words.removeFirst()
        var method: String?
        var url: String?
        var headers: [HTTPHeader] = []
        var data: [String] = []
        var forms: [(name: String, value: String)] = []
        var getData = false
        var index = 0
        func next() -> String? {
            index += 1
            return index < words.count ? words[index] : nil
        }
        let ignoredWithValue: Set<String> = ["-o", "--output", "--connect-timeout", "-m", "--max-time", "--max-redirs",
                                             "-w", "--write-out", "--proxy", "-x", "--cacert", "--cert", "--key", "-r", "--range"]
        while index < words.count {
            var word = words[index]
            var inline: String?
            // --opt=value
            if word.hasPrefix("--"), let equals = word.firstIndex(of: "=") {
                inline = String(word[word.index(after: equals)...])
                word = String(word[..<equals])
            }
            func value() -> String? { inline ?? next() }
            switch word {
            case "-X", "--request": method = value()?.uppercased()
            case "-H", "--header":
                if let header = value(), let colon = header.firstIndex(of: ":") {
                    headers.append(HTTPHeader(name: header[..<colon].trimmingCharacters(in: .whitespaces),
                                              value: header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii":
                if let value = value() { data.append(value.hasPrefix("@") && word != "--data-raw" ? "< " + value.dropFirst() : value) }
            case "--data-urlencode":
                if let value = value() { data.append(urlEncodedPair(value)) }
            case "-F", "--form", "--form-string":
                if let value = value(), let equals = value.firstIndex(of: "=") {
                    forms.append((String(value[..<equals]), String(value[value.index(after: equals)...])))
                }
            case "-u", "--user":
                if let value = value() { headers.append(HTTPHeader(name: "Authorization", value: "Basic \(value)")) }
            case "-A", "--user-agent":
                if let value = value() { headers.append(HTTPHeader(name: "User-Agent", value: value)) }
            case "-e", "--referer":
                if let value = value() { headers.append(HTTPHeader(name: "Referer", value: value)) }
            case "-b", "--cookie":
                if let value = value(), value.contains("=") { headers.append(HTTPHeader(name: "Cookie", value: value)) }
            case "--url": url = value()
            case "-G", "--get": getData = true
            case "-I", "--head": method = "HEAD"
            default:
                if ignoredWithValue.contains(word) {
                    _ = value()
                } else if !word.hasPrefix("-"), url == nil {
                    url = word
                }
                // Other flags (--compressed, -L, -k, -s, -i, -v, …) don't change the request.
            }
            index += 1
        }
        guard var url else { throw ImportError.noURL }
        var body: String?
        if !forms.isEmpty {
            let boundary = "----OhMyCodeFormBoundary"
            headers.remove(named: "Content-Type")
            headers.append(HTTPHeader(name: "Content-Type", value: "multipart/form-data; boundary=\(boundary)"))
            var lines: [String] = []
            for (name, value) in forms {
                lines.append("--\(boundary)")
                if value.hasPrefix("@") {
                    var path = String(value.dropFirst())
                    var type: String?
                    if let semicolon = path.firstIndex(of: ";") {
                        let options = path[path.index(after: semicolon)...]
                        path = String(path[..<semicolon])
                        if let typeRange = options.range(of: "type=") { type = options[typeRange.upperBound...].split(separator: ";").first.map(String.init) }
                    }
                    lines.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\((path as NSString).lastPathComponent)\"")
                    lines.append("Content-Type: \(type ?? "application/octet-stream")")
                    lines.append("")
                    lines.append("< \(path)")
                } else {
                    lines.append("Content-Disposition: form-data; name=\"\(name)\"")
                    lines.append("")
                    lines.append(value)
                }
            }
            lines.append("--\(boundary)--")
            body = lines.joined(separator: "\n")
            if method == nil { method = "POST" }
        } else if !data.isEmpty {
            let joined = data.joined(separator: "&")
            if getData {
                url += (url.contains("?") ? "&" : "?") + joined
            } else {
                body = joined
                if !headers.contains(named: "Content-Type") {
                    headers.append(HTTPHeader(name: "Content-Type", value: "application/x-www-form-urlencoded"))
                }
                if method == nil { method = "POST" }
            }
        }
        var lines = ["\(method ?? "GET") \(url)"] + headers.map { "\($0.name): \($0.value)" }
        if let body {
            lines.append("")
            lines.append(body)
        }
        return lines.joined(separator: "\n")
    }

    /// `--data-urlencode`'s forms: `content`, `=content`, `name=content`, `@file`, `name@file`.
    static func urlEncodedPair(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        if let equals = value.firstIndex(of: "=") {
            let name = String(value[..<equals])
            let content = encode(String(value[value.index(after: equals)...]))
            return name.isEmpty ? content : name + "=" + content
        }
        return encode(value)
    }

    // MARK: Code snippets

    enum SnippetLanguage: String, CaseIterable, Identifiable {
        case swift = "Swift (URLSession)"
        case javascript = "JavaScript (fetch)"
        case python = "Python (requests)"

        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .swift: "swift"
            case .javascript: "js"
            case .python: "py"
            }
        }
    }

    static func snippet(for request: HTTPPreparedRequest, language: SnippetLanguage) -> String {
        let body = request.bodyText
        func swiftString(_ text: String) -> String {
            if text.contains("\n") || text.contains("\"") { return "#\"\"\"\n\(text)\n\"\"\"#" }
            return "\"\(text)\""
        }
        func jsString(_ text: String) -> String {
            "`" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${") + "`"
        }
        func pyString(_ text: String) -> String {
            text.contains("\n") ? "\"\"\"" + text.replacingOccurrences(of: "\"\"\"", with: "\\\"\\\"\\\"") + "\"\"\""
                : "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        switch language {
        case .swift:
            var lines = ["import Foundation", "",
                         "var request = URLRequest(url: URL(string: \(swiftString(request.url.absoluteString)))!)",
                         "request.httpMethod = \"\(request.method)\""]
            for header in request.headers {
                lines.append("request.setValue(\(swiftString(header.value)), forHTTPHeaderField: \(swiftString(header.name)))")
            }
            if let body { lines.append("request.httpBody = Data(\(swiftString(body)).utf8)") }
            lines += ["", "let (data, response) = try await URLSession.shared.data(for: request)",
                      "print((response as? HTTPURLResponse)?.statusCode ?? 0)",
                      "print(String(decoding: data, as: UTF8.self))"]
            return lines.joined(separator: "\n")
        case .javascript:
            var options = ["  method: \"\(request.method)\","]
            if !request.headers.isEmpty {
                options.append("  headers: {")
                for header in request.headers { options.append("    \(jsString(header.name)): \(jsString(header.value)),") }
                options.append("  },")
            }
            if let body { options.append("  body: \(jsString(body)),") }
            if !request.followRedirects { options.append("  redirect: \"manual\",") }
            return (["const response = await fetch(\(jsString(request.url.absoluteString)), {"] + options + ["});",
                    "console.log(response.status);", "console.log(await response.text());"]).joined(separator: "\n")
        case .python:
            var lines = ["import requests", ""]
            if !request.headers.isEmpty {
                lines.append("headers = {")
                for header in request.headers { lines.append("    \(pyString(header.name)): \(pyString(header.value)),") }
                lines.append("}")
            }
            if let body { lines.append("data = \(pyString(body))") }
            var call = "response = requests.request(\(pyString(request.method)), \(pyString(request.url.absoluteString))"
            if !request.headers.isEmpty { call += ", headers=headers" }
            if body != nil { call += ", data=data" }
            if !request.followRedirects { call += ", allow_redirects=False" }
            lines += [call + ")", "print(response.status_code)", "print(response.text)"]
            return lines.joined(separator: "\n")
        }
    }
}
