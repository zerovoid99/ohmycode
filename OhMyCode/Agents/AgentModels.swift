import Foundation

/// One item of a conversation with an agent, in order.
struct AgentEntry: Identifiable {
    enum Kind {
        /// What the user sent (its text, and the names of what was attached).
        case user(String, attachments: [String])
        /// The agent's reply, Markdown, streamed in chunks.
        case message(String)
        /// The agent's reasoning, shown collapsed.
        case thought(String)
        case tool(AgentToolCall)
        /// A line from the editor itself (the turn ended early, the agent stopped).
        case notice(String)
    }

    let id: Int
    var kind: Kind
}

/// Something the agent does: reading a file, an edit, a command.
struct AgentToolCall: Equatable {
    enum Status: String { case pending, inProgress = "in_progress", completed, failed, cancelled }

    let id: String
    var title: String
    /// `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode`, `other`.
    var kind: String
    var status: Status
    var content: [AgentToolContent]
    var locations: [AgentLocation]

    var isFinished: Bool { status == .completed || status == .failed || status == .cancelled }

    var symbolName: String {
        switch kind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.right.doc.on.clipboard"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        case "switch_mode": "arrow.triangle.swap"
        default: "wrench.and.screwdriver"
        }
    }
}

enum AgentToolContent: Equatable {
    case text(String)
    /// A proposed or made change to a file: its text before (nil: a new file) and after.
    case diff(path: String, old: String?, new: String)
    case terminal(id: String)
}

struct AgentLocation: Equatable {
    let path: String
    /// 1-based.
    let line: Int?
}

/// The agent asks before doing something (an edit, a command): the user picks an option.
struct AgentPermissionRequest: Identifiable {
    struct Option: Identifiable {
        let id: String
        let name: String
        /// `allow_once`, `allow_always`, `reject_once`, `reject_always`.
        let kind: String
        var allows: Bool { kind.hasPrefix("allow") }
    }

    /// The JSON-RPC id of the request, answered with the choice.
    let requestID: AnyHashableID
    let toolCallID: String?
    let title: String
    let options: [Option]
    let content: [AgentToolContent]
    var id: AnyHashableID { requestID }
}

/// A JSON-RPC id (number or string), hashable.
enum AnyHashableID: Hashable {
    case number(Int), string(String)

    init?(_ value: Any?) {
        if let number = value as? Int { self = .number(number) } else if let string = value as? String { self = .string(string) } else { return nil }
    }

    var json: Any {
        switch self {
        case .number(let number): number
        case .string(let string): string
        }
    }
}

struct AgentPlanEntry: Equatable {
    let content: String
    /// `high`, `medium`, `low`.
    let priority: String
    /// `pending`, `in_progress`, `completed`.
    let status: String
}

struct AgentMode: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
}

/// A setting of the session the agent offers (its model, how hard it thinks, its mode).
struct AgentConfigOption: Identifiable, Equatable {
    struct Choice: Identifiable, Equatable {
        var id: String { value }
        let value: String
        let name: String
        let description: String?
        /// The group's name, when the choices are grouped.
        let group: String?
    }

    enum Kind: Equatable {
        case select(current: String, choices: [Choice])
        case boolean(Bool)
    }

    let id: String
    let name: String
    let description: String?
    /// `mode`, `model`, `model_config`, `thought_level`, `other`, or the agent's own.
    let category: String?
    var kind: Kind

    /// From the agent's JSON; nil for a type this editor doesn't know (left alone).
    init?(json: Any?) {
        guard let object = json as? [String: Any], let id = object["id"] as? String else { return nil }
        self.id = id
        name = object["name"] as? String ?? id
        description = object["description"] as? String
        category = object["category"] as? String
        switch object["type"] as? String {
        case "select":
            guard let current = object["currentValue"] as? String else { return nil }
            var choices: [Choice] = []
            for entry in object["options"] as? [[String: Any]] ?? [] {
                if let groupOptions = entry["options"] as? [[String: Any]] {
                    let group = entry["name"] as? String ?? entry["group"] as? String
                    choices += groupOptions.compactMap { Self.choice($0, group: group) }
                } else if let choice = Self.choice(entry, group: nil) {
                    choices.append(choice)
                }
            }
            kind = .select(current: current, choices: choices)
        case "boolean":
            guard let current = object["currentValue"] as? Bool else { return nil }
            kind = .boolean(current)
        default:
            return nil
        }
    }

    private static func choice(_ json: [String: Any], group: String?) -> Choice? {
        guard let value = json["value"] as? String else { return nil }
        return Choice(value: value, name: json["name"] as? String ?? value, description: json["description"] as? String, group: group)
    }

    /// The current choice's name (selects).
    var currentName: String {
        switch kind {
        case .select(let current, let choices): choices.first { $0.value == current }?.name ?? current
        case .boolean(let on): on ? "On" : "Off"
        }
    }
}

/// An earlier session with the agent in this folder, to reopen.
struct AgentSessionSummary: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let updatedAt: Date?

    init(id: String, title: String, updatedAt: Date?) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }

    /// From `session/list`'s `SessionInfo`.
    init?(json: [String: Any]) {
        guard let id = json["sessionId"] as? String else { return nil }
        self.id = id
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? "Untitled" : title
        updatedAt = (json["updatedAt"] as? String).flatMap { Self.date($0) }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Sessions this editor opened, per agent and folder: the history of an agent that can reopen
/// sessions but not list them.
@MainActor
enum AgentSessionHistory {
    private static let key = "agents.sessionHistory"
    private static let limit = 30

    private static func storeKey(_ agent: AgentDefinition.ID, _ folder: URL) -> String { "\(agent.uuidString)|\(folder.path)" }

    static func sessions(agent: AgentDefinition.ID, folder: URL, defaults: UserDefaults = .standard) -> [AgentSessionSummary] {
        let all = (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: [AgentSessionSummary]].self, from: $0) } ?? [:]
        return all[storeKey(agent, folder)] ?? []
    }

    static func record(_ session: AgentSessionSummary, agent: AgentDefinition.ID, folder: URL, defaults: UserDefaults = .standard) {
        var all = (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: [AgentSessionSummary]].self, from: $0) } ?? [:]
        var list = all[storeKey(agent, folder)] ?? []
        list.removeAll { $0.id == session.id }
        list.insert(session, at: 0)
        all[storeKey(agent, folder)] = Array(list.prefix(limit))
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }
}

struct AgentCommand: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let hint: String?
}

struct AgentAuthMethod: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
}

/// Something attached to a prompt: a file, or lines of one.
struct AgentAttachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// 1-based lines, when it's part of the file.
    let lines: ClosedRange<Int>?
    /// The text, embedded when the agent accepts that (else the agent is given the path).
    let text: String

    var label: String {
        let name = url.lastPathComponent
        guard let lines else { return name }
        return lines.count == 1 ? "\(name):\(lines.lowerBound)" : "\(name):\(lines.lowerBound)-\(lines.upperBound)"
    }

    static func == (lhs: AgentAttachment, rhs: AgentAttachment) -> Bool { lhs.id == rhs.id }
}

extension AgentToolContent {
    /// From an ACP `ToolCallContent`.
    init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "content":
            guard let text = AgentContent.text(of: object["content"]) else { return nil }
            self = .text(text)
        case "diff":
            guard let path = object["path"] as? String, let new = object["newText"] as? String else { return nil }
            self = .diff(path: path, old: object["oldText"] as? String, new: new)
        case "terminal":
            guard let id = object["terminalId"] as? String else { return nil }
            self = .terminal(id: id)
        default:
            return nil
        }
    }
}

/// ACP content blocks.
enum AgentContent {
    /// A block's text, for display: text as is, a link or resource by name.
    static func text(of block: Any?) -> String? {
        guard let block = block as? [String: Any] else { return nil }
        switch block["type"] as? String {
        case "text":
            return block["text"] as? String
        case "resource_link":
            let name = block["name"] as? String ?? block["uri"] as? String ?? "link"
            if let uri = block["uri"] as? String { return "[\(name)](\(uri))" }
            return name
        case "resource":
            let resource = block["resource"] as? [String: Any]
            return resource?["text"] as? String ?? (resource?["uri"] as? String).map { "[\($0)]" }
        case "image":
            return "[image]"
        case "audio":
            return "[audio]"
        default:
            return nil
        }
    }

    static func textBlock(_ text: String) -> [String: Any] { ["type": "text", "text": text] }

    /// An attachment as a block: its text embedded (`embeddedContext`), else a link to the file.
    static func block(for attachment: AgentAttachment, embedded: Bool) -> [String: Any] {
        var uri = attachment.url.absoluteString
        if let lines = attachment.lines { uri += "#L\(lines.lowerBound)-\(lines.upperBound)" }
        if embedded {
            return ["type": "resource", "resource": ["uri": uri, "text": attachment.text, "mimeType": "text/plain"]]
        }
        return ["type": "resource_link", "uri": uri, "name": attachment.label]
    }
}
