import AppKit

/// A folder's own settings, from `.omc/settings.json`: they override the app's for files in it.
/// Unset ones (or unknown, or of the wrong type) leave the app's setting.
struct ProjectSettings: Equatable {
    static let file = ".omc/settings.json"

    var formatOnSave: Bool?
    var formatOnSaveScope: FormatOnSaveScope?
    var autoSave: AutoSave?
    var autoSaveDelay: Double?
    var wordWrap: WordWrap?
    var renderWhitespace: RenderWhitespace?
    var showsInlayHints: Bool?
    var semanticHighlighting: Bool?
    var showsCodeLens: Bool?

    /// The names it understands, for the template and for warnings.
    static let keys = ["formatOnSave", "formatOnSaveScope", "autoSave", "autoSaveDelay", "wordWrap", "renderWhitespace",
                       "showsInlayHints", "semanticHighlighting", "showsCodeLens"]

    init() {}

    /// Reads the settings; also what it didn't understand (to say so).
    init(json data: Data) throws {
        // Comments and trailing commas, as people write them in VS Code settings.
        let cleaned = Self.stripComments(String(decoding: data, as: UTF8.self))
        guard let object = try JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        formatOnSave = object["formatOnSave"] as? Bool
        formatOnSaveScope = (object["formatOnSaveScope"] as? String).flatMap(FormatOnSaveScope.init(rawValue:))
        autoSave = (object["autoSave"] as? String).flatMap(AutoSave.init(rawValue:))
        autoSaveDelay = (object["autoSaveDelay"] as? NSNumber).map { min(max($0.doubleValue, 0.2), 60) }
        wordWrap = (object["wordWrap"] as? String).flatMap(WordWrap.init(rawValue:))
        renderWhitespace = (object["renderWhitespace"] as? String).flatMap(RenderWhitespace.init(rawValue:))
        showsInlayHints = object["showsInlayHints"] as? Bool
        semanticHighlighting = object["semanticHighlighting"] as? Bool
        showsCodeLens = object["showsCodeLens"] as? Bool
        unknownKeys = object.keys.filter { !Self.keys.contains($0) }.sorted()
    }

    /// Names in the file it didn't understand.
    var unknownKeys: [String] = []

    /// `//` and `/* */` comments and trailing commas out (outside strings).
    static func stripComments(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        var inString = false
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inString {
                result.append(character)
                if character == "\\", next < text.endIndex { result.append(text[next]); index = text.index(after: next); continue }
                if character == "\"" { inString = false }
                index = next
                continue
            }
            if character == "\"" { inString = true; result.append(character); index = next; continue }
            if character == "/", next < text.endIndex, text[next] == "/" {
                index = text[next...].firstIndex(of: "\n") ?? text.endIndex
                continue
            }
            if character == "/", next < text.endIndex, text[next] == "*" {
                let rest = text[text.index(after: next)...]
                index = rest.range(of: "*/").map(\.upperBound) ?? text.endIndex
                continue
            }
            result.append(character)
            index = next
        }
        // Trailing commas before } or ].
        return result.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
    }

    static let template = """
    // Settings for this folder: they override Oh My Code's for files in it. Remove a line to use
    // the app's setting again.
    {
      // "formatOnSave": true,
      // "formatOnSaveScope": "modifications",   // or "file"
      // "autoSave": "afterDelay",               // "off", "afterDelay", "onFocusChange"
      // "autoSaveDelay": 1,
      // "wordWrap": "prose",                    // "off", "on", "prose"
      // "renderWhitespace": "boundary",         // "none", "selection", "boundary", "all"
      // "showsInlayHints": true,
      // "semanticHighlighting": true,
      // "showsCodeLens": true
    }

    """
}

extension Workspace {
    /// The effective settings for this window: the folder's over the app's.
    var formatsOnSave: Bool { formatOnSave ?? projectSettings.formatOnSave ?? AppSettings.shared.formatOnSave }
    var effectiveFormatOnSaveScope: FormatOnSaveScope { projectSettings.formatOnSaveScope ?? AppSettings.shared.formatOnSaveScope }
    var effectiveAutoSave: AutoSave { projectSettings.autoSave ?? AppSettings.shared.autoSave }
    var effectiveAutoSaveDelay: Double { projectSettings.autoSaveDelay ?? AppSettings.shared.autoSaveDelay }

    /// Reads `.omc/settings.json` again (opening the folder, or after it changed); editors
    /// restyle with the new values.
    func loadProjectSettings() {
        var settings = ProjectSettings()
        if let root = rootURL, let data = try? Data(contentsOf: root.appending(path: ProjectSettings.file)) {
            do {
                settings = try ProjectSettings(json: data)
                if !settings.unknownKeys.isEmpty {
                    let names = settings.unknownKeys.map { "“\($0)”" }.joined(separator: ", ")
                    Task { _ = await notify(.warning, "\(ProjectSettings.file): \(names) isn't a setting it knows.", source: nil) }
                }
            } catch {
                Task { _ = await notify(.warning, "\(ProjectSettings.file) couldn't be read: it isn't valid JSON.", source: nil) }
            }
        }
        guard settings != projectSettings else { return }
        projectSettings = settings
        // Editors apply settings when they change: the same path as the app's.
        for document in documents { document.editors.forEach { $0.projectSettingsChanged() } }
    }

    /// Preferences: Open Folder Settings: `.omc/settings.json`, written from a template first.
    func openProjectSettings() {
        guard let root = rootURL else { NSSound.beep(); return }
        let url = root.appending(path: ProjectSettings.file)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ProjectSettings.template.write(to: url, atomically: true, encoding: .utf8)
            }
            open(fileAt: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension EditorDocument {
    /// The folder's settings (none outside a folder).
    var projectSettings: ProjectSettings { workspace?.projectSettings ?? ProjectSettings() }
}
