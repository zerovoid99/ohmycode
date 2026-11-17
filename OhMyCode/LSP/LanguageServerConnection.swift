import Foundation

/// A message from the server, parsed where it was read: off the main thread. (A big answer,
/// thousands of completion items or a long file's semantic tokens, takes tens of milliseconds
/// to parse.)
final class IncomingMessage: @unchecked Sendable {
    // @unchecked Sendable: made on the read queue, then only read (JSON objects are immutable).
    let object: [String: Any]
    /// `textDocument/publishDiagnostics`, already decoded.
    let diagnostics: (url: URL, list: [Diagnostic])?

    init?(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.object = object
        if object["method"] as? String == "textDocument/publishDiagnostics", object["id"] == nil,
           let params = object["params"] as? [String: Any], let uri = params["uri"] as? String, let url = URL(string: uri) {
            diagnostics = (url, (params["diagnostics"] as? [Any] ?? []).compactMap(Diagnostic.init(json:)))
        } else {
            diagnostics = nil
        }
    }
}

/// A process speaking JSON-RPC over stdio: a language server (`Content-Length` framing) or an
/// agent (the Agent Client Protocol: one message per line). Bytes are read on a background
/// queue; each complete message is delivered, in order, to the main thread: as its body
/// (`onMessage`), or with `parsesMessages` already parsed there (`onParsedMessage`).
final class LanguageServerConnection: @unchecked Sendable {
    enum Framing: Sendable { case contentLength, newlineDelimited }

    // @unchecked Sendable: `buffer` is only touched on the stdout handler's queue, writes are
    // serialized on `writeQueue`, `onMessage`/`onExit` are used on the main thread only.
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let writeQueue = DispatchQueue(label: "omc.lsp.write")
    private let readQueue = DispatchQueue(label: "omc.lsp.read")
    private var readSource: DispatchSourceRead?
    private var buffer = Data()

    private let parsesMessages: Bool
    private let framing: Framing
    private let stderr: Pipe?

    @MainActor var onMessage: ((Data) -> Void)?
    @MainActor var onParsedMessage: ((IncomingMessage) -> Void)?
    @MainActor var onExit: ((Int32) -> Void)?
    /// What the process writes to stderr (with `capturesStandardError`), as it comes.
    @MainActor var onStandardError: ((String) -> Void)?

    init(command: [String], directory: URL, environment: [String: String], parsesMessages: Bool = false,
         framing: Framing = .contentLength, capturesStandardError: Bool = false) throws {
        self.parsesMessages = parsesMessages
        self.framing = framing
        stderr = capturesStandardError ? Pipe() : nil
        process.executableURL = URL(filePath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = stdin
        // Writing to a process that exited fails (EPIPE) instead of killing the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardOutput = stdout
        if let stderr {
            process.standardError = stderr
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onStandardError?(text) } }
            }
        } else {
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onExit?(status) } }
        }
        try process.run()
        startReading()
    }

    /// Reads with a dispatch source and non-blocking read(2), so "no data yet" (EAGAIN) is never
    /// mistaken for end of file. (FileHandle.availableData returns empty for both, and treating
    /// that as EOF silently stopped reading under load.)
    private func startReading() {
        let fd = stdout.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &chunk, chunk.count)
                if count > 0 {
                    self.receive(Data(chunk[0..<count]))
                } else if count == 0 {
                    self.readSource?.cancel() // EOF: the server closed its stdout
                    return
                } else {
                    return // EAGAIN/EINTR: wait for the next readiness event
                }
            }
        }
        readSource = source
        source.resume()
    }

    deinit { terminate() }

    var isRunning: Bool { process.isRunning }

    func send(_ body: Data) {
        send { body }
    }

    /// Sends what `body` makes on the write queue (a big message encoded off the main thread),
    /// in order with the other messages; nothing if it makes nothing.
    func send(_ body: @escaping @Sendable () -> Data?) {
        let handle = stdin.fileHandleForWriting
        let framing = framing
        writeQueue.async {
            guard let body = body() else { return }
            switch framing {
            case .contentLength:
                try? handle.write(contentsOf: Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
            case .newlineDelimited:
                // JSONSerialization escapes newlines inside strings: a message is one line.
                try? handle.write(contentsOf: body + Data([0x0A]))
            }
        }
    }

    func terminate() {
        readQueue.sync {
            readSource?.cancel()
            readSource = nil
        }
        stderr?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        var messages: [Data] = []
        if framing == .newlineDelimited {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                if line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) { messages.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            deliver(messages)
            return
        }
        deliver(Self.takeContentLengthMessages(from: &buffer))
    }

    /// The whole `Content-Length` framed messages at the start of `buffer`, removed from it (a
    /// partial one stays for more data).
    static func takeContentLengthMessages(from buffer: inout Data) -> [Data] {
        var messages: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            // A negative length is malformed too: it made the body's end come before its start (a trap).
            guard let length = header.split(separator: "\r\n").lazy
                .compactMap({ line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }).first, length >= 0
            else {
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound) // malformed header
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            messages.append(Data(buffer[bodyStart..<bodyEnd]))
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        }
        return messages
    }

    private func deliver(_ messages: [Data]) {
        guard !messages.isEmpty else { return }
        let parsed = parsesMessages ? messages.compactMap(IncomingMessage.init) : []
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                for message in parsed { self?.onParsedMessage?(message) }
                guard self?.parsesMessages == false else { return }
                for message in messages { self?.onMessage?(message) }
            }
        }
    }
}
