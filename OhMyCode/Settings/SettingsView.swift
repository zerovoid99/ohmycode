import SwiftUI

/// Settings window (⌘,). Changes apply immediately to open editors and terminals.
struct SettingsView: View {
    @Bindable var settings = AppSettings.shared

    var body: some View {
        TabView {
            Tab("Appearance", systemImage: "paintpalette") { appearance }
            Tab("Editor", systemImage: "doc.text") { editor }
            Tab("Terminal", systemImage: "terminal") { terminal }
        }
        .frame(width: 520)
    }

    // MARK: Appearance

    private var appearance: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Section("Color Theme") {
                ForEach(EditorTheme.themes) { theme in
                    ThemeRow(theme: theme, isSelected: settings.themeID == theme.id)
                        .contentShape(Rectangle())
                        .onTapGesture { settings.themeID = theme.id }
                }
            }
            restoreDefaults
        }
        .formStyle(.grouped)
    }

    // MARK: Editor

    private var editor: some View {
        Form {
            FontFamilyPicker(title: "Font", selection: $settings.editorFontFamily, defaultLabel: "System Monospaced (SF Mono)")
            FontSizeField(title: "Size", size: $settings.editorFontSize)
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
