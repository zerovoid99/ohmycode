import Foundation

/// A language server process speaking JSON-RPC over stdio with `Content-Length` framing.
/// Bytes are read on a background queue; each complete message body is delivered to the
/// main thread, where the client parses and routes it.
final class LanguageServerConnection: @unchecked Sendable {
    // @unchecked Sendable: `buffer` is only touched on the stdout handler's queue, writes are
    // serialized on `writeQueue`, `onMessage`/`onExit` are used on the main thread only.
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let writeQueue = DispatchQueue(label: "omc.lsp.write")
    private let readQueue = DispatchQueue(label: "omc.lsp.read")
    private var readSource: DispatchSourceRead?
    private var buffer = Data()

    @MainActor var onMessage: ((Data) -> Void)?
    @MainActor var onExit: ((Int32) -> Void)?

    init(command: [String], directory: URL, environment: [String: String]) throws {
        process.executableURL = URL(filePath: command[0])
        process.arguments = Array(command.dropFirst())
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
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
        let message = Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
        let handle = stdin.fileHandleForWriting
        writeQueue.async {
            try? handle.write(contentsOf: message)
        }
    }

    func terminate() {
        readQueue.sync {
            readSource?.cancel()
            readSource = nil
        }
        if process.isRunning { process.terminate() }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        var messages: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            guard let length = header.split(separator: "\r\n").lazy
                .compactMap({ line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }).first
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
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                for message in messages { self?.onMessage?(message) }
            }
        }
    }
}
