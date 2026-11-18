import AppKit
import SwiftUI

/// Opens Settings at Languages.
@MainActor
enum LanguageServersWindow {
    static let tab = "languages"

    static func show() {
        UserDefaults.omc.set(tab, forKey: SettingsView.tabKey)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }
}

/// Settings → Languages: every language server (built in and from extensions) with whether
/// it's running, a switch, Restart and its log; and `files.associations`.
struct LanguagesSettingsView: View {
    @Bindable var settings = AppSettings.shared
    @State private var path: String?
    @State private var shownLog: String?
    @State private var newPattern = ""
    @State private var newLanguage = ""
    /// Bumped when extensions' grammars change, to list them again.
    @State private var grammarsGeneration = 0

    struct Server: Identifiable {
        let id: String
        let name: String
        let languages: [String]
        let source: String
        /// The program, to see whether it's there.
        let executable: (String) -> String?
    }

    private var workspaces: [Workspace] { OpenRouter.shared.allWorkspaces }

    private var servers: [Server] {
        var list = LanguageServers.candidates.map { candidate in
            Server(id: candidate.id, name: candidate.name, languages: candidate.languages.map(\.displayName).sorted(), source: "Built in",
                   executable: { LanguageServers.find(candidate.executable, in: $0) })
        }
        var seen = Set(list.map(\.id))
        for workspace in workspaces {
            for definition in workspace.extensions.languageServerDefinitions where seen.insert(definition.id).inserted {
                let source = workspace.extensions.extensions.first { $0.id == definition.extensionID }?.manifest.name ?? definition.extensionID
                list.insert(Server(id: definition.id, name: definition.name,
                                   languages: definition.languages.map { SourceLanguage(languageId: $0).displayName }.sorted(),
                                   source: source, executable: { definition.executable(path: $0) }), at: 0)
            }
        }
        return list
    }

    /// Languages with a contributed grammar: what can highlight them, and what does by default.
    private var highlightedLanguages: [(language: SourceLanguage, name: String, engines: [HighlightingEngine], automatic: HighlightingEngine)] {
        _ = grammarsGeneration
        let grammars = ContributedGrammars.shared
        return LanguageRegistry.shared.languages.compactMap { entry in
            let engines = grammars.availableEngines(for: entry.language)
            guard engines.contains(where: { $0 != .builtIn }), let automatic = grammars.preference(for: entry.language).first else { return nil }
            return (entry.language, entry.name, engines, automatic)
        }
    }

    private func clients(of id: String) -> [LanguageClient] {
        workspaces.flatMap { $0.languageClients.values.filter { $0.serverID == id } }
    }

    private func status(of server: Server) -> (text: String, color: Color) {
        if settings.languageServersEnabled[server.id] == false { return ("Off", .secondary) }
        let clients = clients(of: server.id)
        if clients.contains(where: { $0.state == .ready }) { return ("Running", .green) }
        if clients.contains(where: { $0.state == .starting }) { return ("Starting", .orange) }
        if let failure = clients.lazy.compactMap({ if case .failed(let message) = $0.state { message } else { nil } }).first
            ?? workspaces.lazy.compactMap({ $0.languageServerFailures[server.id] }).first {
            return ("Failed: \(failure)", .red)
        }
        if let path, server.executable(path) == nil { return ("Not found", .secondary) }
        return ("Not running", .secondary)
    }

    var body: some View {
        Form {
            Section {
                ForEach(servers) { server in
                    serverRow(server)
                }
            } header: {
                Text("Language Servers")
            } footer: {
                Text("An extension's server is used for its languages before a built-in one. A folder's .omc/settings.json can turn one off with \"languageServers.<id>.enabled\": false.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if highlightedLanguages.isEmpty {
                    Text("No extension adds a grammar.").foregroundStyle(.secondary)
                }
                ForEach(highlightedLanguages, id: \.language) { entry in
                    Picker(entry.name, selection: Binding(
                        get: { settings.languageHighlighting[entry.language.languageId] ?? "" },
                        set: { settings.languageHighlighting[entry.language.languageId] = $0.isEmpty ? nil : $0 })) {
                        Text("Automatic (\(entry.automatic.title))").tag("")
                        ForEach(entry.engines, id: \.self) { engine in
                            Text(engine.title).tag(engine.rawValue)
                        }
                    }
                }
            } header: {
                Text("Highlighting")
            } footer: {
                Text("Languages an extension adds a grammar for. A language the app highlights itself keeps its built-in highlighting unless the grammar says \"override\": true, or you pick it here. Developer: Inspect Editor Tokens and Scopes shows what colors the text under the caret.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(settings.fileAssociations.keys.sorted(), id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.system(.body, design: .monospaced))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(settings.fileAssociations[pattern] ?? "")
                        Spacer()
                        Button("Remove") { settings.fileAssociations[pattern] = nil }
                    }
                }
                HStack {
                    TextField("Pattern (*.tpl)", text: $newPattern)
                    TextField("Language id (html)", text: $newLanguage)
                    Button("Add") {
                        settings.fileAssociations[newPattern.trimmingCharacters(in: .whitespaces)] = newLanguage.trimmingCharacters(in: .whitespaces)
                        newPattern = ""
                        newLanguage = ""
                    }
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty || newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("File Associations")
            } footer: {
                Text("files.associations: files matching a pattern (on the name, or the path when it has a /) open in that language. Change Language Mode picks one for a single file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { path = await ShellEnvironment.shared.environment()["PATH"] ?? "" }
        .onReceive(NotificationCenter.default.publisher(for: LanguageRegistry.didChange)) { _ in
            grammarsGeneration = ContributedGrammars.shared.generation
        }
        .sheet(item: Binding(get: { shownLog.map(LogID.init) }, set: { shownLog = $0?.id })) { log in
            LanguageServerLogView(name: servers.first { $0.id == log.id }?.name ?? log.id, lines: clients(of: log.id).flatMap(\.log)) {
                shownLog = nil
            }
        }
    }

    private struct LogID: Identifiable { let id: String }

    private func serverRow(_ server: Server) -> some View {
        let status = status(of: server)
        return HStack(alignment: .top) {
            Toggle("", isOn: Binding(get: { settings.languageServersEnabled[server.id] ?? true },
                                     set: { settings.languageServersEnabled[server.id] = $0 ? nil : false }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.headline)
                Text("\(server.id) · \(server.source) · \(server.languages.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(status.text).font(.caption).foregroundStyle(status.color).lineLimit(2)
            }
            Spacer()
            Button("Log") { shownLog = server.id }
                .disabled(clients(of: server.id).allSatisfy(\.log.isEmpty))
            Button("Restart") { workspaces.forEach { $0.restartLanguageServer(id: server.id) } }
                .disabled(settings.languageServersEnabled[server.id] == false)
        }
    }
}

/// What a server wrote to stderr and logged (`window/logMessage`).
private struct LanguageServerLogView: View {
    let name: String
    let lines: [String]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(name) Log").font(.headline)
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 640, height: 420)
    }
}
