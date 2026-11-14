import UniformTypeIdentifiers
import SwiftUI

/// Settings window (⌘,). Changes apply immediately to open editors and terminals.
struct SettingsView: View {
    @Bindable var settings = AppSettings.shared
    private let library = ThemeLibrary.shared
    @State private var importError: String?
    static let tabKey = "settings.tab"
    @AppStorage(SettingsView.tabKey) private var tab = "appearance"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") { appearance.frame(width: 520) }
            Tab("Editor", systemImage: "doc.text", value: "editor") { editor.frame(width: 520) }
            Tab("Terminal", systemImage: "terminal", value: "terminal") { terminal.frame(width: 520) }
            Tab("Keyboard Shortcuts", systemImage: "keyboard", value: KeyboardShortcutsWindow.tab) {
                KeyboardShortcutsView().frame(width: 760, height: 520)
            }
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(settings.themeSetsAppearance)
            if settings.themeSetsAppearance {
                Text("The selected theme sets light or dark for the whole window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(EditorTheme.builtInThemes + library.themes) { theme in
                    ThemeRow(theme: theme, isSelected: settings.themeID == theme.id,
                             onRemove: library.isImported(theme.id) ? { library.remove(theme.id) } : nil)
                        .contentShape(Rectangle())
                        .onTapGesture { settings.themeID = theme.id }
                }
            } header: {
                Text("Color Theme")
            } footer: {
                HStack {
                    Text("VS Code themes (.json) can be imported, e.g. from an extension's themes folder.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Import VS Code Theme…", action: importTheme)
                }
            }
            restoreDefaults
        }
        .formStyle(.grouped)
        .alert("Couldn't Import Theme", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose VS Code color theme files (.json)"
        guard panel.runModal() == .OK else { return }
        var last: EditorThemeDefinition?
        for url in panel.urls {
            do {
                last = try library.importTheme(from: url)
            } catch {
                importError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if let last { settings.themeID = last.id }
    }

    // MARK: Editor

    private var editor: some View {
        Form {
            FontFamilyPicker(title: "Font", selection: $settings.editorFontFamily, defaultLabel: "System Monospaced (SF Mono)")
            FontSizeField(title: "Size", size: $settings.editorFontSize)
            Toggle("Show minimap", isOn: $settings.showsMinimap)
            Toggle("Sticky scroll (keep enclosing declarations at the top)", isOn: $settings.stickyScroll)
            Toggle("Close brackets and quotes automatically", isOn: $settings.autoClosePairs)
            Toggle("Format on save (with the language server)", isOn: $settings.formatOnSave)
            Toggle("Show git blame for the current line", isOn: $settings.showsLineBlame)
            Toggle("Show breadcrumbs (path and symbols above the editor)", isOn: $settings.showsBreadcrumbs)
            Toggle("Stage files when their merge conflicts are resolved and saved", isOn: $settings.stagesResolvedConflicts)
            Section("Preview") {
                CodePreview(font: settings.editorFont, theme: EditorTheme.themes.first { $0.id == settings.themeID }
                            ?? EditorTheme.defaultTheme)
            }
            Text("Zoom with ⌘+ and ⌘−, reset with ⌘0 (editor and terminal together).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    // MARK: Terminal

    private var terminal: some View {
        Form {
            FontFamilyPicker(title: "Font", selection: $settings.terminalFontFamily, defaultLabel: "Same as Editor")
            FontSizeField(title: "Size", size: $settings.terminalFontSize)
            Section("Preview") {
                CodePreview(font: settings.terminalFont(), theme: EditorTheme.themes.first { $0.id == settings.themeID }
                            ?? EditorTheme.defaultTheme, terminal: true)
            }
        }
        .formStyle(.grouped)
    }

    private var restoreDefaults: some View {
        HStack {
            Spacer()
            Button("Restore Defaults") { settings.restoreDefaults() }
        }
    }
}

private struct FontFamilyPicker: View {
    let title: String
    @Binding var selection: String
    let defaultLabel: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text(defaultLabel).tag("")
            Divider()
            ForEach(AppSettings.monospacedFamilies, id: \.self) { family in
                Text(family).font(.custom(family, size: 13)).tag(family)
            }
        }
    }
}

private struct FontSizeField: View {
    let title: String
    @Binding var size: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $size, format: .number)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $size, in: AppSettings.fontSizes, step: 1).labelsHidden()
                Text("pt").foregroundStyle(.secondary)
            }
        }
    }
}

/// One theme in the list: name and a small swatch of its colors.
private struct ThemeRow: View {
    let theme: EditorThemeDefinition
    let isSelected: Bool
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(theme.name)
            Spacer()
            HStack(spacing: 3) {
                ForEach(["keyword", "string", "type", "function", "comment"], id: \.self) { role in
                    Circle().fill(Color(nsColor: theme.syntax[role] ?? theme.foreground)).frame(width: 9, height: 9)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: theme.background), in: Capsule())
            .environment(\.colorScheme, theme.isDark.map { $0 ? .dark : .light } ?? .light)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove Imported Theme")
            }
        }
    }
}

/// A few lines of code drawn with the theme and font.
private struct CodePreview: View {
    let font: NSFont
    let theme: EditorThemeDefinition
    var terminal = false
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let scheme: ColorScheme = theme.isDark.map { $0 ? .dark : .light } ?? systemScheme
        VStack(alignment: .leading, spacing: 2) {
            if terminal {
                line([("~/project ", "function"), ("$ ", nil), ("git status", nil)])
                line([("On branch ", nil), ("main", "string")])
            } else {
                line([("// Greets someone", "comment")])
                line([("func ", "keyword"), ("greet", "function"), ("(name: ", nil), ("String", "type"), (") {", nil)])
                line([("    print(", nil), ("\"Hello, \\(name)!\"", "string"), (", ", nil), ("42", "number"), (")", nil)])
                line([("}", nil)])
            }
        }
        .font(Font(font))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: theme.background), in: RoundedRectangle(cornerRadius: 6))
        .environment(\.colorScheme, scheme)
    }

    private func line(_ parts: [(String, String?)]) -> Text {
        parts.reduce(Text("")) { text, part in
            text + Text(part.0).foregroundColor(Color(nsColor: part.1.flatMap { theme.syntax[$0] } ?? theme.foreground))
        }
    }
}
