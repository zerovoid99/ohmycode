import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
private func eventually(_ timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}

private func makeFolder(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "omc-tasks-\(UUID().uuidString)")
    for (path, text) in files {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

struct ProblemMatcherTests {
    @Test func readsCompilerToolOutput() throws {
        var matcher = ProblemMatcher(directory: URL(filePath: "/work"))
        matcher.fileExists = { $0.hasPrefix("/work/") || $0.hasPrefix("/abs/") }
        func match(_ line: String) -> ProblemMatcher.Problem? { matcher.match(line) }

        let swift = try #require(match("/work/Sources/App/main.swift:12:7: error: cannot find 'x' in scope"))
        #expect(swift == ProblemMatcher.Problem(url: URL(filePath: "/work/Sources/App/main.swift"), line: 12, column: 7,
                                                severity: .error, message: "cannot find 'x' in scope", code: nil))
        #expect(swift.diagnostic.range.start == LSPPosition(line: 11, character: 6))
        #expect(match("src/a.c:3:1: warning: unused variable 'y' [-Wunused-variable]")?.severity == .warning)
        #expect(match("src/a.c:3: note: declared here")?.column == 1)
        #expect(match("src/a.c:9:2: fatal error: 'z.h' file not found")?.severity == .error)
        // Colored output.
        #expect(match("\u{1B}[1msrc/a.c:4:2: \u{1B}[0;1;31merror: \u{1B}[0mboom\u{1B}[0m")?.message == "boom")

        let ts = try #require(match("src/index.ts(4,10): error TS2304: Cannot find name 'foo'."))
        #expect(ts.line == 4 && ts.column == 10 && ts.code == "TS2304" && ts.diagnostic.message == "Cannot find name 'foo'. [TS2304]")
        #expect(match("src/index.ts:5:1 - warning TS6133: 'a' is declared but never used.")?.severity == .warning)

        // Rust: the location is on a later line.
        #expect(match("error[E0425]: cannot find value `x` in this scope") == nil)
        let rust = try #require(match("  --> src/main.rs:2:13"))
        #expect(rust.line == 2 && rust.column == 13 && rust.code == "E0425" && rust.message == "cannot find value `x` in this scope")
        #expect(match("warning: unused import") == nil)
        #expect(match("") == nil)
        #expect(match("   --> src/lib.rs:1:1")?.severity == .warning)
        #expect(match("error: could not compile `app`") == nil)
        #expect(match("some other line") == nil)
        #expect(match("  --> src/main.rs:9:9") == nil) // the pending message was dropped

        #expect(match("./cmd/main.go:7:2: undefined: foo")?.message == "undefined: foo")
        #expect(match("    calc_test.go:14: got 3, want 4")?.line == 14)
        let lint = try #require(match("/abs/app.js:3:5: 'x' is assigned a value but never used. [Warning/no-unused-vars]"))
        #expect(lint.severity == .warning && lint.code == "no-unused-vars")

        // Ordinary output, and paths that don't exist, are left alone.
        #expect(match("Compiling app v0.1.0 (/work)") == nil)
        #expect(match("/elsewhere/x.c:1:1: error: nope") == nil)
        #expect(match("Build complete! (0.52s)") == nil)
    }
}

struct TaskDefinitionTests {
    @Test func loadsDetectsAndResolvesTasks() throws {
        let root = try makeFolder([
            "Package.swift": "// swift-tools-version:5.9\n",
            "package.json": #"{ "scripts": { "test": "jest", "lint": "eslint ." } }"#,
            "yarn.lock": "",
            "Makefile": "CC := clang\n.PHONY: all clean\nall: app\napp: main.o util.o\n\t$(CC) -o app\n%.o: %.c\n\tcc -c $<\nclean install:\n\trm -f app\n",
        ])
        #expect(TaskDefinition.makeTargets(in: try String(contentsOf: root.appending(path: "Makefile"), encoding: .utf8))
                == ["all", "app", "clean", "install"])
        let detected = TaskDefinition.detect(in: root)
        #expect(detected.map(\.label) == ["swift: build", "swift: test", "yarn: lint", "yarn: test",
                                          "make: all", "make: app", "make: clean", "make: install"])
        #expect(detected.first { $0.label == "yarn: test" }?.group == .test)
        #expect(detected.first { $0.label == "make: all" }?.group == .build && detected.first?.command == "swift build")

        // tasks.json (with comments) comes first; found tasks with the same label are left out.
        try FileManager.default.createDirectory(at: root.appending(path: ".omc"), withIntermediateDirectories: true)
        try """
        {
          // mine
          "tasks": [
            { "label": "swift: build", "command": "swift build -c release", "group": "build", "isDefault": true },
            { "label": "Echo", "command": "echo ${fileBasename} in ${workspaceFolder}", "cwd": "${workspaceFolder}/Sources",
              "env": { "WHERE": "${fileDirname}" }, "problemMatcher": "none" }
          ]
        }
        """.write(to: root.appending(path: TaskDefinition.file), atomically: true, encoding: .utf8)
        let all = try TaskDefinition.all(in: root)
        #expect(all.map(\.label).prefix(3) == ["swift: build", "Echo", "swift: test"])
        #expect(all.count == detected.count + 1 && all[0].command == "swift build -c release")
        let echo = all[1].resolved(root: URL(filePath: "/r"), file: URL(filePath: "/r/src/a.swift"))
        #expect(echo.command == "echo a.swift in /r" && echo.cwd == "/r/Sources" && echo.env == ["WHERE": "/r/src"])
        #expect(!echo.matchesProblems && all[0].matchesProblems)

        try "{ broken".write(to: root.appending(path: TaskDefinition.file), atomically: true, encoding: .utf8)
        #expect(throws: TaskDefinition.LoadError.self) { try TaskDefinition.load(in: root) }

        // The template lists the found tasks, the first of each group the default; it reads back.
        try FileManager.default.removeItem(at: root.appending(path: TaskDefinition.file))
        _ = try TaskDefinition.writeTemplate(in: root, tasks: detected)
        let written = try TaskDefinition.load(in: root)
        #expect(written.map(\.label) == detected.map(\.label))
        #expect(written.filter { $0.isDefault == true }.map(\.label) == ["swift: build", "swift: test"])
        #expect(written.allSatisfy { $0.detail == nil })
    }
}

@MainActor
struct TaskRunTests {
    @Test func runsShowsOutputAndProblems() async throws {
        let root = try makeFolder([
            "src/a.c": "int main() {\n  return x;\n}\n",
            ".omc/tasks.json": """
            { "tasks": [
              { "label": "Build", "group": "build", "isDefault": true,
                "command": "printf 'compiling\\\\r50%%\\\\r100%%\\\\n'; echo 'src/a.c:2:10: error: use of undeclared x' >&2; echo 'src/a.c:2:10: error: use of undeclared x'; printf 'no newline'; exit 3" },
              { "label": "Fixed", "command": "echo ok" }
            ] }
            """,
        ])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.runBuildTask()
        let run = try #require(workspace.taskRuns.first)
        #expect(workspace.bottomPanel == .tasks && workspace.isTerminalVisible && workspace.taskHistory == ["Build"])
        await run.waitUntilEnded()
        #expect(run.state == .failed(3))
        let texts = run.lines.map(\.text)
        #expect(texts.first == "> \(run.task.command)")
        #expect(texts.contains("100%") && texts.contains("no newline"))
        #expect(texts.contains { $0.hasPrefix("✗ Failed with exit code 3") })
        // The error, printed twice, is one problem; both lines link to it.
        #expect(run.problems.count == 1 && run.lines.filter { $0.problem == 0 }.count == 2)

        let url = root.appending(path: "src/a.c")
        #expect(workspace.problems.files().map(\.url.lastPathComponent) == ["a.c"])
        #expect(workspace.problems.files().first?.diagnostics.first?.source == "Build")
        // Opening the line's file: the diagnostic is in the editor too.
        workspace.open(run.problems[0])
        let document = try #require(workspace.activeDocument)
        #expect(document.url.lastPathComponent == "a.c" && document.diagnostics.map(\.message) == ["use of undeclared x"])
        #expect(document.pendingReveal?.location == document.offset(for: LSPPosition(line: 1, character: 9)))
        _ = url

        // Running it again starts over: its old problems go (from the open editor too).
        let again = try #require(workspace.runTask(TaskDefinition(label: "Build", command: "echo fine")))
        #expect(workspace.taskRuns.count == 1 && workspace.problems.totalCount == 0 && document.diagnostics.isEmpty)
        await again.waitUntilEnded()
        #expect(again.state == .succeeded && again.lines.contains { $0.text == "fine" })
        // Closing a run removes it.
        workspace.closeTaskRun(again)
        #expect(workspace.taskRuns.isEmpty)
    }

    @Test func terminatingStopsEverythingItStarted() async throws {
        let root = try makeFolder(["x.txt": ""])
        let workspace = Workspace()
        workspace.openFolder(root)
        // The shell waits on a child that holds the output open: both must go.
        let run = try #require(workspace.runTask(TaskDefinition(label: "Sleep", command: "echo started; sleep 60; echo after")))
        #expect(try await eventually { run.lines.contains { $0.text == "started" } })
        let started = ContinuousClock.now
        workspace.terminateTask(run)
        await run.waitUntilEnded()
        #expect(run.state == .terminated && ContinuousClock.now - started < .seconds(5))
        #expect(!run.lines.contains { $0.text == "after" })
    }

    @Test func endsWhenTheCommandExitsEvenIfSomethingItStartedKeepsTheOutput() async throws {
        let root = try makeFolder(["x.txt": ""])
        let workspace = Workspace()
        workspace.openFolder(root)
        // Like a build service started by a build: it lives on, holding the output open.
        let run = try #require(workspace.runTask(TaskDefinition(label: "Daemon", command: "echo before; sleep 20 & echo after; exit 4")))
        let started = ContinuousClock.now
        await run.waitUntilEnded()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(run.state == .failed(4) && run.lines.map(\.text).contains("before") && run.lines.map(\.text).contains("after"))
    }

    @Test func missingCommandFailsAndEnvironmentApplies() async throws {
        let root = try makeFolder(["x.txt": ""])
        let workspace = Workspace()
        workspace.openFolder(root)
        let run = try #require(workspace.runTask(TaskDefinition(label: "Env", command: "echo \"$GREETING from $(basename \"$PWD\")\"; no-such-command-omc",
                                                                cwd: "${workspaceFolder}", env: ["GREETING": "hi"])))
        await run.waitUntilEnded()
        #expect(run.lines.contains { $0.text == "hi from \(root.lastPathComponent)" })
        #expect(run.state == .failed(127))
    }

    @Test func aQuotedFileNameReachesTheCommandIntact() async throws {
        let root = try makeFolder(["it's $(touch pwned) a.txt": "inside\n"])
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: root.appending(path: "it's $(touch pwned) a.txt"))
        let run = try #require(workspace.runTask(TaskDefinition(label: "Cat", command: "cat ${file}; cat \"${file}\"")))
        await run.waitUntilEnded()
        #expect(run.state == .succeeded && run.lines.filter { $0.text == "inside" }.count == 2)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "pwned").path))
    }

    @Test func terminatingBeforeTheProcessStartsStopsIt() async throws {
        let run = TaskRun(task: TaskDefinition(label: "Late", command: "echo should-not-run"))
        run.terminate()
        #expect(run.state == .terminated)
        run.start(environment: ProcessInfo.processInfo.environment)
        await run.waitUntilEnded()
        #expect(run.state == .terminated && !run.lines.contains { $0.text == "should-not-run" })
    }
}

struct TaskQuotingTests {
    @Test func substitutedValuesStayOneShellWord() throws {
        let task = TaskDefinition(label: "Q", command: #"cat ${file} "${fileBasename}" '${fileDirname}' ${workspaceFolder}/x \${file}"#)
        let resolved = task.resolved(root: URL(filePath: "/r"), file: URL(filePath: "/r/a b/it's $(x).c"))
        #expect(resolved.command == #"cat '/r/a b/it'\''s $(x).c' "it's \$(x).c" '/r/a b' /r/x \${file}"#)
        // Plain values are left as they were.
        let plain = TaskDefinition(label: "P", command: "swiftc ${file}").resolved(root: URL(filePath: "/r"), file: URL(filePath: "/r/a.swift"))
        #expect(plain.command == "swiftc /r/a.swift")
    }
}
