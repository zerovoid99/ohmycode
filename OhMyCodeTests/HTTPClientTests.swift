import AppKit
import Foundation
import Network
import Testing
@testable import Oh_My_Code

// MARK: A local HTTP server

/// A tiny HTTP/1.1 server on 127.0.0.1 (a port of its own), answering each request with what
/// `handler` says and closing the connection. Only for tests: never reachable from outside.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
        func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }

    struct Reply: Sendable {
        var status = 200
        var headers: [(String, String)] = []
        var body = Data()
        /// Seconds before answering.
        var delay: Double = 0

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, headers: [("Content-Type", "application/json")], body: Data(text.utf8))
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "omc.test.http-server")
    private let handler: @Sendable (Request) -> Reply
    private let lock = NSLock()
    private var received: [Request] = []
    private(set) var port: UInt16 = 0

    var requests: [Request] { lock.withLock { received } }
    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    init(handler: @escaping @Sendable (Request) -> Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start() async throws {
        let ready = AsyncStream<Bool> { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.yield(true); continuation.finish()
                case .failed, .cancelled: continuation.yield(false); continuation.finish()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        for await isReady in ready {
            guard isReady else { throw URLError(.cannotConnectToHost) }
            break
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.respond(connection, to: request)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer)
            }
        }
    }

    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ connection: NWConnection, to request: Request) {
        lock.withLock { received.append(request) }
        let reply = handler(request)
        var head = "HTTP/1.1 \(reply.status) \(HTTPResponse.reasonPhrase(reply.status))\r\n"
        for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(reply.body.count)\r\nConnection: close\r\n\r\n"
        let data = Data(head.utf8) + reply.body
        queue.asyncAfter(deadline: .now() + reply.delay) {
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// The usual routes for these tests.
    static func standard() throws -> LocalHTTPServer {
        let gzipped = gzip(Data(#"{"compressed":true}"#.utf8))
        return try LocalHTTPServer { request in
            let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
            switch path {
            case "/json": return .json(#"{"token":"abc123","items":[{"id":7},{"id":8}],"ok":true}"#)
            case "/login": return .json(#"{"token":"t-\#(String(decoding: request.body, as: UTF8.self).count)"}"#)
            case "/echo":
                let headers = request.headers.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
                return Reply(headers: [("Content-Type", "text/plain"), ("X-Echo-Method", request.method)],
                             body: Data("\(request.method) \(request.path)\n\(headers)\n\n".utf8) + request.body)
            case "/redirect": return Reply(status: 302, headers: [("Location", "/json")])
            case "/set-cookie": return Reply(headers: [("Set-Cookie", "session=xyz; Path=/"), ("Content-Type", "text/plain")], body: Data("set".utf8))
            case "/cookies": return Reply(headers: [("Content-Type", "text/plain")], body: Data((request.header("Cookie") ?? "none").utf8))
            case "/gzip": return Reply(headers: [("Content-Type", "application/json"), ("Content-Encoding", "gzip")], body: gzipped)
            case "/slow": return Reply(body: Data("late".utf8), delay: 3)
            case "/large": return Reply(headers: [("Content-Type", "text/plain")], body: Data(repeating: 0x61, count: 300_000))
            case "/missing": return .json(#"{"error":"nope"}"#, status: 404)
            default: return Reply(status: 404)
            }
        }
    }

    /// gzip of `data` (the system's gzip).
    static func gzip(_ data: Data) -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/gzip")
        process.arguments = ["-c"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try? process.run()
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return result
    }
}

private func temporaryFolder(_ name: String = "omc-http") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: Parsing

struct HTTPFileParserTests {
    @Test func readsRequestsSeparatorsNamesAndBodies() throws {
        let file = HTTPFile(text: """
        @host = https://api.example.com
        @token = {{login.response.body.$.token}}

        # @name login
        POST {{host}}/login HTTP/1.1
        Content-Type: application/json
        // a comment between headers

        {
          # not a comment: body text
          "user": "me"
        }

        ### Get things
        GET {{host}}/things
            ?page=2
            &size=10
        Authorization: Bearer {{token}}

        ###
        https://example.com/bare

        ### empty
        # just a comment
        """)
        #expect(file.variables.map(\.name) == ["host", "token"])
        #expect(file.variables.first?.value == "https://api.example.com")
        #expect(file.requests.count == 3)

        let login = file.requests[0]
        #expect(login.name == "login" && login.method == "POST" && login.url == "{{host}}/login" && login.httpVersion == "HTTP/1.1")
        #expect(login.headers == [HTTPHeader(name: "Content-Type", value: "application/json")])
        #expect(login.body == "{\n  # not a comment: body text\n  \"user\": \"me\"\n}")
        #expect(login.requestLine == 4 && login.bodyLine == 8 && login.lastLine == 11)

        let things = file.requests[1]
        #expect(things.title == "Get things" && things.name == nil && things.displayName == "Get things")
        #expect(things.url == "{{host}}/things?page=2&size=10")
        #expect(things.headers.value(for: "authorization") == "Bearer {{token}}")
        #expect(things.body == nil)

        let bare = file.requests[2]
        #expect(bare.method == "GET" && bare.url == "https://example.com/bare" && bare.body == nil)
        #expect(file.request(atLine: 5)?.index == 0 && file.request(atLine: 15)?.index == 1)
        #expect(file.request(atLine: 24) == nil) // the comment-only block
        #expect(file.issues.isEmpty)
    }

    @Test func crlfFilesMetadataAndIssues() {
        let file = HTTPFile(text: "### one\r\n# @no-redirect\r\n// @no-cookie-jar\r\n# @prompt otp One-time code\r\n# @note Deletes data\r\nDELETE http://x/a\r\nX-A: 1\r\n\r\nbody\r\n\r\n\r\n###\r\nGET\r\n###\r\nFOO bar baz\r\nnot a header\r\n")
        #expect(file.requests.count == 3)
        let first = file.requests[0]
        #expect(first.noRedirect && first.noCookieJar && first.note == "Deletes data")
        #expect(first.prompts == [HTTPPrompt(name: "otp", description: "One-time code")])
        #expect(first.headers == [HTTPHeader(name: "X-A", value: "1")] && first.body == "body")
        #expect(first.title == "one" && first.name == "one")
        #expect(file.issues.map(\.line) == [12, 14, 15])
        #expect(file.issues[0].message.contains("no URL"))
        #expect(file.issues[1].message.contains("Unknown method"))
        #expect(file.issues[2].message.contains("header"))
    }

    @Test func aBodyWithoutABlankLineAndEmptyBodies() {
        let file = HTTPFile(text: "POST http://x\nContent-Type: application/json\n{\"a\": 1}\n\n\n###\nPOST http://x\n\n\n")
        #expect(file.requests[0].body == "{\"a\": 1}" && file.issues.isEmpty)
        #expect(file.requests[1].body == nil && file.requests[1].lastLine == 6)
    }
}

// MARK: Variables

struct HTTPVariableTests {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC

    private func resolver(_ file: [String: String] = [:], env: [String: String] = [:]) -> HTTPVariableResolver {
        var system = HTTPSystemContext()
        let now = fixedNow
        system.now = { now }
        system.randomInt = { low, _ in low }
        system.uuid = { "fixed-uuid" }
        system.processEnvironment = ["SECRET_KEY": "s3cret", "HOME_DIR": "/home/me"]
        system.dotenv = ["API_KEY": "from-dotenv"]
        system.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        return HTTPVariableResolver(fileVariables: file, environment: env, system: system)
    }

    @Test func fileVariablesEnvironmentAndNesting() throws {
        let resolver = resolver(["base": "{{scheme}}://{{host}}/v1", "scheme": "https"], env: ["host": "dev.example.com", "user": "{{scheme}}-user"])
        #expect(try resolver.resolve("GET {{base}}/items?u={{ user }}") == "GET https://dev.example.com/v1/items?u=https-user")
        #expect(throws: HTTPVariableError.unknown("nope")) { try resolver.resolve("{{nope}}") }
        #expect(throws: HTTPVariableError.cycle("a")) { try self.resolver(["a": "{{b}}", "b": "{{a}}"]).resolve("{{a}}") }
        // A file variable wins over the environment's.
        #expect(try self.resolver(["host": "file"], env: ["host": "env"]).resolve("{{host}}") == "file")
    }

    @Test func requestVariablesReadEarlierExchanges() throws {
        var resolver = resolver()
        resolver.requestNames = ["login", "other"]
        resolver.exchanges["login"] = HTTPExchangeRecord(
            requestHeaders: [HTTPHeader(name: "X-Trace", value: "t1")], requestBody: Data(#"{"user":"me"}"#.utf8), statusCode: 200,
            responseHeaders: [HTTPHeader(name: "X-Token", value: "hdr")],
            responseBody: Data(#"{"token":"abc","items":[{"id":7},{"id":8}],"ok":true,"n":1.5,"obj":{"a":1}}"#.utf8))
        #expect(try resolver.resolve("{{login.response.body.$.token}}") == "abc")
        #expect(try resolver.resolve("{{login.response.body.$.items[1].id}}") == "8")
        #expect(try resolver.resolve("{{login.response.body.$['ok']}}") == "true")
        #expect(try resolver.resolve("{{login.response.body.$.n}}") == "1.5")
        #expect(try resolver.resolve("{{login.response.body.$.obj}}") == #"{"a":1}"#)
        #expect(try resolver.resolve("{{login.response.headers.x-token}}") == "hdr")
        #expect(try resolver.resolve("{{login.request.headers.X-Trace}}") == "t1")
        #expect(try resolver.resolve("{{login.request.body.*}}") == #"{"user":"me"}"#)
        #expect(try resolver.resolve("{{login.request.body.$.user}}") == "me")
        #expect(throws: HTTPVariableError.notSent("other")) { try resolver.resolve("{{other.response.body.*}}") }
        #expect(throws: HTTPVariableError.self) { try resolver.resolve("{{login.response.body.$.missing}}") }
        #expect(throws: HTTPVariableError.unknown("ghost.response.body.*")) { try resolver.resolve("{{ghost.response.body.*}}") }
        // A file variable may hold a request variable.
        resolver.fileVariables["token"] = "{{login.response.body.$.token}}"
        #expect(try resolver.resolve("Bearer {{token}}") == "Bearer abc")
    }

    @Test func systemVariablesWithAFixedClock() throws {
        let resolver = resolver(env: ["keyName": "SECRET_KEY"])
        #expect(try resolver.resolve("{{$guid}}") == "fixed-uuid")
        #expect(try resolver.resolve("{{$randomInt 5 10}}") == "5")
        #expect(throws: HTTPVariableError.self) { try resolver.resolve("{{$randomInt 10 5}}") }
        #expect(try resolver.resolve("{{$timestamp}}") == "1700000000")
        #expect(try resolver.resolve("{{$timestamp -1 d}}") == "1699913600")
        #expect(try resolver.resolve("{{$datetime iso8601}}") == "2023-11-14T22:13:20.000Z")
        #expect(try resolver.resolve("{{$datetime rfc1123}}") == "Tue, 14 Nov 2023 22:13:20 GMT")
        #expect(try resolver.resolve("{{$datetime \"DD/MM/YYYY HH:mm\" 1 h}}") == "14/11/2023 23:13")
        #expect(try resolver.resolve("{{$datetime 'YYYY-MM-DD[T]HH' 2 M}}") == "2024-01-14T22")
        #expect(try resolver.resolve("{{$localDatetime iso8601}}") == "2023-11-15T05:13:20.000+07:00")
        #expect(try resolver.resolve("{{$processEnv HOME_DIR}}") == "/home/me")
        #expect(try resolver.resolve("{{$processEnv %keyName}}") == "s3cret")
        #expect(throws: HTTPVariableError.self) { try resolver.resolve("{{$processEnv NOT_SET_ANYWHERE}}") }
        #expect(try resolver.resolve("{{$dotenv API_KEY}}") == "from-dotenv")
        #expect(throws: HTTPVariableError.unknown("$nope")) { try resolver.resolve("{{$nope}}") }
        #expect(resolver.isDefined("$datetime iso8601") && !resolver.isDefined("$nope") && resolver.isDefined("keyName"))
    }

    @Test func dotenvFiles() throws {
        let values = DotEnv.parse("# comment\nexport A=1\nB = \"two words\"\nC='single'\nD=plain # trailing\n\nbad line\n")
        #expect(values == ["A": "1", "B": "two words", "C": "single", "D": "plain"])
        let root = try temporaryFolder()
        let sub = root.appending(path: "api")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "A=root\nB=root".write(to: root.appending(path: ".env"), atomically: true, encoding: .utf8)
        try "A=near".write(to: sub.appending(path: ".env"), atomically: true, encoding: .utf8)
        #expect(DotEnv.load(for: sub.appending(path: "x.http"), root: root) == ["A": "near", "B": "root"])
    }
}

// MARK: Environments

struct HTTPEnvironmentTests {
    @Test func vsCodeSettingsWithShared() {
        let environments = HTTPEnvironments.fromSettings(Data("""
        {
          // comments are fine
          "editor.fontSize": 12,
          "rest-client.environmentVariables": {
            "$shared": { "version": "v1", "host": "shared" },
            "dev": { "host": "localhost", "port": 8080, "debug": true },
            "prod": { "host": "example.com", },
          },
        }
        """.utf8))
        #expect(environments.names == ["dev", "prod"])
        #expect(environments.variables(for: "dev") == ["version": "v1", "host": "localhost", "port": "8080", "debug": "true"])
        #expect(environments.variables(for: "prod") == ["version": "v1", "host": "example.com"])
        #expect(environments.variables(for: nil) == ["version": "v1", "host": "shared"])
    }

    @Test func jetBrainsFilesWithPrivateOverridesFoundUpToTheFolder() throws {
        let root = try temporaryFolder()
        let nested = root.appending(path: "api/users")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try #"{"$shared": {"v": "1"}, "dev": {"host": "dev.local", "token": "public"}, "staging": {"host": "stg"}}"#
            .write(to: root.appending(path: "api/http-client.env.json"), atomically: true, encoding: .utf8)
        try #"{"dev": {"token": "private-secret"}}"#.write(to: root.appending(path: "http-client.private.env.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appending(path: ".vscode"), withIntermediateDirectories: true)
        try #"{"rest-client.environmentVariables": {"dev": {"fromVSCode": "yes", "host": "vscode"}}}"#
            .write(to: root.appending(path: ".vscode/settings.json"), atomically: true, encoding: .utf8)

        let environments = HTTPEnvironments.load(for: nested.appending(path: "users.http"), root: root)
        #expect(environments.names == ["dev", "staging"])
        // JetBrains' over VS Code's, the private file over both.
        #expect(environments.variables(for: "dev") == ["v": "1", "host": "dev.local", "token": "private-secret", "fromVSCode": "yes"])
        #expect(environments.sources.count == 3)
        #expect(HTTPEnvironments.folders(from: nested.appending(path: "x.http"), upTo: root).count == 3)
    }
}

// MARK: Building requests

struct HTTPRequestBuilderTests {
    private func build(_ text: String, variables: [String: String] = [:], base: URL? = nil, at index: Int = 0) throws -> HTTPPreparedRequest {
        let file = HTTPFile(text: text)
        var resolver = HTTPVariableResolver(fileVariables: file.variableValues.merging(variables) { $1 })
        resolver.requestNames = file.requestNames
        return try HTTPRequestBuilder(resolver: resolver, baseDirectory: base).build(file.requests[index])
    }

    @Test func basicAuthIsEncoded() throws {
        #expect(HTTPRequestBuilder.encodeBasicAuth("Basic user:pass") == "Basic dXNlcjpwYXNz")
        #expect(HTTPRequestBuilder.encodeBasicAuth("Basic user pass") == "Basic dXNlcjpwYXNz")
        #expect(HTTPRequestBuilder.encodeBasicAuth("Basic dXNlcjpwYXNz") == "Basic dXNlcjpwYXNz")
        #expect(HTTPRequestBuilder.encodeBasicAuth("Bearer abc") == "Bearer abc")
        let request = try build("GET http://x\nAuthorization: Basic {{user}}:{{pass}}", variables: ["user": "user", "pass": "pass"])
        #expect(request.headers.value(for: "Authorization") == "Basic dXNlcjpwYXNz")
    }

    @Test func urlsAndHosts() throws {
        #expect(try build("GET /api/items?q=a b\nHost: localhost:8080").url.absoluteString == "http://localhost:8080/api/items?q=a%20b")
        #expect(try build("example.com/x").url.absoluteString == "http://example.com/x")
        #expect(try build("@id = 42\nGET https://x.dev/items/{{id}}").url.absoluteString == "https://x.dev/items/42")
        #expect(throws: HTTPVariableError.unknown("missing")) { try build("GET https://x/{{missing}}") }
    }

    @Test func formBodiesJoinTheirLines() throws {
        let request = try build("""
        POST http://x/form
        Content-Type: application/x-www-form-urlencoded

        name={{name}}
        &age=30
          &city=Jakarta
        """, variables: ["name": "Ann"])
        #expect(request.bodyText == "name=Ann&age=30&city=Jakarta")
    }

    @Test func filesInBodiesAndMultipart() throws {
        let folder = try temporaryFolder()
        try "{\"id\": \"{{id}}\"}".write(to: folder.appending(path: "payload.json"), atomically: true, encoding: .utf8)
        try Data([0x00, 0x01, 0xFF]).write(to: folder.appending(path: "blob.bin"))

        let raw = try build("POST http://x\nContent-Type: application/json\n\n< ./payload.json", variables: ["id": "9"], base: folder)
        #expect(raw.bodyText == "{\"id\": \"{{id}}\"}")
        let substituted = try build("POST http://x\nContent-Type: application/json\n\n<@ ./payload.json", variables: ["id": "9"], base: folder)
        #expect(substituted.bodyText == "{\"id\": \"9\"}")
        let latin = try build("POST http://x\n\n<@latin1 payload.json", variables: ["id": "1"], base: folder)
        #expect(latin.bodyText == "{\"id\": \"1\"}")
        #expect(throws: HTTPBuildError.missingFile("./nope.txt")) { try build("POST http://x\n\n< ./nope.txt", base: folder) }

        let multipart = try build("""
        POST http://x/upload
        Content-Type: multipart/form-data; boundary=B

        --B
        Content-Disposition: form-data; name="title"

        {{title}}
        --B
        Content-Disposition: form-data; name="file"; filename="blob.bin"
        Content-Type: application/octet-stream

        < ./blob.bin
        --B--
        """, variables: ["title": "Hello"], base: folder)
        var expected = Data("--B\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nHello\r\n--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"blob.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        expected.append(Data([0x00, 0x01, 0xFF]))
        expected.append(Data("\r\n--B--\r\n".utf8))
        #expect(multipart.body == expected)
    }

    @Test func graphQLBodies() throws {
        let request = try build("""
        POST http://x/graphql
        X-Request-Type: GraphQL

        query Users($first: Int) {
          users(first: $first) { name }
        }

        { "first": {{count}} }
        """, variables: ["count": "3"])
        #expect(!request.headers.contains(named: "X-Request-Type"))
        #expect(request.headers.value(for: "Content-Type") == "application/json")
        let object = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        #expect(object["query"] as? String == "query Users($first: Int) {\n  users(first: $first) { name }\n}")
        #expect((object["variables"] as? [String: Any])?["first"] as? Int == 3)
        #expect(object["operationName"] as? String == "Users")
        #expect(throws: HTTPBuildError.self) { try build("POST http://x\nX-Request-Type: GraphQL\n\n{ a }\n\n{ not json") }
    }
}

// MARK: cURL and snippets

struct HTTPCurlTests {
    @Test func exportsAndImportsTheSameRequest() throws {
        let request = HTTPPreparedRequest(method: "PUT", url: URL(string: "https://api.x.dev/items/1?a=b")!,
                                          headers: [HTTPHeader(name: "Content-Type", value: "application/json"),
                                                    HTTPHeader(name: "X-Quote", value: "it's")],
                                          body: Data(#"{"name": "it's", "n": 1}"#.utf8), displayName: "x")
        let command = HTTPCurl.command(for: request)
        #expect(command.hasPrefix("curl \\\n  -X PUT \\\n  'https://api.x.dev/items/1?a=b'"))
        #expect(command.contains(#"-H 'X-Quote: it'\''s'"#))
        let text = try HTTPCurl.httpText(fromCurl: command)
        let parsed = try #require(HTTPFile(text: text).requests.first)
        let rebuilt = try HTTPRequestBuilder(resolver: HTTPVariableResolver(), baseDirectory: nil).build(parsed)
        #expect(rebuilt.method == request.method && rebuilt.url == request.url)
        #expect(rebuilt.headers == request.headers && rebuilt.body == request.body)
    }

    @Test func importsCommonCurlOptions() throws {
        let text = try HTTPCurl.httpText(fromCurl: """
        curl 'https://x.dev/login' \\
          -H "Accept: application/json" \\
          -u admin:secret --compressed -L -s \\
          --data-urlencode 'q=a b&c' -d "x=1"
        """)
        #expect(text == "POST https://x.dev/login\nAccept: application/json\nAuthorization: Basic admin:secret\nContent-Type: application/x-www-form-urlencoded\n\nq=a%20b%26c&x=1")
        #expect(try HTTPCurl.httpText(fromCurl: "curl -G https://x.dev/s -d q=1 --data-urlencode 'w=a b'") == "GET https://x.dev/s?q=1&w=a%20b")
        #expect(try HTTPCurl.httpText(fromCurl: "curl -X DELETE --url=https://x.dev/a/1") == "DELETE https://x.dev/a/1")
        let form = try HTTPCurl.httpText(fromCurl: "curl https://x.dev/up -F name=Ann -F 'file=@./photo.png;type=image/png'")
        #expect(form.contains("Content-Type: multipart/form-data; boundary="))
        #expect(form.contains("Content-Disposition: form-data; name=\"file\"; filename=\"photo.png\"\nContent-Type: image/png\n\n< ./photo.png"))
        #expect(form.hasPrefix("POST https://x.dev/up"))
        #expect(try HTTPCurl.httpText(fromCurl: "curl --data-raw $'{\"a\":\\n1}' https://x") == "POST https://x\nContent-Type: application/x-www-form-urlencoded\n\n{\"a\":\n1}")
        #expect(throws: HTTPCurl.ImportError.notCurl) { try HTTPCurl.httpText(fromCurl: "wget https://x") }
        #expect(throws: HTTPCurl.ImportError.noURL) { try HTTPCurl.httpText(fromCurl: "curl -H 'A: b'") }
    }

    @Test func codeSnippets() {
        let request = HTTPPreparedRequest(method: "POST", url: URL(string: "https://x.dev/a")!,
                                          headers: [HTTPHeader(name: "Content-Type", value: "application/json")],
                                          body: Data(#"{"a":1}"#.utf8), followRedirects: false, displayName: "x")
        let swift = HTTPCurl.snippet(for: request, language: .swift)
        #expect(swift.contains("request.httpMethod = \"POST\"") && swift.contains("forHTTPHeaderField: \"Content-Type\""))
        let js = HTTPCurl.snippet(for: request, language: .javascript)
        #expect(js.contains("await fetch(`https://x.dev/a`") && js.contains("redirect: \"manual\""))
        let python = HTTPCurl.snippet(for: request, language: .python)
        #expect(python.contains("requests.request(\"POST\", \"https://x.dev/a\", headers=headers, data=data, allow_redirects=False)"))
    }
}

// MARK: Responses and history

struct HTTPResponseFormatTests {
    @Test func prettyPrintsJSONInItsOrder() {
        #expect(HTTPResponseFormat.prettyJSON(#"{"z":1,"a":[1,2,{}],"s":"x, {y}: \"q\"","e":[]}"#)
                == "{\n  \"z\": 1,\n  \"a\": [\n    1,\n    2,\n    {}\n  ],\n  \"s\": \"x, {y}: \\\"q\\\"\",\n  \"e\": []\n}")
        #expect(HTTPResponseFormat.prettyJSON("not json") == nil)
        #expect(HTTPResponseFormat.prettyXML("<a><b x=\"1\">t</b></a>")?.contains("\n") == true)
    }

    @Test func bodyKindsSizesAndTimes() {
        #expect(HTTPResponseFormat.kind(contentType: "application/json; charset=utf-8", body: Data("{}".utf8)) == .json)
        #expect(HTTPResponseFormat.kind(contentType: "application/problem+json", body: Data("{}".utf8)) == .json)
        #expect(HTTPResponseFormat.kind(contentType: "text/html", body: Data("<p>".utf8)) == .html)
        #expect(HTTPResponseFormat.kind(contentType: "application/xml", body: Data("<a/>".utf8)) == .xml)
        #expect(HTTPResponseFormat.kind(contentType: "image/png", body: Data([1])) == .image)
        #expect(HTTPResponseFormat.kind(contentType: nil, body: Data(#"[1,2]"#.utf8)) == .json)
        #expect(HTTPResponseFormat.kind(contentType: "application/octet-stream", body: Data([0, 1, 2])) == .binary)
        #expect(HTTPResponseFormat.kind(contentType: "text/plain", body: Data()) == .empty)
        #expect(HTTPResponseFormat.duration(0.2456) == "246 ms" && HTTPResponseFormat.duration(1.234) == "1.23 s")
        #expect(HTTPResponseFormat.size(2048) == ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file))
        #expect(HTTPResponseFormat.BodyKind.image.fileExtension(contentType: "image/jpeg") == "jpg")
        #expect(HTTPResponseFormat.hexPreview(Data([0x41, 0x42])).hasPrefix("00000000"))
        #expect(HTTPResponse.reasonPhrase(200) == "OK" && HTTPResponse.reasonPhrase(404) == "Not Found")
    }
}

@MainActor
struct HTTPHistoryTests {
    @Test func redactsSecretsAndPersistsTheLastFifty() throws {
        let redacted = HTTPHistory.redact("""
        POST https://x/login
        Authorization: Bearer abc.def
        authorization: {{auth}}
        Cookie: session=1
        X-API-Key: k-123
        X-Session-Token: {{token}}
        Content-Type: application/json

        {"password": "hunter2", "user": "me"}
        """)
        #expect(!redacted.contains("hunter2")) // a secret-looking JSON key too
        #expect(redacted.contains("Authorization: Bearer •••") && redacted.contains("Cookie: •••") && redacted.contains("X-API-Key: •••"))
        #expect(redacted.contains("authorization: {{auth}}") && redacted.contains("X-Session-Token: {{token}}"))
        #expect(!redacted.contains("abc.def") && !redacted.contains("session=1") && !redacted.contains("k-123"))
        #expect(redacted.contains("Content-Type: application/json"))

        let file = try temporaryFolder().appending(path: "history.json")
        let history = HTTPHistory(file: file)
        for index in 0..<55 {
            history.add(HTTPHistoryEntry(date: Date(timeIntervalSince1970: Double(index)), method: "GET", url: "http://x/\(index)",
                                         status: 200, duration: 0.1, requestText: "GET http://x/\(index)\nCookie: c=\(index)", file: nil, name: nil))
        }
        let reloaded = HTTPHistory(file: file)
        #expect(reloaded.entries.count == HTTPHistory.limit)
        #expect(reloaded.entries.first?.url == "http://x/54" && reloaded.entries.last?.url == "http://x/5")
        #expect(reloaded.entries.first?.requestText == "GET http://x/54\nCookie: •••")
        reloaded.clear()
        #expect(HTTPHistory(file: file).entries.isEmpty)
    }
}

// MARK: Editor support

@MainActor
struct HTTPLanguageTests {
    static let sample = """
    @host = http://localhost
    # @name login
    POST {{host}}/login HTTP/1.1
    Content-Type: application/json

    {"user": "a", "n": 1, "ok": true}
    ### second
    GET {{host}}/me
    Accept: application/xml

    <a x="1">t</a>
    """

    private func tokens(_ text: String) -> [(String, String)] {
        let string = text as NSString
        return HTTPSyntax.tokens(in: string, range: NSRange(location: 0, length: string.length)).map { (string.substring(with: $0.range), $0.capture) }
    }

    @Test func highlightsTheFile() async throws {
        let found = tokens(Self.sample)
        func has(_ text: String, _ capture: String) -> Bool { found.contains { $0.0.trimmingCharacters(in: .whitespaces) == text && $0.1 == capture } }
        #expect(has("@host", "attribute") && has("http://localhost", "string"))
        #expect(has("# @name login", "comment") && has("@name", "attribute"))
        #expect(has("POST", "keyword") && has("{{host}}/login", "string.special.url") && has("HTTP/1.1", "constant"))
        #expect(has("{{host}}", "type"))
        #expect(has("Content-Type", "property") && has("Accept", "property"))
        #expect(has("\"user\"", "property") && has("\"a\"", "string") && has("1", "number") && has("true", "constant.builtin"))
        #expect(has("###", "comment") && has("second", "function") && has("GET", "keyword"))
        #expect(has("<a", "tag") && has("x", "attribute") && has("\"1\"", "string"))
        // The editor's highlighter runs it for .http files (no grammar needed).
        let storage = NSTextStorage(string: Self.sample)
        let highlighter = try #require(SyntaxHighlighter(language: .http, textStorage: storage))
        let highlights = await highlighter.highlights(in: NSRange(location: 0, length: storage.length))
        #expect(highlights.contains { $0.name == "keyword" && storage.mutableString.substring(with: $0.range) == "POST" })
        // A range in the middle still knows it's in a JSON body.
        let line = (Self.sample as NSString).range(of: "{\"user\"")
        let middle = HTTPSyntax.tokens(in: Self.sample as NSString, range: NSRange(location: line.location, length: 8))
        #expect(middle.contains { $0.capture == "property" })
        #expect(SourceLanguage(fileExtension: "rest") == .http && SourceLanguage.http.lineComment == "#")
    }

    @Test func lensesFoldsAndOutline() {
        let file = HTTPFile(text: Self.sample)
        let lenses = HTTPSyntax.codeLenses(file)
        #expect(lenses.keys.sorted() == [2, 7])
        #expect(lenses[2]?.map(\.title) == ["Send Request", "Copy as cURL"])
        #expect(lenses[7]?.first?.commandName == HTTPSyntax.sendCommand)
        #expect(HTTPSyntax.foldRegions(file) == [FoldRegion(start: 2, end: 5, kind: .region), FoldRegion(start: 6, end: 10, kind: .region)])
        let lines = LineIndex(string: Self.sample as NSString)
        let symbols = HTTPSyntax.symbols(file, lineIndex: lines, length: (Self.sample as NSString).length)
        #expect(symbols.map(\.name) == ["login", "second"])
        #expect(symbols.first?.detail == "POST {{host}}/login")
    }

    @Test func completesMethodsHeadersTypesAndVariables() {
        func labels(_ text: String, variables: [(String, String)] = [], requests: [String] = []) -> [String] {
            let string = text as NSString
            let lines = LineIndex(string: string)
            let line = lines.line(containing: string.length)
            return HTTPCompletion.items(text: string, cursor: string.length, line: line, lineStart: lines.lineStarts[line],
                                        variables: variables.map { (name: $0.0, detail: $0.1) }, requestNames: requests, firstID: 0).map(\.label)
        }
        #expect(labels("PO").contains("POST"))
        #expect(labels("GET http://x\nCont").contains("Content-Type"))
        #expect(labels("GET http://x\nContent-Type: app").contains("application/json"))
        #expect(labels("GET http://x\nAuthorization: ").contains("Bearer "))
        #expect(labels("GET http://x\n\n{\"a\": 1").isEmpty)
        let variables = labels("GET http://x/{{ho", variables: [("host", "File")], requests: ["login"])
        #expect(variables.contains("host") && variables.contains("login.response.body.$.") && variables.contains("$guid"))
        // The item replaces what's typed, and closes the braces.
        let string = "GET http://x\nContent-Ty" as NSString
        let item = HTTPCompletion.items(text: string, cursor: string.length, line: 1, lineStart: 13, variables: [], requestNames: [], firstID: 0)
            .first { $0.label == "Content-Type" }
        #expect(item?.editRange == LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 1, character: 10)))
        #expect(item?.insertText == "Content-Type: ")
        let variable = HTTPCompletion.items(text: "{{to" as NSString, cursor: 4, line: 0, lineStart: 0, variables: [("token", "")], requestNames: [], firstID: 0)
        #expect(variable.first?.insertText == "token}}")
    }

    @Test func problems() throws {
        let folder = try temporaryFolder()
        let text = """
        @known = 1
        GET http://x/{{known}}/{{unknown}}/{{$guid}}/{{$bogus}}/{{onlyProd}}/{{login.response.body.$.a}}

        ###
        # @prompt code
        FOO bar baz
        X: {{code}}

        < ./missing.json
        """
        let file = HTTPFile(text: text)
        var resolver = HTTPVariableResolver(fileVariables: file.variableValues)
        resolver.requestNames = ["login"]
        let diagnostics = HTTPSyntax.diagnostics(text: text, file: file, resolver: resolver, otherEnvironments: ["prod": ["onlyProd"]],
                                                 baseDirectory: folder)
        let messages = diagnostics.map(\.message)
        #expect(messages.contains { $0.contains("Unknown variable “unknown”") })
        #expect(messages.contains { $0.contains("Unknown system variable “$bogus”") })
        #expect(diagnostics.contains { $0.message.contains("“onlyProd” is only defined in the environment “prod”") && $0.severity == .warning })
        #expect(messages.contains { $0.contains("Unknown method") })
        #expect(messages.contains { $0.contains("missing.json") })
        #expect(!messages.contains { $0.contains("known”") && !$0.contains("unknown") } && !messages.contains { $0.contains("code") })
        let unknown = try #require(diagnostics.first { $0.message.contains("“unknown”") })
        #expect(unknown.range.start.line == 1 && unknown.range.start.character == 23 && unknown.range.end.character == 34)
    }
}

// MARK: Sending

@Suite(.serialized)
struct HTTPTransferTests {
    @Test func statusHeadersBodyAndTimings() async throws {
        let server = try LocalHTTPServer.standard()
        try await server.start()
        defer { server.stop() }
        let request = HTTPPreparedRequest(method: "POST", url: URL(string: server.url("/echo?x=1"))!,
                                          headers: [HTTPHeader(name: "X-Test", value: "yes"), HTTPHeader(name: "Content-Type", value: "text/plain")],
                                          body: Data("hello".utf8), displayName: "echo")
        let response = try await HTTPTransfer.send(request, options: HTTPSendOptions(), jar: nil)
        #expect(response.statusCode == 200 && response.reason == "OK")
        #expect(response.headers.value(for: "x-echo-method") == "POST")
        let body = String(decoding: response.body, as: UTF8.self)
        #expect(body.hasPrefix("POST /echo?x=1\n") && body.contains("X-Test=yes") && body.hasSuffix("\n\nhello"))
        #expect(response.bodySize == response.body.count && response.isBodyComplete)
        #expect(response.timings.total > 0 && response.timings.timeToFirstByte != nil)

        let missing = try await HTTPTransfer.send(HTTPPreparedRequest(method: "GET", url: URL(string: server.url("/missing"))!, headers: [],
                                                                      displayName: "m"), options: HTTPSendOptions(), jar: nil)
        #expect(missing.statusCode == 404 && missing.reason == "Not Found")
    }

    @Test func redirectsFollowedOrNot() async throws {
        let server = try LocalHTTPServer.standard()
        try await server.start()
        defer { server.stop() }
        var request = HTTPPreparedRequest(method: "GET", url: URL(string: server.url("/redirect"))!, headers: [], displayName: "r")
        let followed = try await HTTPTransfer.send(request, options: HTTPSendOptions(), jar: nil)
        #expect(followed.statusCode == 200 && followed.url.path == "/json" && followed.timings.redirects == 1)
        request.followRedirects = false
        let stopped = try await HTTPTransfer.send(request, options: HTTPSendOptions(), jar: nil)
        #expect(stopped.statusCode == 302 && stopped.headers.value(for: "Location") == "/json")
        let globallyOff = try await HTTPTransfer.send(HTTPPreparedRequest(method: "GET", url: URL(string: server.url("/redirect"))!, headers: [], displayName: "r"),
                                                      options: HTTPSendOptions(followRedirects: false), jar: nil)
        #expect(globallyOff.statusCode == 302)
    }

    @Test func cookiesAreKeptSentAndPersisted() async throws {
        let server = try LocalHTTPServer.standard()
        try await server.start()
        defer { server.stop() }
        let file = try temporaryFolder().appending(path: "cookies.json")
        let jar = HTTPCookieJar(file: file)
        let set = try await HTTPTransfer.send(HTTPPreparedRequest(method: "GET", url: URL(string: server.url("/set-cookie"))!, headers: [], displayName: "s"),
                                              options: HTTPSendOptions(), jar: jar)
        #expect(set.cookies.map(\.name) == ["session"])
        let echo = HTTPPreparedRequest(method: "GET", url: URL(string: server.url("/cookies"))!, headers: [], displayName: "c")
        let sent = try await HTTPTransfer.send(echo, options: HTTPSendOptions(), jar: jar)
        #expect(String(decoding: sent.body, as: UTF8.self) == "session=xyz")
        // Kept between launches.
        let reloaded = HTTPCookieJar(file: file)
        #expect(reloaded.cookies(for: URL(string: server.url("/x"))!).map(\.value) == ["xyz"])
        // A request's own Cookie header comes first; # @no-cookie-jar sends none of the jar's.
        var own = echo
        own.headers = [HTTPHeader(name: "Cookie", value: "mine=1")]
        #expect(String(decoding: try await HTTPTransfer.send(own, options: HTTPSendOptions(), jar: reloaded).body, as: UTF8.self) == "mine=1; session=xyz")
        var noJar = echo
        noJar.useCookieJar = false
        #expect(String(decoding: try await HTTPTransfer.send(noJar, options: HTTPSendOptions(), jar: reloaded).body, as: UTF8.self) == "none")
        reloaded.clear()
        #expect(HTTPCookieJar(file: file).all.isEmpty)
    }

    @Test func gzipIsDecoded() async throws {
        let server = try LocalHTTPServer.standard()
        try await server.start()
        defer { server.stop() }
        let response = try await HTTPTransfer.send(HTTPPreparedRequest(method: "GET", url: URL(string: server.url("/gzip"))!, headers: [], displayName: "g"),
                                                   options: HTTPSendOptions(), jar: nil)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"compressed":true}"#)
    }

    @Test func timeoutsAndCancelling() async throws {
        let server = try LocalHTTPServer.standard()
        try await server.start()
        defer { server.stop() }
        let slow = HTTPPreparedRequest(method: "GET", url: URL(string: server.url("/slow"))!, headers: [], displayName: "slow")
        await #expect(throws: HTTPSendError.timedOut(1)) {
            _ = try await HTTPTransfer.send(slow, options: HTTPSendOptions(timeout: 1), jar: nil)
        }
        let task = Task { try await HTTPTransfer.send(slow, options: HTTPSendOptions(timeout: 10), jar: nil) }
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        task.cancel()
        await #expect(throws: HTTPSendError.cancelled) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func largeBodiesGoToAFile() async throws {
        let server = try LocalHTTPServer.standard()
        try await server.start()
        defer { server.stop() }
        let response = try await HTTPTransfer.send(HTTPPreparedRequest(method: "GET", url: URL(string: server.url("/large"))!, headers: [], displayName: "l"),
                                                   options: HTTPSendOptions(inMemoryLimit: 100_000, previewLength: 1_000), jar: nil)
        let file = try #require(response.bodyFile)
        #expect(response.bodySize == 300_000 && response.body.count == 1_000 && !response.isBodyComplete)
        #expect(response.fullBody().count == 300_000)
        try? FileManager.default.removeItem(at: file)
    }
}

// MARK: The workspace

@MainActor
@Suite(.serialized)
struct HTTPWorkspaceTests {
    private func makeWorkspace(_ text: String, files: [String: String] = [:]) throws -> (Workspace, EditorDocument, URL) {
        let root = try temporaryFolder("omc-http-ws")
        try text.write(to: root.appending(path: "api.http"), atomically: true, encoding: .utf8)
        for (path, contents) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.http.storageRoot = root.appending(path: ".storage")
        workspace.http.settings = HTTPClientSettings(defaults: ScratchDefaults.named("http-\(UUID().uuidString)"))
        workspace.open(fileAt: root.appending(path: "api.http"))
        return (workspace, try #require(workspace.activeDocument), root)
    }

    @Test func sendsChainsReusesTabsAndKeepsHistory() async throws {
        let server = try LocalHTTPServer.standard()
        try await server.start()
        defer { server.stop() }
        let (workspace, document, root) = try makeWorkspace("""
        @base = \(server.url(""))

        # @name login
        POST {{base}}/login
        Content-Type: application/json

        {"user": "{{user}}"}

        ### me
        GET {{base}}/echo
        Authorization: Bearer {{login.response.body.$.token}}
        """, files: ["http-client.env.json": #"{"dev": {"user": "ann"}, "prod": {"user": "bob"}}"#])
        #expect(document.language == .http)
        // Without an environment, {{user}} is unknown: nothing is sent.
        #expect(await workspace.sendHTTPRequest(in: document, line: 3)?.value == nil)
        #expect(workspace.errorMessage?.contains("Unknown variable “user”") == true)
        #expect(workspace.http.responseTabs.isEmpty && server.requests.isEmpty)

        workspace.http.setEnvironment("dev", for: document.url)
        #expect(workspace.httpEnvironmentLabel == "dev")
        let login = try #require(await workspace.sendHTTPRequest(in: document, line: 3)?.value)
        #expect(login.state == .done && login.title == "Response: login")
        #expect(server.requests.last?.body == Data(#"{"user": "ann"}"#.utf8))
        // Beside the file: a group of its own to the right.
        #expect(workspace.groups.count == 2 && workspace.groups[1].activeDocumentID == login.id)
        #expect(workspace.tabInfo(login.id)?.title == "Response: login")

        // The second request reads the first's response.
        let me = try #require(await workspace.sendHTTPRequest(in: document, line: 10)?.value)
        #expect(server.requests.last?.header("Authorization") == "Bearer t-15")
        #expect(me.request?.headers.value(for: "Authorization") == "Bearer t-15")
        #expect(workspace.http.responseTabs.count == 2)

        // The same request again reuses its tab, unless it's pinned.
        let again = try #require(await workspace.sendHTTPRequest(in: document, line: 10)?.value)
        #expect(again === me && workspace.http.responseTabs.count == 2)
        me.isPinned = true
        let fresh = try #require(await workspace.sendHTTPRequest(in: document, line: 10)?.value)
        #expect(fresh !== me && workspace.http.responseTabs.count == 3)

        // History: newest first, secrets redacted, kept on disk.
        let entries = workspace.http.history.entries
        #expect(entries.count == 4 && entries.first?.status == 200 && entries.first?.url == server.url("/echo"))
        #expect(entries.first?.requestText.contains("Authorization: Bearer {{login.response.body.$.token}}") == true)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".storage").path))

        // Rerun Last Request.
        let count = server.requests.count
        workspace.http.rerunLast()
        #expect(try await LanguageClientTests.eventually { server.requests.count == count + 1 })

        // Closing a response tab.
        for tab in workspace.http.responseTabs {
            for group in workspace.groups where group.contains(tab.id) { workspace.closeTab(tab.id, in: group) }
        }
        #expect(workspace.http.responseTabs.isEmpty && workspace.groups.count == 1)
    }

    @Test func promptsNotesLensesAndProblems() async throws {
        let server = try LocalHTTPServer.standard()
        try await server.start()
        defer { server.stop() }
        let (workspace, document, _) = try makeWorkspace("""
        # @prompt code The code
        # @note Careful
        GET \(server.url("/echo"))?code={{code}}
        X-Missing: {{nowhere}}
        """)
        // Problems and lenses come on their own.
        #expect(try await LanguageClientTests.eventually { document.codeLenses[2]?.count == 2 })
        #expect(try await LanguageClientTests.eventually {
            workspace.problems.diagnostics(for: document.url, source: "http").contains { $0.message.contains("nowhere") }
        })
        #expect(document.diagnostics.contains { $0.message.contains("nowhere") })
        #expect(!document.diagnostics.contains { $0.message.contains("“code”") })

        // Fill in the missing variable: the problem goes.
        document.textStorage.replaceCharacters(in: (document.textStorage.string as NSString).range(of: "{{nowhere}}"), with: "1")
        #expect(try await LanguageClientTests.eventually { workspace.problems.diagnostics(for: document.url, source: "http").isEmpty })

        var asked: [String] = []
        workspace.http.askForPrompt = { prompt in asked.append(prompt.name); return "42" }
        var notes: [String] = []
        workspace.http.confirmNote = { notes.append($0); return false }
        #expect(await workspace.sendHTTPRequest(in: document, line: 2)?.value == nil) // the note was declined
        #expect(notes.first?.hasPrefix("Careful") == true && asked.isEmpty)

        workspace.http.confirmNote = { _ in true }
        // The lens sends it.
        let lens = try #require(document.codeLenses[2]?.first)
        workspace.run(lens, in: document)
        #expect(try await LanguageClientTests.eventually { workspace.http.responseTabs.first?.state == .done })
        #expect(asked == ["code"] && server.requests.last?.path == "/echo?code=42")

        // Completion of variables in the document.
        let labels = document.httpCompletions(at: (document.textStorage.string as NSString).range(of: "{{code").location + 4, firstID: 0).map(\.label)
        #expect(labels.contains("code") && labels.contains("$guid"))
    }

    @Test func pasteCurlAndEnvironmentChoiceIsRememberedPerFolder() async throws {
        let (workspace, document, root) = try makeWorkspace("GET http://x/a\n", files: [".vscode/settings.json": #"{"rest-client.environmentVariables": {"$shared": {"a": "1"}, "local": {"b": "2"}}}"#])
        workspace.http.quickPick = { items, _ in items.firstIndex { $0.label == "local" } }
        await workspace.http.switchEnvironment(for: document.url)
        #expect(workspace.http.environmentName(for: document.url) == "local")
        // Another window on the same folder sees the choice.
        let other = Workspace()
        other.openFolder(root)
        other.http.settings = workspace.http.settings
        #expect(other.http.environmentName(for: document.url) == "local")
        #expect(other.http.environmentName(for: root.appending(path: "nested/x.http")) == "local")
        workspace.http.setEnvironment(nil, for: document.url)
        #expect(workspace.httpEnvironmentLabel == "No Environment")

        let parsed = HTTPFile(text: try HTTPCurl.httpText(fromCurl: "curl -X POST https://x.dev/a -d 'k=v'"))
        #expect(parsed.requests.first?.method == "POST" && parsed.requests.first?.body == "k=v")
        #expect(Workspace.httpPaletteCommands.first { $0.id == "rest.send" }?.key == "alt+cmd+r")
        #expect(Keybindings.builtInDefaults.filter { $0.value == "alt+cmd+r" }.keys.sorted() == ["rest.send"])
    }
}
