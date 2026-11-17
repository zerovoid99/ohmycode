import AppKit
import Testing
@testable import Oh_My_Code

/// The Agent Client Protocol client against a scripted agent (Fixtures/fake_acp.py).
@MainActor
@Suite(.serialized)
struct AgentClientTests {
    private static var fakeAgent: AgentDefinition {
        let script = Bundle(for: AgentBundleToken.self).url(forResource: "fake_acp", withExtension: "py", subdirectory: "Fixtures")!
        return AgentDefinition(id: UUID(), name: "Fake", command: "/usr/bin/python3 '\(script.path)'")
    }

    private func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func makeWorkspace(_ files: [String: String] = [:]) throws -> (Workspace, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let workspace = Workspace()
        workspace.openFolder(root)
        return (workspace, root.resolvingSymlinksInPath())
    }

    private func start(_ workspace: Workspace, root: URL, environment: [String: String] = [:]) async throws -> AgentClient {
        var definition = Self.fakeAgent
        definition.environment = environment.map { "\($0.key)=\($0.value)" }
        let client = AgentClient(definition: definition, rootURL: root, host: workspace)
        await client.start(environment: ProcessInfo.processInfo.environment)
        return client
    }

    private func messages(_ client: AgentClient) -> [String] {
        client.entries.compactMap { if case .message(let text) = $0.kind { text } else { nil } }
    }

    @Test func startsASessionAndStreamsTheReply() async throws {
        let (workspace, root) = try makeWorkspace()
        let client = try await start(workspace, root: root)
        defer { client.stop() }
        #expect(client.state == .ready)
        #expect(client.agentTitle == "Fake Agent 1.0")
        #expect(client.modes.map(\.id) == ["default", "plan"] && client.currentModeID == "default")
        #expect(try await eventually { client.commands.map(\.name) == ["review"] })

        await client.send("hello")
        #expect(client.state == .ready)
        // The two chunks make one message, after the user's.
        #expect(messages(client) == ["Hello there"])
        if case .user(let text, _) = client.entries.first?.kind { #expect(text == "hello") } else { Issue.record("no user entry") }
        #expect(client.plan.map(\.status) == ["completed", "pending"])
        #expect(client.log.contains("fake-acp started"))

        client.setMode("plan")
        #expect(try await eventually { client.currentModeID == "plan" })
    }

    @Test func readsTheEditorsTextAndOnlyInsideTheFolder() async throws {
        let (workspace, root) = try makeWorkspace(["a.txt": "on disk\n"])
        let file = root.appending(path: "a.txt")
        workspace.open(fileAt: file)
        let document = try #require(workspace.document(matching: file))
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 7), with: "unsaved")
        let client = try await start(workspace, root: root)
        defer { client.stop() }

        await client.send("read \(file.path)")
        #expect(messages(client).last == "read: unsaved\n")
        await client.send("read /etc/hosts")
        #expect(messages(client).last?.contains("outside the workspace") == true)
        await client.send("read \(root.path)/../outside.txt")
        #expect(messages(client).last?.contains("outside the workspace") == true)
    }

    @Test func writesOnlyWhenAllowed() async throws {
        let (workspace, root) = try makeWorkspace(["b.txt": "old\n"])
        let open = root.appending(path: "b.txt"), new = root.appending(path: "dir/new.txt")
        workspace.open(fileAt: open)
        let client = try await start(workspace, root: root)
        defer { client.stop() }

        // Rejected: nothing written.
        let rejected = Task { await client.send("write \(open.path) rejected") }
        #expect(try await eventually { client.permissions.count == 1 })
        let permission = try #require(client.permissions.first)
        #expect(permission.title == "Edit b.txt")
        #expect(permission.content == [.diff(path: open.path, old: nil, new: "rejected")])
        client.respond(to: permission, with: try #require(permission.options.first { !$0.allows }))
        await rejected.value
        #expect(messages(client).last == "rejected")
        #expect(try String(contentsOf: open, encoding: .utf8) == "old\n")

        // Allowed: the open document gets the text (one undo step) and is saved; a new file is made.
        let allowed = Task { await client.send("write \(open.path) new text") }
        #expect(try await eventually { !client.permissions.isEmpty })
        client.respond(to: client.permissions[0], with: client.permissions[0].options[0])
        await allowed.value
        #expect(messages(client).last == "wrote")
        let document = try #require(workspace.document(matching: open))
        #expect(document.textStorage.string == "new text" && !document.isDirty)
        #expect(try String(contentsOf: open, encoding: .utf8) == "new text")
        #expect(document.undoManager.canUndo)

        let created = Task { await client.send("write \(new.path) fresh") }
        #expect(try await eventually { !client.permissions.isEmpty })
        client.respond(to: client.permissions[0], with: client.permissions[0].options[0])
        await created.value
        #expect(try String(contentsOf: new, encoding: .utf8) == "fresh")
        // The tool call ended completed, with its diff and location.
        let calls = client.entries.compactMap { if case .tool(let call) = $0.kind { call } else { nil } }
        #expect(calls.last?.status == .completed && calls.last?.locations.first?.line == 1)
    }

    @Test func runsCommandsForTheAgent() async throws {
        let (workspace, root) = try makeWorkspace()
        let client = try await start(workspace, root: root)
        defer { client.stop() }
        await client.send("run")
        #expect(messages(client).last == "exit 3: out|err|")
        // Released, but still shown where the conversation has it.
        let call = client.entries.compactMap { if case .tool(let call) = $0.kind { call } else { nil } }.last
        guard case .terminal(let id) = call?.content.first else { Issue.record("no terminal"); return }
        #expect(client.terminal(id: id)?.exitStatus == AgentTerminal.ExitStatus(exitCode: 3, signal: nil))
    }

    @Test func stoppingATurnCancelsItAndWhatItAsks() async throws {
        let (workspace, root) = try makeWorkspace(["c.txt": "c\n"])
        let client = try await start(workspace, root: root)
        defer { client.stop() }

        let waiting = Task { await client.send("wait") }
        #expect(try await eventually { messages(client).last == "waiting" })
        client.cancel()
        await waiting.value
        #expect(client.state == .ready)
        if case .notice(let text) = client.entries.last?.kind { #expect(text == "Stopped.") } else { Issue.record("no notice") }

        // A question pending when the turn stops is answered "cancelled".
        let file = root.appending(path: "c.txt")
        let asking = Task { await client.send("write \(file.path) x") }
        #expect(try await eventually { !client.permissions.isEmpty })
        client.cancel()
        await asking.value
        #expect(client.permissions.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "c\n")
    }

    @Test func signsInWhenTheAgentAsks() async throws {
        let (workspace, root) = try makeWorkspace()
        let client = try await start(workspace, root: root, environment: ["FAKE_ACP_AUTH": "1"])
        defer { client.stop() }
        #expect(client.state == .needsAuthentication)
        let method = try #require(client.authMethods.first)
        #expect(method.name == "Use a token")
        await client.authenticate(method)
        #expect(client.state == .ready)
    }

    @Test func aMissingCommandSaysSo() async throws {
        let (workspace, root) = try makeWorkspace()
        let client = AgentClient(definition: AgentDefinition(id: UUID(), name: "Nope", command: "omc-no-such-agent --acp"),
                                 rootURL: root, host: workspace)
        await client.start(environment: ["PATH": "/usr/bin:/bin"])
        guard case .failed(let message) = client.state else { Issue.record("started"); return }
        #expect(message.contains("omc-no-such-agent wasn't found"))
    }

    @Test func attachmentsGoAsEmbeddedText() async throws {
        let (workspace, root) = try makeWorkspace(["d.swift": "one\ntwo\nthree\n"])
        let file = root.appending(path: "d.swift")
        let client = try await start(workspace, root: root)
        defer { client.stop() }
        await client.send("hello", attachments: [AgentAttachment(url: file, lines: 2...3, text: "two\nthree")])
        #expect(messages(client).first == "attached: \(file.absoluteString)#L2-3\nHello there")
        if case .user(_, let attachments) = client.entries.first?.kind { #expect(attachments == ["d.swift:2-3"]) }
    }

    @Test func changesTheSessionsSettings() async throws {
        let (workspace, root) = try makeWorkspace()
        let client = try await start(workspace, root: root)
        defer { client.stop() }
        // The slider is a type this editor doesn't know: left out. The boolean is there because
        // the editor said it takes booleans.
        #expect(client.configOptions.map(\.id) == ["model", "fast"])
        let model = try #require(client.configOptions.first)
        guard case .select(let current, let choices) = model.kind else { Issue.record("not a select"); return }
        #expect(current == "sonnet" && model.currentName == "Sonnet" && model.category == "model")
        #expect(choices.map(\.value) == ["sonnet", "opus", "small"])
        #expect(choices.map(\.group) == ["Claude", "Claude", "Other"])

        client.setConfigOption("model", to: "opus")
        #expect(client.configOptions.first?.currentName == "Opus") // at once
        client.setConfigOption("fast", to: true)
        await client.send("config")
        #expect(messages(client).last == "model=opus fast=True")
        #expect(client.configOptions.last?.kind == .boolean(true))

        // Refused: back to what it was, and said.
        client.setConfigOption("model", to: "huge")
        #expect(try await eventually { client.configOptions.first?.currentName == "Opus" })
        #expect(try await eventually {
            if case .notice(let text) = client.entries.last?.kind { text.contains("No such model") } else { false }
        })
    }

    @Test(arguments: [true, false])
    func reopensEarlierSessions(agentLists: Bool) async throws {
        let (workspace, root) = try makeWorkspace()
        let client = try await start(workspace, root: root, environment: [agentLists ? "FAKE_ACP_LIST" : "FAKE_ACP_LOAD": "1"])
        client.historyDefaults.removeObject(forKey: "agents.sessionHistory")
        defer { client.stop() }
        #expect(client.canLoadSessions && client.canListSessions == agentLists)
        await client.send("hello")
        await client.newSession()
        await client.send("config")
        // The other session is listed (by the agent, or from this editor's own history).
        #expect(try await eventually { client.recentSessions.map(\.title) == ["hello"] })

        let earlier = try #require(client.recentSessions.first)
        await client.loadSession(earlier)
        #expect(client.state == .ready)
        // Replayed: the user's message in one entry (it came in pieces), then the reply.
        if case .user(let text, _) = client.entries.first?.kind { #expect(text == "hello") } else { Issue.record("no user entry") }
        #expect(client.entries.count == 2 && messages(client) == ["Hello there"])
        // Prompts go to the reopened session.
        await client.send("config")
        #expect(messages(client).last?.hasPrefix("model=") == true)
        #expect(try await eventually { client.recentSessions.map(\.title) == ["config"] })
    }

    @Test func markdownBlocks() {
        let text = """
        # Plan
        Some **bold** text
        on two lines.

        - one
          - nested
        - [x] done
        2. second
        > quoted
        ---
        | a | b |
        |---|---|
        ```swift
        let x = 1
        ```
        ```
        still streaming
        """
        #expect(AgentMarkdown.blocks(text) == [
            .heading(level: 1, text: "Plan"),
            .paragraph("Some **bold** text\non two lines."),
            .listItem(marker: "•", depth: 0, text: "one"),
            .listItem(marker: "•", depth: 1, text: "nested"),
            .listItem(marker: "☑", depth: 0, text: "done"),
            .listItem(marker: "2.", depth: 0, text: "second"),
            .quote("quoted"),
            .rule,
            .table("| a | b |\n|---|---|"),
            .code(language: "swift", text: "let x = 1"),
            .code(language: nil, text: "still streaming"),
        ])
        #expect(AgentMarkdown.blocks("#hashtag and 1.5 apples") == [.paragraph("#hashtag and 1.5 apples")])
    }

    @Test func commandLinesSplitLikeAShell() {
        #expect(AgentDefinition.words("npx -y @scope/pkg") == ["npx", "-y", "@scope/pkg"])
        #expect(AgentDefinition.words("'/path with/space' \"a b\" c\\ d ''") == ["/path with/space", "a b", "c d", ""])
        #expect(AgentDefinition(id: UUID(), name: "", command: "", environment: ["A=1", "B = x=y", "bad"]).environmentVariables == ["A": "1", "B": " x=y"])
    }
}

private final class AgentBundleToken {}
