import Darwin
import Foundation

/// A child process attached to a pseudo-terminal. Output is read on a background queue and
/// delivered to the main thread in coalesced chunks: one main-thread hop per burst instead of
/// one per `read`, so `cat bigfile` doesn't flood the main queue.
final class PTYProcess: @unchecked Sendable {
    // @unchecked Sendable: `pending`/`flushScheduled` are only touched on `readQueue`;
    // `onOutput`/`onExit` only on the main thread; the fd and pid are immutable after init.
    let pid: pid_t
    private let masterFD: Int32
    private let readQueue = DispatchQueue(label: "omc.pty.read", qos: .userInteractive)
    private let writeQueue = DispatchQueue(label: "omc.pty.write", qos: .userInteractive)
    private var readSource: DispatchSourceRead?
    private var pending = Data()
    private var flushScheduled = false
    private var closed = false

    @MainActor var onOutput: ((Data) -> Void)?
    @MainActor var onExit: ((Int32) -> Void)?

    struct Size {
        var columns: UInt16
        var rows: UInt16
        var cellWidth: UInt16 = 0
        var cellHeight: UInt16 = 0
    }

    enum SpawnError: LocalizedError {
        case forkFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .forkFailed(let code): "Could not start the shell: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Starts `executable` with `arguments` (argv[0] included) in `directory`.
    init(executable: String, arguments: [String], environment: [String: String],
         directory: String, size: Size) throws {
        // Everything the child needs is prepared before fork: after fork only
        // async-signal-safe calls (chdir, execve, _exit) are made.
        let argv = Self.cStringArray(arguments)
        let envp = Self.cStringArray(environment.map { "\($0.key)=\($0.value)" })
        let path = strdup(executable)!
        let cwd = strdup(directory)!
        defer {
            Self.freeCStringArray(argv)
            Self.freeCStringArray(envp)
            free(path)
            free(cwd)
        }

        var windowSize = winsize(ws_row: size.rows, ws_col: size.columns,
                                 ws_xpixel: size.columns * size.cellWidth, ws_ypixel: size.rows * size.cellHeight)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &windowSize)
        if pid < 0 { throw SpawnError.forkFailed(errno) }
        if pid == 0 {
            _ = chdir(cwd)
            execve(path, argv, envp)
            _exit(127)
        }

        self.pid = pid
        self.masterFD = master
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        startReading()
    }

    deinit {
        terminate()
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [masterFD] in
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(masterFD, buffer.baseAddress! + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && (errno == EAGAIN || errno == EINTR) {
                        usleep(1000) // pty buffer full (large paste): wait for the child to drain it
                    } else {
                        return
                    }
                }
            }
        }
    }

    func resize(_ size: Size) {
        var windowSize = winsize(ws_row: size.rows, ws_col: size.columns,
                                 ws_xpixel: size.columns * size.cellWidth, ws_ypixel: size.rows * size.cellHeight)
        _ = ioctl(masterFD, TIOCSWINSZ, &windowSize)
    }

    /// Hangs up the child (as closing a terminal window does) and releases the pty.
    func terminate() {
        readQueue.sync {
            guard !closed else { return }
            closed = true
            readSource?.cancel()
            readSource = nil
            kill(pid, SIGHUP)
        }
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [masterFD] in close(masterFD) }
        readSource = source
        source.resume()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                pending.append(buffer, count: count)
                continue
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { break }
            // EOF or EIO: the child exited and the slave side closed.
            processDidExit()
            break
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !pending.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let chunk = self.readQueue.sync { () -> Data in
                self.flushScheduled = false
                defer { self.pending.removeAll(keepingCapacity: true) }
                return self.pending
            }
            MainActor.assumeIsolated { self.onOutput?(chunk) }
        }
    }

    private func processDidExit() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        let pid = pid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            DispatchQueue.main.async {
                // Deliver after any output still queued for the main thread.
                MainActor.assumeIsolated { self?.onExit?(code) }
            }
        }
    }

    private static func cStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (i, string) in strings.enumerated() { array[i] = strdup(string) }
        array[strings.count] = nil
        return array
    }

    private static func freeCStringArray(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var i = 0
        while let pointer = array[i] { free(pointer); i += 1 }
        array.deallocate()
    }
}
