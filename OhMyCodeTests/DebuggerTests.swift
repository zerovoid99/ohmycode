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
        let store = BreakpointStore(defaults: UserDefaults(suiteName: name)!)
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
        let reopened = BreakpointStore(defaults: UserDefaults(suiteName: name)!)
        reopened.load(for: root)
        #expect(reopened.breakpoints(in: "/f.c") == [BreakpointStore.Breakpoint(line: 11, condition: nil, isEnabled: false)])
        reopened.load(for: URL(filePath: "/elsewhere"))
        #expect(reopened.byPath.isEmpty)
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
