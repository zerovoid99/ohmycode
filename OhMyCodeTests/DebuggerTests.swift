import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
private func eventually(_ timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}

@MainActor
struct BreakpointStoreTests {
    @Test func breakpointsFollowEditsAndPersist() {
        let name = "omc-bp-\(UUID().uuidString)"
        let store = BreakpointStore(defaults: ScratchDefaults.named(name))
        let root = URL(filePath: "/tmp/\(name)")
        store.load(for: root)
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        store.toggle("/f.c", line: 3)
        store.toggle("/f.c", line: 10)
        store.toggle("/f.c", line: 6)
        #expect(store.breakpoints(in: "/f.c").map(\.line) == [3, 6, 10] && changed == ["/f.c", "/f.c", "/f.c"])

        // Two lines inserted before line 6 (zero-based 4..<4 became 2 lines): 6 and 10 move.
        store.linesReplaced(in: "/f.c", 4..<4, with: 2)
        #expect(store.breakpoints(in: "/f.c").map(\.line) == [3, 8, 12])
        // Line 8 (zero-based 7) deleted: its breakpoint goes, 12 moves up.
        store.linesReplaced(in: "/f.c", 7..<8, with: 0)
        #expect(store.breakpoints(in: "/f.c").map(\.line) == [3, 11])
        // Typing within a line moves nothing.
        store.linesReplaced(in: "/f.c", 2..<3, with: 1)
        #expect(store.breakpoints(in: "/f.c").map(\.line) == [3, 11])

        store.setCondition("/f.c", line: 3, "i > 2")
        store.setEnabled("/f.c", line: 11, false)
        store.setVerified([3], for: "/f.c")
        #expect(store.marks(for: "/f.c") == [2: BreakpointMark(isEnabled: true, isVerified: true, hasCondition: true),
                                            10: BreakpointMark(isEnabled: false, isVerified: false, hasCondition: false)])
        store.toggle("/f.c", line: 3)
        #expect(store.breakpoints(in: "/f.c").map(\.line) == [11])

        // Saved per folder.
        let reopened = BreakpointStore(defaults: ScratchDefaults.named(name))
        reopened.load(for: root)
        #expect(reopened.breakpoints(in: "/f.c") == [BreakpointStore.Breakpoint(line: 11, condition: nil, isEnabled: false)])
        reopened.load(for: URL(filePath: "/elsewhere"))
        #expect(reopened.byPath.isEmpty)
    }

    /// With several folders each folder's files' breakpoints are saved under that folder (so it
    /// keeps them opened alone); ones saved under the first folder before that move to theirs.
    @Test func eachFolderKeepsItsBreakpoints() throws {
        let name = "omc-bp-multi-\(UUID().uuidString)"
        let defaults = ScratchDefaults.named(name)
        let base = FileManager.default.temporaryDirectory.appending(path: name)
        let (api, web) = (base.appending(path: "api"), base.appending(path: "web"))
        for folder in [api, web] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let apiFile = FileWatcher.canonicalPath(api) + "/main.c"
        let webFile = FileWatcher.canonicalPath(web) + "/app.c"

        // Saved by 0.2.0 for a two-folder window: everything under the first folder.
        let legacy: [String: [BreakpointStore.Breakpoint]] = [apiFile: [.init(line: 3)], webFile: [.init(line: 7)], "/outside.c": [.init(line: 1)]]
        defaults.set(try JSONEncoder().encode(legacy), forKey: BreakpointStore.key(api))
        let store = BreakpointStore(defaults: defaults)
        store.load(for: [api, web])
        #expect(store.breakpoints(in: apiFile).map(\.line) == [3] && store.breakpoints(in: webFile).map(\.line) == [7])
        #expect(store.breakpoints(in: "/outside.c").map(\.line) == [1])

        // Each folder opened by itself has its own (a file outside stays with the first folder).
        let alone = BreakpointStore(defaults: defaults)
        alone.load(for: web)
        #expect(alone.byPath.keys.sorted() == [webFile])
        alone.load(for: api)
        #expect(alone.byPath.keys.sorted() == ["/outside.c", apiFile])

        // A breakpoint set in a folder opened alone shows in the workspace.
        alone.load(for: web)
        alone.toggle(webFile, line: 9)
        store.load(for: [api, web])
        #expect(store.breakpoints(in: webFile).map(\.line) == [7, 9])

        // Moved to another folder: saved with that one.
        let moved = FileWatcher.canonicalPath(web) + "/main.c"
        store.move(from: apiFile, to: moved)
        alone.load(for: web)
        #expect(alone.breakpoints(in: moved).map(\.line) == [3])
        alone.load(for: api)
        #expect(alone.byPath.keys.sorted() == ["/outside.c"])

        // The folders change: their breakpoints come and go, and the files are announced.
        store.load(for: api)
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        store.setFolders([api, web])
        #expect(Set(changed) == [moved, webFile] && store.breakpoints(in: webFile).map(\.line) == [7, 9])
        changed = []
        store.setFolders([api])
        #expect(Set(changed) == [moved, webFile] && store.breakpoints(in: webFile).isEmpty)
    }

    /// One folder: its saved breakpoints read as before.
    @Test func singleFolderBreakpointsStayWhereTheyWere() throws {
        let name = "omc-bp-single-\(UUID().uuidString)"
        let defaults = ScratchDefaults.named(name)
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = FileWatcher.canonicalPath(root) + "/f.c"
        defaults.set(try JSONEncoder().encode([file: [BreakpointStore.Breakpoint(line: 4, condition: "x > 1")]]),
                     forKey: "breakpoints.\(root.standardizedFileURL.path)")
        let store = BreakpointStore(defaults: defaults)
        store.load(for: root)
        #expect(store.breakpoints(in: file) == [BreakpointStore.Breakpoint(line: 4, condition: "x > 1")])
        store.toggle(file, line: 8)
        let data = try #require(defaults.data(forKey: "breakpoints.\(root.standardizedFileURL.path)"))
        #expect(try JSONDecoder().decode([String: [BreakpointStore.Breakpoint]].self, from: data)[file]?.map(\.line) == [4, 8])
    }

    @Test func documentsMoveTheirBreakpoints() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-bp-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "a\nb\nc\n".write(to: root.appending(path: "f.c"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "f.c"))
        let document = try #require(workspace.activeDocument)
        document.toggleBreakpointAction?(2)
        let path = FileWatcher.canonicalPath(document.url)
        #expect(workspace.breakpoints.breakpoints(in: path).map(\.line) == [3])
        #expect(document.breakpointMarks?() == [2: BreakpointMark(isEnabled: true, isVerified: nil, hasCondition: false)])
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "new\n")
        #expect(workspace.breakpoints.breakpoints(in: path).map(\.line) == [4])
        workspace.breakpoints.removeAll()
    }

    /// Renaming a file (or a folder above it) takes its breakpoints along.
    @Test func renamesTakeBreakpointsAlong() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-bp-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try "a\nb\nc\n".write(to: root.appending(path: "src/f.c"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "src/f.c"))
        let document = try #require(workspace.activeDocument)
        document.toggleBreakpointAction?(1)
        let oldPath = FileWatcher.canonicalPath(document.url)

        let renamed = try #require(await workspace.move(root.appending(path: "src/f.c"), to: root.appending(path: "src/g.c")))
        let newPath = FileWatcher.canonicalPath(renamed)
        #expect(workspace.breakpoints.breakpoints(in: oldPath).isEmpty)
        #expect(workspace.breakpoints.breakpoints(in: newPath).map(\.line) == [2])
        let moved = try #require(workspace.document(matching: renamed))
        #expect(moved.breakpointMarks?().keys.sorted() == [1])

        let folder = try #require(await workspace.move(root.appending(path: "src"), to: root.appending(path: "lib")))
        #expect(workspace.breakpoints.breakpoints(in: FileWatcher.canonicalPath(folder.appending(path: "g.c"))).map(\.line) == [2])
        #expect(workspace.breakpoints.byPath.count == 1)
        workspace.breakpoints.removeAll()
    }
}

struct LaunchConfigurationTests {
    @Test func readsAndFillsInConfigurations() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".omc"), withIntermediateDirectories: true)
        #expect(try LaunchConfiguration.load(in: root).isEmpty)
        try """
        {
          // comments are fine
          "configurations": [
            { "name": "Run", "program": "${workspaceFolder}/bin/${fileBasenameNoExtension}", "args": ["${file}"],
              "env": { "DIR": "${fileDirname}" }, "preLaunch": "  " }
          ]
        }
        """.write(to: root.appending(path: ".omc/launch.json"), atomically: true, encoding: .utf8)
        let configuration = try #require(try LaunchConfiguration.load(in: root).first)
        let file = root.appending(path: "src/tool.c")
        let resolved = configuration.resolved(root: root, file: file)
        #expect(resolved.program == root.path + "/bin/tool")
        #expect(resolved.args == [file.path] && resolved.env == ["DIR": root.path + "/src"])
        #expect(resolved.cwd == root.path && resolved.preLaunch == nil)

        try "{ nope".write(to: root.appending(path: ".omc/launch.json"), atomically: true, encoding: .utf8)
        #expect(throws: LaunchConfiguration.LoadError.self) { try LaunchConfiguration.load(in: root) }
        // The template is valid.
        _ = try LaunchConfiguration.writeTemplate(in: root)
        #expect(try LaunchConfiguration.load(in: root).first?.name == "Debug")
    }
}

/// Debugs a small C program with lldb-dap: breakpoints, stepping, variables, evaluation.
@MainActor
struct DebugSessionTests {
    static let program = """
    #include <stdio.h>
    int add(int a, int b) {
        int sum = a + b;
        return sum;
    }
    int main(void) {
        int x = 2;
        int y = add(x, 3);
        printf("y=%d\\n", y);
        return 0;
    }

    """

    private func makeProject(preLaunch: String = "clang -g -O0 -o prog main.c") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-debug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".omc"), withIntermediateDirectories: true)
        try Self.program.write(to: root.appending(path: "main.c"), atomically: true, encoding: .utf8)
        try """
        { "configurations": [{ "name": "prog", "program": "${workspaceFolder}/prog", "preLaunch": "\(preLaunch)" }] }
        """.write(to: root.appending(path: ".omc/launch.json"), atomically: true, encoding: .utf8)
        return root
    }

    private func variables(_ session: DebugSession) -> [String: String] {
        guard let locals = session.scopes.first, let children = session.children[locals.reference] else { return [:] }
        return Dictionary(children.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func stopsAtBreakpointsStepsAndInspects() async throws {
        let root = try makeProject()
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "main.c"))
        let document = try #require(workspace.activeDocument)
        let path = FileWatcher.canonicalPath(document.url)
        workspace.toggleBreakpoint(in: document, line: 2) // int sum = a + b;
        defer { workspace.breakpoints.removeAll() }

        await workspace.loadLaunchConfigurations()
        #expect(workspace.launchConfigurations.map(\.name) == ["prog"])
        await workspace.startDebugging()
        let session = try #require(workspace.debugSession)
        #expect(workspace.sidebarMode == .debug && workspace.bottomPanel == .debugConsole)

        #expect(try await eventually { session.state == .stopped && !session.frames.isEmpty })
        #expect(session.stopReason == "breakpoint")
        #expect(session.frames.first?.name.contains("add") == true && session.frames.first?.line == 3)
        #expect(session.frames.contains { $0.name.contains("main") && $0.line == 8 })
        #expect(workspace.breakpoints.verified?[path] == [3])
        #expect(document.executionLine == 2)
        #expect(try await eventually { variables(session)["a"] == "2" && variables(session)["b"] == "3" })
        #expect(await session.evaluate("a * 10 + b") == "23")
        // A debugger command after a backtick.
        #expect(await session.evaluate("`frame variable b")?.contains("b = 3") == true)
        #expect(await session.evaluate("nope_not_a_variable") == nil)
        #expect(session.console.last?.kind == .error)
        #expect(session.console.contains { $0.kind == .result && $0.text == "23" })

        session.stepOver()
        #expect(try await eventually { session.state == .stopped && session.frames.first?.line == 4 })
        #expect(try await eventually { variables(session)["sum"] == "5" })
        #expect(document.executionLine == 3)

        session.stepOut()
        #expect(try await eventually { session.state == .stopped && session.frames.first?.name.contains("main") == true })

        // A breakpoint added while paused is sent right away.
        workspace.toggleBreakpoint(in: document, line: 9) // return 0;
        #expect(try await eventually { workspace.breakpoints.verified?[path] == [3, 10] })
        session.resume()
        #expect(try await eventually { session.state == .stopped && session.frames.first?.line == 10 })
        #expect(try await eventually { variables(session)["y"] == "5" })

        session.resume()
        #expect(try await eventually { session.state == .terminated })
        #expect(session.exitCode == 0)
        #expect(session.console.contains { $0.text.contains("y=5") })
        #expect(document.executionLine == nil && workspace.breakpoints.verified == nil)
        withExtendedLifetime(workspace) {}
    }

    @Test func stopsAndReportsFailedBuilds() async throws {
        let root = try makeProject(preLaunch: "clang -o prog missing.c")
        let workspace = Workspace()
        workspace.openFolder(root)
        await workspace.startDebugging()
        let session = try #require(workspace.debugSession)
        #expect(session.state == .terminated)
        #expect(session.console.contains { $0.text.contains("missing.c") })
        #expect(session.console.contains { $0.kind == .error && $0.text.contains("pre-launch command failed") })

        // Running without breakpoints ends by itself; stopping a running one ends it too.
        let fine = try makeProject()
        let other = Workspace()
        other.openFolder(fine)
        await other.startDebugging()
        let run = try #require(other.debugSession)
        #expect(try await eventually { run.state == .terminated })
        #expect(run.exitCode == 0 && run.console.contains { $0.text.contains("y=5") })
        withExtendedLifetime((workspace, other)) {}
    }

    @Test func pausesStopsAndHonorsConditions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-debug-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".omc"), withIntermediateDirectories: true)
        try """
        #include <unistd.h>
        int main(void) {
            for (int i = 0; ; i++) {
                usleep(1000);
            }
        }

        """.write(to: root.appending(path: "loop.c"), atomically: true, encoding: .utf8)
        try """
        { "configurations": [{ "name": "loop", "program": "${workspaceFolder}/loop", "preLaunch": "clang -g -O0 -o loop loop.c" }] }
        """.write(to: root.appending(path: ".omc/launch.json"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "loop.c"))
        let document = try #require(workspace.activeDocument)
        let path = FileWatcher.canonicalPath(document.url)
        workspace.toggleBreakpoint(in: document, line: 3) // usleep(1000);
        workspace.breakpoints.setCondition(path, line: 4, "i == 40")
        defer { workspace.breakpoints.removeAll() }

        await workspace.startDebugging()
        let session = try #require(workspace.debugSession)
        // Only when the condition holds.
        #expect(try await eventually { session.state == .stopped && !session.frames.isEmpty })
        #expect(try await eventually { variables(session)["i"] == "40" })

        // Disabled: it runs on; pause stops it wherever it is.
        workspace.breakpoints.setEnabled(path, line: 4, false)
        try await Task.sleep(for: .milliseconds(300))
        session.resume()
        #expect(try await eventually { session.state == .running })
        try await Task.sleep(for: .milliseconds(200))
        session.pause()
        #expect(try await eventually { session.state == .stopped && session.stopReason == "pause" })
        // Stopped inside usleep: the first frame with source (main) is the one shown.
        #expect(try await eventually { session.frames.first { $0.id == session.selectedFrameID }?.name.contains("main") == true })
        #expect(session.frames.first?.path == nil && document.executionLine == 3)
        #expect(try await eventually { (Int(variables(session)["i"] ?? "") ?? 0) > 40 })

        // Stop ends the program.
        workspace.stopDebugging()
        #expect(try await eventually { session.state == .terminated })
        #expect(document.executionLine == nil)
        withExtendedLifetime(workspace) {}
    }

    @Test func explainsWhenThereIsNothingToDebug() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-debug-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = Workspace()
        workspace.openFolder(root)
        await workspace.startDebugging()
        #expect(workspace.debugSession == nil && workspace.errorMessage?.contains("launch.json") == true)
        workspace.createLaunchFile()
        #expect(workspace.activeDocument?.url.lastPathComponent == "launch.json")
        await workspace.loadLaunchConfigurations()
        #expect(workspace.launchConfigurations.first?.name == "Debug")
    }

    /// An adapter that refuses the launch and never says `initialized` (as lldb-dap does for a
    /// missing program): the session ends with its error instead of starting forever.
    @Test func failedLaunchEndsTheSession() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-debug-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let adapter = folder.appending(path: "adapter.py")
        try """
        import json, sys
        def send(message):
            body = json.dumps(message).encode()
            sys.stdout.buffer.write(b"Content-Length: %d\\r\\n\\r\\n" % len(body) + body)
            sys.stdout.buffer.flush()
        while True:
            length = None
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    sys.exit(0)
                if not line.strip():
                    break
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":")[1])
            request = json.loads(sys.stdin.buffer.read(length))
            reply = {"seq": 0, "type": "response", "request_seq": request["seq"], "command": request["command"], "success": True}
            if request["command"] == "launch":
                reply.update(success=False, message="no such program: /nope")
            send(reply)
        """.write(to: adapter, atomically: true, encoding: .utf8)
        let session = DebugSession(configuration: LaunchConfiguration(name: "x", program: "/nope", cwd: folder.path),
                                   adapter: ["/usr/bin/python3", adapter.path], environment: [:])
        let outcome = try await ExtensionHost.within(.seconds(10)) { @MainActor in
            do { try await session.start(); return "started" } catch { return error.localizedDescription }
        }
        #expect(outcome == "no such program: /nope")
        #expect(session.state == .terminated)
    }
}

/// A Swift package's executable, found, built and debugged without any launch.json.
@MainActor
struct SwiftPackageDebugTests {
    @Test func debugsASwiftPackageExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-swiftpm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Sources/Greeter"), withIntermediateDirectories: true)
        try """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "Greeter", targets: [.executableTarget(name: "Greeter")])

        """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try """
        struct Greeting {
            let name: String
            var count: Int
        }
        var greeting = Greeting(name: "Ann", count: 2)
        greeting.count += 1
        print("Hello, \\(greeting.name) x\\(greeting.count)")

        """.write(to: root.appending(path: "Sources/Greeter/main.swift"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        workspace.openFolder(root)
        await workspace.loadLaunchConfigurations()
        #expect(workspace.launchConfigurations.map(\.name) == ["Debug Greeter"])
        #expect(workspace.launchConfigurations.first?.preLaunch == "swift build --product Greeter")

        workspace.open(fileAt: root.appending(path: "Sources/Greeter/main.swift"))
        let document = try #require(workspace.activeDocument)
        workspace.toggleBreakpoint(in: document, line: 6) // print(…)
        defer { workspace.breakpoints.removeAll() }
        await workspace.startDebugging()
        let session = try #require(workspace.debugSession)
        let deadline = ContinuousClock.now + .seconds(240)
        while !(session.state == .stopped && !session.frames.isEmpty) && session.state != .terminated && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(session.state == .stopped, "\(session.console.suffix(20).map(\.text))")
        #expect(session.frames.first?.line == 7)
        #expect(await session.evaluate("greeting.count") == "3")
        #expect(await session.evaluate("greeting.name")?.contains("Ann") == true)
        session.resume()
        let end = ContinuousClock.now + .seconds(30)
        while session.state != .terminated && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(50)) }
        #expect(session.console.contains { $0.text == "Hello, Ann x3" } && session.exitCode == 0,
                "\(session.state) \(String(describing: session.exitCode)) \(session.console.suffix(8).map { "\($0.kind):\($0.text)" })")
        withExtendedLifetime(workspace) {}
    }
}

/// Watch, set value, logpoints, exception breakpoints, attaching, other adapters.
@MainActor
struct DebuggerMoreTests {
    private func project(_ files: [String: String], configuration: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-debug2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: ".omc"), withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: root.appending(path: name), atomically: true, encoding: .utf8) }
        try "{ \"configurations\": [\(configuration)] }".write(to: root.appending(path: ".omc/launch.json"), atomically: true, encoding: .utf8)
        return root
    }

    private func variables(_ session: DebugSession) -> [String: DebugSession.Variable] {
        guard let locals = session.scopes.first, let children = session.children[locals.reference] else { return [:] }
        return Dictionary(children.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test func watchesSetsValuesAndLogs() async throws {
        let root = try project(["main.c": DebugSessionTests.program],
                               configuration: #"{ "name": "prog", "program": "${workspaceFolder}/prog", "preLaunch": "clang -g -O0 -o prog main.c" }"#)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "main.c"))
        let document = try #require(workspace.activeDocument)
        let path = FileWatcher.canonicalPath(document.url)
        workspace.toggleBreakpoint(in: document, line: 2) // int sum = a + b;
        workspace.toggleBreakpoint(in: document, line: 8) // printf(…)
        workspace.breakpoints.setLogMessage(path, line: 9, "y is {y}, x is {x}")
        #expect(workspace.breakpoints.marks(for: path)[8]?.isLogpoint == true)
        workspace.breakpoints.addWatch("a + b")
        workspace.breakpoints.addWatch("no_such_thing")
        workspace.breakpoints.addWatch("a + b") // once
        #expect(workspace.breakpoints.watches == ["a + b", "no_such_thing"])
        defer { workspace.breakpoints.removeAll(); workspace.breakpoints.removeWatch(at: 1); workspace.breakpoints.removeWatch(at: 0) }

        await workspace.startDebugging()
        let session = try #require(workspace.debugSession)
        #expect(try await eventually { session.state == .stopped && session.watchResults.count == 2 })
        #expect(session.watchResults["a + b"] == .value("5"))
        if case .error = session.watchResults["no_such_thing"] {} else { Issue.record("an unknown name is an error") }
        #expect(session.supportsSetVariable && session.supportsLogPoints)

        // Set a = 10: the variable, and the watch using it, change.
        let a = try #require(variables(session)["a"])
        #expect(try await session.setValue(of: a, to: "10") == "10")
        #expect(variables(session)["a"]?.value == "10" && session.watchResults["a + b"] == .value("13"))
        do { _ = try await session.setValue(of: a, to: "not a number"); Issue.record("a bad value fails") } catch {}

        // A watch added while stopped is evaluated right away.
        workspace.breakpoints.addWatch("a * 2")
        #expect(try await eventually { session.watchResults["a * 2"] == .value("20") })
        workspace.breakpoints.removeWatch(at: 2)

        // The logpoint prints instead of stopping; the program ends with the new value.
        session.resume()
        #expect(try await eventually { session.state == .terminated })
        #expect(session.console.contains { $0.text.contains("y is 13, x is 2") })
        #expect(session.console.contains { $0.text.contains("y=13") })
        withExtendedLifetime(workspace) {}
    }

    @Test func stopsOnThrownExceptionsWhenAsked() async throws {
        let source = """
        #include <stdexcept>
        int risky(int x) {
            if (x > 1) throw std::runtime_error("too big");
            return x;
        }
        int main() {
            try { risky(2); } catch (const std::exception &) { return 3; }
            return 0;
        }

        """
        let root = try project(["main.cpp": source],
                               configuration: #"{ "name": "prog", "program": "${workspaceFolder}/prog", "preLaunch": "clang++ -g -O0 -o prog main.cpp" }"#)
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(workspace.breakpoints.exceptionFilters.map(\.filter).contains("cpp_throw"))

        // Off: the exception is caught and the program ends.
        await workspace.startDebugging()
        let first = try #require(workspace.debugSession)
        #expect(try await eventually { first.state == .terminated } && first.exitCode == 3)

        workspace.breakpoints.setException("cpp_throw", enabled: true)
        defer { workspace.breakpoints.setException("cpp_throw", enabled: false) }
        await workspace.startDebugging()
        let session = try #require(workspace.debugSession)
        #expect(try await eventually { session.state == .stopped && !session.frames.isEmpty })
        #expect(session.stopReason == "exception")
        #expect(session.frames.first { $0.id == session.selectedFrameID }?.name.contains("risky") == true)
        await session.stop()
        withExtendedLifetime(workspace) {}
    }

    @Test func attachesToARunningProcessAndLetsItGo() async throws {
        let source = """
        #include <unistd.h>
        int main(void) {
            for (int i = 0; ; i++) {
                usleep(2000);
            }
        }

        """
        let root = try project(["loop.c": source], configuration: "")
        let build = Process()
        build.executableURL = URL(filePath: "/usr/bin/clang")
        build.arguments = ["-g", "-O0", "-o", root.appending(path: "loop").path, root.appending(path: "loop.c").path]
        try build.run()
        build.waitUntilExit()
        let target = Process()
        target.executableURL = root.appending(path: "loop")
        try target.run()
        defer { if target.isRunning { target.terminate() } }
        let pid = Int(target.processIdentifier)
        #expect(await Workspace.runningProcesses().contains { $0.pid == pid && $0.name == "loop" })

        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "loop.c"))
        let document = try #require(workspace.activeDocument)
        workspace.toggleBreakpoint(in: document, line: 3) // usleep(2000);
        defer { workspace.breakpoints.removeAll() }
        await workspace.startDebugging(LaunchConfiguration(name: "Attach", request: "attach", pid: pid))
        let session = try #require(workspace.debugSession)
        #expect(try await eventually { session.state == .stopped && !session.frames.isEmpty })
        #expect(session.frames.first { $0.id == session.selectedFrameID }?.line == 4)
        #expect(try await eventually { variables(session)["i"] != nil })

        // Stopping detaches: the process keeps running.
        workspace.stopDebugging()
        #expect(try await eventually { session.state == .terminated })
        try await Task.sleep(for: .milliseconds(300))
        #expect(target.isRunning)
        withExtendedLifetime(workspace) {}
    }

    @Test func runsOtherAdaptersAndExplainsBadConfigurations() async throws {
        // Any DAP adapter on stdio: here lldb-dap given as a command, with extra launch arguments.
        let root = try project(["main.c": DebugSessionTests.program], configuration: """
        { "name": "custom", "adapter": ["/usr/bin/xcrun", "lldb-dap"], "program": "${workspaceFolder}/prog",
          "preLaunch": "clang -g -O0 -o prog main.c", "adapterArguments": { "args": ["--custom"] } }
        """)
        let workspace = Workspace()
        workspace.openFolder(root)
        await workspace.startDebugging()
        let session = try #require(workspace.debugSession)
        #expect(try await eventually { session.state == .terminated })
        #expect(session.exitCode == 0 && session.console.contains { $0.text.contains("y=5") })

        let python = LaunchConfiguration(name: "py", type: "python", program: "/tmp/x.py", args: ["1"], cwd: "/tmp")
        #expect(try python.adapterCommand().command == ["/usr/bin/env", "python3", "-m", "debugpy.adapter"])
        let arguments = try python.requestArguments()
        #expect(arguments["program"] == .string("/tmp/x.py") && arguments["console"] == .string("internalConsole"))
        #expect(throws: LaunchConfiguration.ConfigurationError.self) { try LaunchConfiguration(name: "x", type: "cobol").adapterCommand() }
        #expect(throws: LaunchConfiguration.ConfigurationError.self) {
            try LaunchConfiguration(name: "x", type: "python", request: "attach", pid: 1).requestArguments()
        }
        #expect(throws: LaunchConfiguration.ConfigurationError.self) { try LaunchConfiguration(name: "x", request: "attach").requestArguments() }

        await workspace.startDebugging(LaunchConfiguration(name: "bad", type: "cobol", program: "x"))
        #expect(workspace.errorMessage?.contains("cobol") == true && workspace.debugSession?.state == .terminated)
        withExtendedLifetime(workspace) {}
    }

    nonisolated static let hasDebugpy: Bool = {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import debugpy"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    /// Needs debugpy (`pip install debugpy`): skipped without it.
    @Test(.enabled(if: hasDebugpy)) func debugsPythonWithDebugpy() async throws {
        let root = try project(["app.py": "total = 0\nfor n in range(4):\n    total += n\nprint('total', total)\n"],
                               configuration: #"{ "name": "py", "type": "python", "program": "${workspaceFolder}/app.py" }"#)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "app.py"))
        let document = try #require(workspace.activeDocument)
        workspace.toggleBreakpoint(in: document, line: 3)
        defer { workspace.breakpoints.removeAll() }
        await workspace.startDebugging()
        let session = try #require(workspace.debugSession)
        #expect(try await eventually { session.state == .stopped })
        #expect(await session.evaluate("total") == "6")
        await session.stop()
    }
}
