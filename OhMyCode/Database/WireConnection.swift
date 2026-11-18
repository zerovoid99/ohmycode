import Foundation
import Network
import Security

/// What a server connection does before TLS: Postgres asks with an SSLRequest and the server
/// answers S or N; MySQL's server greets first and the client asks with a short packet. Both
/// switch to TLS mid-connection, which Network.framework does with a framer under the TLS it
/// adds once the server agrees (`prependApplicationProtocol`).
final class WireNegotiation: @unchecked Sendable {
    enum Server { case postgres, mysql }

    let server: Server
    let mode: DatabaseSSLMode
    /// TLS to add when the server agrees (nil: never).
    let tls: NWProtocolTLS.Options?
    /// MySQL: the SSL request packet (header included) for the server's greeting, or nil when
    /// the server can't do TLS.
    let mysqlSSLRequest: (@Sendable (Data) -> Data?)?

    private let lock = NSLock()
    private var _greeting: Data?
    private var _usesTLS = false
    private var _failure: String?

    init(server: Server, mode: DatabaseSSLMode, tls: NWProtocolTLS.Options?, mysqlSSLRequest: (@Sendable (Data) -> Data?)? = nil) {
        self.server = server
        self.mode = mode
        self.tls = tls
        self.mysqlSSLRequest = mysqlSSLRequest
    }

    /// MySQL: the greeting packet's payload, read before TLS.
    var greeting: Data? {
        get { lock.withLock { _greeting } }
        set { lock.withLock { _greeting = newValue } }
    }

    var usesTLS: Bool {
        get { lock.withLock { _usesTLS } }
        set { lock.withLock { _usesTLS = newValue } }
    }

    /// Why it gave up (shown instead of the connection's own error).
    var failure: String? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
}

/// The framer under TLS that does the plain-text part of the handshake, then steps aside.
final class WireNegotiationFramer: NWProtocolFramerImplementation {
    static let label = "omc-database-negotiation"
    static let definition = NWProtocolFramer.Definition(implementation: WireNegotiationFramer.self)
    static let optionKey = "negotiation"

    private var negotiation: WireNegotiation?
    /// MySQL: the greeting's length once its header is read.
    private var greetingLength: Int?

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        guard let negotiation = framer.options[Self.optionKey] as? WireNegotiation else { return .ready }
        self.negotiation = negotiation
        if negotiation.server == .postgres {
            // SSLRequest: length 8, code 1234 5679.
            var request = Data()
            request.appendInt32(8)
            request.appendInt32(80_877_103)
            framer.writeOutput(data: request)
        }
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard let negotiation else { return 0 }
        switch negotiation.server {
        case .postgres:
            var answer: UInt8?
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 1) { buffer, _ in
                guard let buffer, buffer.count >= 1 else { return 0 }
                answer = buffer[0]
                return 1
            }
            guard let answer else { return 1 }
            if answer == UInt8(ascii: "S"), let tls = negotiation.tls {
                startTLS(tls, framer: framer)
            } else if answer == UInt8(ascii: "N") {
                if negotiation.mode == .require || negotiation.mode == .verifyFull {
                    fail("The server doesn't accept SSL connections (SSL mode “\(negotiation.mode.rawValue)”).", framer: framer)
                } else {
                    finish(framer)
                }
            } else {
                fail("The server didn't answer the SSL request.", framer: framer)
            }
        case .mysql:
            if greetingLength == nil {
                var length: Int?
                _ = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buffer, _ in
                    guard let buffer, buffer.count >= 4 else { return 0 }
                    length = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16
                    return 4
                }
                guard let length else { return 4 }
                greetingLength = length
            }
            guard let length = greetingLength else { return 0 }
            var payload: Data?
            _ = framer.parseInput(minimumIncompleteLength: length, maximumLength: length) { buffer, _ in
                guard let buffer, buffer.count >= length else { return 0 }
                payload = Data(buffer.prefix(length))
                return length
            }
            guard let payload else { return length }
            negotiation.greeting = payload
            if payload.first == 0xFF || negotiation.tls == nil {
                finish(framer) // an error, or no TLS wanted: the driver goes on in plain text
            } else if let request = negotiation.mysqlSSLRequest?(payload), let tls = negotiation.tls {
                framer.writeOutput(data: request)
                startTLS(tls, framer: framer)
            } else if negotiation.mode == .require || negotiation.mode == .verifyFull {
                fail("The server doesn't support SSL connections (SSL mode “\(negotiation.mode.rawValue)”).", framer: framer)
            } else {
                finish(framer)
            }
        }
        return 0
    }

    private func startTLS(_ tls: NWProtocolTLS.Options, framer: NWProtocolFramer.Instance) {
        do {
            try framer.prependApplicationProtocol(options: tls)
            negotiation?.usesTLS = true
            finish(framer)
        } catch {
            fail("Couldn't start TLS: \(error.localizedDescription)", framer: framer)
        }
    }

    private func finish(_ framer: NWProtocolFramer.Instance) {
        framer.passThroughInput()
        framer.passThroughOutput()
        framer.markReady()
    }

    private func fail(_ message: String, framer: NWProtocolFramer.Instance) {
        negotiation?.failure = message
        framer.markFailed(error: NWError.posix(.EPROTO))
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

/// A TCP connection to a database server, read in exact amounts (`read(_:)`), with the
/// optional TLS negotiation underneath.
final class WireConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "omc.database.wire")
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var readIndex = 0
    let negotiation: WireNegotiation?
    let host: String
    let port: Int

    private init(connection: NWConnection, negotiation: WireNegotiation?, host: String, port: Int) {
        self.connection = connection
        self.negotiation = negotiation
        self.host = host
        self.port = port
    }

    var usesTLS: Bool { negotiation?.usesTLS ?? false }

    static func open(host: String, port: Int, negotiation: WireNegotiation?, timeout: TimeInterval = 15) async throws -> WireConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            throw DBError.connection("Port \(port) is out of range.")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(timeout)
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if let negotiation {
            let framer = NWProtocolFramer.Options(definition: WireNegotiationFramer.definition)
            framer[WireNegotiationFramer.optionKey] = negotiation
            parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let wire = WireConnection(connection: connection, negotiation: negotiation, host: host, port: port)
        try await wire.start(timeout: timeout)
        return wire
    }

    private func start(timeout: TimeInterval) async throws {
        let once = Once()
        let where_ = "\(host):\(port)"
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [weak self, negotiation] state in
                    switch state {
                    case .ready:
                        once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error):
                        once.run {
                            self?.connection.cancel()
                            continuation.resume(throwing: DBError.connection(negotiation?.failure ?? Self.describe(error, at: where_)))
                        }
                    case .cancelled:
                        once.run { continuation.resume(throwing: DBError.connection("Cancelled.")) }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    once.run {
                        self?.connection.cancel()
                        continuation.resume(throwing: DBError.connection("Timed out connecting to \(where_)."))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    static func describe(_ error: NWError, at place: String) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Connection refused: nothing is listening at \(place)."
            case .ETIMEDOUT: return "Timed out connecting to \(place)."
            case .EHOSTUNREACH, .ENETUNREACH: return "Can't reach \(place)."
            default: return "\(place): \(error.localizedDescription)"
            }
        case .dns: return "Couldn't find the host of \(place)."
        case .tls(let status):
            let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
            return "TLS with \(place) failed: \(text)"
        default: return "\(place): \(error.localizedDescription)"
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: DBError.connection("Lost the connection: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private var available: Int { lock.withLock { buffer.count - readIndex } }

    /// Exactly `count` bytes (waiting for them).
    func read(_ count: Int) async throws -> Data {
        while available < count { try await receiveMore() }
        return lock.withLock {
            let data = Data(buffer[readIndex..<readIndex + count])
            readIndex += count
            if readIndex > 1 << 16, readIndex * 2 > buffer.count {
                buffer.removeFirst(readIndex)
                readIndex = 0
            }
            return data
        }
    }

    private func receiveMore() async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { content, _, isComplete, error in
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if let error {
                    continuation.resume(throwing: DBError.connection("Lost the connection: \(error.localizedDescription)"))
                } else if isComplete {
                    continuation.resume(throwing: DBError.connection("The server closed the connection."))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
        lock.withLock { buffer.append(contentsOf: data) }
    }

    func close() {
        connection.cancel()
    }

    /// Runs its closure once (the first of ready, failure and the timeout wins).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }
}

// MARK: TLS

enum DatabaseTLS {
    /// TLS options for a mode (nil for disable): no check for prefer and require, the trusted
    /// roots (or the given PEM's certificates only) and the host name for verify-full.
    static func options(mode: DatabaseSSLMode, host: String, rootCertificate: String?) throws -> NWProtocolTLS.Options? {
        guard mode != .disable else { return nil }
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        let isAddress = IPv4Address(host) != nil || IPv6Address(host) != nil
        if !isAddress { sec_protocol_options_set_tls_server_name(security, host) }
        let queue = DispatchQueue(label: "omc.database.tls-verify")
        switch mode {
        case .disable:
            return nil
        case .prefer, .require:
            sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) }, queue)
        case .verifyFull:
            if let rootCertificate, !rootCertificate.isEmpty {
                let path = (rootCertificate as NSString).expandingTildeInPath
                guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
                    throw DBError.connection("Couldn't read the root certificate at \(path).")
                }
                let anchors = PEM.blocks(pem, label: "CERTIFICATE").compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
                guard !anchors.isEmpty else { throw DBError.connection("No certificate in \(path).") }
                let box = AnchorBox(anchors: anchors, host: host)
                sec_protocol_options_set_verify_block(security, { _, trustRef, complete in
                    complete(box.evaluate(sec_trust_copy_ref(trustRef).takeRetainedValue()))
                }, queue)
            }
        }
        return options
    }

    private final class AnchorBox: @unchecked Sendable {
        let anchors: [SecCertificate]
        let host: String
        init(anchors: [SecCertificate], host: String) {
            self.anchors = anchors
            self.host = host
        }

        func evaluate(_ trust: SecTrust) -> Bool {
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            return SecTrustEvaluateWithError(trust, nil)
        }
    }
}

enum PEM {
    /// The DER of each `-----BEGIN <label>-----` block.
    static func blocks(_ text: String, label: String) -> [Data] {
        var result: [Data] = []
        var remaining = Substring(text)
        let begin = "-----BEGIN \(label)-----", end = "-----END \(label)-----"
        while let start = remaining.range(of: begin), let stop = remaining.range(of: end, range: start.upperBound..<remaining.endIndex) {
            let body = remaining[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: String(body)) { result.append(data) }
            remaining = remaining[stop.upperBound...]
        }
        return result
    }
}

// MARK: Bytes

extension Data {
    mutating func appendInt32(_ value: Int32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendInt16(_ value: Int16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(0)
    }

    mutating func appendLE(_ value: UInt64, bytes: Int) {
        for i in 0..<bytes { append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))) }
    }
}

/// Reads values out of a message's bytes in order.
struct ByteReader {
    let data: [UInt8]
    var index = 0

    init(_ data: Data) { self.data = Array(data) }
    init(bytes: [UInt8]) { self.data = bytes }

    var isAtEnd: Bool { index >= data.count }
    var remaining: Int { data.count - index }

    mutating func byte() throws -> UInt8 {
        guard index < data.count else { throw DBError.connection("A message from the server was cut short.") }
        defer { index += 1 }
        return data[index]
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= data.count - index else { throw DBError.connection("A message from the server was cut short.") }
        defer { index += count }
        return Array(data[index..<index + count])
    }

    mutating func int32() throws -> Int32 {
        let b = try bytes(4)
        return Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }

    mutating func int16() throws -> Int16 {
        let b = try bytes(2)
        return Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
    }

    /// Little-endian (MySQL).
    mutating func uintLE(_ count: Int) throws -> UInt64 {
        let b = try bytes(count)
        var value: UInt64 = 0
        for (i, byte) in b.enumerated() { value |= UInt64(byte) << (8 * UInt64(i)) }
        return value
    }

    /// Up to a NUL (consumed); the rest when there's none.
    mutating func cString() -> String {
        let start = index
        while index < data.count, data[index] != 0 { index += 1 }
        let text = String(decoding: data[start..<index], as: UTF8.self)
        if index < data.count { index += 1 }
        return text
    }

    mutating func rest() -> [UInt8] {
        defer { index = data.count }
        return Array(data[min(index, data.count)...])
    }

    // MySQL's length-encoded integers and strings.

    /// nil for the 0xFB "NULL" marker.
    mutating func lengthEncodedInt() throws -> UInt64? {
        let first = try byte()
        switch first {
        case 0xFB: return nil
        case 0xFC: return try uintLE(2)
        case 0xFD: return try uintLE(3)
        case 0xFE: return try uintLE(8)
        default: return UInt64(first)
        }
    }

    mutating func lengthEncodedBytes() throws -> [UInt8]? {
        guard let length = try lengthEncodedInt() else { return nil }
        guard let size = Int(exactly: length) else { throw DBError.connection("A message from the server was cut short.") }
        return try bytes(size)
    }

    mutating func lengthEncodedString() throws -> String {
        try lengthEncodedBytes().map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
