import AppKit
import SwiftUI

/// Opens Settings at Keyboard Shortcuts.
@MainActor
enum KeyboardShortcutsWindow {
    static let tab = "keyboard"

    static func show() {
        UserDefaults.omc.set(tab, forKey: SettingsView.tabKey)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate()
    }
}

/// Settings → Keyboard Shortcuts: every command's shortcut; click one to record another.
struct KeyboardShortcutsView: View {
    var bindings = Keybindings.shared
    @State private var query = ""
    @State private var changedOnly = false
    @State private var recording: String?
    @State private var selection: String?

    struct Row: Identifiable {
        let command: Keybindings.Command
        let chord: KeyChord?
        let source: Keybindings.Source
        let conflicts: [String]
        var id: String { command.id }
    }

    private var rows: [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return bindings.commands.compactMap { command in
            let chord = bindings.chord(for: command.id)
            let source = bindings.source(for: command.id)
            if changedOnly, source != .user, source != .removed { return nil }
            if !needle.isEmpty {
                let text = [command.title, command.id, chord?.display ?? "", chord?.spec ?? "", command.extensionName ?? ""]
                    .joined(separator: " ").lowercased()
                guard needle.split(separator: " ").allSatisfy({ text.contains($0) }) else { return nil }
            }
            let conflicts = chord.map { bindings.conflicts(with: $0, except: command.id) } ?? []
            return Row(command: command, chord: chord, source: source, conflicts: conflicts)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search", text: $query, prompt: Text("Search commands or shortcuts (e.g. “⌘B”, “cmd+shift”, “debug”)"))
                    .textFieldStyle(.roundedBorder)
                Toggle("Changed only", isOn: $changedOnly)
                    .toggleStyle(.checkbox)
                Button {
                    bindings.reloadIfChanged()
                    NSWorkspace.shared.activateFileViewerSelecting([bindings.file])
                } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .help("Show keybindings.json in Finder")
                    .disabled(!FileManager.default.fileExists(atPath: bindings.file.path))
            }
            if let error = bindings.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Table(rows, selection: $selection) {
                TableColumn("Command") { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.command.title)
                        Text(row.command.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .width(min: 220, ideal: 330)
                TableColumn("Shortcut") { row in shortcutCell(row) }
                    .width(min: 140, ideal: 170)
                TableColumn("Source") { row in
                    Text(sourceText(row.source)).foregroundStyle(row.source == .user || row.source == .removed ? .primary : .secondary)
                }
                .width(min: 70, ideal: 100)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button("Change Shortcut…") { recording = id }
                    Button("Remove Shortcut") { bindings.set(nil, for: id) }
                        .disabled(bindings.chord(for: id) == nil)
                    Button("Reset to Default") { bindings.reset(id) }
                        .disabled(bindings.source(for: id) != .user && bindings.source(for: id) != .removed)
                    Divider()
                    Button("Copy Command ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                    }
                }
            } primaryAction: { ids in
                recording = ids.first
            }
            Text("Double-click a command (or its shortcut) and press the new keys; Esc cancels. Shortcuts need ⌘, ⌃ or ⌥, or a function key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { bindings.reloadIfChanged() }
    }

    @ViewBuilder
    private func shortcutCell(_ row: Row) -> some View {
        if recording == row.id {
            ShortcutRecorder(onRecord: { chord in
                bindings.set(chord, for: row.id)
                recording = nil
            }, onCancel: { recording = nil })
            .frame(height: 20)
        } else {
            HStack(spacing: 4) {
                Text(row.chord?.display ?? "—")
                    .font(.system(.body, design: .rounded).monospaced())
                    .foregroundStyle(row.chord == nil ? .tertiary : .primary)
                if !row.conflicts.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Also the shortcut of " + row.conflicts.map { id in
                            bindings.commands.first { $0.id == id }?.title ?? id
                        }.joined(separator: ", "))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { recording = row.id }
        }
    }

    private func sourceText(_ source: Keybindings.Source) -> String {
        switch source {
        case .none: ""
        case .builtIn: "Default"
        case .extension(let name): name
        case .user: "User"
        case .removed: "Removed"
        }
    }
}

/// Captures the next key press (⌘ shortcuts included) as a chord.
struct ShortcutRecorder: NSViewRepresentable {
    let onRecord: (KeyChord) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onRecord = onRecord
        view.onCancel = onCancel
    }

    final class RecorderView: NSView {
        var onRecord: ((KeyChord) -> Void)?
        var onCancel: (() -> Void)?
        private var finished = false

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
            let text = NSAttributedString(string: "Press keys…", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            text.draw(at: NSPoint(x: 6, y: (bounds.height - text.size().height) / 2))
        }

        /// ⌘ shortcuts reach here before the menus.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            handle(event)
            return true
        }

        override func keyDown(with event: NSEvent) { handle(event) }

        override func resignFirstResponder() -> Bool {
            if !finished { finished = true; DispatchQueue.main.async { [onCancel] in onCancel?() } }
            return true
        }

        func handle(_ event: NSEvent) {
            guard !finished else { return }
            if event.keyCode == 53, event.modifierFlags.intersection(KeyChord.relevantModifiers).isEmpty {
                finished = true
                onCancel?()
                return
            }
            guard let chord = KeyChord(event: event) else { NSSound.beep(); return }
            finished = true
            onRecord?(chord)
        }
    }
}
