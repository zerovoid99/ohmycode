import Foundation

/// A new extension's starting files: a Hello World command in TypeScript, already compiled
/// so it runs before any build tools are installed.
enum ExtensionScaffold {
    enum ScaffoldError: LocalizedError {
        case emptyName
        case exists(String)
        case missingTypes

        var errorDescription: String? {
            switch self {
            case .emptyName: "The extension needs a name with letters or digits."
            case .exists(let path): "\(path) already exists."
            case .missingTypes: "The API types (omc.d.ts) are missing from the app."
            }
        }
    }

    /// "My Tool!" → "my-tool".
    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var result = ""
        // "Ünïcode" → "unicode": accents dropped, other non-ASCII letters separate words.
        for scalar in name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased().unicodeScalars {
            if allowed.contains(scalar) && scalar.isASCII { result.unicodeScalars.append(scalar) }
            else if !result.isEmpty && !result.hasSuffix("-") { result += "-" }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// "my-tool" → "myTool", for command ids.
    static func camel(_ slug: String) -> String {
        let parts = slug.split(separator: "-")
        guard let first = parts.first else { return slug }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static var typesURL: URL? { Bundle.main.url(forResource: "omc.d", withExtension: "ts") }

    /// Writes the extension into a new folder named after it inside `parent`; returns the folder.
    @discardableResult
    static func create(named name: String, in parent: URL, types: URL? = typesURL) throws -> URL {
        let slug = slug(name)
        guard !slug.isEmpty else { throw ScaffoldError.emptyName }
        guard let types else { throw ScaffoldError.missingTypes }
        let folder = parent.appending(path: slug, directoryHint: .isDirectory)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: folder.path) else { throw ScaffoldError.exists(folder.path) }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "\(camel(slug)).helloWorld"
        let manifest: [String: Any] = [
            "id": "local.\(slug)",
            "name": displayName,
            "version": "0.0.1",
            "description": "",
            "main": "dist/extension.js",
            "activationEvents": [],
            "contributes": ["commands": [["command": command, "title": "Hello World", "category": displayName]]],
            "permissions": [],
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let quotedName = String(decoding: try JSONSerialization.data(withJSONObject: displayName, options: .fragmentsAllowed), as: UTF8.self)
        let files: [String: String] = [
            "extension.json": String(decoding: json, as: UTF8.self) + "\n",
            "src/extension.ts": """
            import * as omc from "omc";

            export function activate(context: omc.ExtensionContext) {
              context.subscriptions.push(
                omc.commands.registerCommand("\(command)", async () => {
                  await omc.window.showInformationMessage("Hello from " + \(quotedName) + "!");
                }),
              );
            }

            export function deactivate() {}

            """,
            "dist/extension.js": """
            "use strict";
            // Compiled from src/extension.ts: run `npm run build` after changing it.
            Object.defineProperty(exports, "__esModule", { value: true });
            exports.activate = activate;
            exports.deactivate = deactivate;
            const omc = require("omc");
            function activate(context) {
                context.subscriptions.push(omc.commands.registerCommand("\(command)", async () => {
                    await omc.window.showInformationMessage("Hello from " + \(quotedName) + "!");
                }));
            }
            function deactivate() { }

            """,
            "tsconfig.json": """
            {
              "compilerOptions": {
                "target": "ES2020",
                "module": "commonjs",
                "outDir": "dist",
                "rootDir": "src",
                "strict": true,
                "types": [],
                "lib": ["ES2020"]
              },
              "files": ["omc.d.ts", "src/extension.ts"]
            }

            """,
            "package.json": """
            {
              "name": "\(slug)",
              "private": true,
              "scripts": {
                "build": "tsc -p .",
                "watch": "tsc -p . --watch"
              },
              "devDependencies": {
                "typescript": "^5.6.0"
              }
            }

            """,
            "README.md": """
            # \(displayName)

            An Oh My Code extension.

            - `src/extension.ts`: the code. `npm install`, then `npm run build` (or `npm run watch`)
              compiles it to `dist/extension.js`.
            - `extension.json`: its id, commands, settings, keybindings and permissions.
            - `omc.d.ts`: the API's types.

            Installed for development, the editor runs it from this folder: after building, use
            Extensions → + → Reload Extensions.

            """,
            ".gitignore": "node_modules/\n",
        ]
        for (path, text) in files {
            let url = folder.appending(path: path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try fileManager.copyItem(at: types, to: folder.appending(path: "omc.d.ts"))
        return folder
    }
}
