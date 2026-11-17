import SwiftUI

/// Settings ▸ Agents: the agents the Agent sidebar can start, and the Claude Code integration.
struct AgentSettingsView: View {
    @Bindable var store = AgentStore.shared
    @State private var selection: AgentDefinition.ID?

    var body: some View {
        Form {
            Section {
                Toggle("Let Claude Code connect to Oh My Code", isOn: $store.claudeCodeIntegration)
                Text("Run claude in a terminal opened here and it connects to the window: it sees the open files, the selection and the problems, and its proposed edits open as diffs to accept or reject. In another terminal, in the window's folder, type /ide. ⌥⌘K sends the selected lines to it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Claude Code")
            }

            Section {
                List(selection: $selection) {
                    ForEach(store.definitions) { definition in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(definition.name)
                            Text(definition.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(definition.id)
                    }
                }
                .frame(minHeight: 110)
                HStack {
                    Button("Add") { selection = store.add().id }
                    Button("Remove") {
                        store.definitions.removeAll { $0.id == selection }
                        selection = store.definitions.first?.id
                    }
                    .disabled(selection == nil)
                    Spacer()
                    Button("Restore Defaults") { store.restorePresets(); selection = store.definitions.first?.id }
                }
                if let index = store.definitions.firstIndex(where: { $0.id == selection }) {
                    TextField("Name", text: $store.definitions[index].name)
                    TextField("Command", text: $store.definitions[index].command)
                        .font(.body.monospaced())
                    TextField("Environment", text: Binding(
                        get: { store.definitions[index].environment.joined(separator: " ") },
                        set: { store.definitions[index].environment = AgentDefinition.words($0) }))
                        .font(.body.monospaced())
                    Text("Environment: NAME=value pairs separated by spaces (quote values with spaces).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Agents that speak the Agent Client Protocol, started in the window's folder with your login shell's PATH. Claude Code and Codex need Node.js for their adapters (npx); Gemini CLI speaks it itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { if selection == nil { selection = store.definitions.first?.id } }
    }
}
