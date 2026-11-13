import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A message in the corner of the window (an extension's `showInformationMessage`).
struct AppNotification: Identifiable, Equatable {
    enum Kind: String { case info, warning, error }

    let id = UUID()
    let kind: Kind
    let message: String
    let source: String?
    let items: [String]
}

/// The notifications, stacked in the bottom-right corner.
struct NotificationsOverlay: View {
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(workspace.notifications) { notification in
                NotificationCard(notification: notification) { item in
                    workspace.dismissNotification(notification.id, choosing: item)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(12)
        .animation(.easeOut(duration: 0.15), value: workspace.notifications)
    }
}

private struct NotificationCard: View {
    let notification: AppNotification
    let choose: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let source = notification.source {
                        Text(source).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button { choose(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
            if !notification.items.isEmpty {
                HStack {
                    Spacer()
                    ForEach(notification.items, id: \.self) { item in
                        Button(item) { choose(item) }
                    }
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
        .padding(10)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var icon: String {
        switch notification.kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch notification.kind {
        case .info: .blue
        case .warning: .yellow
        case .error: .red
        }
    }
}

/// An extension's status bar item: "$(symbol)" in its text shows an SF Symbol.
struct ExtensionStatusItemView: View {
    let item: ExtensionStatusItem
    let run: (String) -> Void

    var body: some View {
        let label = HStack(spacing: 3) {
            ForEach(Array(Self.parts(item.text).enumerated()), id: \.offset) { _, part in
                switch part {
                case .symbol(let name): Image(systemName: name)
                case .text(let text): Text(text)
                }
            }
        }
        Group {
            if let command = item.command {
                Button { run(command) } label: { label }.buttonStyle(.plain)
            } else {
                label
            }
        }
        .help(item.tooltip ?? item.text)
    }

    enum Part: Equatable { case text(String), symbol(String) }

    /// "$(clock) 3 min" → symbol "clock", text " 3 min".
    static func parts(_ text: String) -> [Part] {
        var parts: [Part] = []
        var rest = Substring(text)
        while let open = rest.range(of: "$("), let close = rest[open.upperBound...].firstIndex(of: ")") {
            if open.lowerBound > rest.startIndex { parts.append(.text(String(rest[..<open.lowerBound]))) }
            parts.append(.symbol(String(rest[open.upperBound..<close])))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        return parts
    }
}

/// The Extensions sidebar: installed extensions, their state, settings and log.
struct ExtensionsView: View {
    let workspace: Workspace
    @State private var expanded: Set<String> = []

    private var host: ExtensionHost { workspace.extensions }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Installed").font(.callout.weight(.semibold))
                Text("\(host.extensions.count)").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("New Extension…") { Task { await workspace.createExtension() } }
                    Divider()
                    Button("Install from Folder…") { install(development: false) }
                    Button("Install for Development…") { install(development: true) }
                        .help("Link the folder instead of copying it: rebuild, then Reload, to try changes")
                    Divider()
                    Button("Reload Extensions") { host.reload(restart: true) }
                    Button("Open Extensions Folder") { openFolder() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Install or reload extensions")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if host.extensions.isEmpty && host.problems.isEmpty {
                ContentUnavailableView {
                    Label("No Extensions", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Extensions are folders with an extension.json and JavaScript (compiled from TypeScript). Install one from a folder.")
                } actions: {
                    Button("Install from Folder…") { install(development: false) }
                }
            } else {
                List {
                    ForEach(host.extensions) { instance in
                        ExtensionRow(workspace: workspace, instance: instance, isExpanded: binding(for: instance.id))
                    }
                    ForEach(host.problems.sorted(by: { $0.key < $1.key }), id: \.key) { folder, problem in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder)
                                Text(problem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func openFolder() {
        let directory = host.store.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    /// Picks an extension folder, shows what it may do, then installs it.
    private func install(development: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose an extension's folder (it has an extension.json)"
        panel.prompt = development ? "Link" : "Install"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        workspace.installExtension(from: folder, development: development)
    }
}

private struct ExtensionRow: View {
    let workspace: Workspace
    let instance: ExtensionInstance
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            details
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(instance.isEnabled ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(instance.manifest.name).fontWeight(.medium).lineLimit(1)
                        Text(instance.manifest.version).font(.caption).foregroundStyle(.secondary)
                        if instance.installed.isDevelopment {
                            Text("DEV").font(.caption2.weight(.bold)).foregroundStyle(.orange)
                                .help("Linked to its source folder")
                        }
                    }
                    if let description = instance.manifest.description {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    stateLabel.font(.caption)
                }
                Spacer(minLength: 4)
                Toggle("Enabled", isOn: Binding(get: { instance.isEnabled },
                                                set: { workspace.extensions.setEnabled(instance, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(instance.isEnabled ? "Disable" : "Enable")
            }
            .contextMenu {
                Button(instance.isEnabled ? "Disable" : "Enable") { workspace.extensions.setEnabled(instance, !instance.isEnabled) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([instance.installed.folder]) }
                Divider()
                Button("Uninstall…", role: .destructive) { workspace.uninstallExtension(instance) }
            }
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch instance.state {
        case .active: Label("Running", systemImage: "circle.fill").foregroundStyle(.green)
        case .activating: Label("Starting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .inactive: Label("Starts when needed", systemImage: "circle").foregroundStyle(.secondary)
        case .disabled: Label("Disabled", systemImage: "pause.circle").foregroundStyle(.secondary)
        case .failed: Label("Failed: see the log", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(instance.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if !instance.manifest.grantedPermissions.isEmpty {
                section("Permissions") {
                    ForEach(ExtensionManifest.Permission.allCases.filter(instance.manifest.grantedPermissions.contains), id: \.self) {
                        Label($0.title, systemImage: "lock.open").font(.caption)
                    }
                }
            }
            if !instance.manifest.commands.isEmpty {
                section("Commands") {
                    ForEach(instance.manifest.commands, id: \.command) { command in
                        Button(command.paletteTitle) { workspace.extensions.run(command.command) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(!instance.isEnabled)
                    }
                }
            }
            if !instance.manifest.settings.isEmpty {
                section("Settings") {
                    ForEach(instance.manifest.settings.keys.sorted(), id: \.self) { key in
                        SettingField(store: workspace.extensions.store, manifest: instance.manifest, key: key)
                    }
                }
            }
            section("Log") {
                if instance.log.isEmpty {
                    Text("Nothing logged.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(instance.log.suffix(200)) { entry in
                                Text(entry.message)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(entry.level == "error" ? .red : entry.level == "warning" ? .orange : .primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                    Button("Clear Log") { instance.clearLog() }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Edits one extension setting: a switch, a text field or a number.
private struct SettingField: View {
    let store: ExtensionStore
    let manifest: ExtensionManifest
    let key: String
    @State private var text = ""

    private var setting: ExtensionManifest.Setting? { manifest.settings[key] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch setting?.type {
            case .boolean:
                Toggle(key, isOn: Binding(get: { store.setting(key, of: manifest)?.bool ?? false },
                                          set: { store.setSetting(key, to: .bool($0), of: manifest.id) }))
                    .toggleStyle(.checkbox)
            default:
                HStack {
                    Text(key)
                    TextField(key, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                }
            }
            if let description = setting?.description {
                Text(description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .onAppear {
            let value = store.setting(key, of: manifest)
            text = value?.string ?? value?.number.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
        }
    }

    private func save() {
        if setting?.type == .number {
            guard let number = Double(text) else { NSSound.beep(); return }
            store.setSetting(key, to: .number(number), of: manifest.id)
        } else {
            store.setSetting(key, to: .string(text), of: manifest.id)
        }
    }
}
