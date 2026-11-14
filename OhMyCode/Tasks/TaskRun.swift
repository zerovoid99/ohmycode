import Foundation
import Observation

/// One run of a task: its process, output and the problems found in it.
@MainActor
@Observable
final class TaskRun: Identifiable {
    enum State: Equatable {
        case running
        case succeeded
        case failed(Int32)
        case terminated
        case couldNotStart(String)

        var isRunning: Bool { self == .running }
    }

    struct Line: Identifiable, Equatable {
        let id: Int
        var text: String
        /// Index into `problems` when the line reports one.
        var problem: Int?
    }

    let id = UUID()
    let task: TaskDefinition
    private(set) var state = State.running
    private(set) var lines: [Line] = []
    private(set) var problems: [ProblemMatcher.Problem] = []
    let started = Date()
    private(set) var ended: Date?
    /// Called with every problem list change (the new full list).
    @ObservationIgnored var onProblems: (([ProblemMatcher.Problem]) -> Void)?
    @ObservationIgnored var onEnd: ((State) -> Void)?

    static let maxLines = 20_000
    @ObservationIgnored private var nextLineID = 0
    @ObservationIgnored private var partial = ""
    @ObservationIgnored private var matcher: ProblemMatcher
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var wasTerminated = false
    @ObservationIgnored private var endWaiters: [CheckedContinuation<Void, Never>] = []

    /// `task` with its variables filled in.
    init(task: TaskDefinition) {
        self.task = task
        matcher = ProblemMatcher(directory: URL(filePath: task.cwd ?? FileManager.default.currentDirectoryPath))
    }

    var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }

    func start(environment: [String: String]) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", task.command]
        if let cwd = task.cwd { process.currentDirectoryURL = URL(filePath: cwd) }
        var environment = environment
        environment.merge(task.env ?? [:]) { $1 }
        environment["TERM"] = "dumb"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        append("> \(task.command)\n", isEcho: true)
        do {
            try process.run()
        } catch {
            finish(.couldNotStart(error.localizedDescription))
            return
        }
        self.process = process
        let handle = pipe.fileHandleForReading
        // Read until every writer closes the pipe, then wait for the exit: the main queue gets
        // the output before the result.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(text) } }
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.flushPartial()
                    self.finish(self.wasTerminated ? .terminated : status == 0 ? .succeeded : .failed(status))
                }
            }
        }
    }

    /// Stops the command and everything it started.
    func terminate() {
        guard state.isRunning, let process, process.isRunning else { return }
        wasTerminated = true
        let pids = Self.descendants(of: process.processIdentifier) + [process.processIdentifier]
        for pid in pids { kill(pid, SIGTERM) }
        // Whatever ignores SIGTERM goes after a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// Returns once the run has ended.
    func waitUntilEnded() async {
        guard state.isRunning else { return }
        await withCheckedContinuation { endWaiters.append($0) }
    }

    func clearOutput() {
        lines.removeAll()
    }

    private func finish(_ state: State) {
        guard self.state.isRunning else { return }
        self.state = state
        ended = Date()
        let seconds = String(format: "%.1f", duration)
        switch state {
        case .succeeded: append("\n✓ Finished in \(seconds)s\n", isEcho: true)
        case .failed(let code): append("\n✗ Failed with exit code \(code) after \(seconds)s\n", isEcho: true)
        case .terminated: append("\n■ Terminated\n", isEcho: true)
        case .couldNotStart(let message): append("Couldn't start: \(message)\n", isEcho: true)
        case .running: break
        }
        process = nil
        onEnd?(state)
        let waiters = endWaiters
        endWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func append(_ text: String, isEcho: Bool = false) {
        var text = partial + text.replacingOccurrences(of: "\r\n", with: "\n")
        partial = ""
        if !text.hasSuffix("\n") {
            // Keep the unfinished last line until the rest of it arrives.
            if let newline = text.lastIndex(of: "\n") {
                partial = String(text[text.index(after: newline)...])
                text = String(text[...newline])
            } else {
                partial = text
                return
            }
        }
        var found = false
        for raw in text.dropLast().split(separator: "\n", omittingEmptySubsequences: false) {
            // A carriage return redraws the line (progress bars): keep what's left at the end.
            let display = ProblemMatcher.stripEscapes(String(raw.split(separator: "\r", omittingEmptySubsequences: false).last ?? ""))
            var problemIndex: Int?
            if !isEcho, task.matchesProblems, let problem = matcher.match(display) {
                if let existing = problems.firstIndex(of: problem) {
                    problemIndex = existing
                } else {
                    problems.append(problem)
                    problemIndex = problems.count - 1
                    found = true
                }
            }
            lines.append(Line(id: nextLineID, text: display, problem: problemIndex))
            nextLineID += 1
        }
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        if found { onProblems?(problems) }
    }

    private func flushPartial() {
        if !partial.isEmpty { append("\n") }
    }

    /// The processes started (directly or not) by `pid`.
    nonisolated static func descendants(of pid: pid_t) -> [pid_t] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var parents: [pid_t: [pid_t]] = [:]
        for candidate in pids.prefix(Int(max(count, 0))) where candidate > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(candidate, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            parents[pid_t(info.pbi_ppid), default: []].append(candidate)
        }
        var result: [pid_t] = []
        var queue = [pid]
        while let next = queue.popLast() {
            for child in parents[next] ?? [] where !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }
}
