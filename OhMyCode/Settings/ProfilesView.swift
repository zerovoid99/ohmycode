import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Profiles: switch, make, export and sync profiles.
struct ProfilesView: View {
    var manager = ProfileManager.shared
    @State private var newName = ""
    @State private var renaming: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section("Profile") {
                Picker("Current", selection: Binding(get: { manager.current }, set: { manager.switchTo($0) })) {
                    ForEach(manager.names, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    TextField("New profile", text: $newName, prompt: Text("Name, e.g. Presenting"))
                        .onSubmit(create)
                    Button("Create and Switch", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || manager.names.contains(newName))
                }
                Text("A new profile starts as a copy of the current one. Switching saves the current profile first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Profiles") {
                ForEach(manager.names, id: \.self) { name in
                    HStack {
                        if renaming == name {
                            RenameField(name: name) { newName in
                                manager.rename(name, to: newName)
                                renaming = nil
                            }
                        } else {
                            Text(name)
                            if name == manager.current { Text("current").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Rename") { renaming = name }.buttonStyle(.borderless)
                        Button("Delete", role: .destructive) { manager.delete(name) }
                            .buttonStyle(.borderless)
                            .disabled(name == manager.current)
                    }
                }
            }
            Section("Move between Macs") {
                HStack {
                    Button("Export…", action: exportProfile)
                    Button("Import…", action: importProfile)
                }
                LabeledContent("Sync folder") {
                    Text(manager.syncFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "None (kept on this Mac)")
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Choose Folder…", action: chooseSyncFolder)
                    Button("Stop Syncing") { manager.setSyncFolder(nil) }.disabled(manager.syncFolder == nil)
                }
                Text("Profiles in a folder you sync (iCloud Drive, Dropbox, a git repository) follow you to your other Macs: each picks up changes when you come back to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = message ?? manager.lastError {
                Text(error).foregroundStyle(.orange).font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        manager.switchTo(name)
        newName = ""
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(manager.current).\(SettingsProfile.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try manager.export(to: url); message = "Exported to \(url.lastPathComponent)." } catch { message = error.localizedDescription }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.message = "Choose an exported .\(SettingsProfile.fileExtension) file: its settings replace the current profile's."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try manager.importProfile(from: url); message = "Imported \(url.lastPathComponent)." } catch { message = "Can't import: \(error.localizedDescription)" }
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Sync Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manager.setSyncFolder(url)
    }
}

private struct RenameField: View {
    let name: String
    let done: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("Name", text: $text)
            .onAppear { text = name }
            .onSubmit { done(text) }
    }
}

extension Workspace {
    /// Profiles: Switch Profile…: the profiles, and a new one.
    func pickProfile() async {
        let manager = ProfileManager.shared
        let names = manager.names
        var items = names.map { QuickPickItem(label: $0, description: $0 == manager.current ? "current" : nil) }
        items.append(QuickPickItem(label: "New Profile…", description: "a copy of \(manager.current)"))
        guard let index = await showQuickPick(items, placeholder: "Profile to switch to") else { return }
        if names.indices.contains(index) {
            manager.switchTo(names[index])
        } else if let name = await showInputBox(prompt: "Name of the new profile", value: "", placeholder: "Presenting") {
            manager.switchTo(name)
        }
    }
}
