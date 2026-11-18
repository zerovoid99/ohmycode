import AppKit
import Observation

/// The Agent sidebar of one window: which agent, its conversation, and the prompt being written.
@MainActor
@Observable
final class AgentPanel {
    @ObservationIgnored private weak var workspace: Workspace?
    /// Where the chosen agent is kept: under tests a scratch store (the test host is the app).
    @ObservationIgnored private let defaults: UserDefaults = AppSettings.isRunningTests
        ? ScratchDefaults.named("dev.zerovoid99.ohmycode.tests.agentPanel") : .omc
    /// The running agent (nil until one is started).
    private(set) var client: AgentClient?
    var selectedAgentID: AgentDefinition.ID? {
        didSet { defaults.set(selectedAgentID?.uuidString, forKey: Self.selectedKey) }
    }
    var draft = ""
    /// The agent's log is shown (from the panel's menu, or its failure).
    var showsLog = false
    var attachments: [AgentAttachment] = []

    private static let selectedKey = "agents.selected"

    init(workspace: Workspace) {
        self.workspace = workspace
        selectedAgentID = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:))
    }

    var selectedAgent: AgentDefinition? { AgentStore.shared.definition(id: selectedAgentID) }

    /// Another agent is picked than the one running (it starts on New Thread, or Restart).
    var selectionDiffersFromRunning: Bool {
        guard let client, let selectedAgent else { return false }
        return client.definition.id != selectedAgent.id
    }

    /// The draft (or what's attached) can go now.
    var canSend: Bool {
        client?.state == .ready
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    /// Starts the selected agent (stopping one that runs) in the workspace folder.
    func start() {
        guard let workspace, let root = workspace.rootURL, let definition = selectedAgent else { return }
        client?.stop()
        let client = AgentClient(definition: definition, rootURL: root, host: workspace)
        self.client = client
        Task {
            let environment = await ShellEnvironment.shared.environment()
            guard self.client === client else { return }
            await client.start(environment: environment)
        }
    }

    /// A fresh conversation: with the running agent, or by starting it.
    func newThread() {
        guard let client, client.definition.id == selectedAgent?.id, client.state == .ready || client.state == .working else {
            return start()
        }
        Task { await client.newSession() }
    }

    func stop() {
        client?.stop()
        client = nil
    }

    /// Sends the draft and the attachments.
    func send() {
        // Not ready (starting, working, signing in): the draft stays, to send later.
        guard let client, canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = attachments
        draft = ""
        attachments = []
        Task { await client.send(text, attachments: attached) }
    }

    /// Attaches the active editor's selection (or its whole file, with nothing selected).
    func attachSelection() {
        guard let workspace, let document = workspace.activeDocument else { NSSound.beep(); return }
        let text = document.textStorage.mutableString
        var range = document.editor?.textView.selectedRange() ?? NSRange(location: 0, length: 0)
        if range.location == NSNotFound || NSMaxRange(range) > text.length { range = NSRange(location: 0, length: 0) }
        let attachment: AgentAttachment
        if range.length == 0 {
            attachment = AgentAttachment(url: document.url, lines: nil, text: text as String)
        } else {
            let index = document.lineIndex
            let first = index.line(containing: range.location) + 1
            // A selection ending at a line's start doesn't take that line.
            var endLocation = NSMaxRange(range)
            if endLocation > range.location, endLocation <= text.length, text.character(at: endLocation - 1) == 0x0A { endLocation -= 1 }
            let last = index.line(containing: endLocation) + 1
            attachment = AgentAttachment(url: document.url, lines: first...max(first, last), text: text.substring(with: range))
        }
        add(attachment)
    }

    /// Adds an attachment; the same lines of the same file again replace the earlier one (with
    /// their text as it is now) rather than going twice.
    func add(_ attachment: AgentAttachment) {
        if let index = attachments.firstIndex(where: { $0.url == attachment.url && $0.lines == attachment.lines }) {
            attachments[index] = attachment
        } else {
            attachments.append(attachment)
        }
    }

    func removeAttachment(_ attachment: AgentAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }
}

extension Workspace: AgentHost {
    var agentRootURL: URL? { rootURL }
    var agentFolders: [URL] { folders }

    func agentReadText(_ url: URL) throws -> String {
        if let document = document(matching: url) { return document.textStorage.mutableString as String }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentError(code: -32002, message: "\(url.path) doesn't exist")
        }
        guard let text = currentText(of: url) else {
            throw AgentError(code: -32603, message: "\(url.path) isn't a UTF-8 text file")
        }
        return text
    }

    func agentWriteText(_ url: URL, _ text: String) throws {
        if let document = document(matching: url) {
            let current = document.textStorage.mutableString
            if !current.isEqual(to: text) {
                try document.apply([TextReplacement(range: NSRange(location: 0, length: current.length), text: text)],
                                   actionName: "Agent Edit")
            }
            guard save(document) else { throw AgentError(code: -32603, message: "Couldn't save \(url.lastPathComponent)") }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
