import Foundation

/// Which language server handles which languages, and how to start it.
struct LanguageServerConfig: Sendable {
    /// What settings call it (`languageServers.<id>.enabled`) and its clients are keyed by.
    var id: String
    let name: String
    let command: [String]
    let languages: Set<SourceLanguage>
    /// Added to the login shell's environment.
    var environment: [String: String] = [:]
    var initializationOptions: JSONValue?
    /// What `workspace/configuration` answers and `workspace/didChangeConfiguration` sends.
    var settings: JSONValue?
    /// Files that mark a project's root ("Cargo.toml"): the server starts in the nearest folder
    /// above a file that has one (within the workspace), rather than in the workspace folder.
    var rootPatterns: [String] = []
    /// The extension that contributes it (nil: built in).
    var extensionID: String?

    init(id: String? = nil, name: String, command: [String], languages: Set<SourceLanguage>) {
        self.id = id ?? name
        self.name = name
        self.command = command
        self.languages = languages
    }

    static func languageId(for language: SourceLanguage) -> String { language.languageId }
}

/// A server an extension declares (`contributes.languageServers`) or registers
/// (`omc.languages.registerLanguageServer`), before its command is looked up.
struct LanguageServerDefinition: Sendable, Equatable {
    var id: String
    var name: String
    /// Language ids (VS Code's: "rust", "typescriptreact").
    var languages: [String]
    /// A path (relative ones are inside the extension's folder) or a name looked up on the
    /// login shell's PATH.
    var command: String
    var args: [String] = []
    var env: [String: String] = [:]
    var initializationOptions: JSONValue?
    var settings: JSONValue?
    var rootPatterns: [String] = []
    var extensionID: String
    /// The extension's folder.
    var folder: URL

    /// From the manifest's or the API's JSON; nil without an id, languages or a command, or
    /// for a transport other than stdio.
    init?(json: JSONValue, extensionID: String, folder: URL) {
        guard let id = json["id"]?.string, !id.isEmpty, let command = json["command"]?.string, !command.isEmpty,
              let languages = json["languages"]?.array?.compactMap(\.string), !languages.isEmpty else { return nil }
        if let transport = json["transport"]?.string, transport != "stdio" { return nil }
        self.id = id
        name = json["name"]?.string ?? id
        self.languages = languages
        self.command = command
        args = json["args"]?.array?.compactMap(\.string) ?? []
        env = (json["env"]?.object ?? [:]).compactMapValues(\.string)
        initializationOptions = json["initializationOptions"].flatMap { $0 == .null ? nil : $0 }
        settings = json["settings"].flatMap { $0 == .null ? nil : $0 }
        rootPatterns = json["rootPatterns"]?.array?.compactMap(\.string) ?? []
        self.extensionID = extensionID
        self.folder = folder
    }

    /// `${extensionPath}` in a string replaced.
    private func expand(_ text: String) -> String {
        text.replacingOccurrences(of: "${extensionPath}", with: folder.path)
    }

    /// The executable: an absolute path, a path inside the extension's folder, or a name on `path`.
    func executable(path: String) -> String? {
        let command = expand(self.command)
        if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
        if command.contains("/") {
            let url = folder.appending(path: command).standardizedFileURL
            guard url.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return nil }
            return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
        }
        return LanguageServers.find(command, in: path)
    }

    /// How to start it, with `${config:…}` references filled in; nil when the program isn't there.
    func config(path: String, setting: (String) -> JSONValue?) -> LanguageServerConfig? {
        guard let executable = executable(path: path) else { return nil }
        var config = LanguageServerConfig(id: id, name: name, command: [executable] + args.map(expand),
                                          languages: Set(languages.map(SourceLanguage.init(languageId:))))
        config.environment = env.mapValues(expand)
        config.initializationOptions = initializationOptions.map { Self.substitute($0, setting) }
        config.settings = settings.map { Self.substitute($0, setting) }
        config.rootPatterns = rootPatterns
        config.extensionID = extensionID
        return config
    }

    /// `"${config:ext.key}"` becomes the setting's value (of its type); inside a longer string,
    /// its text.
    static func substitute(_ value: JSONValue, _ setting: (String) -> JSONValue?) -> JSONValue {
        switch value {
        case .string(let text):
            guard text.contains("${config:") else { return value }
            if text.hasPrefix("${config:"), text.firstIndex(of: "}") == text.index(before: text.endIndex) {
                return setting(String(text.dropFirst(9).dropLast())) ?? .null
            }
            var result = text
            while let range = result.range(of: "${config:"), let close = result[range.upperBound...].firstIndex(of: "}") {
                let key = String(result[range.upperBound..<close])
                let replacement: String = switch setting(key) {
                case .string(let string): string
                case .none, .null: ""
                case .number(let number): Int(exactly: number).map(String.init) ?? String(number)
                case .some(let other): other.json
                }
                result.replaceSubrange(range.lowerBound...close, with: replacement)
            }
            return .string(result)
        case .array(let items): return .array(items.map { substitute($0, setting) })
        case .object(let fields): return .object(fields.mapValues { substitute($0, setting) })
        default: return value
        }
    }
}

@MainActor
enum LanguageServers {
    /// Known servers, tried in order; the first whose executable exists on the login PATH wins.
    static let candidates: [(id: String, name: String, executable: String, arguments: [String], languages: Set<SourceLanguage>)] = [
        ("sourcekit-lsp", "SourceKit-LSP", "xcrun", ["sourcekit-lsp"], [.swift, .c, .cpp, .objc]),
        ("typescript-language-server", "TypeScript", "typescript-language-server", ["--stdio"], [.typescript, .tsx, .javascript]),
        ("pyright", "Pyright", "pyright-langserver", ["--stdio"], [.python]),
        ("pylsp", "pylsp", "pylsp", [], [.python]),
        ("rust-analyzer", "rust-analyzer", "rust-analyzer", [], [.rust]),
        ("gopls", "gopls", "gopls", [], [.go]),
    ]

    /// The server for `language`: a test's override, else the extensions' servers (`contributed`,
    /// in order), else the built-in candidates; servers `isEnabled` turns off are skipped.
    static func config(for language: SourceLanguage, path: String,
                       overrides: [SourceLanguage: LanguageServerConfig] = [:],
                       contributed: [LanguageServerConfig] = [],
                       isEnabled: (String) -> Bool = { _ in true }) -> LanguageServerConfig? {
        if let override = overrides[language] { return override }
        if let config = contributed.first(where: { $0.languages.contains(language) && isEnabled($0.id) }) { return config }
        for candidate in candidates where candidate.languages.contains(language) && isEnabled(candidate.id) {
            if let executable = find(candidate.executable, in: path) {
                return LanguageServerConfig(id: candidate.id, name: candidate.name, command: [executable] + candidate.arguments,
                                            languages: candidate.languages)
            }
        }
        return nil
    }

    nonisolated static func find(_ executable: String, in path: String) -> String? {
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// The user's login-shell environment. Apps launched from Finder get a minimal PATH, which
/// would hide servers installed with Homebrew, npm, cargo, etc.
actor ShellEnvironment {
    static let shared = ShellEnvironment()
    private var loading: Task<[String: String], Never>?

    func environment() async -> [String: String] {
        if let loading { return await loading.value }
        // The login shell (it may take seconds) is waited for off Swift concurrency's threads.
        let task = Task {
            await ProcessIO.detached(priority: .userInitiated) {
                var environment = ProcessInfo.processInfo.environment
                if let path = Self.loginPath() { environment["PATH"] = path }
                return environment
            }
        }
        loading = task
        return await task.value
    }

    private static func loginPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-l", "-c", "printf '__OMC_PATH__%s' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // A profile that hangs (waits for input, a slow plugin) isn't waited for long.
        guard let result = try? ProcessIO.run(process, output: output, error: nil, timeout: .seconds(5)), result.status == 0 else { return nil }
        let text = String(decoding: result.output, as: UTF8.self)
        guard let range = text.range(of: "__OMC_PATH__") else { return nil }
        let path = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
