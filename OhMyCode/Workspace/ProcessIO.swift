import Foundation

/// Reading a child process's output and waiting for it on the calling thread, with `poll` and
/// `waitid`: no extra dispatch threads, and no reliance on `Process` noticing the exit (which
/// needs a free dispatch thread; with many commands at once there may be none, and every
/// `waitUntilExit` would hang).
enum ProcessIO {
    /// What `exitStatus` says when `Process` already reaped the child: its status is
    /// `Process.terminationStatus` then.
    static let reapedElsewhere = Int32.min

    /// The exit status of a child that has exited, nil while it runs. The child is left for
    /// `Process` to reap.
    static func exitStatus(of pid: pid_t, wait: Bool = false) -> Int32? {
        var info = siginfo_t()
        let options = WEXITED | WNOWAIT | (wait ? 0 : WNOHANG)
        while true {
            let result = waitid(P_PID, id_t(pid), &info, options)
            if result == 0 { break }
            if errno == EINTR { continue }
            return errno == ECHILD ? reapedElsewhere : nil
        }
        guard info.si_pid == pid else { return nil }
        return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
    }

    /// Reads `descriptors` (pipes the process writes) until the process has exited and what it
    /// wrote is read (or every pipe is closed and it exits). Not until the pipes close: something
    /// it started may live on with them. `onData(index, data)` gets each chunk. Returns the exit status.
    @discardableResult
    static func collect(pid: pid_t, descriptors: [Int32], timeout: Duration? = nil, onData: (Int, Data) -> Void) -> Int32 {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        var killed = false
        var open = descriptors.enumerated().map { (index: $0.offset, fd: $0.element) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var exited = false
        while !open.isEmpty {
            var fds = open.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            // Wake up for output, or every 50 ms to see whether the command exited.
            let ready = poll(&fds, nfds_t(fds.count), 50)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            var readSomething = false
            var closed: [Int] = []
            for (slot, entry) in fds.enumerated() where entry.revents != 0 {
                let count = read(entry.fd, &buffer, buffer.count)
                if count > 0 {
                    onData(open[slot].index, Data(buffer[0..<count]))
                    readSomething = true
                } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                    closed.append(slot)
                }
            }
            for slot in closed.reversed() { open.remove(at: slot) }
            if let deadline, !killed, ContinuousClock.now > deadline {
                killed = true
                kill(pid, SIGKILL) // took too long
            }
            if readSomething { continue }
            if exited { break } // exited, and what it wrote is read
            if exitStatus(of: pid) != nil { exited = true } // one more pass for the last output
        }
        return exitStatus(of: pid, wait: true) ?? reapedElsewhere
    }

    /// The status `Process` got when it reaped the child first (a signal as 128 + its number,
    /// as `exitStatus` gives it).
    static func statusFromProcess(_ process: Process) -> Int32 {
        process.waitUntilExit() // it has the status already: returns at once
        return process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    }

    /// Runs `process` (pipes already set) to the end on this thread: its output and error, and status.
    static func run(_ process: Process, output: Pipe, error: Pipe?, timeout: Duration? = nil) throws -> (output: Data, error: Data, status: Int32) {
        try process.run()
        var data = Data(), errorData = Data()
        let descriptors = [output.fileHandleForReading.fileDescriptor] + (error.map { [$0.fileHandleForReading.fileDescriptor] } ?? [])
        var status = collect(pid: process.processIdentifier, descriptors: descriptors, timeout: timeout) { index, chunk in
            if index == 0 { data.append(chunk) } else { errorData.append(chunk) }
        }
        if status == reapedElsewhere { status = statusFromProcess(process) }
        return (data, errorData, status)
    }
}
