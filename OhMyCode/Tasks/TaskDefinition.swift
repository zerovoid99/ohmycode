import Foundation

/// A shell command to run from the editor (build, test, lint…): from `.omc/tasks.json`, or
/// found in the folder (Package.swift, package.json, Makefile, Cargo.toml, go.mod).
///
///     {
///       "tasks": [{
///         "label": "Build",
///         "command": "swift build",
///         "group": "build",
///         "isDefault": true,
///         "cwd": "${workspaceFolder}",
///         "env": { "CONFIG": "debug" },
///         "problemMatcher": "auto"
///       }]
///     }
struct TaskDefinition: Codable, Equatable, Identifiable, Sendable {
    enum Group: String, Codable, Sendable { case build, test }

    var label: String
    var command: String
    var group: Group?
    /// The group's task to run without asking (⇧⌘B for build).
    var isDefault: Bool?
    var cwd: String?
    var env: [String: String]?
    /// Reads errors from the output: "auto" (the default: every known format) or "none".
    var problemMatcher: String?
    /// Where it came from, shown next to found tasks ("Package.swift", "package.json"…).
    var detail: String?

    var id: String { label }
    var matchesProblems: Bool { problemMatcher != "none" }

    init(label: String, command: String, group: Group? = nil, isDefault: Bool? = nil, cwd: String? = nil,
         env: [String: String]? = nil, problemMatcher: String? = nil, detail: String? = nil) {
        self.label = label
        self.command = command
        self.group = group
        self.isDefault = isDefault
        self.cwd = cwd
        self.env = env
        self.problemMatcher = problemMatcher
        self.detail = detail
    }

    static let file = ".omc/tasks.json"

    private struct File: Codable { var tasks: [TaskDefinition] }

    enum LoadError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let detail): "\(TaskDefinition.file) can't be read: \(detail)"
            }
        }
    }

    /// The tasks in the folder's tasks.json (none if there's no file).
    static func load(in root: URL) throws -> [TaskDefinition] {
        guard let data = try? Data(contentsOf: root.appending(path: file)) else { return [] }
        do {
            let text = VSCodeTheme.stripJSONC(String(decoding: data, as: UTF8.self))
            return try JSONDecoder().decode(File.self, from: Data(text.utf8)).tasks
        } catch {
            throw LoadError.invalid((error as? DecodingError).map { "\($0)" } ?? error.localizedDescription)
        }
    }

    /// The configured tasks, then the found ones whose labels aren't taken.
    static func all(in root: URL) throws -> [TaskDefinition] {
        let configured = try load(in: root)
        let labels = Set(configured.map(\.label))
        return configured + detect(in: root).filter { !labels.contains($0.label) }
    }

    /// With `${…}` variables filled in (as in launch.json).
    func resolved(root: URL, file: URL?) -> TaskDefinition {
        func fill(_ text: String) -> String {
            var text = text.replacingOccurrences(of: "${workspaceFolder}", with: root.path)
            if let file {
                text = text.replacingOccurrences(of: "${file}", with: file.path)
                    .replacingOccurrences(of: "${fileDirname}", with: file.deletingLastPathComponent().path)
                    .replacingOccurrences(of: "${fileBasenameNoExtension}", with: file.deletingPathExtension().lastPathComponent)
                    .replacingOccurrences(of: "${fileBasename}", with: file.lastPathComponent)
            }
            return text
        }
        var copy = self
        copy.command = fill(command)
        copy.cwd = fill(cwd ?? "${workspaceFolder}")
        copy.env = env?.mapValues(fill)
        return copy
    }

    // MARK: Found tasks

    /// Tasks the folder's build files define.
    static func detect(in root: URL) -> [TaskDefinition] {
        let files = FileManager.default
        func has(_ name: String) -> Bool { files.fileExists(atPath: root.appending(path: name).path) }
        var tasks: [TaskDefinition] = []
        if has("Package.swift") {
            tasks.append(TaskDefinition(label: "swift: build", command: "swift build", group: .build, detail: "Package.swift"))
            tasks.append(TaskDefinition(label: "swift: test", command: "swift test", group: .test, detail: "Package.swift"))
        }
        if has("Cargo.toml") {
            tasks.append(TaskDefinition(label: "cargo: build", command: "cargo build", group: .build, detail: "Cargo.toml"))
            tasks.append(TaskDefinition(label: "cargo: test", command: "cargo test", group: .test, detail: "Cargo.toml"))
            tasks.append(TaskDefinition(label: "cargo: clippy", command: "cargo clippy", detail: "Cargo.toml"))
        }
        if has("go.mod") {
            tasks.append(TaskDefinition(label: "go: build", command: "go build ./...", group: .build, detail: "go.mod"))
            tasks.append(TaskDefinition(label: "go: test", command: "go test ./...", group: .test, detail: "go.mod"))
            tasks.append(TaskDefinition(label: "go: vet", command: "go vet ./...", detail: "go.mod"))
        }
        if let data = try? Data(contentsOf: root.appending(path: "package.json")),
           let scripts = (try? JSONDecoder().decode(JSONValue.self, from: data))?["scripts"]?.object {
            let runner = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn"
                : has("bun.lockb") || has("bun.lock") ? "bun" : "npm"
            for name in scripts.keys.sorted() {
                let command = runner == "npm" ? "npm run \(name)" : "\(runner) run \(name)"
                tasks.append(TaskDefinition(label: "\(runner): \(name)", command: command, group: group(forTarget: name),
                                            detail: "package.json"))
            }
        }
        for name in ["GNUmakefile", "makefile", "Makefile"] where has(name) {
            let text = (try? String(contentsOf: root.appending(path: name), encoding: .utf8)) ?? ""
            for target in makeTargets(in: text) {
                tasks.append(TaskDefinition(label: "make: \(target)", command: "make \(target)", group: group(forTarget: target),
                                            detail: name))
            }
            break
        }
        return tasks
    }

    private static func group(forTarget name: String) -> Group? {
        switch name {
        case "build", "all", "compile": .build
        case "test", "tests", "check": .test
        default: nil
        }
    }

    /// A Makefile's explicit targets, in order (not variables, pattern rules or special ones).
    static func makeTargets(in text: String) -> [String] {
        var targets: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard let first = line.first, first != "\t", first != " ", first != "#", first != ".",
                  let colon = line.firstIndex(of: ":") else { continue }
            let after = line[line.index(after: colon)...]
            if after.hasPrefix("=") { continue } // NAME := value
            let head = line[..<colon]
            if head.contains("=") || head.contains("%") || head.contains("$") { continue }
            for name in head.split(separator: " ").map(String.init) where !targets.contains(name) {
                targets.append(name)
            }
        }
        return targets
    }

    // MARK: Template

    /// Writes a tasks.json listing `tasks` (the found ones) to start from; returns its URL.
    static func writeTemplate(in root: URL, tasks: [TaskDefinition]) throws -> URL {
        let url = root.appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let examples = tasks.isEmpty
            ? [TaskDefinition(label: "Build", command: "make", group: .build, isDefault: true)]
            : tasks.map { task in
                var task = task
                task.detail = nil
                if task.group != nil, !tasks.contains(where: { $0.group == task.group && $0.isDefault == true }),
                   tasks.first(where: { $0.group == task.group })?.label == task.label {
                    task.isDefault = true
                }
                return task
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let list = String(decoding: try encoder.encode(examples), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\n  ")
        let text = """
        {
          // Commands to run from the editor: Terminal → Run Task…, or ⇧⌘B for the default build task.
          // "group" is "build" or "test"; errors in the output show in Problems ("problemMatcher": "none" turns that off).
          // ${workspaceFolder}, ${file}, ${fileDirname}, ${fileBasename} and ${fileBasenameNoExtension} are filled in.
          "tasks": \(list)
        }

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
