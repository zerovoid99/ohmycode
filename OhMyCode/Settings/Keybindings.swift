import AppKit
import Observation
import SwiftUI

/// Every command's keyboard shortcut: the defaults (the commands' own, extensions'), changed by
/// the user's keybindings.json, which reads like VS Code's:
///
///     [
///       { "key": "cmd+shift+r", "command": "tasks.run" },
///       { "key": "cmd+shift+b", "command": "-tasks.build" }
///     ]
///
/// A rule sets a command's shortcut; "-command" removes the command's default one.
@MainActor
@Observable
final class Keybindings {
    static let didChange = Notification.Name("omcKeybindingsDidChange")

    static var shared = Keybindings(file: AppSettings.isRunningTests
        ? FileManager.default.temporaryDirectory.appending(path: "omc-test-keybindings-\(ProcessInfo.processInfo.processIdentifier).json")
        : URL.omcApplicationSupport.appending(path: "OhMyCode/keybindings.json"))

    struct Rule: Codable, Equatable {
        var key: String
        var command: String
        var when: String?
    }

    /// Where a command's shortcut comes from.
    enum Source: Equatable {
        case none, builtIn, `extension`(String), user, removed
    }

    struct Command: Identifiable, Equatable {
        let id: String
        let title: String
        /// The extension that contributes it (nil: built in).
        let extensionName: String?
    }

    let file: URL
    private(set) var rules: [Rule] = []
    /// A problem reading keybindings.json (its rules that make sense still apply).
    private(set) var loadError: String?
    /// Extensions' commands and default shortcuts, by extension id.
    private(set) var extensionCommands: [String: (name: String, commands: [Command], defaults: [String: String])] = [:]
    @ObservationIgnored private var fileDate: Date?

    init(file: URL) {
        self.file = file
        load()
        // Edited by hand in another app: read again when coming back.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfChanged() }
        }
    }

    // MARK: Commands

    /// Built-in commands' default shortcuts.
    static let builtInDefaults: [String: String] = Dictionary(
        PaletteCommand.all.compactMap { command in command.key.map { (command.id, $0) } }, uniquingKeysWith: { first, _ in first })

    /// Every command that can have a shortcut: the built-in ones, then extensions'.
    var commands: [Command] {
        PaletteCommand.all.map { Command(id: $0.id, title: $0.title, extensionName: nil) }
            + extensionCommands.keys.sorted().flatMap { extensionCommands[$0]!.commands }
    }

    func defaultSpec(for command: String) -> String? {
        if let spec = Self.builtInDefaults[command] { return spec }
        for (_, entry) in extensionCommands { if let spec = entry.defaults[command] { return spec } }
        return nil
    }

    func setExtensionCommands(_ id: String, name: String, commands: [(id: String, title: String)], defaults: [String: String]) {
        let entry = (name, commands.map { Command(id: $0.id, title: $0.title, extensionName: name) }, defaults)
        if commands.isEmpty && defaults.isEmpty { extensionCommands[id] = nil } else { extensionCommands[id] = entry }
    }

    func removeExtension(_ id: String) { extensionCommands[id] = nil }

    // MARK: Effective shortcuts

    /// The user's rule for a command, if they changed its shortcut (removing counts).
    private func userRule(for command: String) -> Rule? {
        rules.last { $0.command == command || $0.command == "-" + command }
    }

    func source(for command: String) -> Source {
        if let rule = userRule(for: command) { return rule.command.hasPrefix("-") || rule.key.isEmpty ? .removed : .user }
        if Self.builtInDefaults[command] != nil { return .builtIn }
        for (_, entry) in extensionCommands where entry.defaults[command] != nil { return .extension(entry.name) }
        return .none
    }

    /// The shortcut a command has now.
    func chord(for command: String) -> KeyChord? {
        if let rule = userRule(for: command) {
            guard !rule.command.hasPrefix("-"), !rule.key.isEmpty else { return nil }
            return try? KeyChord(parsing: rule.key)
        }
        return defaultSpec(for: command).flatMap { try? KeyChord(parsing: $0) }
    }

    /// The user's `when` for a command they bound (nil keeps the default's).
    func when(for command: String) -> String? {
        userRule(for: command).flatMap { $0.command.hasPrefix("-") ? nil : $0.when }
    }

    /// For menu items.
    func shortcut(_ command: String) -> KeyboardShortcut? { chord(for: command)?.keyboardShortcut }

    func display(for command: String) -> String? { chord(for: command)?.display }

    /// Commands (other than `command`) with the same shortcut.
    func conflicts(with chord: KeyChord, except command: String? = nil) -> [String] {
        commands.map(\.id).filter { $0 != command && self.chord(for: $0) == chord }
    }

    /// The command a key press is bound to.
    func command(for event: NSEvent) -> String? {
        commands.first { chord(for: $0.id)?.matches(event) == true }?.id
    }

    // MARK: Changing

    /// Gives a command a shortcut (nil removes it); the default again resets it.
    func set(_ chord: KeyChord?, for command: String) {
        rules.removeAll { $0.command == command || $0.command == "-" + command }
        let defaultChord = defaultSpec(for: command).flatMap { try? KeyChord(parsing: $0) }
        if let chord {
            if chord != defaultChord { rules.append(Rule(key: chord.spec, command: command)) }
        } else if let defaultChord {
            rules.append(Rule(key: defaultChord.spec, command: "-" + command))
        }
        save()
    }

    /// Replaces every rule (a profile's), saved.
    func replaceRules(_ rules: [Rule]) {
        self.rules = rules
        save()
    }

    func reset(_ command: String) {
        rules.removeAll { $0.command == command || $0.command == "-" + command }
        save()
    }

    // MARK: File

    private static func modificationDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    func load() {
        fileDate = Self.modificationDate(file)
        guard let data = try? Data(contentsOf: file) else { rules = []; loadError = nil; return }
        let text = VSCodeTheme.stripJSONC(String(decoding: data, as: UTF8.self))
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rules = []; loadError = nil; return }
        do {
            let entries = try JSONDecoder().decode([JSONValue].self, from: Data(text.utf8))
            var problems: [String] = []
            rules = entries.compactMap { entry in
                guard let command = entry["command"]?.string else { problems.append("a rule without a \"command\""); return nil }
                let key = entry["key"]?.string ?? ""
                if !key.isEmpty, !command.hasPrefix("-") {
                    do { _ = try KeyChord(parsing: key) } catch {
                        problems.append("\(command): \(error.localizedDescription)")
                        return nil
                    }
                }
                return Rule(key: key, command: command, when: entry["when"]?.string)
            }
            loadError = problems.isEmpty ? nil : problems.joined(separator: "; ")
        } catch {
            rules = []
            loadError = "\(file.lastPathComponent) isn't a JSON list of rules."
        }
    }

    /// Reads the file again if it changed (edited by hand).
    func reloadIfChanged() {
        if Self.modificationDate(file) != fileDate { load() }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let lines = rules.map { rule -> String in
                var parts = ["\"key\": \(Self.json(rule.key))", "\"command\": \(Self.json(rule.command))"]
                if let when = rule.when { parts.append("\"when\": \(Self.json(when))") }
                return "  { " + parts.joined(separator: ", ") + " }"
            }
            let text = "// Keyboard shortcuts that differ from the defaults (Settings → Keyboard Shortcuts).\n// \"-command\" removes a command's default shortcut.\n[\n"
                + lines.joined(separator: ",\n") + (lines.isEmpty ? "" : "\n") + "]\n"
            try text.write(to: file, atomically: true, encoding: .utf8)
            fileDate = Self.modificationDate(file)
            loadError = nil
            NotificationCenter.default.post(name: Self.didChange, object: self)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func json(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
