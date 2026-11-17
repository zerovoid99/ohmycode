import CryptoKit
import Foundation
import Network

/// A WebSocket server for local programs: it listens on 127.0.0.1 only, on a free port, and
/// upgrades a connection only when `authorize` accepts its request's headers; others get
/// `401` and are closed. Each message is one text frame.
///
/// The handshake and the framing (RFC 6455) are done here, over TCP: Network's WebSocket
/// protocol called its request handler, but upgraded the connection even when the handler
/// rejected it.
final class LocalWebSocketServer: @unchecked Sendable {
    // @unchecked Sendable: the listener and connections are used on `queue`; callbacks run on
    // the main thread.
    private let listener: NWListener
    private let queue = DispatchQueue(label: "omc.websocket")
    private let authorize: @Sendable ([(name: String, value: String)]) -> Bool
    private let subprotocols: [String]
    /// Connections not closed yet (handshake or upgraded), cut when the server stops.
    private var peers: [ObjectIdentifier: WebSocketPeer] = [:]
    private var isStopped = false

    @MainActor var onReady: ((UInt16) -> Void)?
    @MainActor var onFailure: ((String) -> Void)?
    /// A connection that passed the handshake.
    @MainActor var onConnect: ((WebSocketPeer) -> Void)?

    /// `authorize` gets the request's headers (names as sent) and runs off the main thread;
    /// `subprotocols`: the ones it speaks, picked when a client offers one.
    init(subprotocols: [String] = [], authorize: @escaping @Sendable ([(name: String, value: String)]) -> Bool) throws {
        self.authorize = authorize
        self.subprotocols = subprotocols
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let port = self?.listener.port?.rawValue ?? 0
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onReady?(port) } }
            case .failed(let error):
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onFailure?(error.localizedDescription) } }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.isStopped else { return connection.cancel() }
            let peer = WebSocketPeer(connection: connection, queue: self.queue, subprotocols: self.subprotocols,
                                     authorize: self.authorize, upgraded: { [weak self] peer in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onConnect?(peer) } }
            }, ended: { [weak self] peer in
                self?.peers[ObjectIdentifier(peer)] = nil
            })
            self.peers[ObjectIdentifier(peer)] = peer
            peer.start()
        }
    }

    func start() { listener.start(queue: queue) }

    /// Stops listening, and cuts every connection.
    func stop() {
        listener.cancel()
        queue.async {
            self.isStopped = true
            let peers = self.peers.values
            self.peers = [:]
            for peer in peers { peer.cancel() }
        }
    }
}

/// One connection to `LocalWebSocketServer`: the HTTP upgrade, then frames.
final class WebSocketPeer: @unchecked Sendable {
    // @unchecked Sendable: `buffer`, `fragments` and `phase` are only touched on `queue`;
    // the callbacks run on the main thread.
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let authorize: @Sendable ([(name: String, value: String)]) -> Bool
    private let upgraded: @Sendable (WebSocketPeer) -> Void
    private let ended: @Sendable (WebSocketPeer) -> Void
    private let subprotocols: [String]
    private var buffer = Data()
    private var phase = Phase.handshake
    /// A message arriving in several frames: its opcode and the payload so far.
    private var fragments: (opcode: UInt8, data: Data)?

    @MainActor var onMessage: ((Data) -> Void)?
    @MainActor var onClose: (() -> Void)?
    @MainActor private(set) var isOpen = true

    private enum Phase {
        case handshake, open
        /// A close frame went or came, or the request was refused: what else comes is dropped
        /// (it's never read as another request).
        case closing
    }

    /// Requests and messages bigger than these close the connection.
    private static let maxRequest = 16 * 1024
    private static let maxMessage = 64 * 1024 * 1024
    private static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    /// A connection that hasn't upgraded within this long is closed (tests: shorter).
    nonisolated(unsafe) static var handshakeTimeout: TimeInterval = 10

    fileprivate init(connection: NWConnection, queue: DispatchQueue, subprotocols: [String],
                     authorize: @escaping @Sendable ([(name: String, value: String)]) -> Bool,
                     upgraded: @escaping @Sendable (WebSocketPeer) -> Void,
                     ended: @escaping @Sendable (WebSocketPeer) -> Void) {
        self.connection = connection
        self.subprotocols = subprotocols
        self.queue = queue
        self.authorize = authorize
        self.upgraded = upgraded
        self.ended = ended
    }

    fileprivate func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.closed()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
            guard let self, self.phase == .handshake else { return }
            self.cancel()
        }
    }

    /// Cuts the connection at once (on `queue`).
    fileprivate func cancel() {
        phase = .closing
        connection.cancel()
    }

    private func receive() {
        // Strongly: the pending receive is what keeps the connection's peer alive (nothing else
        // holds it before the upgrade); it ends when the connection does.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.buffer.append(data)
                switch self.phase {
                case .handshake: self.readRequest()
                case .open: self.readFrames()
                case .closing: self.buffer.removeAll()
                }
            }
            if isComplete || error != nil { return self.connection.cancel() }
            self.receive()
        }
    }

    // MARK: Handshake

    private func readRequest() {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxRequest { connection.cancel() }
            return
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let headers: [(name: String, value: String)] = lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        func header(_ name: String) -> String? { headers.first { $0.name.lowercased() == name }?.value }
        guard requestLine.hasPrefix("GET "),
              header("upgrade")?.lowercased() == "websocket",
              header("connection")?.lowercased().contains("upgrade") == true,
              header("sec-websocket-version") == "13",
              let key = header("sec-websocket-key"), !key.isEmpty else {
            return refuse("400 Bad Request")
        }
        guard authorize(headers) else { return refuse("401 Unauthorized") }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + Self.guid).utf8))).base64EncodedString()
        var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n"
        // A client that asks for subprotocols gives up on a server that picks none (Claude Code
        // asks for "mcp").
        let offered = (header("sec-websocket-protocol") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let subprotocol = offered.first(where: subprotocols.contains) { response += "Sec-WebSocket-Protocol: \(subprotocol)\r\n" }
        response += "\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        phase = .open
        upgraded(self)
        if !buffer.isEmpty { readFrames() }
    }

    private func refuse(_ status: String) {
        phase = .closing
        buffer.removeAll()
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    // MARK: Frames

    private func readFrames() {
        while true {
            let bytes = [UInt8](buffer.prefix(14))
            guard bytes.count >= 2 else { return }
            let final = bytes[0] & 0x80 != 0, opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7F), header = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) << 8 | Int(bytes[3])
                header = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return }
                length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
                header = 10
            }
            // Clients mask every frame (RFC 6455 5.1); messages have a sane size.
            guard masked, length >= 0, length <= Self.maxMessage else { return close(code: 1002) }
            // Control frames (close, ping, pong) come whole, and short (RFC 6455 5.5).
            if opcode & 0x8 != 0, !final || length > 125 { return close(code: 1002) }
            guard buffer.count >= header + 4 + length else { return }
            let start = buffer.startIndex
            let mask = [UInt8](buffer[(start + header)..<(start + header + 4)])
            var payload = [UInt8](buffer[(start + header + 4)..<(start + header + 4 + length)])
            for index in payload.indices { payload[index] ^= mask[index % 4] }
            buffer.removeSubrange(start..<(start + header + 4 + length))
            handle(opcode: opcode, final: final, payload: Data(payload))
            if phase != .open { return }
        }
    }

    private func handle(opcode: UInt8, final: Bool, payload: Data) {
        switch opcode {
        case 0x1, 0x2: // text, binary
            // Not while another message is still arriving in pieces.
            guard fragments == nil else { return close(code: 1002) }
            if final { deliver(payload) } else { fragments = (opcode, payload) }
        case 0x0: // continuation
            guard var message = fragments else { return close(code: 1002) }
            message.data.append(payload)
            guard message.data.count <= Self.maxMessage else { return close(code: 1009) }
            if final { fragments = nil; deliver(message.data) } else { fragments = message }
        case 0x8: // close: answered, then closed
            sendFrame(opcode: 0x8, payload: payload.prefix(2))
            phase = .closing
            buffer.removeAll()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
        case 0x9: // ping
            sendFrame(opcode: 0xA, payload: payload)
        default: // pong, or unknown
            break
        }
    }

    private func deliver(_ message: Data) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onMessage?(message) } }
    }

    /// Sends a close frame, then (once it's sent) closes the connection.
    private func close(code: UInt16) {
        guard phase != .closing else { return }
        phase = .closing
        buffer.removeAll()
        sendFrame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)])) { [connection] in connection.cancel() }
    }

    private func sendFrame(opcode: UInt8, payload: Data, then sent: (@Sendable () -> Void)? = nil) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        } else {
            frame.append(127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) })
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in sent?() })
    }

    private func closed() {
        phase = .closing
        ended(self)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.isOpen else { return }
                self.isOpen = false
                self.onClose?()
            }
        }
    }

    /// Sends one text frame.
    func send(_ data: Data) {
        queue.async { self.sendFrame(opcode: 0x1, payload: data) }
    }

    func close() {
        queue.async { self.close(code: 1000) }
    }
}
