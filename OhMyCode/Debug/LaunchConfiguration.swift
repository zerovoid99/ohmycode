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
    /// The workspace folder it's from (`${workspaceFolder}`); nil: the first.
    var folder: URL?

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
        let output = await ProcessIO.detached(priority: .userInitiated) { () -> Data? in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["swift", "package", "describe", "--type", "json"]
            process.currentDirectoryURL = root
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard let result = try? ProcessIO.run(process, output: pipe, error: nil), result.status == 0 else { return nil }
            return result.output
        }
        guard let output, let description = try? JSONDecoder().decode(JSONValue.self, from: output) else { return [] }
        let executables = (description["products"]?.array ?? []).filter { $0["type"]?["executable"] != nil }.compactMap { $0["name"]?.string }
        return executables.map { product in
            LaunchConfiguration(name: "Debug \(product)", program: "${workspaceFolder}/.build/debug/\(product)",
                                cwd: "${workspaceFolder}", preLaunch: "swift build --product \(product)")
        }
    }

    // MARK: Xcode projects

    /// Configurations for an Xcode project's or workspace's schemes that build a Mac app or
    /// command-line tool (built first with `xcodebuild`, debugged where Xcode puts the product).
    static func xcodeProjects(in root: URL, environment: [String: String]) async -> [LaunchConfiguration] {
        guard let container = xcodeContainer(in: root) else { return [] }
        let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        let name = container.lastPathComponent
        guard let list = await xcodebuild([flag, name, "-list", "-json"], in: root, environment: environment) else { return [] }
        let schemes = (list["workspace"] ?? list["project"])?["schemes"]?.array?.compactMap(\.string) ?? []
        var found: [LaunchConfiguration] = []
        // Each scheme's settings take a second or two to read: the first few are enough.
        for scheme in schemes.prefix(6) {
            guard let settings = await xcodebuild([flag, name, "-scheme", scheme, "-configuration", "Debug", "-showBuildSettings", "-json"],
                                                  in: root, environment: environment),
                  let configuration = xcodeConfiguration(scheme: scheme, containerFlag: flag, container: name, settings: settings)
            else { continue }
            found.append(configuration)
        }
        return found
    }

    /// The workspace (not the one inside a project) or else the project at the folder's top.
    static func xcodeContainer(in root: URL) -> URL? {
        let entries = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return entries.first { $0.pathExtension == "xcworkspace" } ?? entries.first { $0.pathExtension == "xcodeproj" }
    }

    /// A scheme's configuration from its build settings (`xcodebuild -showBuildSettings
    /// -json`): its first Mac app or tool target's product; nil if it builds neither.
    static func xcodeConfiguration(scheme: String, containerFlag: String, container: String, settings: JSONValue) -> LaunchConfiguration? {
        let runnable: Set<String> = ["com.apple.product-type.application", "com.apple.product-type.tool"]
        for entry in settings.array ?? [] {
            guard let build = entry["buildSettings"], build["PLATFORM_NAME"]?.string == "macosx",
                  let type = build["PRODUCT_TYPE"]?.string, runnable.contains(type),
                  let directory = build["TARGET_BUILD_DIR"]?.string, let executable = build["EXECUTABLE_PATH"]?.string
            else { continue }
            let quoted = { (text: String) in "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            return LaunchConfiguration(
                name: "Debug \(scheme)", program: directory + "/" + executable, cwd: "${workspaceFolder}",
                preLaunch: "xcodebuild \(containerFlag) \(quoted(container)) -scheme \(quoted(scheme)) -configuration Debug -quiet build")
        }
        return nil
    }

    private static func xcodebuild(_ arguments: [String], in root: URL, environment: [String: String]) async -> JSONValue? {
        let output = await ProcessIO.detached(priority: .userInitiated) { () -> Data? in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcrun")
            process.arguments = ["xcodebuild"] + arguments
            process.currentDirectoryURL = root
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard let result = try? ProcessIO.run(process, output: pipe, error: nil), result.status == 0 else { return nil }
            return result.output
        }
        return output.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    // MARK: Python

    /// Debugs the Python file being edited, in a folder with Python in it.
    static func pythonCurrentFile(in root: URL) -> [LaunchConfiguration] {
        let markers = ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        guard entries.contains(where: { markers.contains($0) || $0.hasSuffix(".py") }) else { return [] }
        return [LaunchConfiguration(name: "Python: Current File", type: "python", program: "${file}", cwd: "${workspaceFolder}")]
    }
}
