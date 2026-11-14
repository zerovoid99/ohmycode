import Foundation

/// Which language server handles which languages, and how to start it.
struct LanguageServerConfig: Sendable {
    let name: String
    let command: [String]
    let languages: Set<SourceLanguage>

    static func languageId(for language: SourceLanguage) -> String {
        switch language {
        case .objc: "objective-c"
        case .tsx: "typescriptreact"
        case .javascript: "javascript"
        case .shell: "shellscript"
        default: language.rawValue
        }
    }
}

@MainActor
enum LanguageServers {
    /// Known servers, tried in order; the first whose executable exists on the login PATH wins.
    private static let candidates: [(name: String, executable: String, arguments: [String], languages: Set<SourceLanguage>)] = [
        ("SourceKit-LSP", "xcrun", ["sourcekit-lsp"], [.swift, .c, .cpp, .objc]),
        ("TypeScript", "typescript-language-server", ["--stdio"], [.typescript, .tsx, .javascript]),
        ("Pyright", "pyright-langserver", ["--stdio"], [.python]),
        ("pylsp", "pylsp", [], [.python]),
        ("rust-analyzer", "rust-analyzer", [], [.rust]),
        ("gopls", "gopls", [], [.go]),
    ]

    static func config(for language: SourceLanguage, path: String,
                       overrides: [SourceLanguage: LanguageServerConfig] = [:]) -> LanguageServerConfig? {
        if let override = overrides[language] { return override }
        for candidate in candidates where candidate.languages.contains(language) {
            if let executable = find(candidate.executable, in: path) {
                return LanguageServerConfig(name: candidate.name, command: [executable] + candidate.arguments,
                                            languages: candidate.languages)
            }
        }
        return nil
    }

    private static func find(_ executable: String, in path: String) -> String? {
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
    private var cached: [String: String]?

    func environment() -> [String: String] {
        if let cached { return cached }
        var environment = ProcessInfo.processInfo.environment
        if let path = loginPath() { environment["PATH"] = path }
        cached = environment
        return environment
    }

    private func loginPath() -> String? {
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
