import Foundation
import Observation

/// One run of a program under the debugger (lldb-dap): its state while it runs or is stopped,
/// the stopped thread's frames and variables, and the console.
@MainActor
@Observable
final class DebugSession: Identifiable {
    enum State: Equatable {
        /// Running the pre-launch command (a build).
        case building
        case starting
        case running
        case stopped
        case terminated
    }

    struct ConsoleLine: Identifiable, Equatable {
        enum Kind: Equatable { case output, error, info, input, result }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    struct Thread: Identifiable, Equatable {
        let id: Int
        let name: String
    }

    struct Frame: Identifiable, Equatable {
        let id: Int
        let name: String
        let path: String?
        /// One-based.
        let line: Int
        let column: Int
    }

    struct Variable: Identifiable, Equatable {
        /// Unique among its siblings: the parent's reference and the name.
        let id: String
        let name: String
        let value: String
        let type: String?
        /// Non-zero when it has children (members, elements).
        let reference: Int
    }

    let id = UUID()
    let configuration: LaunchConfiguration
    private(set) var state: State = .starting
    /// Why it stopped ("breakpoint", "step", "pause", "exception", "entry").
    private(set) var stopReason: String?
    private(set) var threads: [Thread] = []
    private(set) var stoppedThreadID: Int?
    private(set) var frames: [Frame] = []
    private(set) var selectedFrameID: Int?
    /// The selected frame's scopes (Locals, Globals, Registers…), as variables with children.
    private(set) var scopes: [Variable] = []
    /// Children read so far, by reference.
    private(set) var children: [Int: [Variable]] = [:]
    private(set) var console: [ConsoleLine] = []
    private(set) var exitCode: Int?

    /// Shows where the program stopped (the workspace opens the file and marks the line).
    @ObservationIgnored var onStop: ((Frame?) -> Void)?
    /// Breakpoints to send, per file: (one-based line, condition, enabled).
    @ObservationIgnored var breakpoints: (() -> [String: [BreakpointStore.Breakpoint]])?
    /// What the debugger said about a file's breakpoints (lines it placed).
    @ObservationIgnored var onBreakpointsVerified: ((String, Set<Int>) -> Void)?
    @ObservationIgnored var onEnd: (() -> Void)?

    @ObservationIgnored private var client: DAPClient?
    @ObservationIgnored private var build: Process?
    @ObservationIgnored private let adapter: [String]
    @ObservationIgnored private let environment: [String: String]
    @ObservationIgnored private var initialized: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var didInitialize = false
    /// The next stop is ours (lldb-dap reports an interrupt as an "exception").
    @ObservationIgnored private var pauseRequested = false

    /// `adapter`: the debug adapter's command (lldb-dap through xcrun by default).
    init(configuration: LaunchConfiguration, adapter: [String] = ["/usr/bin/xcrun", "lldb-dap"], environment: [String: String]) {
        self.configuration = configuration
        self.adapter = adapter
        self.environment = environment
    }

    var isActive: Bool { state != .terminated }

    // MARK: Starting and stopping

    /// Builds (if configured), launches the program and runs it to the first breakpoint.
    func start() async throws {
        do {
            if let command = configuration.preLaunch {
                state = .building
                append(.info, "> \(command)")
                let status = try await runPreLaunch(command)
                guard state == .building else { return } // stopped meanwhile
                guard status == 0 else {
                    append(.error, "The pre-launch command failed (exit code \(status)).")
                    finish()
                    return
                }
            }
            state = .starting
            try await launch()
        } catch {
            append(.error, error.localizedDescription)
            finish()
            throw error
        }
    }

    private func launch() async throws {
        let cwd = URL(filePath: configuration.cwd ?? FileManager.default.currentDirectoryPath)
        let client = try DAPClient(command: adapter, directory: cwd, environment: environment)
        self.client = client
        client.onEvent = { [weak self] event, body in self?.handle(event, body) }
        client.onExit = { [weak self] _ in self?.finish() }

        try await client.request("initialize", .object([
            "clientID": .string("omc"), "clientName": .string("Oh My Code"), "adapterID": .string("lldb-dap"),
            "linesStartAt1": .bool(true), "columnsStartAt1": .bool(true), "pathFormat": .string("path"),
            "supportsVariableType": .bool(true), "supportsRunInTerminalRequest": .bool(false),
        ]))
        var arguments: [String: JSONValue] = [
            "program": .string(configuration.program),
            "args": .array((configuration.args ?? []).map(JSONValue.string)),
            "cwd": .string(cwd.path),
            "stopOnEntry": .bool(configuration.stopOnEntry ?? false),
        ]
        if let env = configuration.env, !env.isEmpty { arguments["env"] = .object(env.mapValues(JSONValue.string)) }
        // The launch answers once configuration is done: send it, then configure.
        let launched = Task { try await client.request("launch", .object(arguments)) }
        await waitForInitialized()
        for path in (breakpoints?() ?? [:]).keys { await sendBreakpoints(for: path) }
        _ = try? await client.request("setExceptionBreakpoints", .object(["filters": .array([])]))
        try await client.request("configurationDone")
        _ = try await launched.value
        if state == .starting { state = .running }
    }

    private func waitForInitialized() async {
        guard !didInitialize else { return }
        await withCheckedContinuation { initialized = $0 }
    }

    /// Ends the program (and the debugger).
    func stop() async {
        if state == .building { build?.terminate(); finish(); return }
        guard let client, !client.isClosed else { finish(); return }
        _ = try? await ExtensionHost.within(.seconds(2)) { @MainActor in
            try await client.request("disconnect", .object(["terminateDebuggee": .bool(true)]))
        }
        client.terminate()
        finish()
    }

    private func finish() {
        guard state != .terminated else { return }
        state = .terminated
        initialized?.resume()
        initialized = nil
        clearStop()
        client?.terminate()
        client = nil
        onEnd?()
    }

    // MARK: Running

    func resume() { step("continue") }
    func stepOver() { step("next") }
    func stepInto() { step("stepIn") }
    func stepOut() { step("stepOut") }

    func pause() {
        guard state == .running, let client else { return }
        pauseRequested = true
        let thread = threads.first?.id ?? 1
        Task { _ = try? await client.request("pause", .object(["threadId": .number(Double(thread))])) }
    }

    private func step(_ command: String) {
        guard state == .stopped, let client, let thread = stoppedThreadID else { return }
        state = .running
        clearStop()
        Task {
            do { try await client.request(command, .object(["threadId": .number(Double(thread))])) }
            catch { append(.error, error.localizedDescription) }
        }
    }

    private func clearStop() {
        frames = []
        scopes = []
        children = [:]
        selectedFrameID = nil
        stopReason = nil
        onStop?(nil)
    }

    // MARK: Breakpoints

    /// Sends a file's breakpoints (all of them, as DAP wants) and notes which were placed.
    func sendBreakpoints(for path: String) async {
        guard let client, didInitialize else { return }
        let list = (breakpoints?()[path] ?? []).filter(\.isEnabled)
        let body = try? await client.request("setBreakpoints", .object([
            "source": .object(["path": .string(path), "name": .string((path as NSString).lastPathComponent)]),
            "breakpoints": .array(list.map { breakpoint in
                var entry: [String: JSONValue] = ["line": .number(Double(breakpoint.line))]
                if let condition = breakpoint.condition { entry["condition"] = .string(condition) }
                return .object(entry)
            }),
            "sourceModified": .bool(false),
        ]))
        let placed = (body?["breakpoints"]?.array ?? []).enumerated().compactMap { index, entry -> Int? in
            guard entry["verified"]?.bool == true else { return nil }
            return entry["line"]?.number.map(Int.init) ?? (index < list.count ? list[index].line : nil)
        }
        onBreakpointsVerified?(path, Set(placed))
    }

    // MARK: Inspecting

    /// Selects a frame of the stopped thread: its variables load, its line shows.
    func select(_ frame: Frame) async {
        guard let client, state == .stopped else { return }
        selectedFrameID = frame.id
        children = [:]
        onStop?(frame)
        let body = try? await client.request("scopes", .object(["frameId": .number(Double(frame.id))]))
        guard selectedFrameID == frame.id else { return }
        scopes = (body?["scopes"]?.array ?? []).map { scope in
            let name = scope["name"]?.string ?? "Scope"
            return Variable(id: "scope/\(name)", name: name, value: "", type: nil, reference: Int(scope["variablesReference"]?.number ?? 0))
        }
        // Locals (the first scope) open right away.
        if let first = scopes.first { await loadChildren(of: first.reference) }
    }

    /// Reads a variable's (or scope's) children once.
    func loadChildren(of reference: Int) async {
        guard reference > 0, children[reference] == nil, let client else { return }
        let body = try? await client.request("variables", .object(["variablesReference": .number(Double(reference))]))
        children[reference] = (body?["variables"]?.array ?? []).map { variable in
            let name = variable["name"]?.string ?? ""
            return Variable(id: "\(reference)/\(name)", name: name, value: variable["value"]?.string ?? "",
                            type: variable["type"]?.string, reference: Int(variable["variablesReference"]?.number ?? 0))
        }
    }

    /// Evaluates an expression in the selected frame (the debug console), or runs a debugger
    /// command after a backtick; the result is also printed there.
    @discardableResult
    func evaluate(_ expression: String) async -> String? {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client else { return nil }
        append(.input, text)
        // An expression shows just its value; "`command" runs a debugger command (`bt`, …).
        var arguments: [String: JSONValue] = ["expression": .string(text),
                                              "context": .string(text.hasPrefix("`") ? "repl" : "watch")]
        if let frame = selectedFrameID { arguments["frameId"] = .number(Double(frame)) }
        do {
            let body = try await client.request("evaluate", .object(arguments))
            let result = body["result"]?.string ?? ""
            append(.result, result)
            return result
        } catch {
            append(.error, error.localizedDescription)
            return nil
        }
    }

    func clearConsole() { console = [] }

    // MARK: Events

    private func handle(_ event: String, _ body: JSONValue) {
        switch event {
        case "initialized":
            didInitialize = true
            initialized?.resume()
            initialized = nil
        case "stopped":
            state = .stopped
            stopReason = pauseRequested ? "pause" : body["reason"]?.string
            pauseRequested = false
            stoppedThreadID = body["threadId"]?.number.map(Int.init) ?? stoppedThreadID
            Task { await loadStop() }
        case "continued":
            if state == .stopped { state = .running; clearStop() }
        case "output":
            guard let text = body["output"]?.string, !text.isEmpty else { return }
            let category = body["category"]?.string
            // lldb-dap's own chatter ("console") is kept short: the program's output matters.
            append(category == "stderr" ? .error : category == "console" || category == "important" ? .info : .output, text)
        case "exited":
            exitCode = body["exitCode"]?.number.map(Int.init)
            append(.info, "The program exited with code \(exitCode ?? 0).")
        case "terminated":
            Task { await stop() }
        case "breakpoint":
            break // breakpoints are sent again on changes; their state comes back then
        default:
            break
        }
    }

    /// After a stop: the threads, the stopped thread's frames, the top frame's variables.
    private func loadStop() async {
        guard let client, let thread = stoppedThreadID else { return }
        if let body = try? await client.request("threads") {
            threads = (body["threads"]?.array ?? []).compactMap { entry in
                entry["id"]?.number.map { Thread(id: Int($0), name: entry["name"]?.string ?? "Thread \(Int($0))") }
            }
        }
        let body = try? await client.request("stackTrace", .object(["threadId": .number(Double(thread)), "startFrame": .number(0),
                                                                    "levels": .number(64)]))
        guard state == .stopped else { return }
        frames = (body?["stackFrames"]?.array ?? []).compactMap { frame in
            guard let id = frame["id"]?.number.map(Int.init) else { return nil }
            // System frames come with made-up paths ("libsystem_c.dylib`usleep"): no source.
            let path = frame["source"]?["path"]?.string.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            return Frame(id: id, name: frame["name"]?.string ?? "?", path: path,
                         line: Int(frame["line"]?.number ?? 0), column: Int(frame["column"]?.number ?? 0))
        }
        // The first frame with source (system frames have none).
        if let frame = frames.first(where: { $0.path != nil }) ?? frames.first { await select(frame) }
    }

    /// Adds output to the console, a line per line ("\r\n" from a terminal counts as one break).
    private func append(_ kind: ConsoleLine.Kind, _ text: String) {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
        if text.hasSuffix("\n") { text.removeLast() }
        for line in text.components(separatedBy: "\n") { console.append(ConsoleLine(kind: kind, text: line)) }
        if console.count > 5000 { console.removeFirst(console.count - 5000) }
    }

    // MARK: Pre-launch

    /// Runs the pre-launch command in the login shell's environment, its output to the console.
    private func runPreLaunch(_ command: String) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(filePath: configuration.cwd ?? FileManager.default.currentDirectoryPath)
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        build = process
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.append(.output, text) }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Let output still queued for the main thread arrive before the result.
                DispatchQueue.main.async { continuation.resume(returning: process.terminationStatus) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
