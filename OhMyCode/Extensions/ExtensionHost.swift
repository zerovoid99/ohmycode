import AppKit
import Observation

/// One installed extension in a window: its state, log and runtime.
@MainActor
@Observable
final class ExtensionInstance: Identifiable {
    enum State: Equatable {
        /// Waiting for its activation event.
        case inactive
        case activating
        case active
        case failed(String)
        case disabled
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let date = Date()
        let level: String
        let message: String
    }

    let installed: InstalledExtension
    nonisolated let id: String
    var manifest: ExtensionManifest { installed.manifest }
    internal(set) var state: State
    private(set) var log: [LogEntry] = []
    @ObservationIgnored var runtime: ExtensionRuntime?
    @ObservationIgnored var activation: Task<Bool, Never>?
    /// Commands its code registered (contributed ones are in the manifest).
    @ObservationIgnored var registeredCommands: Set<String> = []

    init(installed: InstalledExtension, enabled: Bool) {
        self.installed = installed
        id = installed.id
        state = enabled ? .inactive : .disabled
    }

    var isEnabled: Bool { state != .disabled }

    func append(_ level: String, _ message: String) {
        log.append(LogEntry(level: level, message: message))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearLog() { log = [] }
}

/// A status bar item an extension shows.
struct ExtensionStatusItem: Identifiable, Equatable {
    let extensionID: String
    let itemID: Int
    var text: String
    var tooltip: String?
    var command: String?
    var isLeft: Bool
    var priority: Double

    var id: String { "\(extensionID)#\(itemID)" }
}

/// Runs a window's extensions: activates them on their events, answers their API calls and
/// tells them about documents and editors.
@MainActor
@Observable
final class ExtensionHost {
    /// Weak: work still in flight when the window closes goes to a closed workspace (does nothing).
    @ObservationIgnored private weak var owner: Workspace?
    private var workspace: Workspace { owner ?? Workspace.closed }
    private(set) var extensions: [ExtensionInstance] = []
    private(set) var statusItems: [ExtensionStatusItem] = []
    /// Folders in the extensions folder that aren't valid extensions, with why.
    private(set) var problems: [String: String] = [:]
    @ObservationIgnored var store: ExtensionStore = .shared
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var changeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeDocument: ObjectIdentifier?
    /// How long document changes settle before extensions hear about them.
    @ObservationIgnored var changeDelay: Duration = .milliseconds(150)

    init(workspace: Workspace) {
        self.owner = workspace
    }

    // MARK: Lifecycle

    /// (Re)starts the extensions for the folder the window opened.
    func start() {
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(forName: ExtensionStore.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: ExtensionStore.settingDidChange, object: nil, queue: .main) { [weak self] note in
                guard let id = note.userInfo?["id"] as? String, let key = note.userInfo?["key"] as? String else { return }
                MainActor.assumeIsolated {
                    self?.emit("didChangeConfiguration", .object(["key": .string(key)]), to: id)
                }
            })
            trackActiveEditor()
            listenForKeys()
        }
        reload(restart: true)
    }

    /// Picks up installed, removed, enabled and disabled extensions; `restart` restarts all.
    func reload(restart: Bool = false) {
        let previous = reloadTask
        reloadTask = Task {
            await previous?.value
            let installed = store.installed()
            problems = store.problems
            var kept: [ExtensionInstance] = []
            for instance in extensions {
                let current = installed.first { $0.id == instance.id }
                let enabled = store.isEnabled(instance.id)
                if restart || current != instance.installed || enabled != instance.isEnabled || current == nil {
                    await deactivate(instance)
                } else {
                    kept.append(instance)
                }
            }
            extensions = installed.map { item in
                kept.first { $0.id == item.id } ?? ExtensionInstance(installed: item, enabled: store.isEnabled(item.id))
            }
            updateKeybindings()
            for instance in extensions where instance.state == .inactive && instance.manifest.activatesOnStartup {
                _ = await activate(instance)
            }
            for document in workspace.documents { activateForLanguage(of: document) }
        }
    }

    /// Waits for loading and activation to finish (tests).
    func waitUntilIdle() async {
        await reloadTask?.value
        for instance in extensions { _ = await instance.activation?.value }
    }

    /// Stops every extension (the window is closing or opening another folder).
    func stopAll() async {
        await reloadTask?.value
        for instance in extensions { await deactivate(instance) }
    }

    @discardableResult
    func activate(_ instance: ExtensionInstance) async -> Bool {
        if instance.state == .active { return true }
        if let activation = instance.activation { return await activation.value }
        guard instance.state == .inactive || { if case .failed = instance.state { true } else { false } }() else { return false }
        let task = Task { () -> Bool in
            instance.state = .activating
            let installed = instance.installed
            let runtime = ExtensionRuntime(label: installed.id, bridge: makeBridge(for: installed.id), timeLimit: executionTimeLimit)
            instance.runtime = runtime
            do {
                let source = try String(contentsOf: installed.mainURL, encoding: .utf8)
                let context = JSONValue.object([
                    "extensionId": .string(installed.id),
                    "extensionPath": .string(installed.folder.path),
                ])
                let timeout = activationTimeout
                let started = try await Self.within(timeout) {
                    try await runtime.start(source: source, filename: installed.mainURL.path, contextJSON: context.json)
                }
                guard started != nil else {
                    throw ExtensionRuntime.RuntimeError.script("activate() didn't finish within \(timeout.components.seconds) seconds.")
                }
                instance.state = .active
                return true
            } catch {
                instance.append("error", "Activation failed: \(error.localizedDescription)")
                instance.state = .failed(error.localizedDescription)
                await stop(runtime, of: instance)
                instance.runtime = nil
                removeContributions(of: instance)
                return false
            }
        }
        instance.activation = task
        let result = await task.value
        instance.activation = nil
        return result
    }

    private func deactivate(_ instance: ExtensionInstance) async {
        _ = await instance.activation?.value
        if let runtime = instance.runtime {
            instance.runtime = nil
            await stop(runtime, of: instance)
        }
        removeContributions(of: instance)
        if instance.state != .disabled { instance.state = .inactive }
    }

    /// Stops a runtime, giving `deactivate()` `stopTimeout`: a stuck extension is left behind
    /// (its queue may still be busy) rather than holding up reloads.
    private func stop(_ runtime: ExtensionRuntime, of instance: ExtensionInstance) async {
        let timeout = stopTimeout
        let stopped = try? await Self.within(timeout) { await runtime.stop() }
        if stopped == nil {
            instance.append("warning", "deactivate() didn't finish within \(timeout.components.seconds) seconds; the extension was left running in the background.")
        }
    }

    /// How long the extension's JavaScript may run in one go (see `ExtensionRuntime.timeLimit`).
    @ObservationIgnored var executionTimeLimit: Double? = 5
    /// How long `activate()` and `deactivate()` may take.
    @ObservationIgnored var activationTimeout: Duration = .seconds(10)
    @ObservationIgnored var stopTimeout: Duration = .seconds(3)

    /// Runs `operation`, giving up after `timeout` (nil); it keeps running in the background then.
    static func within<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
            Task {
                do {
                    let value = try await operation()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private func removeContributions(of instance: ExtensionInstance) {
        instance.registeredCommands = []
        statusItems.removeAll { $0.extensionID == instance.id }
        providers.removeAll { $0.extensionID == instance.id }
        let collections = Set(diagnostics.values.flatMap(\.keys).filter { $0.hasPrefix(instance.id + "#") })
        for collection in collections { clearDiagnostics(collection: collection) }
    }

    // MARK: Language features

    enum ProviderKind: String { case completion, hover, formatting }

    struct Provider {
        let extensionID: String
        let id: Int
        let kind: ProviderKind
        /// Language ids ("*": every language).
        let languages: Set<String>
        let triggerCharacters: [String]

        @MainActor
        func handles(_ document: EditorDocument) -> Bool {
            if languages.contains("*") { return true }
            return languages.contains(document.languageId)
        }
    }

    @ObservationIgnored private(set) var providers: [Provider] = []
    /// Extensions' diagnostics by file path, then by collection ("<extension id>#<number>").
    @ObservationIgnored private var diagnostics: [String: [String: [Diagnostic]]] = [:]
    /// How long a provider may take before its answer is left out.
    @ObservationIgnored var providerTimeout: Duration = .milliseconds(1500)

    private func providers(_ kind: ProviderKind, for document: EditorDocument) -> [Provider] {
        providers.filter { $0.kind == kind && $0.handles(document) }
    }

    func hasProviders(_ kind: ProviderKind, for document: EditorDocument) -> Bool {
        !providers(kind, for: document).isEmpty
    }

    func completionTriggers(for document: EditorDocument) -> Set<String> {
        Set(providers(.completion, for: document).flatMap(\.triggerCharacters))
    }

    /// Asks the providers of `kind` for `document` (all at once, each within the timeout).
    private func ask(_ kind: ProviderKind, for document: EditorDocument, _ arguments: [String: JSONValue]) async -> [(Provider, JSONValue)] {
        var payload = arguments
        payload["document"] = Self.info(document)
        let json = JSONValue.object(payload).json
        let asked = providers(kind, for: document).compactMap { provider -> (Provider, ExtensionRuntime, ExtensionInstance)? in
            guard let instance = extensions.first(where: { $0.id == provider.extensionID }), instance.state == .active,
                  let runtime = instance.runtime else { return nil }
            return (provider, runtime, instance)
        }
        let timeout = providerTimeout
        var answers: [(index: Int, provider: Provider, value: JSONValue)] = []
        await withTaskGroup(of: (Int, String?, String?).self) { group in
            for (index, entry) in asked.enumerated() {
                let runtime = entry.1, id = entry.0.id
                group.addTask {
                    do {
                        guard let answer = try await Self.within(timeout, { try await runtime.provide(id, argumentsJSON: json) }) else {
                            return (index, nil, "didn't answer within \(timeout.components.seconds) s")
                        }
                        return (index, answer, nil)
                    } catch {
                        return (index, nil, error.localizedDescription)
                    }
                }
            }
            for await (index, answer, error) in group {
                let (provider, _, instance) = asked[index]
                if let error {
                    instance.append("error", "\(provider.kind.rawValue) provider: \(error)")
                } else if let answer, let value = JSONValue(json: answer), value != .null {
                    answers.append((index, provider, value))
                }
            }
        }
        // In the order the providers were registered, however fast each answered.
        return answers.sorted { $0.index < $1.index }.map { ($0.provider, $0.value) }
    }

    private static func position(_ document: EditorDocument, _ offset: Int) -> JSONValue {
        let position = document.lspPosition(at: min(offset, document.textStorage.length))
        return .object(["line": .number(Double(position.line)), "character": .number(Double(position.character))])
    }

    /// Completion items from the extensions (ids from `firstID` up).
    func completions(for document: EditorDocument, at offset: Int, trigger: String?, firstID: Int) async -> (items: [CompletionItem], isIncomplete: Bool) {
        let answers = await ask(.completion, for: document, ["position": Self.position(document, offset),
                                                             "triggerCharacter": trigger.map(JSONValue.string) ?? .null])
        var items: [CompletionItem] = []
        var isIncomplete = false
        for (_, answer) in answers {
            isIncomplete = isIncomplete || answer["isIncomplete"]?.bool == true
            for item in answer["items"]?.array ?? [] {
                let json = try? JSONSerialization.jsonObject(with: Data(item.json.utf8))
                if let completion = CompletionItem(json: json, id: firstID + items.count) { items.append(completion) }
            }
        }
        return (items, isIncomplete)
    }

    /// Hover texts (markdown) from the extensions.
    func hovers(for document: EditorDocument, at offset: Int) async -> [String] {
        await ask(.hover, for: document, ["position": Self.position(document, offset)])
            .flatMap { $0.1.array?.compactMap(\.string) ?? [] }.filter { !$0.isEmpty }
    }

    /// Formatting edits from the first extension formatter that answers; nil when none does.
    func formattingEdits(for document: EditorDocument) async -> [TextReplacement]? {
        let (tabSize, insertSpaces) = document.indentation
        let answers = await ask(.formatting, for: document, ["options": .object(["tabSize": .number(Double(tabSize)),
                                                                                 "insertSpaces": .bool(insertSpaces)])])
        guard let edits = answers.first?.1.array else { return nil }
        return edits.compactMap { edit in
            guard let range = edit["range"].flatMap(LSPRange.init(value:)) else { return nil }
            return TextReplacement(range: document.range(for: range), text: edit["newText"]?.string ?? "")
        }
    }

    private func applyDiagnostics(to document: EditorDocument) {
        for (collection, list) in diagnostics[document.url.standardizedFileURL.path] ?? [:] {
            document.setExtensionDiagnostics(list, collection: collection)
        }
    }

    private func clearDiagnostics(collection: String) {
        workspace.problems.clear(source: collection)
        for path in Array(diagnostics.keys) where diagnostics[path]?[collection] != nil {
            diagnostics[path]?[collection] = nil
            if diagnostics[path]?.isEmpty == true { diagnostics[path] = nil }
            workspace.document(matching: URL(filePath: path))?.setExtensionDiagnostics([], collection: collection)
        }
    }

    /// A diagnostic from the API (severity numbered like VS Code's: 0 error … 3 hint).
    private static func diagnostic(_ value: JSONValue) -> Diagnostic? {
        guard let range = value["range"].flatMap(LSPRange.init(value:)), let message = value["message"]?.string else { return nil }
        let severity: Diagnostic.Severity = switch Int(value["severity"]?.number ?? 0) {
        case 1: .warning
        case 2: .information
        case 3: .hint
        default: .error
        }
        return Diagnostic(range: range, severity: severity, message: message, source: value["source"]?.string)
    }

    // MARK: Keybindings

    /// The enabled extensions' shortcuts, as the user's keybindings leave them (rules that
    /// don't parse are in the extensions' logs).
    var keybindings: [(chord: KeyChord, binding: ExtensionManifest.Keybinding, extension: ExtensionInstance)] {
        let bindings = Keybindings.shared
        var result: [(chord: KeyChord, binding: ExtensionManifest.Keybinding, extension: ExtensionInstance)] = []
        for instance in extensions where instance.isEnabled {
            let manifest = instance.manifest
            for binding in manifest.keybindings {
                switch bindings.source(for: binding.command) {
                case .user, .removed:
                    continue // below
                default:
                    guard let chord = try? KeyChord(parsing: binding.key) else { continue }
                    result.append((chord, binding, instance))
                }
            }
            for command in Set(manifest.commands.map(\.command) + manifest.keybindings.map(\.command)).sorted()
            where bindings.source(for: command) == .user {
                guard let chord = bindings.chord(for: command) else { continue }
                let when = bindings.when(for: command) ?? manifest.keybindings.first { $0.command == command }?.when
                result.append((chord, ExtensionManifest.Keybinding(command: command, key: chord.spec, when: when), instance))
            }
        }
        return result
    }

    /// Tells Keybindings the extensions' commands and default shortcuts (logging bad ones).
    private func updateKeybindings() {
        let bindings = Keybindings.shared
        for id in bindings.extensionCommands.keys where !extensions.contains(where: { $0.id == id }) { bindings.removeExtension(id) }
        for instance in extensions {
            var defaults: [String: String] = [:]
            for binding in instance.manifest.keybindings {
                do {
                    let chord = try KeyChord(parsing: binding.key)
                    if defaults[binding.command] == nil { defaults[binding.command] = chord.spec }
                } catch {
                    instance.append("warning", "Keybinding \(binding.key) for \(binding.command) ignored: \(error.localizedDescription)")
                }
            }
            if instance.isEnabled {
                bindings.setExtensionCommands(instance.id, name: instance.manifest.name,
                                              commands: instance.manifest.commands.map { ($0.command, $0.paletteTitle) }, defaults: defaults)
            } else {
                bindings.removeExtension(instance.id)
            }
        }
    }

    /// The shortcut shown for a command in the palette.
    func shortcut(for command: String) -> String? {
        Keybindings.shared.display(for: command)
    }

    /// Runs the command bound to a key press in this window; false if none applies. A shortcut
    /// a menu item already has stays the menu's. Built-in commands get here only when their
    /// shortcut isn't in a menu (palette commands the user gave one).
    func handleKeyDown(_ event: NSEvent, in window: NSWindow?) -> Bool {
        let bindings = Keybindings.shared
        let match = keybindings.first { $0.chord.matches(event) && isTrue($0.binding.when, in: window) }
        let command = PaletteCommand.all.first { bindings.chord(for: $0.id)?.matches(event) == true }
        guard let chord = command.flatMap({ bindings.chord(for: $0.id) }) ?? match?.chord else { return false }
        if let item = chord.menuItem(in: NSApp.mainMenu) {
            if let match {
                match.extension.append("warning", "\(chord.display) is the menu's “\(item.title)”: \(match.binding.command) isn't run.")
            }
            return false
        }
        if let command {
            guard isTrue(bindings.when(for: command.id), in: window), command.isAvailable(workspace) else { return false }
            command.perform(workspace)
            return true
        }
        guard let match else { return false }
        run(match.binding.command)
        return true
    }

    /// Evaluates a `when` clause: terms joined with "&&", each "editorTextFocus",
    /// "editorLangId == <id>" (or "!="), optionally negated with "!". Unknown terms are false.
    func isTrue(_ when: String?, in window: NSWindow?) -> Bool {
        guard let when, !when.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return when.components(separatedBy: "&&").allSatisfy { raw in
            var term = raw.trimmingCharacters(in: .whitespaces)
            var negated = false
            while term.hasPrefix("!") && !term.hasPrefix("!=") { negated.toggle(); term = String(term.dropFirst()).trimmingCharacters(in: .whitespaces) }
            let value: Bool
            if term == "editorTextFocus" {
                value = (window?.firstResponder as? NSTextView).map { $0 === workspace.activeDocument?.editor?.textView } ?? false
            } else if term.hasPrefix("editorLangId") {
                let rest = term.dropFirst("editorLangId".count).trimmingCharacters(in: .whitespaces)
                let language = workspace.activeDocument?.languageId
                if rest.hasPrefix("==") { value = language == rest.dropFirst(2).trimmingCharacters(in: .whitespaces) }
                else if rest.hasPrefix("!=") { value = language != rest.dropFirst(2).trimmingCharacters(in: .whitespaces) }
                else { value = false }
            } else {
                value = false
            }
            return value != negated
        }
    }

    /// One key monitor for the app, handing key presses to the host of the window they're in.
    private static let hosts = NSHashTable<ExtensionHost>.weakObjects()
    private static var keyMonitor: Any?

    private func listenForKeys() {
        Self.hosts.add(self)
        guard Self.keyMonitor == nil else { return }
        Self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let window = event.window,
                      let host = ExtensionHost.hosts.allObjects.first(where: { $0.workspace.window === window }) else { return false }
                return host.handleKeyDown(event, in: window)
            }
            return handled ? nil : event
        }
    }

    // MARK: Managing

    func setEnabled(_ instance: ExtensionInstance, _ enabled: Bool) {
        store.setEnabled(instance.id, enabled)
    }

    func uninstall(_ instance: ExtensionInstance) throws {
        try store.uninstall(instance.installed)
    }

    // MARK: Commands

    /// Commands the enabled extensions add to the palette.
    var paletteCommands: [(command: ExtensionManifest.Command, extension: ExtensionInstance)] {
        extensions.filter(\.isEnabled).flatMap { instance in instance.manifest.commands.map { ($0, instance) } }
    }

    enum CommandError: LocalizedError {
        case notFound(String)
        case notActive(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let id): "There's no command “\(id)”."
            case .notActive(let name): "\(name) couldn't start: see its log in Extensions."
            }
        }
    }

    /// Runs an extension's command (activating the extension first) or a built-in one.
    @discardableResult
    func executeCommand(_ id: String, arguments: [JSONValue] = []) async throws -> JSONValue? {
        if let instance = extensions.first(where: { $0.isEnabled && ($0.registeredCommands.contains(id) || $0.manifest.activates(onCommand: id)) }) {
            guard await activate(instance), let runtime = instance.runtime else { throw CommandError.notActive(instance.manifest.name) }
            let result = try await runtime.runCommand(id, argumentsJSON: JSONValue.array(arguments).json)
            return result.flatMap(JSONValue.init(json:))
        }
        if let command = PaletteCommand.all.first(where: { $0.id == id }) {
            command.perform(workspace)
            return nil
        }
        throw CommandError.notFound(id)
    }

    /// Runs a command for the user (palette, status bar): errors show as alerts.
    func run(_ id: String) {
        Task {
            do { try await executeCommand(id) } catch { workspace.errorMessage = error.localizedDescription }
        }
    }

    // MARK: Documents and editors

    func documentOpened(_ document: EditorDocument) {
        document.extensionHost = self
        applyDiagnostics(to: document)
        document.onDidEdit = { [weak self, weak document] in
            guard let self, let document else { return }
            self.documentChanged(document)
        }
        document.onDidSave = { [weak self, weak document] in
            guard let self, let document else { return }
            self.emitAll("didSaveTextDocument", Self.info(document))
        }
        activateForLanguage(of: document)
        emitAll("didOpenTextDocument", Self.info(document))
    }

    func documentClosed(_ document: EditorDocument) {
        changeTasks.removeValue(forKey: ObjectIdentifier(document))?.cancel()
        emitAll("didCloseTextDocument", Self.info(document))
    }

    private func documentChanged(_ document: EditorDocument) {
        let key = ObjectIdentifier(document)
        guard changeTasks[key] == nil else { return }
        changeTasks[key] = Task { [weak self, weak document] in
            try? await Task.sleep(for: self?.changeDelay ?? .zero)
            guard let self else { return }
            self.changeTasks[key] = nil
            guard !Task.isCancelled, let document else { return }
            self.emitAll("didChangeTextDocument", Self.info(document))
        }
    }

    private func activateForLanguage(of document: EditorDocument) {
        for instance in extensions where instance.state == .inactive && instance.manifest.activates(onLanguage: document.languageId) {
            Task { await activate(instance) }
        }
    }

    /// Tells the extensions when the active editor changes (changes within one run loop turn
    /// arrive as one).
    private func trackActiveEditor() {
        withObservationTracking {
            _ = workspace.activeDocument
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let document = self.workspace.activeDocument
                if document.map(ObjectIdentifier.init) != self.activeDocument {
                    self.activeDocument = document.map(ObjectIdentifier.init)
                    self.emitAll("didChangeActiveTextEditor", document.map(self.editorInfo) ?? .null)
                }
                self.trackActiveEditor()
            }
        }
    }

    private func emitAll(_ event: String, _ payload: JSONValue) {
        let json = payload.json
        for instance in extensions where instance.state == .active { instance.runtime?.emit(event, payloadJSON: json) }
    }

    private func emit(_ event: String, _ payload: JSONValue, to id: String) {
        guard let instance = extensions.first(where: { $0.id == id }), instance.state == .active else { return }
        instance.runtime?.emit(event, payloadJSON: payload.json)
    }

    static func info(_ document: EditorDocument) -> JSONValue {
        .object([
            "path": .string(document.url.path),
            "fileName": .string(document.fileName),
            "languageId": .string(document.languageId),
            "isDirty": .bool(document.isDirty),
            "lineCount": .number(Double(document.lineCount)),
            "version": .number(Double(document.editVersion)),
        ])
    }

    private func editorInfo(_ document: EditorDocument) -> JSONValue {
        let ranges = document.editor?.textView?.selectedRanges.map(\.rangeValue) ?? [NSRange(location: 0, length: 0)]
        return .object([
            "document": Self.info(document),
            "selections": .array(ranges.map { range in
                .object(["start": position(document, range.location), "end": position(document, NSMaxRange(range))])
            }),
        ])
    }

    private func position(_ document: EditorDocument, _ offset: Int) -> JSONValue {
        let position = document.lspPosition(at: min(offset, document.textStorage.length))
        return .object(["line": .number(Double(position.line)), "character": .number(Double(position.character))])
    }

    // MARK: Bridge

    private final class WeakHost: @unchecked Sendable {
        weak var host: ExtensionHost?
        init(_ host: ExtensionHost) { self.host = host }
    }

    private func makeBridge(for id: String) -> ExtensionRuntime.Bridge {
        let box = WeakHost(self)
        return ExtensionRuntime.Bridge(
            call: { method, arguments in
                let answer = { MainActor.assumeIsolated { box.host?.answer(id, method, arguments) ?? Self.reply(error: "The window closed.") } }
                return Thread.isMainThread ? answer() : DispatchQueue.main.sync(execute: answer)
            },
            callAsync: { method, arguments, reply in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let host = box.host else { reply("The window closed.", nil); return }
                        Task { @MainActor in
                            do {
                                let result = try await host.answerAsync(id, method, JSONValue(json: arguments) ?? .null)
                                reply(nil, result?.json)
                            } catch {
                                reply(error.localizedDescription, nil)
                            }
                        }
                    }
                }
            },
            log: { level, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { box.host?.extensions.first { $0.id == id }?.append(level, message) }
                }
            })
    }

    nonisolated static func reply(result: JSONValue? = nil, error: String? = nil) -> String {
        if let error { return JSONValue.object(["error": .string(error)]).json }
        return JSONValue.object(["result": result ?? .null]).json
    }

    enum APIError: LocalizedError {
        case unknownMethod(String)
        case badArguments(String)
        case notOpen(String)
        case permission(ExtensionManifest.Permission)
        case outsideWorkspace(String)

        var errorDescription: String? {
            switch self {
            case .unknownMethod(let method): "Unknown API: \(method)."
            case .badArguments(let method): "Wrong arguments for \(method)."
            case .notOpen(let path): "\(path) isn't open: open it with omc.workspace.openTextDocument first."
            case .permission(let permission):
                "This extension didn't ask to \(permission.title.lowercased()): add \"\(permission.rawValue)\" to \"permissions\" in its extension.json."
            case .outsideWorkspace(let path): "\(path) is outside the open folder."
            }
        }
    }

    private func answer(_ id: String, _ method: String, _ arguments: String) -> String {
        do {
            return Self.reply(result: try answerNow(id, method, JSONValue(json: arguments) ?? .null))
        } catch {
            return Self.reply(error: error.localizedDescription)
        }
    }

    /// Calls answered right away.
    private func answerNow(_ id: String, _ method: String, _ args: JSONValue) throws -> JSONValue? {
        guard let instance = extensions.first(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        switch method {
        case "commands.register":
            guard let command = args["id"]?.string else { throw APIError.badArguments(method) }
            instance.registeredCommands.insert(command)
            return nil
        case "commands.unregister":
            if let command = args["id"]?.string { instance.registeredCommands.remove(command) }
            return nil
        case "editor.active":
            return workspace.activeDocument.map(editorInfo)
        case "document.getText":
            let document = try openDocument(args)
            let text = document.textStorage.mutableString
            guard let range = args["range"], range != .null else { return .string(text as String) }
            return .string(text.substring(with: try nsRange(range, in: document, method: method)))
        case "document.getLine":
            let document = try openDocument(args)
            guard let line = args["line"]?.number.map(Int.init), line >= 0, line < document.lineIndex.lineCount
            else { throw APIError.badArguments(method) }
            let starts = document.lineIndex.lineStarts
            let end = line + 1 < starts.count ? starts[line + 1] - 1 : document.textStorage.length
            return .string(document.textStorage.mutableString.substring(with: NSRange(location: starts[line], length: max(0, end - starts[line]))))
        case "editor.setSelections":
            let document = try openDocument(args)
            guard let selections = args["selections"]?.array, !selections.isEmpty else { throw APIError.badArguments(method) }
            let ranges = try selections.map { try nsRange($0, in: document, method: method) }
            if let textView = document.editor?.textView {
                textView.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
                textView.scrollRangeToVisible(ranges[0])
            }
            return nil
        case "workspace.root":
            return workspace.rootURL.map { .string($0.path) }
        case "workspace.documents":
            return .array(workspace.documents.map(Self.info))
        case "config.get":
            guard let key = args["key"]?.string else { throw APIError.badArguments(method) }
            return store.setting(key, of: instance.manifest)
        case "storage.get":
            guard let key = args["key"]?.string else { throw APIError.badArguments(method) }
            return store.stored(key, of: id)
        case "storage.set":
            guard let key = args["key"]?.string else { throw APIError.badArguments(method) }
            let value = args["value"]
            store.store(value == .null ? nil : value, for: key, of: id)
            return nil
        case "statusBar.update":
            guard let item = args["id"]?.number.map(Int.init) else { throw APIError.badArguments(method) }
            statusItems.removeAll { $0.extensionID == id && $0.itemID == item }
            if args["visible"]?.bool == true {
                statusItems.append(ExtensionStatusItem(extensionID: id, itemID: item, text: args["text"]?.string ?? "",
                                                       tooltip: args["tooltip"]?.string, command: args["command"]?.string,
                                                       isLeft: args["alignment"]?.string == "left",
                                                       priority: args["priority"]?.number ?? 0))
                statusItems.sort { $0.priority > $1.priority }
            }
            return nil
        case "languages.register":
            guard let provider = args["id"]?.number.map(Int.init), let kind = args["kind"]?.string.flatMap(ProviderKind.init) else {
                throw APIError.badArguments(method)
            }
            providers.append(Provider(extensionID: id, id: provider, kind: kind,
                                      languages: Set(args["languages"]?.array?.compactMap(\.string) ?? ["*"]),
                                      triggerCharacters: args["triggerCharacters"]?.array?.compactMap(\.string) ?? []))
            return nil
        case "languages.unregister":
            if let provider = args["id"]?.number.map(Int.init) { providers.removeAll { $0.extensionID == id && $0.id == provider } }
            return nil
        case "diagnostics.set":
            guard let collection = args["id"]?.number.map(Int.init), let path = args["path"]?.string else { throw APIError.badArguments(method) }
            let key = "\(id)#\(collection)"
            let url = (path.hasPrefix("/") ? URL(filePath: path) : workspace.rootURL?.appending(path: path) ?? URL(filePath: path)).standardizedFileURL
            let list = (args["diagnostics"]?.array ?? []).compactMap { Self.diagnostic($0) }
            diagnostics[url.path, default: [:]][key] = list.isEmpty ? nil : list
            if diagnostics[url.path]?.isEmpty == true { diagnostics[url.path] = nil }
            workspace.problems.set(list, for: url, source: key)
            workspace.document(matching: url)?.setExtensionDiagnostics(list, collection: key)
            return nil
        case "diagnostics.clear":
            guard let collection = args["id"]?.number.map(Int.init) else { throw APIError.badArguments(method) }
            clearDiagnostics(collection: "\(id)#\(collection)")
            return nil
        case "statusBar.remove":
            if let item = args["id"]?.number.map(Int.init) { statusItems.removeAll { $0.extensionID == id && $0.itemID == item } }
            return nil
        default:
            throw APIError.unknownMethod(method)
        }
    }

    /// Calls answered later (dialogs, edits, files, processes, network).
    private func answerAsync(_ id: String, _ method: String, _ args: JSONValue) async throws -> JSONValue? {
        guard let instance = extensions.first(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        let permissions = instance.manifest.grantedPermissions
        switch method {
        case "window.showMessage":
            let kind = AppNotification.Kind(rawValue: args["kind"]?.string ?? "") ?? .info
            let items = args["items"]?.array?.compactMap(\.string) ?? []
            return await workspace.notify(kind, args["message"]?.string ?? "", source: instance.manifest.name, items: items).map(JSONValue.string)
        case "window.showInputBox":
            return await workspace.showInputBox(prompt: args["prompt"]?.string, value: args["value"]?.string ?? "",
                                                placeholder: args["placeHolder"]?.string).map(JSONValue.string)
        case "window.showQuickPick":
            let items = (args["items"]?.array ?? []).map { item in
                QuickPickItem(label: item["label"]?.string ?? "", description: item["description"]?.string, detail: item["detail"]?.string)
            }
            return await workspace.showQuickPick(items, placeholder: args["placeHolder"]?.string).map { .number(Double($0)) }
        case "editor.edit":
            let document = try openDocument(args)
            let edits = try (args["edits"]?.array ?? []).map { edit in
                TextReplacement(range: try nsRange(edit["range"] ?? .null, in: document, method: method), text: edit["text"]?.string ?? "")
            }
            return .bool(try document.apply(edits, actionName: instance.manifest.name))
        case "document.save":
            return .bool(workspace.save(try openDocument(args)))
        case "window.showTextDocument":
            let url = try resolve(args["path"]?.string, permissions: permissions, method: method)
            workspace.open(fileAt: url)
            return workspace.activeDocument.map(editorInfo)
        case "workspace.openTextDocument":
            let url = try resolve(args["path"]?.string, permissions: permissions, method: method)
            guard let document = workspace.document(matching: url) ?? workspace.openInBackground(url) else {
                throw APIError.notOpen(url.path)
            }
            return Self.info(document)
        case "commands.execute":
            guard let command = args["id"]?.string else { throw APIError.badArguments(method) }
            return try await executeCommand(command, arguments: args["args"]?.array ?? [])
        case "commands.list":
            let ids = PaletteCommand.all.map(\.id) + extensions.filter(\.isEnabled).flatMap { $0.manifest.commands.map(\.command) + $0.registeredCommands }
            return .array(Array(Set(ids)).sorted().map(JSONValue.string))
        case "config.update":
            guard let key = args["key"]?.string else { throw APIError.badArguments(method) }
            let value = args["value"]
            store.setSetting(key, to: value == .null ? nil : value, of: id)
            return nil
        case "fs.readFile":
            let url = try resolve(args["path"]?.string, permissions: permissions, method: method)
            return .string(try await Task.detached { try String(contentsOf: url, encoding: .utf8) }.value)
        case "fs.writeFile":
            let url = try resolve(args["path"]?.string, permissions: permissions, method: method)
            let text = args["text"]?.string ?? ""
            try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value
            return nil
        case "fs.readDirectory":
            let url = try resolve(args["path"]?.string, permissions: permissions, method: method)
            let entries = try await Task.detached { () -> [JSONValue] in
                try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]).map { item in
                    let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    return .object(["name": .string(item.lastPathComponent), "isDirectory": .bool(isDirectory)])
                }
            }.value
            return .array(entries.sorted { ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "") })
        case "fs.exists":
            let url = try resolve(args["path"]?.string, permissions: permissions, method: method)
            return .bool(FileManager.default.fileExists(atPath: url.path))
        case "process.run":
            guard permissions.contains(.process) else { throw APIError.permission(.process) }
            guard let command = args["command"]?.string, !command.isEmpty else { throw APIError.badArguments(method) }
            let cwd = try args["cwd"]?.string.map { try resolve($0, permissions: permissions, method: method) } ?? workspace.rootURL
            return try await ExtensionProcess.run(command, arguments: args["args"]?.array?.compactMap(\.string) ?? [],
                                                  directory: cwd, input: args["input"]?.string,
                                                  timeout: args["timeout"]?.number.map { $0 / 1000 } ?? 60)
        case "net.fetch":
            guard permissions.contains(.network) else { throw APIError.permission(.network) }
            guard let text = args["url"]?.string, let url = URL(string: text), url.scheme == "https" || url.scheme == "http"
            else { throw APIError.badArguments(method) }
            var request = URLRequest(url: url)
            request.httpMethod = args["method"]?.string ?? "GET"
            for (name, value) in args["headers"]?.object ?? [:] { request.setValue(value.string, forHTTPHeaderField: name) }
            if let body = args["body"]?.string { request.httpBody = Data(body.utf8) }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: JSONValue] = [:]
            for (name, value) in http?.allHeaderFields ?? [:] { headers[String(describing: name).lowercased()] = .string(String(describing: value)) }
            return .object(["status": .number(Double(http?.statusCode ?? 0)), "headers": .object(headers),
                            "body": .string(String(decoding: data, as: UTF8.self))])
        default:
            throw APIError.unknownMethod(method)
        }
    }

    /// An open document by `path`.
    private func openDocument(_ args: JSONValue) throws -> EditorDocument {
        guard let path = args["path"]?.string else { throw APIError.badArguments("document") }
        guard let document = workspace.document(matching: URL(filePath: path)) else { throw APIError.notOpen(path) }
        return document
    }

    /// A `{start, end}` range (line, UTF-16 character) as offsets in the document.
    private func nsRange(_ range: JSONValue, in document: EditorDocument, method: String) throws -> NSRange {
        func offset(_ position: JSONValue?) throws -> Int {
            guard let line = position?["line"]?.number, let character = position?["character"]?.number else {
                throw APIError.badArguments(method)
            }
            return document.offset(for: LSPPosition(line: Int(line), character: Int(character)))
        }
        let start = try offset(range["start"]), end = try offset(range["end"])
        return NSRange(location: min(start, end), length: abs(end - start))
    }

    /// A path (relative to the open folder, or absolute) the extension may use: outside the
    /// folder needs the fileSystem permission.
    private func resolve(_ path: String?, permissions: Set<ExtensionManifest.Permission>, method: String) throws -> URL {
        guard let path, !path.isEmpty else { throw APIError.badArguments(method) }
        let root = workspace.rootURL
        let url = (path.hasPrefix("/") ? URL(filePath: path) : root.map { $0.appending(path: path) } ?? URL(filePath: path)).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        let inside = root.map { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            return resolved == rootPath || resolved.hasPrefix(rootPath + "/")
        } ?? false
        if !inside && !permissions.contains(.fileSystem) { throw APIError.outsideWorkspace(path) }
        return url
    }
}

/// True for the first `claim()` only, from any thread.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// Programs extensions run, with the login shell's PATH (like the terminal).
enum ExtensionProcess {
    struct Timeout: LocalizedError {
        let seconds: Double
        var errorDescription: String? { "The program didn't finish within \(Int(seconds)) seconds and was stopped." }
    }

    static func run(_ command: String, arguments: [String], directory: URL?, input: String?, timeout: Double) async throws -> JSONValue {
        let environment = await ShellEnvironment.shared.environment()
        return try await Task.detached(priority: .userInitiated) {
            try runBlocking(command, arguments: arguments, directory: directory, input: input, timeout: timeout, environment: environment)
        }.value
    }

    private static func runBlocking(_ command: String, arguments: [String], directory: URL?, input: String?, timeout: Double,
                                    environment: [String: String]) throws -> JSONValue {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = [command] + arguments
            process.environment = environment
            if let directory { process.currentDirectoryURL = directory }
            let output = Pipe(), errors = Pipe(), inputPipe = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
            if let input {
                DispatchQueue.global().async {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    try? inputPipe.fileHandleForWriting.close()
                }
            }
            nonisolated(unsafe) var didTimeOut = false
            let timer = DispatchWorkItem {
                if process.isRunning { didTimeOut = true; process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let result = try ProcessIO.run(process, output: output, error: errors)
            timer.cancel()
            if didTimeOut { throw Timeout(seconds: timeout) }
            return JSONValue.object([
                "code": .number(Double(result.status)),
                "stdout": .string(String(decoding: result.output, as: UTF8.self)),
                "stderr": .string(String(decoding: result.error, as: UTF8.self)),
            ])
    }
}

extension LSPRange {
    /// From an API range: {start: {line, character}, end: {line, character}}.
    init?(value: JSONValue) {
        guard let start = value["start"], let end = value["end"],
              let startLine = start["line"]?.number, let startCharacter = start["character"]?.number,
              let endLine = end["line"]?.number, let endCharacter = end["character"]?.number else { return nil }
        self.init(start: LSPPosition(line: Int(startLine), character: Int(startCharacter)),
                  end: LSPPosition(line: Int(endLine), character: Int(endCharacter)))
    }
}
