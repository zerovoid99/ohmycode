import Foundation
import Observation

/// A coding agent that speaks the Agent Client Protocol (ACP), and how to start it.
struct AgentDefinition: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// The command line, split as a shell would (quotes around arguments with spaces), run with
    /// the login shell's PATH.
    var command: String
    /// Extra environment variables, one `NAME=value` each.
    var environment: [String] = []

    /// Agents with an ACP adapter, as they're installed by default. Claude Code's and Codex's
    /// adapters come from npm (Node.js needed); Gemini CLI speaks ACP itself.
    static let presets: [AgentDefinition] = [
        AgentDefinition(id: UUID(uuidString: "6F1B3C2E-7D0A-4C55-9E21-3A1F0C9B7E01")!, name: "Claude Code",
                        command: "npx -y @agentclientprotocol/claude-agent-acp"),
        AgentDefinition(id: UUID(uuidString: "6F1B3C2E-7D0A-4C55-9E21-3A1F0C9B7E02")!, name: "Gemini CLI",
                        command: "gemini --experimental-acp"),
        AgentDefinition(id: UUID(uuidString: "6F1B3C2E-7D0A-4C55-9E21-3A1F0C9B7E03")!, name: "Codex",
                        command: "npx -y @agentclientprotocol/codex-acp"),
    ]

    /// The command line's words: whitespace separates them, except inside single or double
    /// quotes; a backslash makes the next character literal (outside single quotes).
    static func words(_ command: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for character in command {
            if escaped { word.append(character); escaped = false; continue }
            if character == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; started = true; continue }
            if character.isWhitespace {
                if started { words.append(word); word = ""; started = false }
                continue
            }
            word.append(character)
            started = true
        }
        if started { words.append(word) }
        return words
    }

    /// The environment variables as a dictionary (entries without `=` are left out).
    var environmentVariables: [String: String] {
        var result: [String: String] = [:]
        for entry in environment {
            guard let equals = entry.firstIndex(of: "="), equals > entry.startIndex else { continue }
            result[String(entry[..<equals]).trimmingCharacters(in: .whitespaces)] = String(entry[entry.index(after: equals)...])
        }
        return result
    }
}

/// The agents the user can start (Settings ▸ Agents), and whether `claude` in a terminal can
/// connect to the editor (see `ClaudeCodeServer`).
@MainActor
@Observable
final class AgentStore {
    /// Under tests, a scratch store, with the Claude Code integration off (tests that want it
    /// turn it on, with its files in a scratch folder).
    static let shared: AgentStore = {
        guard AppSettings.isRunningTests else { return AgentStore(defaults: .standard) }
        let name = "dev.zerovoid99.ohmycode.tests.agents"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(false, forKey: integrationKey)
        return AgentStore(defaults: defaults)
    }()

    var definitions: [AgentDefinition] { didSet { save() } }
    /// Claude Code started in this app's terminal (or with `/ide`) sees the open files and the
    /// selection, and shows its proposed edits as diffs here.
    var claudeCodeIntegration: Bool { didSet { save(); NotificationCenter.default.post(name: Self.integrationDidChange, object: self) } }

    static let integrationDidChange = Notification.Name("AgentStore.integrationDidChange")

    @ObservationIgnored private let defaults: UserDefaults
    private static let definitionsKey = "agents.definitions"
    private static let integrationKey = "agents.claudeCodeIntegration"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.definitionsKey),
           let saved = try? JSONDecoder().decode([AgentDefinition].self, from: data) {
            definitions = saved
        } else {
            definitions = AgentDefinition.presets
        }
        claudeCodeIntegration = defaults.object(forKey: Self.integrationKey) as? Bool ?? true
    }

    func definition(id: AgentDefinition.ID?) -> AgentDefinition? {
        definitions.first { $0.id == id } ?? definitions.first
    }

    func add() -> AgentDefinition {
        let definition = AgentDefinition(id: UUID(), name: "New Agent", command: "")
        definitions.append(definition)
        return definition
    }

    func restorePresets() {
        definitions = AgentDefinition.presets
    }

    private func save() {
        if let data = try? JSONEncoder().encode(definitions) { defaults.set(data, forKey: Self.definitionsKey) }
        defaults.set(claudeCodeIntegration, forKey: Self.integrationKey)
    }
}
