import Foundation
import Observation

/// A command an agent runs (ACP `terminal/create`): its output, kept to the last
/// `outputByteLimit` bytes, and how it ended. Shown in the conversation as it runs.
@MainActor
@Observable
final class AgentTerminal: Identifiable {
    struct ExitStatus: Equatable {
        let exitCode: Int32?
        let signal: String?
    }

    let id: String
    let commandLine: String
    private(set) var output = ""
    private(set) var truncated = false
    private(set) var exitStatus: ExitStatus?

    @ObservationIgnored private let process = Process()
    @ObservationIgnored private let pipe = Pipe()
    @ObservationIgnored private let byteLimit: Int?
    @ObservationIgnored private var waiters: [CheckedContinuation<ExitStatus, Never>] = []
    /// Bytes not yet decoded (a character split between two reads).
    @ObservationIgnored private var pending = Data()
    /// The output pipe reached its end; the process exited (with this status).
    @ObservationIgnored private var outputClosed = false
    @ObservationIgnored private var exited: ExitStatus?

    init(id: String, command: String, arguments: [String], environment: [String: String], directory: URL,
         byteLimit: Int?) throws {
        self.id = id
        self.byteLimit = byteLimit
        commandLine = ([command] + arguments).joined(separator: " ")
        // Through `env`, so a bare name is looked up on the PATH given.
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if data.isEmpty { self?.outputDidClose() } else { self?.append(data) }
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status: ExitStatus = process.terminationReason == .uncaughtSignal
                ? ExitStatus(exitCode: nil, signal: Self.signalName(process.terminationStatus))
                : ExitStatus(exitCode: process.terminationStatus, signal: nil)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processDidExit(status) } }
        }
        try process.run()
    }

    private func append(_ data: Data) {
        pending.append(data)
        // Up to the last complete character.
        var end = pending.endIndex
        while end > pending.startIndex, String(data: pending[pending.startIndex..<end], encoding: .utf8) == nil,
              pending.distance(from: end, to: pending.endIndex) < 4 {
            end = pending.index(before: end)
        }
        guard end > pending.startIndex else { return }
        output += String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
        pending.removeSubrange(pending.startIndex..<end)
        if let byteLimit, output.utf8.count > byteLimit {
            // The tail, cut at a character boundary.
            var cut = output.utf8.count - byteLimit
            var index = output.startIndex
            while cut > 0, index < output.endIndex {
                cut -= String(output[index]).utf8.count
                index = output.index(after: index)
            }
            output = String(output[index...])
            truncated = true
        }
    }

    private func outputDidClose() {
        outputClosed = true
        if let exited { finish(exited) }
    }

    /// Finished once its output is read to the end too, or shortly after it exits (something
    /// it started in the background may keep the pipe open).
    private func processDidExit(_ status: ExitStatus) {
        exited = status
        if outputClosed { return finish(status) }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.finish(status)
        }
    }

    private func finish(_ status: ExitStatus) {
        guard exitStatus == nil else { return }
        exitStatus = status
        for waiter in waiters { waiter.resume(returning: status) }
        waiters.removeAll()
    }

    func waitForExit() async -> ExitStatus {
        if let exitStatus { return exitStatus }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Stops the command and what it started: Process puts the command in a process group of
    /// its own, and the whole group gets SIGTERM, then SIGKILL if any of it is still there
    /// after a moment. (The group outlives the command while something it started runs.)
    func kill() {
        let group = process.processIdentifier
        guard group > 0, Darwin.kill(-group, SIGTERM) == 0 else {
            if process.isRunning { process.terminate() } // not a group of its own after all
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
            if Darwin.kill(-group, 0) == 0 { Darwin.kill(-group, SIGKILL) }
        }
    }

    /// How long a stopped command's group has to end before it's killed.
    nonisolated static let killGrace = 2.0

    /// Stops every one of these commands (the agent is stopped, or the app quits).
    static func terminateAll(_ terminals: some Sequence<AgentTerminal>) {
        for terminal in terminals { terminal.kill() }
    }

    var isRunning: Bool { exitStatus == nil }

    nonisolated private static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        case SIGINT: "SIGINT"
        case SIGHUP: "SIGHUP"
        case SIGSEGV: "SIGSEGV"
        case SIGABRT: "SIGABRT"
        default: "SIG\(number)"
        }
    }
}
