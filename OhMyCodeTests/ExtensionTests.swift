import AppKit
import Testing
@testable import Oh_My_Code

/// Writes an extension folder: extension.json from `manifest`, the main file from `source`.
private func makeExtension(_ manifest: String, source: String, main: String = "main.js") throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "omc-ext-src-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try manifest.write(to: folder.appending(path: "extension.json"), atomically: true, encoding: .utf8)
    try source.write(to: folder.appending(path: main), atomically: true, encoding: .utf8)
    return folder
}

@MainActor
private func makeStore() -> ExtensionStore {
    let name = "omc-ext-tests-\(UUID().uuidString)"
    return ExtensionStore(directory: FileManager.default.temporaryDirectory.appending(path: name),
                          defaults: UserDefaults(suiteName: name)!)
}

@MainActor
private func eventually(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// A workspace on a fresh folder (with a.txt), its extensions from `store`.
@MainActor
private func makeWorkspace(store: ExtensionStore, files: [String: String] = ["a.txt": "hello world\n"]) throws -> (Workspace, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "omc-ext-ws-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, text) in files { try text.write(to: root.appending(path: name), atomically: true, encoding: .utf8) }
    let workspace = Workspace()
    workspace.extensions.store = store
    workspace.extensions.changeDelay = .milliseconds(10)
    workspace.openFolder(root)
    return (workspace, root)
}

struct ExtensionManifestTests {
    private func manifest(_ json: String, main: String = "main.js", createMain: Bool = true) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json.write(to: folder.appending(path: "extension.json"), atomically: true, encoding: .utf8)
        if createMain { try "".write(to: folder.appending(path: main), atomically: true, encoding: .utf8) }
        return folder
    }

    @Test func readsAndValidatesManifests() throws {
        let good = try manifest("""
        { "id": "acme.count", "name": "Count", "version": "1.0.0", "main": "main.js",
          "activationEvents": ["onLanguage:swift"], "permissions": ["process"],
          "contributes": { "commands": [{ "command": "count.show", "title": "Show", "category": "Count" }],
                           "configuration": { "count.limit": { "type": "number", "default": 3 } } } }
        """)
        let loaded = try ExtensionManifest.load(from: good)
        #expect(loaded.commands.first?.paletteTitle == "Count: Show")
        #expect(loaded.settings["count.limit"]?.default == .number(3))
        #expect(loaded.grantedPermissions == [.process])
        #expect(loaded.activates(onLanguage: "swift") && !loaded.activates(onLanguage: "c") && !loaded.activatesOnStartup)
        #expect(loaded.activates(onCommand: "count.show") && !loaded.activates(onCommand: "other"))

        func error(_ json: String, createMain: Bool = true) throws -> ExtensionManifest.ValidationError? {
            do { _ = try ExtensionManifest.load(from: try manifest(json, createMain: createMain)); return nil }
            catch let error as ExtensionManifest.ValidationError { return error }
        }
        #expect(try error(#"{ "id": "nodot", "name": "x", "version": "1", "main": "main.js" }"#) == .invalidID("nodot"))
        #expect(try error(#"{ "id": "a.b c", "name": "x", "version": "1", "main": "main.js" }"#) == .invalidID("a.b c"))
        #expect(try error(#"{ "id": "a.b", "name": " ", "version": "1", "main": "main.js" }"#) == .emptyField("name"))
        #expect(try error(#"{ "id": "a.b", "name": "x", "version": "1", "main": "../main.js" }"#) == .mainOutside("../main.js"))
        #expect(try error(#"{ "id": "a.b", "name": "x", "version": "1", "main": "main.js" }"#, createMain: false) == .mainMissing("main.js"))
        if case .unreadable = try error(#"{ "id": "a.b" }"#) {} else { Issue.record("a missing field is reported") }
    }

    @Test func parsesStatusTextSymbols() {
        typealias Part = ExtensionStatusItemView.Part
        #expect(ExtensionStatusItemView.parts("$(clock) 3 min") == [Part.symbol("clock"), .text(" 3 min")])
        #expect(ExtensionStatusItemView.parts("a $(x)$(y) b") == [Part.text("a "), .symbol("x"), .symbol("y"), .text(" b")])
        #expect(ExtensionStatusItemView.parts("plain $(") == [Part.text("plain $(")])
    }
}

@MainActor
struct ExtensionHostTests {
    static let basicManifest = """
    { "id": "test.basic", "name": "Basic", "version": "1.0.0", "main": "main.js",
      "activationEvents": ["onStartup"],
      "contributes": {
        "commands": [{ "command": "basic.upper", "title": "Uppercase", "category": "Basic" }],
        "configuration": { "basic.greeting": { "type": "string", "default": "hello" } } } }
    """

    static let basicSource = """
    const omc = require('omc');
    function record(context, event) {
      const events = context.storage.get('events', []);
      events.push(event);
      context.storage.update('events', events);
    }
    exports.activate = (context) => {
      console.log('hello from', context.extensionId);
      const register = (id, fn) => context.subscriptions.push(omc.commands.registerCommand(id, fn));
      register('basic.upper', async () => {
        const editor = omc.window.activeTextEditor;
        if (!editor) return 'no editor';
        const text = editor.document.getText(editor.selection);
        await editor.edit((b) => b.replace(editor.selection, text.toUpperCase()));
        editor.select(new omc.Range(0, 0, 0, 2));
        return editor.document.getText();
      });
      register('basic.ask', async () => {
        const name = await omc.window.showInputBox({ prompt: 'Your name?' });
        const color = await omc.window.showQuickPick(['red', { label: 'green', description: 'like grass' }], { placeHolder: 'Color' });
        const answer = await omc.window.showInformationMessage('Hi ' + name, 'OK', 'Later');
        return { name, color: color.label, answer };
      });
      register('basic.config', async () => {
        const before = omc.workspace.getConfiguration('basic').get('greeting');
        await omc.workspace.getConfiguration('basic').update('greeting', 'hey');
        return [before, omc.workspace.getConfiguration('basic').get('greeting'), omc.workspace.getConfiguration().get('basic.missing', 42)];
      });
      register('basic.status', () => {
        const item = omc.window.createStatusBarItem(omc.StatusBarAlignment.Left, 5);
        item.text = '$(star) 3';
        item.tooltip = 'Stars';
        item.command = 'basic.upper';
        item.show();
      });
      register('basic.timer', () => new Promise((resolve) => setTimeout(() => resolve('fired'), 20)));
      register('basic.events', () => context.storage.get('events', []));
      register('basic.process', () => omc.process.run('echo', ['hi']));
      register('basic.require', () => require('fs'));
      register('basic.throw', () => { throw new Error('boom'); });
      register('basic.outside', () => omc.workspace.fs.readFile('/etc/hosts'));
      register('basic.files', async () => {
        await omc.workspace.fs.writeFile('made.txt', 'made');
        const names = (await omc.workspace.fs.readDirectory('.')).map((e) => e.name);
        return [await omc.workspace.fs.readFile('made.txt'), names, await omc.workspace.fs.exists('nope.txt')];
      });
      register('basic.builtin', () => omc.commands.executeCommand('go.line'));
      register('basic.lines', () => {
        const doc = omc.workspace.textDocuments[0];
        return [doc.fileName, doc.lineCount, doc.lineAt(0).text, omc.workspace.rootPath.length > 0];
      });
      omc.workspace.onDidSaveTextDocument((d) => record(context, 'save:' + d.fileName), null, context.subscriptions);
      omc.workspace.onDidChangeTextDocument((e) => record(context, 'change:' + e.document.fileName), null, context.subscriptions);
      omc.workspace.onDidOpenTextDocument((d) => record(context, 'open:' + d.fileName), null, context.subscriptions);
      omc.window.onDidChangeActiveTextEditor((e) => record(context, 'active:' + (e ? e.document.fileName : 'none')), null, context.subscriptions);
    };
    """

    /// The workspace with the basic extension running, a.txt open in an editor.
    private func makeBasic() async throws -> (Workspace, URL, EditorDocument, EditorController, NSWindow) {
        let store = makeStore()
        try store.install(from: try makeExtension(Self.basicManifest, source: Self.basicSource))
        let (workspace, root) = try makeWorkspace(store: store)
        await workspace.extensions.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "a.txt"))
        let document = try #require(workspace.activeDocument)
        let controller = EditorController(document: document)
        document.editor = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        return (workspace, root, document, controller, window)
    }

    private func run(_ workspace: Workspace, _ id: String) async throws -> JSONValue? {
        try await workspace.extensions.executeCommand(id)
    }

    private func failure(_ workspace: Workspace, _ id: String) async -> String? {
        do { _ = try await workspace.extensions.executeCommand(id); return nil } catch { return error.localizedDescription }
    }

    @Test func runsCommandsThatEditTheActiveEditor() async throws {
        let (workspace, _, document, controller, window) = try await makeBasic()
        let instance = try #require(workspace.extensions.extensions.first)
        #expect(instance.state == .active)
        #expect(try await eventually { instance.log.contains { $0.message == "hello from test.basic" } })

        // The contributed command is in the palette.
        workspace.showPalette(.commands)
        #expect(workspace.palette?.items.contains { $0.title == "Basic: Uppercase" && $0.detail == nil } == true)
        workspace.closePalette()

        controller.textView.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(try await run(workspace, "basic.upper") == .string("HELLO world\n"))
        #expect(document.textStorage.string == "HELLO world\n")
        #expect(controller.textView.selectedRange() == NSRange(location: 0, length: 2))
        // One undo step, named after the extension.
        #expect(document.undoManager.undoActionName == "Basic")

        #expect(try await run(workspace, "basic.lines") == .array([.string("a.txt"), .number(2), .string("HELLO world"), .bool(true)]))
        #expect(try await run(workspace, "basic.timer") == .string("fired"))
        withExtendedLifetime(window) {}
    }

    @Test func asksThroughThePaletteAndNotifications() async throws {
        let (workspace, _, _, _, window) = try await makeBasic()
        let result = Task { try await run(workspace, "basic.ask") }

        #expect(try await eventually { workspace.palette?.mode == .prompt })
        let input = try #require(workspace.palette)
        #expect(input.items.first?.title == "Your name?")
        input.query = "Ann"
        input.acceptSelection()

        #expect(try await eventually { workspace.palette !== input && workspace.palette?.mode == .prompt })
        let pick = try #require(workspace.palette)
        #expect(pick.placeholder == "Color" && pick.items.map(\.title) == ["red", "green"])
        #expect(pick.items[1].detail == "like grass")
        pick.query = "gre"
        #expect(pick.items.map(\.title) == ["green"])
        pick.acceptSelection()

        #expect(try await eventually { workspace.notifications.count == 1 })
        let notification = try #require(workspace.notifications.first)
        #expect(notification.message == "Hi Ann" && notification.items == ["OK", "Later"] && notification.source == "Basic")
        workspace.dismissNotification(notification.id, choosing: "Later")
        #expect(try await result.value == .object(["name": .string("Ann"), "color": .string("green"), "answer": .string("Later")]))
        #expect(workspace.palette == nil && workspace.notifications.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func dismissingPromptsAnswersNothing() async throws {
        let (workspace, _, _, _, window) = try await makeBasic()
        let pick = Task { await workspace.showQuickPick([QuickPickItem(label: "a")], placeholder: nil) }
        #expect(try await eventually { workspace.palette?.mode == .prompt })
        workspace.closePalette()
        #expect(await pick.value == nil)

        // Opening the palette for something else cancels a question too.
        let input = Task { await workspace.showInputBox(prompt: nil, value: "x", placeholder: nil) }
        #expect(try await eventually { workspace.palette?.query == "x" })
        workspace.showPalette(.commands)
        #expect(await input.value == nil && workspace.palette?.mode == .commands)

        // A message without items goes away by itself.
        workspace.notificationDuration = .milliseconds(20)
        #expect(await workspace.notify(.info, "Done", source: nil) == nil)
        #expect(workspace.notifications.isEmpty)
        withExtendedLifetime(window) {}
    }

    @Test func settingsStatusBarFilesAndBuiltInCommands() async throws {
        let (workspace, root, _, _, window) = try await makeBasic()
        #expect(try await run(workspace, "basic.config") == .array([.string("hello"), .string("hey"), .number(42)]))

        _ = try await run(workspace, "basic.status")
        let item = try #require(workspace.extensions.statusItems.first)
        #expect(item.text == "$(star) 3" && item.tooltip == "Stars" && item.command == "basic.upper" && item.isLeft)

        #expect(try await run(workspace, "basic.files") == .array([.string("made"), .array([.string("a.txt"), .string("made.txt")]), .bool(false)]))
        #expect(try String(contentsOf: root.appending(path: "made.txt"), encoding: .utf8) == "made")

        _ = try await run(workspace, "basic.builtin")
        #expect(workspace.palette?.mode == .goToLine)
        withExtendedLifetime(window) {}
    }

    @Test func errorsAndPermissions() async throws {
        let (workspace, _, _, _, window) = try await makeBasic()
        #expect(await failure(workspace, "basic.throw")?.hasPrefix("boom") == true)
        #expect(await failure(workspace, "basic.require")?.contains("Cannot find module 'fs'") == true)
        #expect(await failure(workspace, "basic.process")?.contains("\"process\"") == true)
        #expect(await failure(workspace, "basic.outside")?.contains("outside the open folder") == true)
        #expect(await failure(workspace, "nobody.has.this")?.contains("There's no command") == true)
        // Still running after all that.
        #expect(workspace.extensions.extensions.first?.state == .active)
        #expect(try await run(workspace, "basic.timer") == .string("fired"))
        withExtendedLifetime(window) {}
    }

    @Test func hearsAboutDocumentsAndEditors() async throws {
        let (workspace, root, document, _, window) = try await makeBasic()
        func events() -> [String] { workspace.extensions.store.stored("events", of: "test.basic")?.array?.compactMap(\.string) ?? [] }
        // Editor changes in one run loop turn arrive as one: let this one arrive first.
        #expect(try await eventually { events().contains("active:a.txt") })
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        _ = workspace.save(document)
        try "b\n".write(to: root.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        workspace.open(fileAt: root.appending(path: "b.txt"))
        #expect(try await eventually { (workspace.extensions.store.stored("events", of: "test.basic")?.array?.count ?? 0) >= 6 })
        let events = workspace.extensions.store.stored("events", of: "test.basic")?.array?.compactMap(\.string) ?? []
        #expect(events.contains("change:a.txt") && events.contains("save:a.txt"))
        #expect(events.contains("open:b.txt") && events.contains("active:b.txt"))
        withExtendedLifetime(window) {}
    }

    @Test func disablingStopsTheExtension() async throws {
        let (workspace, _, _, _, window) = try await makeBasic()
        _ = try await run(workspace, "basic.status")
        let host = workspace.extensions
        let instance = try #require(host.extensions.first)
        host.setEnabled(instance, false)
        await host.waitUntilIdle()
        #expect(host.extensions.first?.state == .disabled)
        #expect(host.statusItems.isEmpty && host.paletteCommands.isEmpty)
        #expect(await failure(workspace, "basic.upper")?.contains("There's no command") == true)

        host.setEnabled(try #require(host.extensions.first), true)
        await host.waitUntilIdle()
        #expect(host.extensions.first?.state == .active)
        #expect(try await run(workspace, "basic.timer") == .string("fired"))
        withExtendedLifetime(window) {}
    }

    @Test func activatesWhenNeededAndReportsFailures() async throws {
        let store = makeStore()
        try store.install(from: try makeExtension("""
        { "id": "test.lazy", "name": "Lazy", "version": "1", "main": "main.js",
          "contributes": { "commands": [{ "command": "lazy.hi", "title": "Hi" }] } }
        """, source: """
        exports.activate = () => { require('omc').commands.registerCommand('lazy.hi', (who) => 'hi ' + (who || 'there')); };
        """))
        try store.install(from: try makeExtension("""
        { "id": "test.lang", "name": "Lang", "version": "1", "main": "main.js", "activationEvents": ["onLanguage:swift"] }
        """, source: "exports.activate = () => {};"))
        try store.install(from: try makeExtension("""
        { "id": "test.broken", "name": "Broken", "version": "1", "main": "main.js", "activationEvents": ["onStartup"],
          "contributes": { "commands": [{ "command": "broken.go", "title": "Go" }] } }
        """, source: "exports.activate = () => { this is not javascript"))
        try store.install(from: try makeExtension("""
        { "id": "test.runner", "name": "Runner", "version": "1", "main": "main.js", "permissions": ["process"],
          "contributes": { "commands": [{ "command": "runner.echo", "title": "Echo" }] } }
        """, source: """
        exports.activate = () => {
          require('omc').commands.registerCommand('runner.echo', () => require('omc').process.run('cat', [], { input: 'piped' }));
        };
        """))
        try store.install(from: try makeExtension("""
        { "id": "test.hang", "name": "Hang", "version": "1", "main": "main.js", "activationEvents": ["onStartup"] }
        """, source: "exports.activate = () => new Promise(() => {}); exports.deactivate = () => new Promise(() => {});"))
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-ext-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace()
        workspace.extensions.store = store
        workspace.extensions.activationTimeout = .milliseconds(200)
        workspace.extensions.stopTimeout = .milliseconds(200)
        workspace.openFolder(root)
        await workspace.extensions.waitUntilIdle()
        let host = workspace.extensions
        func state(_ id: String) -> ExtensionInstance.State? { host.extensions.first { $0.id == id }?.state }

        #expect(state("test.lazy") == .inactive && state("test.lang") == .inactive)
        if case .failed = state("test.broken") {} else { Issue.record("a syntax error fails activation") }
        // One that never finishes activating fails instead of holding up the others.
        if case .failed(let message) = state("test.hang") { #expect(message.contains("didn't finish")) }
        else { Issue.record("a hanging activate() fails") }
        #expect(host.extensions.first { $0.id == "test.broken" }?.log.contains { $0.level == "error" } == true)
        #expect(await failure(workspace, "broken.go")?.contains("couldn't start") == true)

        #expect(try await host.executeCommand("lazy.hi", arguments: [.string("Ann")]) == .string("hi Ann"))
        #expect(state("test.lazy") == .active)

        try "let x = 1\n".write(to: root.appending(path: "x.swift"), atomically: true, encoding: .utf8)
        workspace.open(fileAt: root.appending(path: "x.swift"))
        #expect(try await eventually { state("test.lang") == .active })

        let echo = try await host.executeCommand("runner.echo")
        #expect(echo?["code"] == .number(0) && echo?["stdout"] == .string("piped"))

        // Reloading isn't held up by it either.
        host.reload(restart: true)
        await host.waitUntilIdle()
        #expect(try await host.executeCommand("lazy.hi") == .string("hi there"))
        withExtendedLifetime(workspace) {}
    }

    @Test func installsReplacesAndUninstalls() async throws {
        let store = makeStore()
        let (workspace, _) = try makeWorkspace(store: store)
        let source = try makeExtension("""
        { "id": "test.inst", "name": "Inst", "version": "1.0.0", "main": "main.js", "permissions": ["network"],
          "contributes": { "configuration": { "inst.on": { "type": "boolean", "default": true } } } }
        """, source: "exports.activate = () => {};")

        var asked: [(String, Bool)] = []
        workspace.extensionInstallConfirmation = { manifest, replacing in asked.append((manifest.id, replacing)); return false }
        workspace.installExtension(from: source, development: false)
        #expect(store.installed().isEmpty && asked.count == 1 && asked[0] == ("test.inst", false))

        workspace.extensionInstallConfirmation = { manifest, replacing in asked.append((manifest.id, replacing)); return true }
        workspace.installExtension(from: source, development: false)
        #expect(try await eventually { workspace.extensions.extensions.map(\.id) == ["test.inst"] })
        #expect(store.installed().first?.isDevelopment == false)

        // Again: a replacement, here as a development link.
        workspace.installExtension(from: source, development: true)
        #expect(asked.last.map { $0.1 } == true)
        #expect(try await eventually { workspace.extensions.extensions.first?.installed.isDevelopment == true })
        store.setSetting("inst.on", to: .bool(false), of: "test.inst")

        // Not an extension: the error shows.
        workspace.installExtension(from: FileManager.default.temporaryDirectory, development: false)
        #expect(workspace.errorMessage?.contains("extension.json") == true)
        workspace.errorMessage = nil

        workspace.confirmation = { _ in true }
        workspace.uninstallExtension(try #require(workspace.extensions.extensions.first))
        #expect(try await eventually { workspace.extensions.extensions.isEmpty })
        // The link went, not the source; settings were cleared.
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "extension.json").path))
        let manifest = try ExtensionManifest.load(from: source)
        #expect(store.setting("inst.on", of: manifest) == .bool(true))
    }
}

/// The example in ExtensionAPI/examples, as shipped.
@MainActor
struct ExampleExtensionTests {
    @Test func wordCountCountsTheActiveFile() async throws {
        let example = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ExtensionAPI/examples/word-count")
        let store = makeStore()
        try store.install(from: example)
        let (workspace, root) = try makeWorkspace(store: store, files: ["a.txt": "one two three\n"])
        await workspace.extensions.waitUntilIdle()
        #expect(workspace.extensions.extensions.first?.state == .active)
        workspace.open(fileAt: root.appending(path: "a.txt"))
        #expect(try await eventually { workspace.extensions.statusItems.first?.text == "$(text.word.spacing) 3" })
        let document = try #require(workspace.activeDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "zero, ")
        #expect(try await eventually { workspace.extensions.statusItems.first?.text == "$(text.word.spacing) 4" })

        let command = Task { try await workspace.extensions.executeCommand("wordCount.show") }
        #expect(try await eventually { workspace.notifications.first?.message == "4 words in a.txt." })
        workspace.dismissNotification(try #require(workspace.notifications.first).id)
        _ = try await command.value
    }
}

@MainActor
struct ExtensionWatchdogTests {
    @Test func stopsEndlessLoopsAndKeepsTheExtensionRunning() async throws {
        #expect(ExecutionLimit.isAvailable)
        let store = makeStore()
        try store.install(from: try makeExtension("""
        { "id": "test.loop", "name": "Loop", "version": "1", "main": "main.js", "activationEvents": ["onStartup"],
          "contributes": { "commands": [{ "command": "loop.spin", "title": "Spin" }] } }
        """, source: """
        const omc = require('omc');
        exports.activate = () => {
          omc.commands.registerCommand('loop.spin', () => { while (true) {} });
          omc.commands.registerCommand('loop.caught', () => { try { while (true) {} } catch (e) { return 'caught'; } });
          omc.commands.registerCommand('loop.ok', () => 'ok');
          omc.commands.registerCommand('loop.later', () => { setTimeout(() => { while (true) {} }, 0); return 'scheduled'; });
        };
        """))
        try store.install(from: try makeExtension("""
        { "id": "test.loopstart", "name": "Loop Start", "version": "1", "main": "main.js", "activationEvents": ["onStartup"] }
        """, source: "exports.activate = () => { for (;;) {} };"))
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-ext-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace()
        let host = workspace.extensions
        host.store = store
        host.executionTimeLimit = 0.3
        workspace.openFolder(root)
        await host.waitUntilIdle()

        let start = ContinuousClock.now
        do { _ = try await host.executeCommand("loop.spin"); Issue.record("an endless loop is stopped") }
        catch { #expect(error.localizedDescription.contains("endless loop")) }
        #expect(ContinuousClock.now - start < .seconds(3))
        // It can't be caught, and the extension still works afterwards.
        do { _ = try await host.executeCommand("loop.caught"); Issue.record("termination can't be caught") }
        catch { #expect(error.localizedDescription.contains("endless loop")) }
        #expect(try await host.executeCommand("loop.ok") == .string("ok"))

        // In a timer: logged.
        #expect(try await host.executeCommand("loop.later") == .string("scheduled"))
        let loop = try #require(host.extensions.first { $0.id == "test.loop" })
        #expect(try await eventually { loop.log.contains { $0.level == "error" && $0.message.contains("endless loop") } })
        #expect(try await host.executeCommand("loop.ok") == .string("ok") && loop.state == .active)

        // In activate(): the extension fails to start.
        let failed = host.extensions.first { $0.id == "test.loopstart" }?.state
        if case .failed(let message) = failed { #expect(message.contains("endless loop")) } else { Issue.record("activation fails") }
        withExtendedLifetime(workspace) {}
    }
}

private func keyEvent(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, _ characters: String = "") -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

@MainActor
struct ExtensionKeybindingTests {
    @Test func parsesShowsAndMatchesChords() throws {
        let chord = try KeyChord(parsing: "cmd+shift+k")
        #expect(chord.display == "⇧⌘K")
        #expect(chord.matches(keyEvent(40, [.command, .shift], "K")))
        #expect(!chord.matches(keyEvent(40, [.command], "k")))
        #expect(!chord.matches(keyEvent(40, [.command, .shift, .option], "K")))
        #expect(!chord.matches(keyEvent(41, [.command, .shift], ";")))
        // Caps lock and the like don't count.
        #expect(chord.matches(keyEvent(40, [.command, .shift, .capsLock], "K")))
        #expect(try KeyChord(parsing: "ctrl+alt+f5").display == "⌃⌥F5")
        #expect(try KeyChord(parsing: "Cmd+Enter").display == "⌘↩")
        #expect(try KeyChord(parsing: "f12").display == "F12")
        #expect(try KeyChord(parsing: "cmd+.").keyCode == 47)

        #expect(throws: KeyChord.ParseError.needsModifier("shift+a")) { try KeyChord(parsing: "shift+a") }
        #expect(throws: KeyChord.ParseError.unknownModifier("hyper")) { try KeyChord(parsing: "hyper+a") }
        #expect(throws: KeyChord.ParseError.unknownKey("§")) { try KeyChord(parsing: "cmd+§") }
    }

    @Test func findsTheSameShortcutInMenus() throws {
        let menu = NSMenu(), file = NSMenuItem(title: "File", action: nil, keyEquivalent: ""), submenu = NSMenu()
        file.submenu = submenu
        menu.addItem(file)
        submenu.addItem(NSMenuItem(title: "Save", action: nil, keyEquivalent: "s"))
        submenu.addItem(NSMenuItem(title: "Kill", action: nil, keyEquivalent: "K"))
        #expect(try KeyChord(parsing: "cmd+s").menuItem(in: menu)?.title == "Save")
        #expect(try KeyChord(parsing: "cmd+shift+k").menuItem(in: menu)?.title == "Kill")
        #expect(try KeyChord(parsing: "cmd+k").menuItem(in: menu) == nil)
        #expect(try KeyChord(parsing: "cmd+alt+s").menuItem(in: menu) == nil)
    }

    @Test func runsBoundCommandsWhenTheirConditionHolds() async throws {
        let store = makeStore()
        try store.install(from: try makeExtension("""
        { "id": "test.keys", "name": "Keys", "version": "1", "main": "main.js",
          "contributes": {
            "commands": [{ "command": "keys.mark", "title": "Mark" }, { "command": "keys.save", "title": "Save" }],
            "keybindings": [
              { "command": "keys.mark", "key": "cmd+shift+u", "when": "editorTextFocus && editorLangId == plaintext" },
              { "command": "keys.mark", "key": "u" },
              { "command": "keys.save", "key": "cmd+s" } ] } }
        """, source: """
        const omc = require('omc');
        exports.activate = (context) => {
          omc.commands.registerCommand('keys.mark', () => context.storage.update('marks', (context.storage.get('marks', 0)) + 1));
          omc.commands.registerCommand('keys.save', () => context.storage.update('saved', true));
        };
        """))
        let (workspace, root) = try makeWorkspace(store: store)
        await workspace.extensions.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "a.txt"))
        let document = try #require(workspace.activeDocument)
        let controller = EditorController(document: document)
        document.editor = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        let host = workspace.extensions
        let instance = try #require(host.extensions.first)
        // The one without a modifier is refused, with a note in the log.
        #expect(host.keybindings.count == 2)
        #expect(instance.log.contains { $0.message.contains("Keybinding u") })
        #expect(host.shortcut(for: "keys.mark") == "⇧⌘U")
        workspace.showPalette(.commands)
        #expect(workspace.palette?.items.first { $0.title == "Mark" }?.shortcut == "⇧⌘U")
        workspace.closePalette()

        let press = keyEvent(32, [.command, .shift], "U")
        // Not focused in the editor: the condition fails, the key goes on.
        window.makeFirstResponder(nil)
        #expect(!host.handleKeyDown(press, in: window))
        window.makeFirstResponder(controller.textView)
        #expect(host.handleKeyDown(press, in: window))
        #expect(try await eventually { store.stored("marks", of: "test.keys") == .number(1) })
        #expect(instance.state == .active) // activated by its first use

        // ⌘S is the File menu's: it stays Save. (The test host has no menus of its own.)
        let menus = NSApp.mainMenu
        defer { NSApp.mainMenu = menus }
        let menu = NSMenu(), file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu()
        file.submenu?.addItem(NSMenuItem(title: "Save", action: nil, keyEquivalent: "s"))
        menu.addItem(file)
        NSApp.mainMenu = menu
        #expect(!host.handleKeyDown(keyEvent(1, [.command], "s"), in: window))
        #expect(instance.log.contains { $0.message.contains("isn't run") })

        #expect(host.isTrue("!editorTextFocus", in: window) == false)
        #expect(host.isTrue("editorLangId != swift", in: window))
        #expect(!host.isTrue("someUnknownContext", in: window))
        withExtendedLifetime((workspace, window)) {}
    }
}

@MainActor
struct ExtensionScaffoldTests {
    @Test func namesFoldersAndCommands() {
        #expect(ExtensionScaffold.slug("My Tool!") == "my-tool")
        #expect(ExtensionScaffold.slug("  Ünïcode  & Co ") == "unicode-co")
        #expect(ExtensionScaffold.slug("!!!") == "")
        #expect(ExtensionScaffold.camel("my-cool-tool") == "myCoolTool")
        #expect(ExtensionScaffold.typesURL != nil) // bundled with the app
    }

    @Test func createsInstallsAndRunsANewExtension() async throws {
        let store = makeStore()
        let (workspace, _) = try makeWorkspace(store: store)
        let parent = FileManager.default.temporaryDirectory.appending(path: "omc-new-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        workspace.extensionFolderChooser = { parent }
        var opened: [URL] = []
        workspace.openInNewWindow = { opened.append($0) }

        let creating = Task { await workspace.createExtension() }
        #expect(try await eventually { workspace.palette?.mode == .prompt })
        workspace.palette?.query = "My \"Quoted\" Tool"
        workspace.palette?.acceptSelection()
        let folder = try #require(await creating.value)
        #expect(folder.lastPathComponent == "my-quoted-tool" && opened == [folder])
        for file in ["extension.json", "src/extension.ts", "dist/extension.js", "tsconfig.json", "package.json", "omc.d.ts", "README.md"] {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: file).path), "\(file)")
        }
        let manifest = try ExtensionManifest.load(from: folder)
        #expect(manifest.id == "local.my-quoted-tool" && manifest.name == "My \"Quoted\" Tool")
        #expect(manifest.commands.first?.command == "myQuotedTool.helloWorld")

        // Installed as a link, and it runs as written.
        #expect(try await eventually { workspace.extensions.extensions.first?.installed.isDevelopment == true })
        let run = Task { try await workspace.extensions.executeCommand("myQuotedTool.helloWorld") }
        #expect(try await eventually { workspace.notifications.first?.message == "Hello from My \"Quoted\" Tool!" })
        workspace.dismissNotification(try #require(workspace.notifications.first).id)
        _ = try await run.value

        // The same name again: the folder exists.
        let again = Task { await workspace.createExtension() }
        #expect(try await eventually { workspace.palette?.mode == .prompt })
        workspace.palette?.query = "My Quoted Tool"
        workspace.palette?.acceptSelection()
        #expect(await again.value == nil && workspace.errorMessage?.contains("already exists") == true)
    }
}

@MainActor
struct ExtensionLanguageTests {
    static let manifest = """
    { "id": "test.lang", "name": "Lang", "version": "1", "main": "main.js", "activationEvents": ["onLanguage:plaintext"] }
    """
    static let source = """
    const omc = require('omc');
    exports.activate = (context) => {
      const sub = (d) => context.subscriptions.push(d);
      sub(omc.languages.registerCompletionItemProvider('plaintext', {
        provideCompletionItems(document, position, ctx) {
          return [
            { label: 'apple', detail: 'fruit via ' + (ctx.triggerCharacter || 'typing'), kind: omc.CompletionItemKind.Function },
            'banana',
            { label: 'cherry', insertText: 'cherry()', range: new omc.Range(position.line, 0, position.line, position.character) },
          ];
        },
      }, '@'));
      sub(omc.languages.registerCompletionItemProvider({ language: 'swift' }, { provideCompletionItems: () => ['swifty'] }));
      sub(omc.languages.registerCompletionItemProvider('*', { provideCompletionItems: () => { throw new Error('broken provider'); } }));
      sub(omc.languages.registerCompletionItemProvider('*', { provideCompletionItems: () => new Promise(() => {}) }));
      sub(omc.languages.registerHoverProvider('plaintext', {
        provideHover(document, position) {
          const word = document.lineAt(position.line).text.split(' ')[0];
          return { contents: ['**' + word + '**', 'line ' + position.line] };
        },
      }));
      sub(omc.languages.registerDocumentFormattingEditProvider('plaintext', {
        provideDocumentFormattingEdits(document, options) {
          const last = document.lineCount - 1;
          return [{ range: new omc.Range(0, 0, last, document.lineAt(last).text.length),
                    newText: document.getText().toUpperCase() + (options.insertSpaces ? '' : '') }];
        },
      }));
      // Not in subscriptions: the app clears it when the extension stops anyway.
      const loud = omc.languages.createDiagnosticCollection('loud');
      loud.set('a.txt', [{ range: new omc.Range(0, 0, 0, 5), message: 'Too loud', severity: omc.DiagnosticSeverity.Warning }]);
      loud.set('b.txt', [{ range: new omc.Range(0, 0, 0, 1), message: 'Shh' }]);
      sub(omc.commands.registerCommand('lang.quiet', () => loud.delete('a.txt')));
    };
    """

    @Test func providesCompletionHoverFormattingAndDiagnostics() async throws {
        let store = makeStore()
        try store.install(from: try makeExtension(Self.manifest, source: Self.source))
        let (workspace, root) = try makeWorkspace(store: store, files: ["a.txt": "hello world\n", "b.txt": "b\n"])
        let host = workspace.extensions
        host.providerTimeout = .milliseconds(200)
        await host.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "a.txt"))
        let document = try #require(workspace.activeDocument)
        let instance = try #require(host.extensions.first)
        #expect(try await eventually { instance.state == .active })
        #expect(document.languageClient == nil) // no server: the extension alone

        // Completion: the plaintext and "*" providers answer; the broken and silent ones are left out.
        let completions = await host.completions(for: document, at: 5, trigger: "@", firstID: 100)
        #expect(completions.items.map(\.label) == ["apple", "banana", "cherry"])
        #expect(completions.items.map(\.id) == [100, 101, 102])
        #expect(completions.items[0].detail == "fruit via @" && completions.items[0].kind == 3) // Function, as LSP numbers it
        #expect(completions.items[2].insertText == "cherry()" && completions.items[2].editRange?.start.character == 0)
        #expect(host.completionTriggers(for: document) == ["@"])
        #expect(try await eventually { instance.log.contains { $0.message.contains("broken provider") } })
        #expect(instance.log.contains { $0.message.contains("didn't answer") })

        // Hover.
        #expect(await host.hovers(for: document, at: 2) == ["**hello**", "line 0"])

        // Diagnostics: on the open file, and waiting for b.txt until it opens.
        #expect(document.diagnostics.map(\.message) == ["Too loud"] && document.diagnostics.first?.severity == .warning)
        // The Problems panel lists both files, b.txt (an error) first, though b.txt isn't open.
        #expect(workspace.problems.files().map(\.url.lastPathComponent) == ["b.txt", "a.txt"])
        #expect(workspace.problems.errorCount == 1 && workspace.problems.warningCount == 1)
        workspace.open(fileAt: root.appending(path: "b.txt"))
        let other = try #require(workspace.activeDocument)
        #expect(other.diagnostics.map(\.message) == ["Shh"] && other.diagnostics.first?.source == "loud")
        _ = try await host.executeCommand("lang.quiet")
        #expect(document.diagnostics.isEmpty && other.diagnostics.count == 1)
        #expect(workspace.problems.files().map(\.url.lastPathComponent) == ["b.txt"])

        // Formatting goes through the extension, as one undo step.
        #expect(workspace.canFormat(document))
        #expect(try await workspace.format(document))
        #expect(document.textStorage.string == "HELLO WORLD\n")

        // Disabled: its providers and diagnostics go.
        host.setEnabled(instance, false)
        await host.waitUntilIdle()
        #expect(other.diagnostics.isEmpty && !workspace.canFormat(document))
        #expect(workspace.problems.totalCount == 0)
        #expect(await host.completions(for: document, at: 0, trigger: nil, firstID: 0).items.isEmpty)
        withExtendedLifetime(workspace) {}
    }

    @Test func editorsShowExtensionCompletionsAndHovers() async throws {
        let store = makeStore()
        try store.install(from: try makeExtension(Self.manifest, source: Self.source))
        let (workspace, root) = try makeWorkspace(store: store, files: ["a.txt": "hello world\n"])
        workspace.extensions.providerTimeout = .milliseconds(200)
        await workspace.extensions.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "a.txt"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually { workspace.extensions.extensions.first?.state == .active })
        let controller = EditorController(document: document)
        document.editor = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()

        // Typing the trigger character opens the list with the extension's items.
        controller.textView.setSelectedRange(NSRange(location: 12, length: 0))
        document.textStorage.replaceCharacters(in: NSRange(location: 12, length: 0), with: "@")
        controller.textView.setSelectedRange(NSRange(location: 13, length: 0))
        controller.completion.textDidChange(typed: "@")
        #expect(try await eventually { controller.completion.visibleItems.map(\.label) == ["apple", "banana", "cherry"] })
        controller.completion.dismiss()

        #expect(await controller.hover.show(at: 1))
        #expect(controller.hover.shownMarkdown == "**hello**\n\n---\n\nline 0")
        controller.hover.dismiss()
        withExtendedLifetime((workspace, window)) {}
    }
}
