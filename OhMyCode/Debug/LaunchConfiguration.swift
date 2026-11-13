import Foundation

/// How to start a program under the debugger: from `.omc/launch.json`, or found (a Swift
/// package's executables).
///
///     {
///       "configurations": [{
///         "name": "Debug app",
///         "program": "${workspaceFolder}/.build/debug/app",
///         "args": ["--verbose"],
///         "cwd": "${workspaceFolder}",
///         "env": { "LOG": "1" },
///         "preLaunch": "swift build",
///         "stopOnEntry": false
///       }]
///     }
struct LaunchConfiguration: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var program: String
    var args: [String]?
    var cwd: String?
    var env: [String: String]?
    /// A shell command run first (a build); the launch stops if it fails.
    var preLaunch: String?
    var stopOnEntry: Bool?

    var id: String { name }

    static let file = ".omc/launch.json"

    private struct File: Codable { var configurations: [LaunchConfiguration] }

    enum LoadError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let detail): "\(LaunchConfiguration.file) can't be read: \(detail)"
            }
        }
    }

    /// The configurations in the folder's launch.json (none if there's no file).
    static func load(in root: URL) throws -> [LaunchConfiguration] {
        let url = root.appending(path: file)
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let text = VSCodeTheme.stripJSONC(String(decoding: data, as: UTF8.self))
            return try JSONDecoder().decode(File.self, from: Data(text.utf8)).configurations
        } catch {
            throw LoadError.invalid((error as? DecodingError).map { "\($0)" } ?? error.localizedDescription)
        }
    }

    /// Writes a launch.json to start from; returns its URL.
    static func writeTemplate(in root: URL, program: String = "${workspaceFolder}/path/to/program") throws -> URL {
        let url = root.appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = """
        {
          // Programs to run under the debugger (Run and Debug, F5).
          // ${workspaceFolder}, ${file}, ${fileDirname} and ${fileBasenameNoExtension} are filled in.
          "configurations": [
            {
              "name": "Debug",
              "program": "\(program)",
              "args": [],
              "cwd": "${workspaceFolder}",
              // A build to run first, e.g. "swift build" or "make".
              "preLaunch": ""
            }
          ]
        }

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// With `${…}` variables filled in.
    func resolved(root: URL, file: URL?) -> LaunchConfiguration {
        func fill(_ text: String) -> String {
            var text = text.replacingOccurrences(of: "${workspaceFolder}", with: root.path)
            if let file {
                text = text.replacingOccurrences(of: "${file}", with: file.path)
                    .replacingOccurrences(of: "${fileDirname}", with: file.deletingLastPathComponent().path)
                    .replacingOccurrences(of: "${fileBasenameNoExtension}", with: file.deletingPathExtension().lastPathComponent)
            }
            return text
        }
        var copy = self
        copy.program = fill(program)
        copy.args = args?.map(fill)
        copy.cwd = fill(cwd ?? "${workspaceFolder}")
        copy.env = env?.mapValues(fill)
        copy.preLaunch = preLaunch.map(fill).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return copy
    }

    /// Configurations for a Swift package's executables (built first with `swift build`).
    static func swiftPackage(in root: URL, environment: [String: String]) async -> [LaunchConfiguration] {
        guard FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) else { return [] }
        let output = await Task.detached(priority: .userInitiated) { () -> Data? in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["swift", "package", "describe", "--type", "json"]
            process.currentDirectoryURL = root
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        }.value
        guard let output, let description = try? JSONDecoder().decode(JSONValue.self, from: output) else { return [] }
        let executables = (description["products"]?.array ?? []).filter { $0["type"]?["executable"] != nil }.compactMap { $0["name"]?.string }
        return executables.map { product in
            LaunchConfiguration(name: "Debug \(product)", program: "${workspaceFolder}/.build/debug/\(product)",
                                cwd: "${workspaceFolder}", preLaunch: "swift build --product \(product)")
        }
    }
}
