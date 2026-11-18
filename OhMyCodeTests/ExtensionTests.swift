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
                          defaults: ScratchDefaults.named(name))
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
      register('basic.readPath', (path) => omc.workspace.fs.readFile(path));
      register('basic.throughLink', () => omc.workspace.fs.writeFile('link/escaped.txt', 'escaped'));
      register('basic.gitConfig', () => omc.workspace.fs.writeFile('.git/config', '[core]\\n\\tfsmonitor = /tmp/evil'));
      register('basic.gitHook', () => omc.workspace.fs.writeFile('sub/../.GIT/hooks/pre-commit', 'evil'));
      register('basic.gitRead', () => omc.workspace.fs.readFile('.git/HEAD'));
      register('basic.hugeEdit', async () => {
        const editor = omc.window.activeTextEditor;
        await editor.edit((b) => b.replace(new omc.Range(-5, -1e300, 1e300, 1e300), 'X'));
        return editor.document.getText();
      });
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
      register('basic.folders', (path) => [omc.workspace.folders, omc.workspace.getWorkspaceFolder(path) || null, omc.workspace.rootPath]);
      omc.workspace.onDidChangeWorkspaceFolders((e) => record(context, 'folders:' + e.added.map((f) => '+' + f.name + '@' + f.index)
        .concat(e.removed.map((f) => '-' + f.name)).join(',')), null, context.subscriptions);
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

    /// With several folders, files in any of them are inside; others still need the permission.
    @Test func everyWorkspaceFolderIsInside() async throws {
        let (workspace, _, _, _, window) = try await makeBasic()
        let second = FileManager.default.temporaryDirectory.appending(path: "omc-ext-second-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try "second".write(to: second.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let path = JSONValue.string(second.appending(path: "b.txt").path)
        var refused: String?
        do { _ = try await workspace.extensions.executeCommand("basic.readPath", arguments: [path]) } catch { refused = error.localizedDescription }
        #expect(refused?.contains("outside the open folder") == true)
        workspace.addFolder(second)
        #expect(try await workspace.extensions.executeCommand("basic.readPath", arguments: [path]) == .string("second"))
        withExtendedLifetime(window) {}
    }

    /// `omc.workspace.folders`, `getWorkspaceFolder` and `onDidChangeWorkspaceFolders`; relative
    /// paths stay the first folder's, `rootPath` stays the first folder.
    @Test func workspaceFoldersAndTheirChanges() async throws {
        let (workspace, root, _, _, window) = try await makeBasic()
        func events() -> [String] {
            workspace.extensions.store.stored("events", of: "test.basic")?.array?.compactMap(\.string).filter { $0.hasPrefix("folders:") } ?? []
        }
        func folder(_ url: URL, _ name: String, _ index: Int) -> JSONValue {
            .object(["path": .string(url.standardizedFileURL.path), "name": .string(name), "index": .number(Double(index))])
        }
        let first = try #require(workspace.rootURL)
        let firstFolder = folder(first, root.lastPathComponent, 0)
        #expect(try await workspace.extensions.executeCommand("basic.folders", arguments: [.string("a.txt")])
            == .array([.array([firstFolder]), firstFolder, .string(first.path)]))

        let second = FileManager.default.temporaryDirectory.appending(path: "omc-ext-api-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try "second".write(to: second.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        workspace.addFolder(second, name: "API")
        #expect(try await eventually { events() == ["folders:+API@1"] })
        let secondURL = Workspace.folderURL(second)
        let inSecond = JSONValue.string(second.appending(path: "b.txt").path)
        #expect(try await workspace.extensions.executeCommand("basic.folders", arguments: [inSecond])
            == .array([.array([firstFolder, folder(secondURL, "API", 1)]), folder(secondURL, "API", 1), .string(first.path)]))
        // Outside every folder: nothing.
        #expect(try await workspace.extensions.executeCommand("basic.folders", arguments: [.string("/etc/hosts")])?.array?[1] == .null)
        // Relative paths are still the first folder's; absolute ones anywhere inside are inside.
        #expect(try await workspace.extensions.executeCommand("basic.readPath", arguments: [.string("a.txt")]) == .string("hello world\n"))
        #expect(try await workspace.extensions.executeCommand("basic.readPath", arguments: [inSecond]) == .string("second"))

        workspace.removeFolder(secondURL)
        #expect(try await eventually { events() == ["folders:+API@1", "folders:-API"] })
        withExtendedLifetime(window) {}
    }

    /// A link in the folder to a folder outside: a new file through it is outside too.
    @Test func aLinkToOutsideIsOutside() async throws {
        let (workspace, root, _, _, window) = try await makeBasic()
        let outside = FileManager.default.temporaryDirectory.appending(path: "omc-ext-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: outside)
        #expect(await failure(workspace, "basic.throughLink")?.contains("outside the open folder") == true)
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "escaped.txt").path))
        withExtendedLifetime(window) {}
    }

    /// .git/config and .git/hooks name programs git runs: writing them without the fileSystem
    /// permission would let any extension run code, though they're inside the open folder.
    @Test func gitFolderNeedsTheFileSystemPermission() async throws {
        let (workspace, root, _, _, window) = try await makeBasic()
        let git = root.appending(path: ".git")
        try FileManager.default.createDirectory(at: git.appending(path: "hooks"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: git.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        #expect(await failure(workspace, "basic.gitConfig")?.contains("inside .git") == true)
        #expect(await failure(workspace, "basic.gitHook")?.contains("inside .git") == true)
        #expect(!FileManager.default.fileExists(atPath: git.appending(path: "config").path))
        #expect(!FileManager.default.fileExists(atPath: git.appending(path: "hooks/pre-commit").path))
        // Reading is still fine.
        #expect(try await run(workspace, "basic.gitRead") == .string("ref: refs/heads/main\n"))
        // With the permission, the extension may.
        #expect(throws: Never.self) { try ExtensionHost.checkGitWrite(git.appending(path: "config"), permissions: [.fileSystem]) }
        #expect(throws: ExtensionHost.APIError.self) { try ExtensionHost.checkGitWrite(git.appending(path: "config"), permissions: []) }
        withExtendedLifetime(window) {}
    }

    /// Positions far outside the document (or past Int's range) clamp instead of trapping.
    @Test func hugePositionsClamp() async throws {
        let (workspace, _, document, _, window) = try await makeBasic()
        #expect(try await run(workspace, "basic.hugeEdit") == .string("X"))
        #expect(document.textStorage.string == "X")
        #expect(JSONValue.number(1e300).integer == nil && JSONValue.number(.nan).position == nil)
        #expect(JSONValue.number(1e300).position == Int(Int32.max) && JSONValue.number(-1e300).position == -Int(Int32.max))
        #expect(JSONValue.number(3.7).integer == 3 && JSONValue.number(.infinity).integer == nil)
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

// MARK: - Languages

/// A language contributed straight to the registry (no extension), gone after `body`.
@MainActor
private func withLanguage<T>(_ contribution: LanguageContribution, _ body: @MainActor () async throws -> T) async rethrows -> T {
    let owner = "test.registry-\(UUID().uuidString)"
    LanguageRegistry.shared.setContributions([contribution], from: owner)
    defer { LanguageRegistry.shared.setContributions([], from: owner) }
    return try await body()
}

@MainActor
struct LanguageRegistryTests {
    @Test func builtInLanguagesKeepTheirBehavior() {
        #expect(SourceLanguage(fileExtension: "ts") == .typescript && SourceLanguage(fileExtension: "unknownext") == .plaintext)
        #expect(SourceLanguage.swift.lineComment == "//" && SourceLanguage.python.lineComment == "#" && SourceLanguage.sql.lineComment == "--")
        #expect(SourceLanguage.html.lineComment == nil && SourceLanguage.html.blockComment?.start == "<!--")
        #expect(SourceLanguage.tsx.languageId == "typescriptreact" && SourceLanguage.objc.languageId == "objective-c")
        #expect(SourceLanguage(languageId: "shellscript") == .shell && SourceLanguage(languageId: "toy").rawValue == "toy")
        #expect(SourceLanguage.cpp.displayName == "C++" && SourceLanguage(rawValue: "brandnew").displayName == "brandnew")
        // A switch over the open type still reads as it did over the enum.
        let kind = switch SourceLanguage.rust { case .rust: "rust"; default: "other" }
        #expect(kind == "rust")
    }

    @Test func resolvesFilesInOrder() async {
        let tag = UUID().uuidString.prefix(6).lowercased()
        let id = "lang\(tag)"
        await withLanguage(LanguageContribution(id: id, aliases: ["Lang \(tag)"], extensions: [".l\(tag)", ".d.l\(tag)"],
                                                filenames: ["Build\(tag)"], filenamePatterns: ["*.\(tag).conf"],
                                                firstLine: "^#!.*\\bl\(tag)\\b")) {
            let registry = LanguageRegistry.shared
            let mine = SourceLanguage(languageId: id)
            func language(_ name: String, firstLine: String? = nil, _ associations: [String: String] = [:]) -> SourceLanguage {
                registry.language(for: URL(filePath: "/tmp/x/\(name)"), firstLine: firstLine, associations: associations)
            }
            #expect(language("Build\(tag)") == mine)                       // filenames
            #expect(language("app.\(tag).conf") == mine)                    // filenamePatterns
            #expect(language("a.l\(tag)") == mine && language("a.d.l\(tag)") == mine) // extensions
            #expect(language("script", firstLine: "#!/usr/bin/env l\(tag)") == mine)  // firstLine
            #expect(language("script", firstLine: "#!/bin/sh") == .plaintext)
            #expect(language("a.swift") == .swift)                          // built-in
            // files.associations come first: a whole name over a glob.
            #expect(language("a.l\(tag)", ["*.l\(tag)": "python"]) == .python)
            #expect(language("special.l\(tag)", ["*.l\(tag)": "python", "special.l\(tag)": "go"]) == .go)
            #expect(language("a.swift", ["**/x/*.swift": id]) == mine)
            #expect(registry.displayName(for: mine) == "Lang \(tag)" && mine.displayName == "Lang \(tag)")
            #expect(registry.languages.contains { $0.language == mine } && registry.language(named: "lang \(tag)") == mine)
            #expect(SourceLanguage(fileExtension: "l\(tag)") == mine)
        }
        #expect(LanguageRegistry.shared.language(for: URL(filePath: "/tmp/a.l\(tag)")) == .plaintext) // gone with its extension
    }

    @Test func aContributionExtendsABuiltInLanguage() async {
        let ext = "mjsx\(UUID().uuidString.prefix(4).lowercased())"
        await withLanguage(LanguageContribution(id: "javascript", extensions: [".\(ext)"])) {
            #expect(LanguageRegistry.shared.language(for: URL(filePath: "/tmp/a.\(ext)")) == .javascript)
            #expect(SourceLanguage.javascript.displayName == "JavaScript" && SourceLanguage.javascript.lineComment == "//")
        }
    }

    @Test func readsLanguageConfigurations() throws {
        let configuration = try LanguageConfiguration(json: Data(Self.configuration.utf8))
        #expect(configuration.comments?.lineComment == ";;" && configuration.comments?.blockComment?.start == "#|")
        #expect(configuration.brackets?.map(\.open) == ["(", "<"])
        #expect(configuration.autoClosingPairs?.first { $0.open == "\"" }?.notIn == ["string"])
        #expect(configuration.surroundingPairs?.map(\.open) == ["*"] && configuration.autoCloseBefore == " )\n")
        #expect(configuration.onEnterRules?.first?.appendText == ";; " && configuration.onEnterRules?.first?.indent == LanguageConfiguration.OnEnterRule.Indent.none)
        #expect(configuration.indentationRules?.increaseIndent?.matches("x do") == true)
        let markers = try #require(configuration.foldingMarkers)
        let lines = ";; region a\nx\n  ;; region b\ny\n  ;; endregion\n;; endregion\n".split(separator: "\n", omittingEmptySubsequences: false)
        #expect(LanguageConfiguration.markerRegions(markers, lines: lines).map { [$0.start, $0.end] } == [[0, 5], [2, 4]])
        #expect(configuration.wordRange(in: "say foo-bar now", at: 6) == NSRange(location: 4, length: 7))
        #expect(EditorController.context(of: "x \"ab", lineComment: ";;", quotes: ["\""]) == "string")
        #expect(EditorController.context(of: "x ;; \"", lineComment: ";;", quotes: ["\""]) == "comment")
        #expect(EditorController.context(of: "x \"a\" ", lineComment: ";;", quotes: ["\""]) == nil)
    }

    static let configuration = """
    {
      // VS Code's format: comments and trailing commas are fine.
      "comments": { "lineComment": ";;", "blockComment": ["#|", "|#"] },
      "brackets": [["(", ")"], ["<", ">"]],
      "autoClosingPairs": [{ "open": "(", "close": ")" }, ["<", ">"], { "open": "\\"", "close": "\\"", "notIn": ["string"] }],
      "surroundingPairs": [["*", "*"]],
      "autoCloseBefore": " )\\n",
      "folding": { "markers": { "start": "^\\\\s*;;\\\\s*region\\\\b", "end": "^\\\\s*;;\\\\s*endregion\\\\b" } },
      "wordPattern": "[a-z][a-z0-9-]*",
      "indentationRules": { "increaseIndentPattern": "\\\\bdo\\\\s*$", "decreaseIndentPattern": "^\\\\s*end\\\\b" },
      "onEnterRules": [{ "beforeText": "^\\\\s*;;.*$", "action": { "indent": "none", "appendText": ";; " } }],
    }
    """

    /// The configuration's effects in an editor: comments, closing, surrounding, Enter, indentation,
    /// folding and words.
    @Test func configurationDrivesTheEditor() async throws {
        let tag = UUID().uuidString.prefix(6).lowercased()
        var contribution = LanguageContribution(id: "cfg\(tag)", extensions: [".cfg\(tag)"])
        contribution.configuration = try LanguageConfiguration(json: Data(Self.configuration.utf8))
        try await withLanguage(contribution) {
            let wasOn = AppSettings.shared.autoClosePairs
            AppSettings.shared.autoClosePairs = true
            defer { AppSettings.shared.autoClosePairs = wasOn }
            let url = FileManager.default.temporaryDirectory.appending(path: "omc-cfg-\(UUID().uuidString).cfg\(tag)")
            try ";; region top\nkeep it\n;; endregion\n".write(to: url, atomically: true, encoding: .utf8)
            let document = try EditorDocument(url: url)
            #expect(document.language.rawValue == "cfg\(tag)")
            let controller = EditorController(document: document)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = controller.makeView()
            window.makeFirstResponder(controller.textView)
            document.attach(controller)
            document.editor = controller
            let text = { @MainActor in document.textStorage.string }
            @MainActor func set(_ string: String, cursor: Int, length: Int = 0) {
                document.textStorage.replaceCharacters(in: NSRange(location: 0, length: document.textStorage.length), with: string)
                controller.textView.setSelectedRange(NSRange(location: cursor, length: length))
            }
            @MainActor func type(_ keys: String) {
                for key in keys {
                    if key == "\n" {
                        _ = controller.textView.delegate?.textView?(controller.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                    } else {
                        controller.textView.insertText(String(key), replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                }
            }
            @MainActor func state() -> String {
                (text() as NSString).replacingCharacters(in: NSRange(location: controller.textView.selectedRange().location, length: 0), with: "|")
            }

            // Folding markers fold where nothing else has regions.
            document.refreshFoldRegions()
            await document.waitForFoldRegions()
            #expect(document.foldRegions[0]?.end == 2 && document.foldRegions[0]?.kind == .region)

            // Toggle Line Comment uses ";;".
            set("keep it", cursor: 0)
            controller.perform(.toggleComment)
            #expect(text() == ";; keep it")

            // Pairs close themselves; a quote doesn't inside a string; nothing closes before a word.
            set("", cursor: 0)
            type("(<")
            #expect(state() == "(<|>)")
            set("x \"ab", cursor: 5)
            type("\"")
            #expect(text() == "x \"ab\"")
            set("x ", cursor: 2)
            type("\"")
            #expect(state() == "x \"|\"")
            set("word", cursor: 0)
            type("(")
            #expect(state() == "(|word") // "w" isn't in autoCloseBefore
            // A selection is wrapped in a surrounding pair.
            set("word", cursor: 0, length: 4)
            type("*")
            #expect(text() == "*word*")

            // onEnterRules: a comment continues; indentationRules: `do` indents, `end` goes back.
            set(";; note", cursor: 7)
            type("\n")
            #expect(state() == ";; note\n;; |")
            set("run do", cursor: 6)
            type("\n")
            #expect(state() == "run do\n    |")
            type("end")
            #expect(state() == "run do\nend|")

            // The word pattern: dashes are part of words (double-click, completion's prefix).
            set("say foo-bar now", cursor: 6)
            #expect(document.wordRange(at: 6) == NSRange(location: 4, length: 7))
            #expect(controller.textView.selectionRange(forProposedRange: NSRange(location: 6, length: 0), granularity: .selectByWord)
                    == NSRange(location: 4, length: 7))
            // Brackets from the configuration match.
            set("(<a>)", cursor: 0)
            #expect(controller.matchingBracket(at: 1) == 3)
            withExtendedLifetime(window) {}
        }
    }

    @Test func changeLanguageModeAndAssociations() async throws {
        let store = makeStore()
        let (workspace, root) = try makeWorkspace(store: store, files: ["notes.txt": "hi\n", "page.tpl": "<b>\n"])
        workspace.open(fileAt: root.appending(path: "notes.txt"))
        let document = try #require(workspace.activeDocument)
        #expect(document.language == .plaintext)

        // The picker: Auto Detect, then every language by name.
        workspace.changeLanguageMode()
        #expect(try await eventually { workspace.palette?.mode == .prompt })
        let pick = try #require(workspace.palette)
        #expect(pick.items.first?.title == "Auto Detect" && pick.items.contains { $0.title == "Markdown" })
        pick.query = "Markdown"
        pick.acceptSelection()
        #expect(try await eventually { document.language == .markdown })
        // Kept for the file while the window is open: a registry change doesn't undo it.
        workspace.updateLanguageModes()
        #expect(document.language == .markdown)

        // Folder settings' files.associations.
        let settings = root.appending(path: ".omc/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{ "files.associations": { "*.tpl": "html" } }"#.write(to: settings, atomically: true, encoding: .utf8)
        workspace.loadProjectSettings()
        workspace.open(fileAt: root.appending(path: "page.tpl"))
        #expect(workspace.activeDocument?.language == .html)
        withExtendedLifetime(workspace) {}
    }
}

// MARK: - Language providers

@MainActor
struct ExtensionProviderTests {
    /// A language of its own (`toyp`), its snippets, and a provider of every kind.
    static let manifest = """
    { "id": "test.toyp", "name": "Toy Providers", "version": "1", "main": "main.js",
      "contributes": {
        "languages": [{ "id": "toyp", "aliases": ["Toy P"], "extensions": [".toyp"], "configuration": "./config.json" }],
        "snippets": [{ "language": "toyp", "path": "./snippets.json" }],
        "commands": [{ "command": "toyp.count", "title": "Count" }] } }
    """

    static let source = """
    const omc = require('omc');
    exports.activate = (context) => {
      const sub = (d) => context.subscriptions.push(d);
      const sel = { language: 'toyp' };
      const word = (doc, pos) => { const r = doc.getWordRangeAtPosition(pos); return r ? doc.getText(r) : ''; };
      const occurrences = (doc, name) => {
        const found = [];
        for (let i = 0; i < doc.lineCount; i++) {
          const re = new RegExp('\\\\b' + name + '\\\\b', 'g'); const text = doc.lineAt(i).text; let m;
          while ((m = re.exec(text))) found.push(new omc.Range(i, m.index, i, m.index + name.length));
        }
        return found;
      };
      const fnLines = (doc) => { const out = []; for (let i = 0; i < doc.lineCount; i++) { const m = /^fn (\\w+)/.exec(doc.lineAt(i).text); if (m) out.push([i, m[1]]); } return out; };
      sub(omc.commands.registerCommand('toyp.count', (n) => context.storage.update('counted', n)));
      sub(omc.languages.registerDefinitionProvider(sel, { provideDefinition(doc, pos) {
        const hit = fnLines(doc).find(([, name]) => name === word(doc, pos));
        return hit ? new omc.Location(doc.uri, new omc.Range(hit[0], 3, hit[0], 3 + hit[1].length)) : undefined;
      } }));
      sub(omc.languages.registerTypeDefinitionProvider(sel, { provideTypeDefinition: (doc) => [{ targetUri: doc.path, targetRange: new omc.Range(0, 0, 0, 2) }] }));
      sub(omc.languages.registerImplementationProvider(sel, { provideImplementation: (doc) => [new omc.Location(doc.uri, new omc.Position(1, 0)), new omc.Location(doc.uri, new omc.Position(2, 0))] }));
      sub(omc.languages.registerReferenceProvider(sel, { provideReferences: (doc, pos, ctx) => occurrences(doc, word(doc, pos)).map((r) => new omc.Location(doc.uri, r)) }));
      sub(omc.languages.registerDocumentSymbolProvider(sel, { provideDocumentSymbols(doc) {
        return fnLines(doc).map(([line, name]) => {
          const symbol = new omc.DocumentSymbol(name, 'fn', omc.SymbolKind.Function, new omc.Range(line, 0, line, doc.lineAt(line).text.length), new omc.Range(line, 3, line, 3 + name.length));
          symbol.children = [new omc.DocumentSymbol('inner', '', omc.SymbolKind.Variable, new omc.Range(line, 0, line, 1), new omc.Range(line, 0, line, 1))];
          return symbol;
        });
      } }));
      sub(omc.languages.registerWorkspaceSymbolProvider({ provideWorkspaceSymbols: (query) => query === 'zz' ? [] :
        [new omc.SymbolInformation('toypGlobal', omc.SymbolKind.Constant, 'toyp', new omc.Location('main.toyp', new omc.Range(0, 0, 0, 2)))] }));
      sub(omc.languages.registerCodeActionsProvider(sel, { provideCodeActions(doc, range, ctx) {
        const fix = new omc.CodeAction('Remove TODO', omc.CodeActionKind.QuickFix);
        fix.edit = new omc.WorkspaceEdit();
        fix.edit.replace(doc.uri, new omc.Range(range.start.line, 0, range.start.line, 3), 'DONE');
        fix.isPreferred = true;
        fix.diagnostics = ctx.diagnostics;
        return [fix, { title: 'Count Three', command: 'toyp.count', arguments: [3] }];
      } }, { providedCodeActionKinds: [omc.CodeActionKind.QuickFix] }));
      sub(omc.languages.registerCodeLensProvider(sel, {
        provideCodeLenses: (doc) => fnLines(doc).map(([line]) => new omc.CodeLens(new omc.Range(line, 0, line, 2))),
        resolveCodeLens(lens) { lens.command = { title: 'run line ' + lens.range.start.line, command: 'toyp.count', arguments: [lens.range.start.line] }; return lens; },
      }));
      sub(omc.languages.registerSignatureHelpProvider(sel, { provideSignatureHelp(doc, pos, token, ctx) {
        const help = new omc.SignatureHelp();
        const signature = new omc.SignatureInformation('add(a, b)', new omc.MarkdownString('Adds **two**'));
        signature.parameters = [new omc.ParameterInformation('a'), new omc.ParameterInformation('b', 'the second')];
        help.signatures = [signature];
        help.activeParameter = doc.lineAt(pos.line).text.slice(0, pos.character).split(',').length - 1;
        context.storage.update('sigContext', ctx.triggerCharacter || 'none');
        return help;
      } }, { triggerCharacters: ['('], retriggerCharacters: [','] }));
      sub(omc.languages.registerRenameProvider(sel, {
        prepareRename(doc, pos) { const r = doc.getWordRangeAtPosition(pos); if (!r || doc.getText(r) === 'fn') throw new Error('not here'); return { range: r, placeholder: doc.getText(r) }; },
        provideRenameEdits(doc, pos, newName) { const edit = new omc.WorkspaceEdit(); for (const r of occurrences(doc, word(doc, pos))) edit.replace(doc.uri, r, newName); return edit; },
      }));
      sub(omc.languages.registerDocumentHighlightProvider(sel, { provideDocumentHighlights: (doc, pos) =>
        occurrences(doc, word(doc, pos)).map((r, i) => new omc.DocumentHighlight(r, i === 0 ? omc.DocumentHighlightKind.Write : omc.DocumentHighlightKind.Read)) }));
      sub(omc.languages.registerDocumentLinkProvider(sel, {
        provideDocumentLinks(doc) { const out = []; for (let i = 0; i < doc.lineCount; i++) { const at = doc.lineAt(i).text.indexOf('see:'); if (at >= 0) out.push(new omc.DocumentLink(new omc.Range(i, at, i, at + 4))); } return out; },
        resolveDocumentLink(link) { link.target = 'https://example.com/toyp'; return link; },
      }));
      sub(omc.languages.registerFoldingRangeProvider(sel, { provideFoldingRanges: () => [new omc.FoldingRange(0, 2, omc.FoldingRangeKind.Region)] }));
      sub(omc.languages.registerInlayHintsProvider(sel, { provideInlayHints(doc, range) {
        const hints = [];
        for (let i = range.start.line; i <= range.end.line && i < doc.lineCount; i++) {
          const text = doc.lineAt(i).text;
          if (text.startsWith('let ')) { const hint = new omc.InlayHint(new omc.Position(i, text.length), ': num', omc.InlayHintKind.Type); hint.paddingLeft = true; hints.push(hint); }
        }
        return hints;
      } }));
      const legend = new omc.SemanticTokensLegend(['function', 'variable'], []);
      sub(omc.languages.registerDocumentSemanticTokensProvider(sel, { provideDocumentSemanticTokens(doc) {
        const builder = new omc.SemanticTokensBuilder(legend);
        for (const [line, name] of fnLines(doc)) builder.push(new omc.Range(line, 3, line, 3 + name.length), 'function');
        return builder.build();
      } }, legend));
      sub(omc.languages.registerDocumentRangeFormattingEditProvider(sel, { provideDocumentRangeFormattingEdits(doc, range) {
        const edits = [];
        for (let i = range.start.line; i <= range.end.line; i++) { const text = doc.lineAt(i).text; if (text !== text.trim()) edits.push(omc.TextEdit.replace(new omc.Range(i, 0, i, text.length), text.trim())); }
        return edits;
      } }));
      sub(omc.languages.registerOnTypeFormattingEditProvider(sel, { provideOnTypeFormattingEdits: (doc, pos, ch) => [omc.TextEdit.insert(pos, ' ')] }, ';'));
      sub(omc.languages.registerCompletionItemProvider(sel, {
        provideCompletionItems(doc, pos) {
          const item = new omc.CompletionItem('println', omc.CompletionItemKind.Function);
          item.insertText = new omc.SnippetString('println(').appendPlaceholder('value').appendText(')');
          item.commitCharacters = ['('];
          item.command = { title: 'count', command: 'toyp.count', arguments: [7] };
          return [item, { label: 'module', kind: omc.CompletionItemKind.Module, documentation: new omc.MarkdownString('A **module**') }];
        },
        resolveCompletionItem(item) {
          item.documentation = new omc.MarkdownString('docs for ' + item.label);
          item.additionalTextEdits = [omc.TextEdit.insert(new omc.Position(0, 0), 'use io\\n')];
          return item;
        },
      }));
      // Never answers: it hears the cancellation instead.
      sub(omc.languages.registerHoverProvider({ language: 'toyp', pattern: '**/slow.toyp' }, { provideHover: (doc, pos, token) => new Promise((resolve) => {
        token.onCancellationRequested(() => { context.storage.update('cancelled', (context.storage.get('cancelled', 0)) + 1); resolve(undefined); });
      }) }));
    };
    """

    static let text = "fn add do\nlet total = add\nadd TODO see: here\n"

    private func make() async throws -> (Workspace, URL, EditorDocument, ExtensionHost) {
        let store = makeStore()
        let folder = try makeExtension(Self.manifest, source: Self.source)
        try #"{ "comments": { "lineComment": "--" }, "brackets": [["(", ")"]] }"#.write(to: folder.appending(path: "config.json"), atomically: true, encoding: .utf8)
        try #"{ "Loop": { "prefix": ["loop", "lp"], "body": ["loop do", "\t$0", "end"], "description": "A loop" } }"#
            .write(to: folder.appending(path: "snippets.json"), atomically: true, encoding: .utf8)
        try store.install(from: folder)
        let (workspace, root) = try makeWorkspace(store: store, files: ["main.toyp": Self.text, "slow.toyp": "x\n"])
        let host = workspace.extensions
        host.providerTimeout = .milliseconds(300)
        await host.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "main.toyp"))
        let document = try #require(workspace.activeDocument)
        // A file of the language it adds activates it (no activation event needed).
        #expect(try await eventually { host.extensions.first?.state == .active })
        return (workspace, root, document, host)
    }

    @Test func everyProviderKind() async throws {
        let (workspace, _, document, host) = try await make()
        defer { LanguageRegistry.shared.setContributions([], from: "test.toyp") }
        #expect(document.language.rawValue == "toyp" && document.language.displayName == "Toy P" && document.language.lineComment == "--")
        let offset = { (line: Int, character: Int) in document.offset(for: LSPPosition(line: line, character: character)) }

        // Navigation, merged (no server here) and deduplicated.
        let definitions = await workspace.definitions(in: document, at: offset(1, 13))
        #expect(definitions.map(\.range.start.line) == [0] && definitions.first?.range.start.character == 3)
        #expect(await workspace.locations("textDocument/typeDefinition", .typeDefinition, in: document, at: 0).map(\.range.end.character) == [2])
        #expect(await workspace.locations("textDocument/implementation", .implementation, in: document, at: 0).count == 2)
        #expect(try await workspace.references(in: document, at: offset(0, 4)).map(\.range.start.line) == [0, 1, 2])

        // Symbols: the Outline, and Go to Symbol in Workspace.
        document.refreshSymbols()
        await document.waitForSymbols()
        #expect(document.symbols.map(\.name) == ["add"] && document.symbols.first?.children.map(\.name) == ["inner"])
        #expect(await host.workspaceSymbols(query: "toyp").map(\.name) == ["toypGlobal"])

        // Code actions: an edit, and a command that runs in the extension.
        let actions = await workspace.codeActions(for: document, range: NSRange(location: offset(2, 4), length: 0))
        #expect(actions.map(\.title) == ["Remove TODO", "Count Three"] && actions.first?.isQuickFix == true)
        await workspace.run(actions[0], in: document)
        #expect(document.textStorage.string.contains("DONE TODO"))
        await workspace.run(actions[1], in: document)
        #expect(try await eventually { host.store.stored("counted", of: "test.toyp") == .number(3) })
        #expect(await workspace.codeActions(for: document, range: NSRange(location: 0, length: 0), only: ["refactor"]).isEmpty)

        // Code lenses, resolved by the extension.
        let wasShown = AppSettings.shared.showsCodeLens
        AppSettings.shared.showsCodeLens = true
        defer { AppSettings.shared.showsCodeLens = wasShown }
        document.refreshCodeLenses()
        await document.waitForCodeLenses()
        let lens = try #require(document.codeLenses[0]?.first)
        #expect(lens.title == "run line 0")
        workspace.run(lens, in: document)
        #expect(try await eventually { host.store.stored("counted", of: "test.toyp") == .number(0) })

        // Signature help, with the trigger character.
        let help = await host.signatureHelp(for: document, at: offset(0, 3), trigger: "(", isRetrigger: false)
        #expect(help?.signatures.first?.label == "add(a, b)" && help?.signatures.first?.documentation == "Adds **two**", "\(String(describing: help))")
        #expect(help?.signatures.first?.parameters.count == 2 && host.store.stored("sigContext", of: "test.toyp") == .string("("))
        #expect(host.signatureHelpTriggers(for: document) == (open: ["("], update: ["(", ","]))

        // Rename: prepared, then reviewed as one edit.
        #expect(await host.prepareRename(for: document, at: offset(0, 0)) == .invalid)
        #expect(await host.prepareRename(for: document, at: offset(0, 4)) == .range(LSPRange(start: LSPPosition(line: 0, character: 3), end: LSPPosition(line: 0, character: 6)), placeholder: "add"))
        workspace.renamePrompt = { _ in "plus" }
        document.editor = nil
        document.viewState = EditorViewState(topLineOffset: 0, topLineDelta: 0, scrollX: 0, selection: NSRange(location: offset(0, 4), length: 0))
        await workspace.renameSymbol(in: document)?.value
        let preview = try #require(workspace.pendingEdit)
        #expect(preview.title == "Rename “add” to “plus”" && preview.changeCount == 2)
        workspace.pendingEdit = nil

        // Highlights, links (resolved), folding, inlay hints, semantic tokens.
        let highlights = await host.documentHighlights(for: document, at: offset(0, 4))
        #expect(highlights.map(\.kind) == [.write, .read])
        document.refreshLinks()
        await document.waitForLinks()
        let link = try #require(document.serverLinks.first)
        #expect(await host.resolve(link) == URL(string: "https://example.com/toyp"))
        document.refreshFoldRegions()
        await document.waitForFoldRegions()
        #expect(document.foldRegions[0]?.end == 2 && document.foldRegions[0]?.kind == .region)
        let hints = await host.inlayHints(for: document, range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 3, character: 0)))
        #expect(hints.map(\.label) == [": num"] && hints.first?.position.line == 1 && hints.first?.kind == .type)
        let tokens = try #require(await host.semanticTokens(for: document))
        #expect(tokens.map(\.type) == ["function"] && tokens.first?.range == NSRange(location: 3, length: 3))

        // Range and on-type formatting.
        let lines = await host.rangeFormattingEdits(for: document, range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)))
        #expect(lines?.isEmpty == true)
        #expect(host.onTypeFormattingTriggers(for: document) == [";"])
        let typed = await host.onTypeFormattingEdits(for: document, at: 2, character: ";")
        #expect(typed?.first?.text == " " && typed?.first?.range.location == 2)
        #expect(await host.onTypeFormattingEdits(for: document, at: 2, character: "}") == nil)

        // Completion: a snippet, commit characters, a command, Markdown docs, and resolving.
        let completions = await host.completions(for: document, at: 0, trigger: nil, firstID: 0)
        let println = try #require(completions.items.first)
        #expect(println.isSnippet && println.insertText == "println(${1:value})" && println.commitCharacters == ["("])
        #expect(println.kind == 3 && println.origin?.extensionID == "test.toyp" && println.resolvesFromExtension)
        #expect(completions.items[1].documentation == "A **module**")
        let resolved = try #require(await host.resolve(println))
        #expect(resolved.documentation == "docs for println" && resolved.additionalTextEdits.first?.newText == "use io\n")

        // Snippets contributed for the language.
        let snippets = SnippetLibrary.shared.snippets(for: document.languageId, root: nil)
        #expect(snippets.first { $0.name == "Loop" }?.prefixes == ["loop", "lp"] && snippets.first?.body == "loop do\n\t$0\nend")
        #expect(!SnippetLibrary.shared.snippets(for: "swift", root: nil).contains { $0.name == "Loop" })
        withExtendedLifetime(workspace) {}
    }

    @Test func providersAreCancelledWhenNotNeeded() async throws {
        let (workspace, root, _, host) = try await make()
        defer { LanguageRegistry.shared.setContributions([], from: "test.toyp") }
        workspace.open(fileAt: root.appending(path: "slow.toyp"))
        let slow = try #require(workspace.activeDocument)
        func cancelled() -> Int { host.store.stored("cancelled", of: "test.toyp")?.integer ?? 0 }

        // Past the timeout: left out, and its token is cancelled.
        let started = ContinuousClock.now
        #expect(await host.hovers(for: slow, at: 0).isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(try await eventually { cancelled() == 1 })

        // The editor stops waiting (typed on): cancelled at once.
        host.providerTimeout = .seconds(30)
        let asking = Task { await host.hovers(for: slow, at: 0) }
        try await Task.sleep(for: .milliseconds(100))
        asking.cancel()
        #expect(await asking.value.isEmpty)
        #expect(try await eventually { cancelled() == 2 })
        // The pattern in the selector: main.toyp has no hover provider.
        let main = try #require(workspace.documents.first { $0.fileName == "main.toyp" })
        #expect(host.hasProviders(.hover, for: slow) && !host.hasProviders(.hover, for: main))
        withExtendedLifetime(workspace) {}
    }
}

// MARK: - Language servers from extensions

@MainActor
struct ExtensionLanguageServerTests {
    static var fakeServer: String {
        Bundle(for: LanguageServerBundleToken.self).url(forResource: "fake_lsp", withExtension: "py", subdirectory: "Fixtures")!.path
    }

    static func manifest(permissions: String = #"["process"]"#) -> String {
        """
        { "id": "test.toyls", "name": "Toy LS", "version": "1", "main": "main.js", "activationEvents": ["onLanguage:toyls"],
          "permissions": \(permissions),
          "contributes": {
            "languages": [{ "id": "toyls", "extensions": [".toyls"] }, { "id": "toydyn", "extensions": [".toydyn"] }],
            "configuration": { "toyls.level": { "type": "string", "default": "basic" } },
            "languageServers": [{
              "id": "toy-ls", "name": "Toy LS", "languages": ["toyls"], "command": "/usr/bin/python3",
              "args": ["\(fakeServer)", "--extras"], "env": { "TOY": "1" },
              "initializationOptions": { "level": "${config:toyls.level}", "fixed": true },
              "settings": { "toyls": { "level": "${config:toyls.level}", "label": "level ${config:toyls.level}" } }
            }] } }
        """
    }

    static let source = """
    const omc = require('omc');
    exports.activate = (context) => {
      const sub = (d) => context.subscriptions.push(d);
      const server = omc.languages.getLanguageServer('toy-ls');
      sub(server.onNotification('omc/pinged', (params) => context.storage.update('pinged', params.value)));
      sub(server.onRequest('omc/question', (params) => Promise.resolve('blue for ' + params.question)));
      sub(omc.commands.registerCommand('toyls.ping', () => server.sendRequest('omc/ping', { value: 7 })));
      sub(omc.commands.registerCommand('toyls.notify', () => server.sendNotification('omc/notify', { n: 1 })));
      sub(omc.commands.registerCommand('toyls.state', () => server.sendRequest('omc/state')));
      sub(omc.commands.registerCommand('toyls.progress', () => server.sendRequest('omc/progress')));
      sub(omc.commands.registerCommand('toyls.progressEnd', () => server.sendRequest('omc/progressEnd')));
      let dynamic;
      sub(omc.commands.registerCommand('toyls.register', () => {
        dynamic = omc.languages.registerLanguageServer({ id: 'toy-dyn', languages: ['toydyn'], command: '/usr/bin/python3', args: ['\(fakeServer)'] });
      }));
      sub(omc.commands.registerCommand('toyls.unregister', () => dynamic.dispose()));
    };
    """

    private func state(_ workspace: Workspace) async throws -> JSONValue {
        try #require(try await workspace.extensions.executeCommand("toyls.state"))
    }

    @Test func aContributedServerRunsWithItsSettings() async throws {
        let store = makeStore()
        try store.install(from: try makeExtension(Self.manifest(), source: Self.source))
        defer { LanguageRegistry.shared.setContributions([], from: "test.toyls") }
        let (workspace, root) = try makeWorkspace(store: store, files: ["main.toyls": "hello\n", "other.toydyn": "x\n"])
        await workspace.extensions.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "main.toyls"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually(.seconds(10)) { document.languageClient?.state == .ready })
        let client = try #require(document.languageClient)
        #expect(client.serverID == "toy-ls" && client.name == "Toy LS")
        #expect(try await eventually { workspace.extensions.extensions.first?.state == .active })

        // initializationOptions and settings with ${config:…} filled in; sent once it's ready.
        let server = try await state(workspace)
        #expect(server["initializationOptions"] == .object(["level": .string("basic"), "fixed": .bool(true)]))
        #expect(try await eventuallyAsync {
            (try? await self.state(workspace))?["settings"]?.array?.last?["toyls"]?["label"] == .string("level basic")
        })
        // workspace/configuration is answered from the settings, by section.
        _ = try await client.request("omc/askConfiguration", params: ["sections": ["toyls.level", "toyls", "missing"]])
        #expect(try await eventuallyAsync {
            (try? await self.state(workspace))?["answers"]?.object?.values.contains {
                $0 == .array([.string("basic"), .object(["level": .string("basic"), "label": .string("level basic")]), .null])
            } == true
        })
        // A setting change reaches it (workspace/didChangeConfiguration).
        store.setSetting("toyls.level", to: .string("expert"), of: "test.toyls")
        #expect(try await eventuallyAsync {
            (try? await self.state(workspace))?["settings"]?.array?.last?["toyls"]?["level"] == .string("expert")
        })

        // Dynamic registration: it watches *.toy (any change) and *.cfg (deletions only).
        #expect(try await eventually { client.registrations["watch-1"]?.method == "workspace/didChangeWatchedFiles" })
        let created = root.appending(path: "new.toy"), cfg = root.appending(path: "a.cfg")
        try "a".write(to: cfg, atomically: true, encoding: .utf8) // changed, not created or deleted: left out
        workspace.languageServersHear([
            FileWatcher.Event(path: created.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)),
            FileWatcher.Event(path: cfg.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)),
            FileWatcher.Event(path: root.appending(path: "gone.cfg").path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)),
        ])
        #expect(try await eventuallyAsync {
            (try? await self.state(workspace))?["watched"] == .array([.array([.string("new.toy"), .number(3)]), .array([.string("gone.cfg"), .number(3)])])
        })
        try "x".write(to: created, atomically: true, encoding: .utf8)
        workspace.languageServersHear([FileWatcher.Event(path: created.path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))])
        // (The folder's own watcher may report it too.)
        #expect(try await eventuallyAsync {
            (try? await self.state(workspace))?["watched"]?.array?.contains(.array([.string("new.toy"), .number(1)])) == true
        })

        // Its own protocol, both ways: a request, the notification and request it sends back.
        let pong = try #require(try await workspace.extensions.executeCommand("toyls.ping"))
        #expect(pong["pong"] == .number(7))
        let asked = try #require(pong["asked"]?.integer)
        #expect(try await eventually { workspace.extensions.store.stored("pinged", of: "test.toyls") == .number(7) })
        #expect(try await eventuallyAsync { (try? await self.state(workspace))?["answers"]?[String(asked)] == .string("blue for color?") })
        _ = try await workspace.extensions.executeCommand("toyls.notify")
        #expect(try await eventuallyAsync { (try? await self.state(workspace))?["notified"] == .array([.object(["n": .number(1)])]) })

        // Progress in the status bar, and the log (stderr and window/logMessage).
        _ = try await workspace.extensions.executeCommand("toyls.progress")
        #expect(try await eventually { client.progress["work-1"]?.title == "Indexing" && client.progress["work-1"]?.percentage == 10 })
        #expect(try await eventually { client.log.contains("indexing started") && client.log.contains("fake stderr line") })
        _ = try await workspace.extensions.executeCommand("toyls.progressEnd")
        #expect(try await eventually { client.progress.isEmpty })

        // Restart for the user: a new client, the file open in it again.
        workspace.restartLanguageServer(id: "toy-ls")
        #expect(try await eventually(.seconds(10)) { document.languageClient !== client && document.languageClient?.state == .ready })

        // Turned off in the folder's settings: the file has no server.
        let settings = root.appending(path: ".omc/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{ "languageServers.toy-ls.enabled": false }"#.write(to: settings, atomically: true, encoding: .utf8)
        workspace.loadProjectSettings()
        #expect(!workspace.isLanguageServerEnabled("toy-ls", for: document.url))
        #expect(try await eventually { document.languageClient == nil && !workspace.languageClients.values.contains { $0.serverID == "toy-ls" } })
        withExtendedLifetime(workspace) {}
    }

    @Test func registeredFromCodeAndChosenFirst() async throws {
        let store = makeStore()
        try store.install(from: try makeExtension(Self.manifest(), source: Self.source))
        defer { LanguageRegistry.shared.setContributions([], from: "test.toyls") }
        let (workspace, root) = try makeWorkspace(store: store, files: ["main.toyls": "hello\n", "other.toydyn": "x\n"])
        await workspace.extensions.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "main.toyls")) // activates the extension
        #expect(try await eventually { workspace.extensions.extensions.first?.state == .active })
        workspace.open(fileAt: root.appending(path: "other.toydyn"))
        let other = try #require(workspace.activeDocument)
        try await Task.sleep(for: .milliseconds(200))
        #expect(other.languageClient == nil)
        _ = try await workspace.extensions.executeCommand("toyls.register")
        #expect(try await eventually(.seconds(10)) { other.languageClient?.serverID == "toy-dyn" && other.languageClient?.state == .ready })
        _ = try await workspace.extensions.executeCommand("toyls.unregister")
        #expect(try await eventually { other.languageClient == nil && !workspace.languageClients.values.contains { $0.serverID == "toy-dyn" } })

        // Contributed servers come before built-in ones for their languages, unless turned off.
        var contributed = LanguageServerConfig(id: "my-swift", name: "Mine", command: ["/bin/cat"], languages: [.swift])
        contributed.extensionID = "x.y"
        #expect(LanguageServers.config(for: .swift, path: "/usr/bin", contributed: [contributed])?.id == "my-swift")
        #expect(LanguageServers.config(for: .swift, path: "/nonexistent", contributed: [contributed], isEnabled: { $0 != "my-swift" }) == nil)
        withExtendedLifetime(workspace) {}
    }

    @Test func serversNeedTheProcessPermissionAndSubstituteSettings() throws {
        let folder = try makeExtension(Self.manifest(permissions: "[]"), source: "")
        #expect(throws: ExtensionManifest.ValidationError.needsPermission("A language server", .process)) { try ExtensionManifest.load(from: folder) }
        let value = LanguageServerDefinition.substitute(.object(["a": .string("${config:x.n}"), "b": .string("n=${config:x.n}, s=${config:x.s}"),
                                                                 "c": .array([.string("${config:missing}")])]),
                                                        { ["x.n": .number(3), "x.s": .string("hi")][$0] })
        #expect(value == .object(["a": .number(3), "b": .string("n=3, s=hi"), "c": .array([.null])]))
    }
}

private final class LanguageServerBundleToken {}

// MARK: - Merging with a language server

@MainActor
struct ExtensionMergesWithServerTests {
    @Test func extensionAnswersJoinTheServers() async throws {
        let store = makeStore()
        try store.install(from: try makeExtension("""
        { "id": "test.swiftmore", "name": "More Swift", "version": "1", "main": "main.js", "activationEvents": ["onLanguage:swift"] }
        """, source: """
        const omc = require('omc');
        exports.activate = (context) => {
          context.subscriptions.push(omc.languages.registerDefinitionProvider('swift', {
            provideDefinition: (doc) => new omc.Location(doc.path, new omc.Range(1, 0, 1, 4)) }));
          context.subscriptions.push(omc.languages.registerReferenceProvider('swift', {
            provideReferences: (doc) => [new omc.Location(doc.uri, new omc.Range(1, 0, 1, 4))] }));
        };
        """))
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "func target() {}\ntarget()\n".write(to: root.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.extensions.store = store
        workspace.languageServerOverrides[.swift] = LanguageClientTests.fakeServer
        workspace.openFolder(root)
        await workspace.extensions.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "main.swift"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually(.seconds(10)) { document.languageClient?.state == .ready })
        #expect(try await eventually { workspace.extensions.extensions.first?.state == .active })

        // The server's definition first, then the extension's.
        let definitions = await workspace.definitions(in: document, at: document.offset(for: LSPPosition(line: 1, character: 2)))
        #expect(definitions.map(\.range.start.line) == [0, 1])
        let references = try await workspace.references(in: document, at: document.offset(for: LSPPosition(line: 1, character: 2)))
        #expect(references.count >= 2 && references.contains { $0.range.start.line == 1 && $0.range.start.character == 0 })
        withExtendedLifetime(workspace) {}
    }
}

// MARK: - Language Support template

@MainActor
struct LanguageTemplateTests {
    @Test func theTemplateLoadsAndWorks() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "omc-lang-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = try ExtensionScaffold.create(named: "Toy Lang", in: parent, template: .languageSupport)
        for file in ["extension.json", "language-configuration.json", "snippets/toy.json", "src/extension.ts", "dist/extension.js",
                     "sample.toy", "tsconfig.json", "package.json", "omc.d.ts", "README.md"] {
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: file).path), "\(file)")
        }
        let manifest = try ExtensionManifest.load(from: folder)
        #expect(manifest.id == "local.toy-lang" && manifest.name == "Toy Lang" && manifest.languages.first?.id == "toy")

        // Installed, it runs as written: .toy files get its language, configuration and providers.
        let store = makeStore()
        try store.install(from: folder, development: true)
        defer { LanguageRegistry.shared.setContributions([], from: "local.toy-lang") }
        let sample = try String(contentsOf: folder.appending(path: "sample.toy"), encoding: .utf8)
        let (workspace, root) = try makeWorkspace(store: store, files: ["sample.toy": sample])
        await workspace.extensions.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "sample.toy"))
        let document = try #require(workspace.activeDocument)
        let host = workspace.extensions
        #expect(document.language.rawValue == "toy" && document.language.lineComment == "#")
        #expect(try await eventually { host.extensions.first?.state == .active })
        #expect(host.extensions.first?.log.filter { $0.level == "warning" || $0.level == "error" }.isEmpty == true)

        let greetCall = document.offset(for: LSPPosition(line: 10, character: 4))
        #expect(await workspace.definitions(in: document, at: greetCall).first?.range.start == LSPPosition(line: 3, character: 3))
        #expect(await host.hovers(for: document, at: greetCall) == ["\n```toy\nfn greet(name) do\n```\n"])
        #expect(await host.hovers(for: document, at: document.offset(for: LSPPosition(line: 3, character: 0))).first?.hasPrefix("Declares a function") == true)
        let items = await host.completions(for: document, at: 0, trigger: nil, firstID: 0).items
        #expect(items.contains { $0.label == "greet" && $0.insertText == "greet(${1:args})" && $0.isSnippet })
        document.refreshSymbols()
        await document.waitForSymbols()
        #expect(document.symbols.map(\.name) == ["greet", "answer"])
        #expect(SnippetLibrary.shared.snippets(for: "toy", root: nil).contains { $0.prefixes.contains("fn") })
        document.refreshFoldRegions()
        await document.waitForFoldRegions()
        #expect(document.foldRegions[2]?.end == 6) // # region … # endregion
        withExtendedLifetime(workspace) {}
    }
}

@MainActor
private func eventuallyAsync(_ timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now > deadline { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}
