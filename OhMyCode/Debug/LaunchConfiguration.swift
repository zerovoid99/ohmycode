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
    /// The debugger: "lldb" (the default: Swift, C, C++, Objective-C) or "python" (debugpy).
    var type: String?
    /// "launch" (the default) starts `program`; "attach" connects to the running process `pid`
    /// (or, with lldb, waits for `program` to start).
    var request: String?
    var program: String
    var args: [String]?
    var cwd: String?
    var env: [String: String]?
    /// A shell command run first (a build); the launch stops if it fails.
    var preLaunch: String?
    var stopOnEntry: Bool?
    var pid: Int?
    /// Any other debug adapter speaking DAP over stdio: its command line.
    var adapter: [String]?
    /// More arguments for the adapter's launch or attach request (merged last).
    var adapterArguments: [String: JSONValue]?

    var id: String { name }
    var isAttach: Bool { request == "attach" }

    init(name: String, type: String? = nil, request: String? = nil, program: String = "", args: [String]? = nil,
         cwd: String? = nil, env: [String: String]? = nil, preLaunch: String? = nil, stopOnEntry: Bool? = nil,
         pid: Int? = nil, adapter: [String]? = nil, adapterArguments: [String: JSONValue]? = nil) {
        self.name = name
        self.type = type
        self.request = request
        self.program = program
        self.args = args
        self.cwd = cwd
        self.env = env
        self.preLaunch = preLaunch
        self.stopOnEntry = stopOnEntry
        self.pid = pid
        self.adapter = adapter
        self.adapterArguments = adapterArguments
    }

    enum CodingKeys: String, CodingKey {
        case name, type, request, program, args, cwd, env, preLaunch, stopOnEntry, pid, adapter, adapterArguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try container.decode(String.self, forKey: .name),
                  type: try container.decodeIfPresent(String.self, forKey: .type),
                  request: try container.decodeIfPresent(String.self, forKey: .request),
                  program: try container.decodeIfPresent(String.self, forKey: .program) ?? "",
                  args: try container.decodeIfPresent([String].self, forKey: .args),
                  cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                  env: try container.decodeIfPresent([String: String].self, forKey: .env),
                  preLaunch: try container.decodeIfPresent(String.self, forKey: .preLaunch),
                  stopOnEntry: try container.decodeIfPresent(Bool.self, forKey: .stopOnEntry),
                  pid: try container.decodeIfPresent(Int.self, forKey: .pid),
                  adapter: try container.decodeIfPresent([String].self, forKey: .adapter),
                  adapterArguments: try container.decodeIfPresent([String: JSONValue].self, forKey: .adapterArguments))
    }

    enum ConfigurationError: LocalizedError {
        case unknownType(String)
        case nothingToAttach
        case attachUnsupported(String)
        var errorDescription: String? {
            switch self {
            case .unknownType(let type): "There's no debugger of type “\(type)”: use \"lldb\" or \"python\", or give an \"adapter\" command."
            case .nothingToAttach: "An attach configuration needs a \"pid\" (or, with lldb, a \"program\" to wait for)."
            case .attachUnsupported(let type): "Attaching isn't supported for “\(type)” here."
            }
        }
    }

    /// The debug adapter's command line and DAP adapter id.
    func adapterCommand() throws -> (command: [String], id: String) {
        if let adapter, !adapter.isEmpty { return (adapter, type ?? "custom") }
        switch type ?? "lldb" {
        case "lldb": return (["/usr/bin/xcrun", "lldb-dap"], "lldb-dap")
        case "python", "debugpy": return (["/usr/bin/env", "python3", "-m", "debugpy.adapter"], "debugpy")
        case let other: throw ConfigurationError.unknownType(other)
        }
    }

    /// The `launch` or `attach` request's arguments for this configuration's debugger.
    func requestArguments() throws -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [:]
        let kind = adapter == nil ? (type ?? "lldb") : "custom"
        if isAttach {
            switch kind {
            case "lldb":
                if let pid { arguments["pid"] = .number(Double(pid)) }
                else if !program.isEmpty { arguments["program"] = .string(program); arguments["waitFor"] = .bool(true) }
                else { throw ConfigurationError.nothingToAttach }
            case "custom":
                if let pid { arguments["pid"] = .number(Double(pid)) }
            default:
                throw ConfigurationError.attachUnsupported(kind)
            }
        } else {
            arguments["program"] = .string(program)
            arguments["args"] = .array((args ?? []).map(JSONValue.string))
            if let cwd { arguments["cwd"] = .string(cwd) }
            if let env, !env.isEmpty { arguments["env"] = .object(env.mapValues(JSONValue.string)) }
            arguments["stopOnEntry"] = .bool(stopOnEntry ?? false)
            if kind == "python" || kind == "debugpy" {
                arguments["console"] = .string("internalConsole")
                arguments["justMyCode"] = .bool(true)
            }
        }
        arguments.merge(adapterArguments ?? [:]) { $1 }
        return arguments
    }

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
