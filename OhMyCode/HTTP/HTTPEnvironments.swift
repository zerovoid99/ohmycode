import Foundation

/// The environments a `.http` file can be sent with, from both places other editors keep them:
///
/// - VS Code's REST Client: `rest-client.environmentVariables` in the folder's
///   `.vscode/settings.json` or `.omc/settings.json` (the latter wins).
/// - JetBrains' HTTP Client: `http-client.env.json`, overridden by `http-client.private.env.json`
///   (secrets kept out of git), the nearest ones from the file's folder up to the workspace folder.
///
/// `$shared` variables apply to every environment (and when none is chosen); an environment's
/// own win over them.
struct HTTPEnvironments: Equatable, Sendable {
    static let sharedName = "$shared"
    static let settingsKey = "rest-client.environmentVariables"
    static let publicFile = "http-client.env.json"
    static let privateFile = "http-client.private.env.json"

    var shared: [String: String] = [:]
    var environments: [String: [String: String]] = [:]
    /// Where they were read from (shown in the picker).
    var sources: [URL] = []

    var names: [String] { environments.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    /// The variables of `name` (nil: no environment, only the shared ones).
    func variables(for name: String?) -> [String: String] {
        var result = shared
        if let name, let own = environments[name] { result.merge(own) { $1 } }
        return result
    }

    /// Adds `other`'s environments, its variables winning.
    mutating func merge(_ other: HTTPEnvironments) {
        shared.merge(other.shared) { $1 }
        for (name, variables) in other.environments { environments[name, default: [:]].merge(variables) { $1 } }
        sources += other.sources
    }

    /// `{"$shared": {...}, "dev": {...}}`: string, number and boolean values (others, like
    /// JetBrains' auth objects, are skipped).
    static func parse(_ object: Any?) -> HTTPEnvironments {
        var result = HTTPEnvironments()
        guard let object = object as? [String: Any] else { return result }
        for (name, value) in object {
            guard let values = value as? [String: Any] else { continue }
            var variables: [String: String] = [:]
            for (key, raw) in values {
                switch raw {
                case let string as String: variables[key] = string
                case let number as NSNumber: variables[key] = JSONPath.string(number)
                default: continue
                }
            }
            if name == sharedName { result.shared = variables } else { result.environments[name] = variables }
        }
        return result
    }

    /// From a settings file's `rest-client.environmentVariables` (comments allowed).
    static func fromSettings(_ data: Data) -> HTTPEnvironments {
        let cleaned = ProjectSettings.stripComments(String(decoding: data, as: UTF8.self))
        let object = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any]
        return parse(object?[settingsKey])
    }

    /// From a JetBrains env file.
    static func fromEnvFile(_ data: Data) -> HTTPEnvironments {
        let cleaned = ProjectSettings.stripComments(String(decoding: data, as: UTF8.self))
        return parse(try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)))
    }

    /// Folders from the file's up to `root` (inclusive), nearest first; just the file's when it
    /// isn't inside `root`.
    static func folders(from file: URL, upTo root: URL?) -> [URL] {
        var folder = file.deletingLastPathComponent().standardizedFileURL
        guard let root = root?.standardizedFileURL, folder.path == root.path || folder.path.hasPrefix(root.path + "/") else {
            return [folder]
        }
        var result = [folder]
        while folder.path != root.path, folder.path.count > root.path.count {
            folder = folder.deletingLastPathComponent()
            result.append(folder)
        }
        return result
    }

    /// Everything that applies to `file` in the workspace folder `root`.
    static func load(for file: URL, root: URL?) -> HTTPEnvironments {
        var result = HTTPEnvironments()
        if let root {
            for path in [".vscode/settings.json", ProjectSettings.file] {
                let url = root.appending(path: path)
                if let data = try? Data(contentsOf: url) {
                    var found = fromSettings(data)
                    if !found.environments.isEmpty || !found.shared.isEmpty { found.sources = [url]; result.merge(found) }
                }
            }
        }
        let folders = folders(from: file, upTo: root)
        for name in [publicFile, privateFile] {
            guard let url = folders.lazy.map({ $0.appending(path: name) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let data = try? Data(contentsOf: url) else { continue }
            var found = fromEnvFile(data)
            found.sources = [url]
            result.merge(found)
        }
        return result
    }
}

/// `.env` files: `KEY=value` lines (`export` allowed), quoted values, `#` comments.
enum DotEnv {
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in HTTPFile.lines(of: text) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
                if quote == "\"" { value = value.replacingOccurrences(of: "\\n", with: "\n") }
            } else if let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// The `.env` next to `file`, else the one in the workspace folder (both, the nearer winning).
    static func load(for file: URL, root: URL?) -> [String: String] {
        var result: [String: String] = [:]
        var folders = [file.deletingLastPathComponent()]
        if let root, root.standardizedFileURL.path != folders[0].standardizedFileURL.path { folders.insert(root, at: 0) }
        for folder in folders {
            if let text = try? String(contentsOf: folder.appending(path: ".env"), encoding: .utf8) {
                result.merge(parse(text)) { $1 }
            }
        }
        return result
    }
}
