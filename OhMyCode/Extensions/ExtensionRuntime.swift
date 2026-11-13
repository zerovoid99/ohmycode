import Foundation
import JavaScriptCore

/// One extension's JavaScript, in its own JavaScriptCore virtual machine on its own serial
/// queue: a slow or stuck extension never blocks the editor or other extensions. Everything
/// touching the context happens on `queue`.
///
/// The extension calls into the app through `bridge` with JSON strings: `call` answers right
/// away (it waits for the main thread), `callAsync` answers later through `resolve`.
final class ExtensionRuntime: @unchecked Sendable {
    /// Answers the extension's calls (on the main thread).
    struct Bridge: Sendable {
        /// (method, arguments JSON) → reply JSON `{"result": …}` or `{"error": "…"}`.
        let call: @Sendable (String, String) -> String
        /// (method, arguments JSON, reply): reply with (error, result JSON) when done.
        let callAsync: @Sendable (String, String, @escaping @Sendable (String?, String?) -> Void) -> Void
        /// (level, message): console output and errors.
        let log: @Sendable (String, String) -> Void
    }

    enum RuntimeError: LocalizedError {
        case script(String)
        case stopped
        var errorDescription: String? {
            switch self {
            case .script(let message): message
            case .stopped: "The extension isn't running."
            }
        }
    }

    let queue: DispatchQueue
    private let bridge: Bridge
    // Only on `queue`:
    private var context: JSContext?
    private var timers: [Int: DispatchWorkItem] = [:]
    private var waiting: [Int: CheckedContinuation<String?, Error>] = [:]
    private var nextToken = 1

    init(label: String, bridge: Bridge) {
        queue = DispatchQueue(label: "dev.zerovoid99.ohmycode.extension.\(label)", qos: .userInitiated)
        self.bridge = bridge
    }

    // MARK: Lifecycle

    /// Loads the extension's main file and runs its `activate(context)`.
    func start(source: String, filename: String, contextJSON: String) async throws {
        try await perform { token in
            let context = self.makeContext()
            self.context = context
            context.objectForKeyedSubscript("__omcLoad")
                .call(withArguments: [source, filename, (filename as NSString).deletingLastPathComponent])
            if let error = Self.takeException(context) { throw RuntimeError.script(error) }
            context.objectForKeyedSubscript("__omcActivate").call(withArguments: [contextJSON, token])
        }
    }

    /// Runs `deactivate()`, disposes the subscriptions, then drops the context.
    func stop() async {
        _ = try? await perform { token in
            guard let context = self.context else { throw RuntimeError.stopped }
            context.objectForKeyedSubscript("__omcDeactivate").call(withArguments: [token])
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.timers.values.forEach { $0.cancel() }
                self.timers = [:]
                self.context = nil
                for continuation in self.waiting.values { continuation.resume(throwing: RuntimeError.stopped) }
                self.waiting = [:]
                done.resume()
            }
        }
    }

    /// Runs a command the extension registered; its result as JSON (nil for undefined).
    func runCommand(_ id: String, argumentsJSON: String) async throws -> String? {
        try await perform { token in
            guard let context = self.context else { throw RuntimeError.stopped }
            context.objectForKeyedSubscript("__omcRunCommand").call(withArguments: [id, token, argumentsJSON])
        }
    }

    /// Delivers an event (`didSaveTextDocument`, …) to the extension's listeners.
    func emit(_ event: String, payloadJSON: String) {
        queue.async {
            self.context?.objectForKeyedSubscript("__omcEmit").call(withArguments: [event, payloadJSON])
            self.reportException()
        }
    }

    /// Calls `body` on the queue with a token that the script finishes through
    /// `__omcNative.commandDone(token, error, result)`.
    private func perform(_ body: @escaping (Int) throws -> Void) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let token = self.nextToken
                self.nextToken += 1
                self.waiting[token] = continuation
                do {
                    try body(token)
                    if let context = self.context, let error = Self.takeException(context) {
                        throw RuntimeError.script(error)
                    }
                } catch {
                    self.waiting.removeValue(forKey: token)?.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Context

    private func makeContext() -> JSContext {
        let context = JSContext(virtualMachine: JSVirtualMachine())!
        context.name = queue.label
        let native = JSValue(newObjectIn: context)!
        let bridge = self.bridge

        let call: @convention(block) (String, String) -> String = { method, arguments in
            bridge.call(method, arguments)
        }
        let callAsync: @convention(block) (String, String, Int) -> Void = { [weak self] method, arguments, id in
            guard let runtime = self else { return }
            bridge.callAsync(method, arguments) { [weak runtime] error, result in
                runtime?.resolve(id, error: error, result: result)
            }
        }
        let commandDone: @convention(block) (Int, JSValue, JSValue) -> Void = { [weak self] token, error, result in
            guard let continuation = self?.waiting.removeValue(forKey: token) else { return }
            if !error.isNull && !error.isUndefined {
                continuation.resume(throwing: RuntimeError.script(error.toString()))
            } else {
                continuation.resume(returning: result.isNull || result.isUndefined ? nil : result.toString())
            }
        }
        let log: @convention(block) (String, String) -> Void = { level, message in bridge.log(level, message) }
        let setTimer: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, milliseconds, repeats in
            self?.schedule(id, after: milliseconds, repeats: repeats)
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.cancel()
        }
        native.setObject(call, forKeyedSubscript: "call" as NSString)
        native.setObject(callAsync, forKeyedSubscript: "callAsync" as NSString)
        native.setObject(commandDone, forKeyedSubscript: "commandDone" as NSString)
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(setTimer, forKeyedSubscript: "setTimer" as NSString)
        native.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)
        native.setObject(ExtensionPrelude.apiVersion, forKeyedSubscript: "version" as NSString)
        context.setObject(native, forKeyedSubscript: "__omcNative" as NSString)
        context.evaluateScript(ExtensionPrelude.source, withSourceURL: URL(string: "omc://prelude.js"))
        if let error = Self.takeException(context) { bridge.log("error", "The API failed to load: \(error)") }
        return context
    }

    /// Answers an async call (from any thread).
    private func resolve(_ id: Int, error: String?, result: String?) {
        queue.async {
            self.context?.objectForKeyedSubscript("__omcResolve")
                .call(withArguments: [id, error.map { $0 as Any } ?? NSNull(), result.map { $0 as Any } ?? NSNull()])
            self.reportException()
        }
    }

    private func schedule(_ id: Int, after milliseconds: Double, repeats: Bool) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.timers[id] != nil else { return }
            if repeats {
                self.schedule(id, after: milliseconds, repeats: true)
            } else {
                self.timers[id] = nil
            }
            self.context?.objectForKeyedSubscript("__omcTimer").call(withArguments: [id])
            self.reportException()
        }
        timers[id] = item
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(max(milliseconds, repeats ? 1 : 0))), execute: item)
    }

    /// Logs an exception the script left uncaught.
    private func reportException() {
        if let context, let error = Self.takeException(context) { bridge.log("error", error) }
    }

    private static func takeException(_ context: JSContext) -> String? {
        guard let exception = context.exception, !exception.isUndefined, !exception.isNull else { return nil }
        context.exception = nil
        let message = exception.toString() ?? "Unknown error"
        if let stack = exception.objectForKeyedSubscript("stack"), !stack.isUndefined, let text = stack.toString(), !text.isEmpty {
            return message + "\n" + text
        }
        return message
    }
}
