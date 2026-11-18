import Foundation

/// A new extension's starting files: a Hello World command, or Language Support for a toy
/// language, in TypeScript and already compiled so it runs before any build tools are installed.
enum ExtensionScaffold {
    enum Template: String, CaseIterable {
        case helloWorld = "Hello World"
        case languageSupport = "Language Support"

        var detail: String {
            switch self {
            case .helloWorld: "A command that shows a message"
            case .languageSupport: "A .toy language: syntax colors, comments, brackets, indentation, snippets, completion, hover, definitions, symbols"
            }
        }
    }

    enum ScaffoldError: LocalizedError {
        case emptyName
        case exists(String)
        case missingTypes
        case missingTemplate

        var errorDescription: String? {
            switch self {
            case .emptyName: "The extension needs a name with letters or digits."
            case .exists(let path): "\(path) already exists."
            case .missingTypes: "The API types (omc.d.ts) are missing from the app."
            case .missingTemplate: "The Language Support template is missing from the app."
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
    /// The toy language example (ExtensionAPI/examples/toy-language), bundled with the app.
    static var languageTemplateURL: URL? { Bundle.main.url(forResource: "toy-language", withExtension: nil) }

    /// Writes the extension into a new folder named after it inside `parent`; returns the folder.
    @discardableResult
    static func create(named name: String, in parent: URL, types: URL? = typesURL, template: Template = .helloWorld) throws -> URL {
        if template == .languageSupport { return try createLanguageSupport(named: name, in: parent, types: types) }
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

    /// Language Support: the toy language example (its language, configuration, snippets and
    /// providers), as the new extension's own.
    private static func createLanguageSupport(named name: String, in parent: URL, types: URL?) throws -> URL {
        let slug = slug(name)
        guard !slug.isEmpty else { throw ScaffoldError.emptyName }
        guard let types else { throw ScaffoldError.missingTypes }
        guard let template = languageTemplateURL else { throw ScaffoldError.missingTemplate }
        let folder = parent.appending(path: slug, directoryHint: .isDirectory)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: folder.path) else { throw ScaffoldError.exists(folder.path) }
        try fileManager.copyItem(at: template, to: folder)
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Its own id and name; the rest of the manifest is the example's.
        let manifestURL = folder.appending(path: "extension.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        manifest["id"] = "local.\(slug)"
        manifest["name"] = displayName
        manifest["version"] = "0.0.1"
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (String(decoding: json, as: UTF8.self) + "\n").write(to: manifestURL, atomically: true, encoding: .utf8)

        let files: [String: String] = [
            // The example compiles against the repository's types; this one against its copy.
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

            Language support for a toy language (`.toy` files) in Oh My Code: start from it and
            make it yours.

            - `extension.json`: the language (`contributes.languages`: its id, extensions, file
              names, first line), its grammar (`contributes.grammars`) and its snippets
              (`contributes.snippets`).
            - `syntaxes/toy.tmLanguage.json`: the syntax colors, as a TextMate grammar (VS Code's
              format). Developer: Inspect Editor Tokens and Scopes shows the scopes under the caret.
            - `language-configuration.json`: comments, brackets, what closes itself, folding
              markers, what a word is, and how Enter indents.
            - `snippets/toy.json`: snippets, in VS Code's format.
            - `src/extension.ts`: completion, hover, Go to Definition and the Outline. `npm install`,
              then `npm run build` (or `npm run watch`) compiles it to `dist/extension.js`.
            - `sample.toy`: a file to try it on.

            Installed for development, the editor runs it from this folder: after building, use
            Extensions → + → Reload Extensions.

            """,
            ".gitignore": "node_modules/\n",
        ]
        for (path, text) in files {
            try text.write(to: folder.appending(path: path), atomically: true, encoding: .utf8)
        }
        try fileManager.copyItem(at: types, to: folder.appending(path: "omc.d.ts"))
        return folder
    }
}
