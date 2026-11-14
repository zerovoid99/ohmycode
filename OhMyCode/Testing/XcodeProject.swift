import Foundation

/// An Xcode project or workspace in the folder: what `xcodebuild` needs to run its tests.
struct XcodeProject: Equatable, Sendable {
    /// "MyApp.xcworkspace" or "MyApp.xcodeproj" (relative to the folder).
    var container: String
    var isWorkspace: Bool
    var schemes: [String]
    /// Test bundles: their names are the tests' modules (and folders, usually).
    var testTargets: [String]
    var scheme: String
    var destination: String

    /// The first workspace (else project) at the folder's top, without a Package.swift beside it.
    static func container(in root: URL) -> (name: String, isWorkspace: Bool)? {
        let files = FileManager.default
        guard !files.fileExists(atPath: root.appending(path: "Package.swift").path),
              let names = try? files.contentsOfDirectory(atPath: root.path) else { return nil }
        let sorted = names.sorted()
        if let workspace = sorted.first(where: { $0.hasSuffix(".xcworkspace") }) { return (workspace, true) }
        if let project = sorted.first(where: { $0.hasSuffix(".xcodeproj") }) { return (project, false) }
        return nil
    }

    /// Asks `xcodebuild -list` for the schemes and targets (nil without a project, or if it fails).
    static func load(in root: URL, environment: [String: String]) async -> XcodeProject? {
        guard let (container, isWorkspace) = container(in: root) else { return nil }
        let output = await Task.detached(priority: .userInitiated) { () -> Data? in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcrun")
            process.arguments = ["xcodebuild", "-list", "-json", isWorkspace ? "-workspace" : "-project", container]
            process.currentDirectoryURL = root
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard let result = try? ProcessIO.run(process, output: pipe, error: nil, timeout: .seconds(60)), result.status == 0 else { return nil }
            return result.output
        }.value
        guard let output, let json = try? JSONDecoder().decode(JSONValue.self, from: output) else { return nil }
        return parse(json, container: container, isWorkspace: isWorkspace, root: root)
    }

    /// From `xcodebuild -list -json`'s output.
    static func parse(_ json: JSONValue, container: String, isWorkspace: Bool, root: URL) -> XcodeProject? {
        let entry = json[isWorkspace ? "workspace" : "project"]
        let schemes = entry?["schemes"]?.array?.compactMap(\.string) ?? []
        guard !schemes.isEmpty else { return nil }
        let name = (container as NSString).deletingPathExtension
        var targets = entry?["targets"]?.array?.compactMap(\.string) ?? []
        if targets.isEmpty {
            // A workspace doesn't list targets: its test folders stand in for them.
            targets = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        }
        let testTargets = targets.filter { $0.hasSuffix("Tests") }
        // The app's own scheme (named like the project), else the first.
        let scheme = schemes.first { $0 == name } ?? schemes.first { !$0.hasSuffix("Tests") } ?? schemes[0]
        return XcodeProject(container: container, isWorkspace: isWorkspace, schemes: schemes, testTargets: testTargets,
                            scheme: scheme, destination: destination(in: root, container: container))
    }

    /// The Mac, or for an iOS project the first available iPhone simulator.
    static func destination(in root: URL, container: String) -> String {
        let project = container.hasSuffix(".xcodeproj") ? container : container.replacingOccurrences(of: ".xcworkspace", with: ".xcodeproj")
        let settings = (try? String(contentsOf: root.appending(path: project).appending(path: "project.pbxproj"), encoding: .utf8)) ?? ""
        guard settings.contains("SDKROOT = iphoneos") else { return "platform=macOS" }
        return "platform=iOS Simulator,name=\(firstSimulator() ?? "iPhone 16")"
    }

    private static func firstSimulator() -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "-j"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let result = try? ProcessIO.run(process, output: pipe, error: nil, timeout: .seconds(20)),
              let json = try? JSONDecoder().decode(JSONValue.self, from: result.output) else { return nil }
        let devices = (json["devices"]?.object ?? [:]).filter { $0.key.contains("iOS") }.sorted { $0.key > $1.key }
        for (_, list) in devices {
            if let name = list.array?.compactMap({ $0["name"]?.string }).first(where: { $0.hasPrefix("iPhone") }) { return name }
        }
        return nil
    }

    /// The test target a file belongs to: the folder named like one of them.
    func testTarget(forFile path: String) -> String? {
        let components = path.split(separator: "/").dropLast().map(String.init)
        return components.first { testTargets.contains($0) }
    }

    /// `-only-testing:` for a test: "Module.Suite/name()" → "Module/Suite/name()",
    /// "Module.Class/testX" → "Module/Class/testX", "Module.name()" → "Module/name()".
    static func onlyTesting(_ id: String) -> String {
        guard let slash = id.lastIndex(of: "/") else {
            guard let dot = id.firstIndex(of: ".") else { return id }
            return id[..<dot] + "/" + id[id.index(after: dot)...]
        }
        return id[..<slash].replacingOccurrences(of: ".", with: "/") + id[slash...]
    }

    /// The `xcodebuild test` command for `tests` (nil: all of the scheme's).
    func command(tests: [TestItem]?) -> String {
        var command = "xcodebuild test \(isWorkspace ? "-workspace" : "-project") \(TestRunner.quote(container))"
            + " -scheme \(TestRunner.quote(scheme)) -destination \(TestRunner.quote(destination))"
        for test in tests ?? [] {
            command += " -only-testing:" + TestRunner.quote(Self.onlyTesting(test.id))
        }
        return command
    }
}
