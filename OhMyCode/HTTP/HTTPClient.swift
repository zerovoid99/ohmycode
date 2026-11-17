import CryptoKit
import Foundation
import Observation

/// Settings ▸ HTTP: how requests from `.http` files are sent, and each folder's environment.
@MainActor
@Observable
final class HTTPClientSettings {
    static let shared = HTTPClientSettings(defaults: AppSettings.isRunningTests ? ScratchDefaults.named("http-client") : .omc)

    @ObservationIgnored private let defaults: UserDefaults
    /// Seconds without data before a request fails.
    var timeout: Double { didSet { defaults.set(timeout, forKey: "httpClient.timeout") } }
    var followRedirects: Bool { didSet { defaults.set(followRedirects, forKey: "httpClient.followRedirects") } }
    /// Self-signed certificates are accepted from localhost (127.0.0.1, ::1) only.
    var allowSelfSignedLocalhost: Bool { didSet { defaults.set(allowSelfSignedLocalhost, forKey: "httpClient.allowSelfSignedLocalhost") } }
    /// The chosen environment per folder (by the history key of the window's folders).
    private var environments: [String: String] { didSet { defaults.set(environments, forKey: "httpClient.environments") } }

    /// Bodies larger than this are written to a temporary file instead of kept in memory.
    nonisolated static let inMemoryBodyLimit = 10 * 1024 * 1024

    init(defaults: UserDefaults) {
        self.defaults = defaults
        timeout = min(max(defaults.object(forKey: "httpClient.timeout") as? Double ?? 30, 1), 3600)
        followRedirects = defaults.object(forKey: "httpClient.followRedirects") as? Bool ?? true
        allowSelfSignedLocalhost = defaults.object(forKey: "httpClient.allowSelfSignedLocalhost") as? Bool ?? false
        environments = defaults.dictionary(forKey: "httpClient.environments") as? [String: String] ?? [:]
    }

    func environment(forKey key: String) -> String? { environments[key] }

    func setEnvironment(_ name: String?, forKey key: String) { environments[key] = name }
}

/// Where the HTTP client keeps each workspace's cookies and history.
@MainActor
enum HTTPStorage {
    static var root: URL {
        AppSettings.isRunningTests
            ? FileManager.default.temporaryDirectory.appending(path: "omc-test-http-\(ProcessInfo.processInfo.processIdentifier)")
            : URL.omcApplicationSupport.appending(path: "OhMyCode/HTTP")
    }

    /// A short, stable name for a window's folders (or its workspace file).
    static func key(folders: [URL], workspaceFile: URL?) -> String {
        let identity = workspaceFile?.standardizedFileURL.path ?? folders.map { $0.standardizedFileURL.path }.joined(separator: "\n")
        guard !identity.isEmpty else { return "no-folder" }
        return SHA256.hash(data: Data(identity.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Cookies

/// One workspace's cookies, kept between launches (as JSON), sent with requests that match
/// them unless a request says `# @no-cookie-jar`.
final class HTTPCookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [HTTPCookie] = []
    let file: URL?

    init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        cookies = list.compactMap(Self.cookie(from:)).filter { !Self.isExpired($0) }
    }

    var all: [HTTPCookie] { lock.withLock { cookies.filter { !Self.isExpired($0) } } }

    private static func isExpired(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        cookie.expiresDate.map { $0 <= now } ?? false
    }

    /// The cookies to send to `url`: its domain and path, https for secure ones, not expired.
    func cookies(for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return all.filter { cookie in
            let domain = cookie.domain.lowercased()
            let domainMatches = domain.hasPrefix(".")
                ? host == domain.dropFirst() || host.hasSuffix(domain)
                : host == domain
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = path == cookiePath || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
            return domainMatches && pathMatches && (!cookie.isSecure || url.scheme == "https")
        }
    }

    /// Keeps the cookies a response set (replacing ones of the same name, domain and path;
    /// an expired one removes it).
    func store(_ new: [HTTPCookie]) {
        guard !new.isEmpty else { return }
        lock.withLock {
            for cookie in new {
                cookies.removeAll { $0.name == cookie.name && $0.domain.lowercased() == cookie.domain.lowercased() && $0.path == cookie.path }
                if !Self.isExpired(cookie) { cookies.append(cookie) }
            }
        }
        save()
    }

    func clear() {
        lock.withLock { cookies.removeAll() }
        save()
    }

    func save() {
        guard let file else { return }
        let list = all.map(Self.dictionary(for:))
        guard let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func dictionary(for cookie: HTTPCookie) -> [String: Any] {
        var result: [String: Any] = ["name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
                                     "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly]
        if let expires = cookie.expiresDate { result["expires"] = expires.timeIntervalSince1970 }
        return result
    }

    private static func cookie(from dictionary: [String: Any]) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: dictionary["name"] as? String ?? "", .value: dictionary["value"] as? String ?? "",
            .domain: dictionary["domain"] as? String ?? "", .path: dictionary["path"] as? String ?? "/",
        ]
        if dictionary["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        if let expires = dictionary["expires"] as? Double { properties[.expires] = Date(timeIntervalSince1970: expires) }
        return HTTPCookie(properties: properties)
    }

    /// The `Cookie` header for `url` (nil when none match).
    func header(for url: URL) -> String? {
        let matching = cookies(for: url)
        return matching.isEmpty ? nil : matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

// MARK: Responses

/// How long each part of a request took (from URLSession's metrics).
struct HTTPTimings: Equatable, Sendable {
    var total: TimeInterval = 0
    var dns: TimeInterval?
    var connect: TimeInterval?
    var tls: TimeInterval?
    var request: TimeInterval?
    /// Request sent to first response byte.
    var waiting: TimeInterval?
    var download: TimeInterval?
    /// Start to the first response byte.
    var timeToFirstByte: TimeInterval?
    /// "h2", "http/1.1".
    var protocolName: String?
    var remoteAddress: String?
    var reusedConnection = false
    var redirects = 0
}

/// A cookie a response set, as shown in its Cookies tab.
struct HTTPCookieInfo: Equatable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
}

struct HTTPResponse: Equatable, Sendable {
    var statusCode: Int
    var headers: [HTTPHeader]
    /// Where it ended up (after redirects).
    var url: URL
    /// The body, or its first part when it was written to `bodyFile`.
    var body: Data
    /// The whole body, when it was too large to keep in memory.
    var bodyFile: URL?
    var bodySize: Int
    var timings = HTTPTimings()
    var cookies: [HTTPCookieInfo] = []

    var reason: String { HTTPResponse.reasonPhrase(statusCode) }
    var contentType: String? { headers.value(for: "Content-Type") }
    var isBodyComplete: Bool { bodyFile == nil }

    /// The whole body (read from the file when it's there).
    func fullBody() -> Data {
        guard let bodyFile else { return body }
        return (try? Data(contentsOf: bodyFile)) ?? body
    }

    static func reasonPhrase(_ code: Int) -> String {
        let known: [Int: String] = [
            100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
            204: "No Content", 205: "Reset Content", 206: "Partial Content", 300: "Multiple Choices", 301: "Moved Permanently",
            302: "Found", 303: "See Other", 304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect",
            400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict", 410: "Gone",
            411: "Length Required", 412: "Precondition Failed", 413: "Payload Too Large", 414: "URI Too Long",
            415: "Unsupported Media Type", 418: "I'm a Teapot", 422: "Unprocessable Content", 425: "Too Early",
            426: "Upgrade Required", 428: "Precondition Required", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
            451: "Unavailable For Legal Reasons", 500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
            503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported",
        ]
        return known[code] ?? HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }
}

enum HTTPSendError: LocalizedError, Equatable {
    case cancelled
    case timedOut(TimeInterval)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "The request was cancelled."
        case .timedOut(let seconds): "The request timed out after \(Int(seconds)) s without an answer."
        case .failed(let message): message
        }
    }
}

struct HTTPSendOptions: Sendable {
    var timeout: TimeInterval = 30
    var followRedirects = true
    var allowSelfSignedLocalhost = false
    /// Bodies past this many bytes go to a temporary file.
    var inMemoryLimit = HTTPClientSettings.inMemoryBodyLimit
    /// How much of a body written to a file is also kept to show.
    var previewLength = 256 * 1024
}

/// Sends one request with its own ephemeral session: cookies from (and into) the jar, redirects
/// followed or not, self-signed localhost certificates if allowed, the body to a file past the
/// limit, and the timings. Cancelling the calling task cancels the request.
final class HTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: HTTPPreparedRequest
    private let options: HTTPSendOptions
    private let jar: HTTPCookieJar?
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var task: URLSessionDataTask?
    private var isCancelled = false
    private var buffer = Data()
    private var size = 0
    private var spillURL: URL?
    private var spillHandle: FileHandle?
    private var metrics: URLSessionTaskMetrics?
    private var redirects = 0
    private var setCookies: [HTTPCookieInfo] = []

    init(request: HTTPPreparedRequest, options: HTTPSendOptions, jar: HTTPCookieJar?) {
        self.request = request
        self.options = options
        self.jar = request.useCookieJar ? jar : nil
    }

    static func send(_ request: HTTPPreparedRequest, options: HTTPSendOptions, jar: HTTPCookieJar?) async throws -> HTTPResponse {
        try await HTTPTransfer(request: request, options: options, jar: jar).run()
    }

    func run() async throws -> HTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    /// The URLRequest sent: the prepared headers, and the jar's cookies added to any `Cookie`.
    static func urlRequest(for request: HTTPPreparedRequest, timeout: TimeInterval, jar: HTTPCookieJar?) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for header in request.headers { urlRequest.addValue(header.value, forHTTPHeaderField: header.name) }
        if let jarCookies = jar?.header(for: request.url) {
            let own = urlRequest.value(forHTTPHeaderField: "Cookie")
            urlRequest.setValue(own.map { $0 + "; " + jarCookies } ?? jarCookies, forHTTPHeaderField: "Cookie")
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    private func start(_ continuation: CheckedContinuation<HTTPResponse, Error>) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = options.timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: Self.urlRequest(for: request, timeout: options.timeout, jar: jar))
        let cancelled = lock.withLock {
            self.continuation = continuation
            self.task = task
            return isCancelled
        }
        if cancelled {
            finish(.failure(HTTPSendError.cancelled))
            session.invalidateAndCancel()
            return
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }

    private func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        try? spillHandle?.close()
        spillHandle = nil
        if case .failure = result, let spillURL { try? FileManager.default.removeItem(at: spillURL) }
        continuation?.resume(with: result)
    }

    private static func headers(of response: HTTPURLResponse) -> [HTTPHeader] {
        response.allHeaderFields.compactMap { key, value in
            guard let name = key as? String else { return nil }
            return HTTPHeader(name: name, value: "\(value)")
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The cookies a response sets, kept in the jar.
    private func keepCookies(from response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String { fields[key] = "\(value)" }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty else { return }
        setCookies += cookies.map {
            HTTPCookieInfo(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate,
                           isSecure: $0.isSecure, isHTTPOnly: $0.isHTTPOnly)
        }
        jar?.store(cookies)
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        keepCookies(from: response)
        guard options.followRedirects, request.followRedirects else { completionHandler(nil); return }
        redirects += 1
        var next = newRequest
        if let url = next.url, let jar {
            // The jar's cookies for the new address, instead of the ones for the old.
            let own = request.headers.value(for: "Cookie")
            let jarCookies = jar.header(for: url)
            let combined = [own, jarCookies].compactMap { $0 }.joined(separator: "; ")
            next.setValue(combined.isEmpty ? nil : combined, forHTTPHeaderField: "Cookie")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, options.allowSelfSignedLocalhost,
           ["localhost", "127.0.0.1", "::1", "[::1]"].contains(space.host.lowercased()), let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        size += data.count
        if let spillHandle {
            try? spillHandle.write(contentsOf: data)
            if buffer.count < options.previewLength { buffer.append(data.prefix(options.previewLength - buffer.count)) }
            return
        }
        buffer.append(data)
        guard buffer.count > options.inMemoryLimit else { return }
        // Too large to keep: the rest goes to a temporary file, with what came so far.
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-http-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: url.path, contents: buffer)
        spillURL = url
        spillHandle = try? FileHandle(forWritingTo: url)
        _ = try? spillHandle?.seekToEnd()
        buffer = buffer.prefix(options.previewLength)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let urlError = error as? URLError
            if urlError?.code == .cancelled || lock.withLock({ isCancelled }) {
                finish(.failure(HTTPSendError.cancelled))
            } else if urlError?.code == .timedOut {
                finish(.failure(HTTPSendError.timedOut(options.timeout)))
            } else {
                finish(.failure(HTTPSendError.failed(error.localizedDescription)))
            }
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            finish(.failure(HTTPSendError.failed("The server's answer isn't an HTTP response.")))
            return
        }
        keepCookies(from: response)
        try? spillHandle?.close()
        spillHandle = nil
        let result = HTTPResponse(statusCode: response.statusCode, headers: Self.headers(of: response),
                                  url: response.url ?? request.url, body: buffer, bodyFile: spillURL, bodySize: size,
                                  timings: Self.timings(metrics, redirects: redirects), cookies: setCookies)
        finish(.success(result))
    }

    static func timings(_ metrics: URLSessionTaskMetrics?, redirects: Int) -> HTTPTimings {
        var timings = HTTPTimings(redirects: redirects)
        guard let metrics else { return timings }
        timings.total = metrics.taskInterval.duration
        func span(_ start: Date?, _ end: Date?) -> TimeInterval? {
            guard let start, let end, end >= start else { return nil }
            return end.timeIntervalSince(start)
        }
        guard let last = metrics.transactionMetrics.last else { return timings }
        timings.dns = span(last.domainLookupStartDate, last.domainLookupEndDate)
        timings.tls = span(last.secureConnectionStartDate, last.secureConnectionEndDate)
        timings.connect = span(last.connectStartDate, last.secureConnectionStartDate ?? last.connectEndDate)
        timings.request = span(last.requestStartDate, last.requestEndDate)
        timings.waiting = span(last.requestEndDate, last.responseStartDate)
        timings.download = span(last.responseStartDate, last.responseEndDate)
        timings.timeToFirstByte = span(metrics.transactionMetrics.first?.fetchStartDate ?? metrics.taskInterval.start, last.responseStartDate)
        timings.protocolName = last.networkProtocolName
        timings.remoteAddress = last.remoteAddress.map { address in last.remotePort.map { "\(address):\($0)" } ?? address }
        timings.reusedConnection = last.isReusedConnection
        return timings
    }
}
