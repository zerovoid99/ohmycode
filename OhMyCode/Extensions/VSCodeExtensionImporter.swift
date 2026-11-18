import AppKit

/// Turns an unpacked VS Code language extension (a folder with a package.json, or an unzipped
/// .vsix with it under `extension/`) into an Oh My Code extension: its languages, grammars
/// and snippets, with the files they name. Code (`main`) isn't brought over: VS Code's API
/// isn't this one; the result is declarations only.
enum VSCodeExtensionImporter {
    enum ImportError: LocalizedError {
        case noPackage
        case unreadable(String)
        case nothingToImport

        var errorDescription: String? {
            switch self {
            case .noPackage: "The folder has no package.json (unzip the .vsix first: its files are under “extension/”)."
            case .unreadable(let detail): "package.json can't be read: \(detail)"
            case .nothingToImport: "The extension contributes no languages, grammars or snippets."
            }
        }
    }

    struct Result {
        /// The converted extension's folder (install it from there).
        let folder: URL
        let manifest: ExtensionManifest
        /// What was left out, and why.
        let warnings: [String]
    }

    /// The folder holding package.json: `source` itself or its `extension/` (an unzipped .vsix).
    static func packageFolder(_ source: URL) -> URL? {
        for folder in [source, source.appending(path: "extension")]
        where FileManager.default.fileExists(atPath: folder.appending(path: "package.json").path) {
            return folder
        }
        return nil
    }

    /// Writes the converted extension into a new folder in `parent`.
    static func convert(_ source: URL, into parent: URL) throws -> Result {
        guard let folder = packageFolder(source) else { throw ImportError.noPackage }
        let package: [String: Any]
        do {
            package = try VSCodeTheme.jsonObject(Data(contentsOf: folder.appending(path: "package.json")))
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
        let contributes = package["contributes"] as? [String: Any] ?? [:]
        var warnings: [String] = []
        var files: [String] = []

        /// A path the package names, if it's inside the package and exists (it's copied).
        func file(_ path: Any?) -> String? {
            guard let path = path as? String else { return nil }
            guard ExtensionManifest.inside(folder, path) != nil,
                  FileManager.default.fileExists(atPath: folder.appending(path: path).path) else {
                warnings.append("\(path) is missing or outside the extension: left out.")
                return nil
            }
            files.append(path)
            return path
        }

        var languages: [[String: Any]] = []
        for case let language as [String: Any] in contributes["languages"] as? [Any] ?? [] {
            guard let id = language["id"] as? String else { continue }
            var converted: [String: Any] = ["id": id]
            for key in ["aliases", "extensions", "filenames", "filenamePatterns"] {
                if let values = language[key] as? [String] { converted[key] = values }
            }
            if let firstLine = language["firstLine"] as? String { converted["firstLine"] = firstLine }
            if let configuration = file(language["configuration"]) { converted["configuration"] = configuration }
            languages.append(converted)
        }

        var grammars: [[String: Any]] = []
        for case let grammar as [String: Any] in contributes["grammars"] as? [Any] ?? [] {
            guard let scopeName = grammar["scopeName"] as? String, let rawPath = grammar["path"] as? String else { continue }
            let ext = (rawPath as NSString).pathExtension.lowercased()
            if ext == "yaml" || ext == "yml" {
                warnings.append("\(rawPath): YAML grammars aren't supported; convert it to .tmLanguage.json.")
                continue
            }
            guard let path = file(rawPath) else { continue }
            var converted: [String: Any] = ["scopeName": scopeName, "path": path]
            for key in ["language", "embeddedLanguages", "tokenTypes", "injectTo"] where grammar[key] != nil {
                converted[key] = grammar[key]
            }
            grammars.append(converted)
        }

        var snippets: [[String: Any]] = []
        for case let snippet as [String: Any] in contributes["snippets"] as? [Any] ?? [] {
            guard let path = file(snippet["path"]) else { continue }
            var converted: [String: Any] = ["path": path]
            if let language = snippet["language"] as? String { converted["language"] = language }
            snippets.append(converted)
        }
        guard !languages.isEmpty || !grammars.isEmpty || !snippets.isEmpty else { throw ImportError.nothingToImport }
        if package["main"] != nil || package["browser"] != nil {
            warnings.append("Its code (completion, commands…) isn't imported: only languages, grammars and snippets.")
        }

        let name = package["name"] as? String ?? folder.lastPathComponent
        let publisher = package["publisher"] as? String ?? "vscode"
        let id = "\(identifier(publisher)).\(identifier(name))"
        var contributions: [String: Any] = [:]
        if !languages.isEmpty { contributions["languages"] = languages }
        if !grammars.isEmpty { contributions["grammars"] = grammars }
        if !snippets.isEmpty { contributions["snippets"] = snippets }
        var manifest: [String: Any] = [
            "id": id,
            "name": (package["displayName"] as? String).flatMap { $0.hasPrefix("%") ? nil : $0 } ?? name,
            "version": package["version"] as? String ?? "0.0.0",
            "publisher": publisher,
            "main": "extension.js",
            "contributes": contributions,
        ]
        if let description = package["description"] as? String, !description.hasPrefix("%") {
            manifest["description"] = description
        }

        let destination = parent.appending(path: id, directoryHint: .isDirectory)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let notices = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter {
            let upper = $0.uppercased()
            return upper.hasPrefix("LICENSE") || upper.hasPrefix("LICENCE") || upper.hasPrefix("NOTICE") || upper.hasPrefix("THIRDPARTY")
                || upper == "README.MD"
        }
        for path in Set(files + notices) {
            let target = destination.appending(path: path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.removeItem(at: target)
            try fileManager.copyItem(at: folder.appending(path: path), to: target)
        }
        try "// Converted from the VS Code extension \(publisher).\(name): languages, grammars and snippets only.\n"
            .write(to: destination.appending(path: "extension.js"), atomically: true, encoding: .utf8)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: destination.appending(path: "extension.json"))
        return Result(folder: destination, manifest: try ExtensionManifest.load(from: destination), warnings: warnings)
    }

    /// Letters, digits, - and _ (what extension ids allow).
    static func identifier(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(text.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        return cleaned.isEmpty ? "extension" : cleaned
    }
}

extension Workspace {
    /// Tests answer this instead of the folder dialog: the VS Code extension's folder.
    static var vsCodeExtensionChooser: (() -> URL?)?

    /// Import VS Code Language Extension: converts an unpacked VS Code extension and installs
    /// the result (after the usual install dialog).
    func importVSCodeExtension() {
        let source = Self.vsCodeExtensionChooser.map { $0() } ?? {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = "Choose an unpacked VS Code extension's folder (it has a package.json)"
            panel.prompt = "Import"
            return panel.runModal() == .OK ? panel.url : nil
        }()
        guard let source else { return }
        let staging = FileManager.default.temporaryDirectory.appending(path: "omc-vscode-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let result = try VSCodeExtensionImporter.convert(source, into: staging)
            installExtension(from: result.folder, development: false)
            if !result.warnings.isEmpty {
                let message = result.warnings.joined(separator: " ")
                Task { _ = await notify(.warning, message, source: result.manifest.name) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
