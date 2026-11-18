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
    /// Spell checking in the folder's files, over the app's setting.
    var spellCheck: Bool?
    /// `files.associations`: glob → language id, over the app's.
    var fileAssociations: [String: String]?
    /// `languageServers.<id>.enabled`, over the app's.
    var languageServersEnabled: [String: Bool] = [:]

    /// The names it understands, for the template and for warnings.
    static let keys = ["formatOnSave", "formatOnSaveScope", "autoSave", "autoSaveDelay", "wordWrap", "renderWhitespace",
                       "showsInlayHints", "semanticHighlighting", "showsCodeLens", "files.associations", "spellCheck"]

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
        spellCheck = object["spellCheck"] as? Bool
        fileAssociations = object["files.associations"] as? [String: String]
        for (key, value) in object where key.hasPrefix("languageServers.") && key.hasSuffix(".enabled") {
            if let enabled = value as? Bool { languageServersEnabled[String(key.dropFirst(16).dropLast(8))] = enabled }
        }
        // REST Client's environments are read by the HTTP client (see `HTTPEnvironments`).
        unknownKeys = object.keys.filter { !Self.keys.contains($0) && !$0.hasPrefix("rest-client.") && !$0.hasPrefix("languageServers.") }.sorted()
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
      // "showsCodeLens": true,
      // "spellCheck": true,                     // words to accept: .omc/dictionary.txt
      // "files.associations": { "*.tpl": "html" },
      // "languageServers.rust-analyzer.enabled": false
    }

    """
}

extension Workspace {
    /// The effective settings for this window: the folder's over the app's.
    var formatsOnSave: Bool { formatOnSave ?? projectSettings.formatOnSave ?? AppSettings.shared.formatOnSave }
    var effectiveFormatOnSaveScope: FormatOnSaveScope { projectSettings.formatOnSaveScope ?? AppSettings.shared.formatOnSaveScope }
    var effectiveAutoSave: AutoSave { projectSettings.autoSave ?? AppSettings.shared.autoSave }
    var effectiveAutoSaveDelay: Double { projectSettings.autoSaveDelay ?? AppSettings.shared.autoSaveDelay }

    /// Reads every folder's `.omc/settings.json` again (opening the folders, or after one
    /// changed); editors restyle with the new values. The window's own settings (auto save) are
    /// the first folder's, over the workspace file's.
    func loadProjectSettings() {
        var all: [URL: ProjectSettings] = [:]
        for folder in folders {
            var settings = ProjectSettings()
            let name = isMultiRoot ? label(of: folder) + "/" + ProjectSettings.file : ProjectSettings.file
            if let data = try? Data(contentsOf: folder.appending(path: ProjectSettings.file)) {
                do {
                    settings = try ProjectSettings(json: data)
                    if !settings.unknownKeys.isEmpty {
                        let names = settings.unknownKeys.map { "“\($0)”" }.joined(separator: ", ")
                        Task { _ = await notify(.warning, "\(name): \(names) isn't a setting it knows.", source: nil) }
                    }
                } catch {
                    Task { _ = await notify(.warning, "\(name) couldn't be read: it isn't valid JSON.", source: nil) }
                }
            }
            all[folder] = settings
        }
        let primary = (rootURL.flatMap { all[$0] } ?? ProjectSettings()).over(workspaceSettings)
        guard all != folderSettings || primary != projectSettings else { return }
        folderSettings = all
        projectSettings = primary
        // Editors apply settings when they change: the same path as the app's.
        for document in documents { document.editors.forEach { $0.projectSettingsChanged() } }
        updateLanguageModes()
        refreshLanguageServerSettings()
    }

    /// Whether a file is one of the folders' `.omc/settings.json`.
    func isProjectSettingsFile(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return folders.contains { $0.appending(path: ProjectSettings.file).standardizedFileURL.path == path }
    }

    /// Preferences: Open Folder Settings: `.omc/settings.json` (the active file's folder's, or
    /// the first folder's), written from a template first.
    func openProjectSettings() {
        guard let root = activeDocument.flatMap({ folder(containing: $0.url) }) ?? rootURL else { NSSound.beep(); return }
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
    /// The settings of the folder it's in (over the workspace file's); none outside a folder.
    var projectSettings: ProjectSettings { workspace?.settings(for: url) ?? ProjectSettings() }
}
