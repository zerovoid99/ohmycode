import Foundation

/// What happened to a test, as a run's output says.
enum TestEvent: Equatable, Sendable {
    /// `name` is a test's id when the output names it fully; otherwise what the output calls it
    /// (Swift Testing's `name()` or "Display Name"), matched with the `file` it's in.
    case started(String)
    case passed(String, duration: Double?)
    case failed(String, duration: Double?)
    case skipped(String)
    /// A failure's message and where it happened (a path relative to the folder or absolute).
    /// `name` nil: the test whose code contains `file`:`line`.
    case issue(String?, message: String, file: String?, line: Int?)
}

/// A command that runs tests, and how to read its output.
struct TestCommand {
    var framework: TestFramework
    var command: String
    /// Where the runner writes its JSON report (Jest, Vitest).
    var reportFile: URL?
}

enum TestRunner {
    /// Single quotes for the shell.
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func escapeRegex(_ text: String) -> String {
        NSRegularExpression.escapedPattern(for: text).replacingOccurrences(of: "\\/", with: "/")
    }

    /// The command running `tests` (nil: all of the framework's tests).
    static func command(_ framework: TestFramework, tests: [TestItem]?, root: URL, hasPytest: Bool = false,
                        xcode: XcodeProject? = nil) -> TestCommand {
        let pytestNodeID = { (test: TestItem) in Self.pytestNodeID(test, root: root) }
        switch framework {
        case .xcode:
            return TestCommand(framework: framework, command: xcode?.command(tests: tests) ?? "xcodebuild test")
        case .swift:
            guard let tests else { return TestCommand(framework: framework, command: "swift test") }
            // Swift Testing's ids ("Module.Suite/name()") match with more after them (where
            // they're declared): anchored at the start only. XCTest's at both ends.
            let filter = tests.map { "^" + escapeRegex($0.name) + ($0.name.hasSuffix(")") ? "" : "$") }.joined(separator: "|")
            return TestCommand(framework: framework, command: "swift test --filter \(quote(filter))")
        case .go:
            guard let tests else { return TestCommand(framework: framework, command: "go test -json ./...") }
            let packages = Array(Set(tests.map { "./" + ($0.name as NSString).deletingLastPathComponent })).sorted()
                .map { $0 == "./." ? "." : $0 }
            let names = Array(Set(tests.map { ($0.name as NSString).lastPathComponent })).sorted()
            return TestCommand(framework: framework,
                               command: "go test -json -run \(quote("^(" + names.joined(separator: "|") + ")$")) " + packages.joined(separator: " "))
        case .python:
            if hasPytest {
                let ids = tests.map { $0.map(pytestNodeID).map(quote).joined(separator: " ") } ?? ""
                return TestCommand(framework: framework, command: "python3 -m pytest -v --tb=line -p no:cacheprovider " + ids)
            }
            guard let tests else { return TestCommand(framework: framework, command: "python3 -m unittest -v") }
            return TestCommand(framework: framework, command: "python3 -m unittest -v " + tests.map { quote($0.name) }.joined(separator: " "))
        case .jest, .vitest:
            let report = FileManager.default.temporaryDirectory.appending(path: "omc-tests-\(UUID().uuidString).json")
            var command = framework == .jest
                ? "npx jest --json --outputFile=\(quote(report.path))"
                : "npx vitest run --reporter=default --reporter=json --outputFile=\(quote(report.path))"
            if let tests {
                let files = Array(Set(tests.map { $0.name.components(separatedBy: "::")[0] })).sorted()
                let names = tests.map { "^" + escapeRegex($0.name.components(separatedBy: "::").dropFirst().joined(separator: "::")) + "$" }
                command += " " + files.map(quote).joined(separator: " ") + " -t " + quote(names.joined(separator: "|"))
            }
            return TestCommand(framework: framework, command: command, reportFile: report)
        case .cargo:
            guard let tests else { return TestCommand(framework: framework, command: "cargo test") }
            let names = tests.map { quote(rustName($0)) }.joined(separator: " ")
            return TestCommand(framework: framework, command: "cargo test -- --exact " + names)
        }
    }

    /// "tests.test_math.MathTests.test_ok" in tests/test_math.py → "tests/test_math.py::MathTests::test_ok".
    static func pytestNodeID(_ test: TestItem, root: URL) -> String {
        var path = test.url.path
        if path.hasPrefix(root.path + "/") {
            path = String(path.dropFirst(root.path.count + 1))
        } else {
            let rootPath = FileWatcher.canonicalPath(root) + "/"
            let canonical = FileWatcher.canonicalPath(test.url)
            if canonical.hasPrefix(rootPath) { path = String(canonical.dropFirst(rootPath.count)) }
        }
        let module = TestDiscovery.pythonModule(for: path)
        let rest = test.name.hasPrefix(module + ".") ? String(test.name.dropFirst(module.count + 1)) : test.label
        return path + "::" + rest.replacingOccurrences(of: ".", with: "::")
    }

    static func rustName(_ test: TestItem) -> String {
        test.name.components(separatedBy: "::").dropFirst().joined(separator: "::")
    }
}

// MARK: Output

/// Reads one framework's output, line by line, into events.
struct TestOutputParser {
    let framework: TestFramework
    /// Go's module path (go.mod), to turn import paths into folders.
    var goModule: String?
    private var section: (name: String?, lines: [String])?

    init(framework: TestFramework, goModule: String? = nil) {
        self.framework = framework
        self.goModule = goModule
    }

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static let xcTestCase = regex(#"^Test Case '-\[([\w.]+) (\w+)\]' (started|passed|failed|skipped)(?: \((\d+(?:\.\d+)?) seconds\))?"#)
    private static let xcTestIssue = regex(#"^(.+?):(\d+): error: -\[([\w.]+) (\w+)\] : (.*)$"#)
    private static let swiftTestingResult = regex(#"^[✔✘↪︎◇􀟈􀢄]?\S*\s*Test (.+?) (started|passed after ([\d.]+) seconds|failed after ([\d.]+) seconds|skipped)"#)
    private static let swiftTestingIssue = regex(#"Test (.+?) recorded an issue at ([^:]+):(\d+):\d+: (.*)$"#)
    private static let unittestResult = regex(#"^(\w+) \(([\w.]+)\)(?:\s.*)? \.\.\. (ok|FAIL|ERROR|skipped.*|expected failure|unexpected success)$"#)
    private static let unittestHeader = regex(#"^(FAIL|ERROR): (\w+) \(([\w.]+)\)"#)
    private static let pythonFrame = regex(#"^\s*File "([^"]+)", line (\d+)"#)
    private static let pytestResult = regex(#"^(\S+\.py)::(\S+) (PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS)"#)
    private static let pytestLine = regex(#"^(\S+\.py):(\d+): (.*)$"#)
    private static let cargoResult = regex(#"^test (\S+) \.\.\. (ok|FAILED|ignored)"#)
    private static let cargoPanic = regex(#"^thread '([^']+)' panicked at ([^:]+):(\d+):\d+:?\s*(.*)$"#)

    private static func groups(_ regex: NSRegularExpression, _ line: String) -> [String?]? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
    }

    /// For the Tasks panel: Go's JSON lines become their output text (nil hides a line).
    func display(_ line: String) -> String? {
        guard framework == .go, line.hasPrefix("{"), let data = line.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return line }
        guard json["Action"]?.string == "output", var output = json["Output"]?.string else { return nil }
        if output.hasSuffix("\n") { output.removeLast() }
        return output
    }

    mutating func consume(_ line: String) -> [TestEvent] {
        switch framework {
        case .swift, .xcode: return swift(line)
        case .go: return go(line)
        case .python: return python(line)
        case .cargo: return cargo(line)
        case .jest, .vitest: return [] // read from the report at the end
        }
    }

    /// Events still waiting for more lines (a failure's last block).
    mutating func finish() -> [TestEvent] {
        defer { section = nil }
        guard framework == .python else { return [] }
        return closeSection()
    }

    // Swift: XCTest and Swift Testing.
    private mutating func swift(_ line: String) -> [TestEvent] {
        if let g = Self.groups(Self.xcTestCase, line), let type = g[1], let name = g[2], let state = g[3] {
            let id = type + "/" + name
            let duration = g[4].flatMap(Double.init)
            switch state {
            case "started": return [.started(id)]
            case "passed": return [.passed(id, duration: duration)]
            case "failed": return [.failed(id, duration: duration)]
            default: return [.skipped(id)]
            }
        }
        if let g = Self.groups(Self.xcTestIssue, line), let type = g[3], let name = g[4] {
            return [.issue(type + "/" + name, message: g[5] ?? "", file: g[1], line: g[2].flatMap(Int.init))]
        }
        if let g = Self.groups(Self.swiftTestingIssue, line), let name = g[1] {
            return [.issue(name, message: g[4] ?? "", file: g[2], line: g[3].flatMap(Int.init))]
        }
        if line.contains("Test "), !line.contains("Test run"), let g = Self.groups(Self.swiftTestingResult, line), let name = g[1], let state = g[2] {
            if state == "started" { return [.started(name)] }
            if state.hasPrefix("passed") { return [.passed(name, duration: g[3].flatMap(Double.init))] }
            if state.hasPrefix("failed") { return [.failed(name, duration: g[4].flatMap(Double.init))] }
            return [.skipped(name)]
        }
        return []
    }

    // Go: `go test -json`.
    private mutating func go(_ line: String) -> [TestEvent] {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let test = json["Test"]?.string, !test.contains("/"), let action = json["Action"]?.string else { return [] }
        let package = json["Package"]?.string ?? ""
        var directory = "."
        if let goModule, package.hasPrefix(goModule) {
            let rest = package.dropFirst(goModule.count).drop { $0 == "/" }
            directory = rest.isEmpty ? "." : String(rest)
        }
        let id = directory + "/" + test
        let elapsed = json["Elapsed"]?.number
        switch action {
        case "run": return [.started(id)]
        case "pass": return [.passed(id, duration: elapsed)]
        case "fail": return [.failed(id, duration: elapsed)]
        case "skip": return [.skipped(id)]
        case "output":
            // "    calc_test.go:12: got 2, want 3"
            let output = (json["Output"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = Self.groups(Self.regex(#"^(\w[\w.-]*\.go):(\d+): (.*)$"#), output), let file = match[1] {
                let path = directory == "." ? file : directory + "/" + file
                return [.issue(id, message: match[3] ?? "", file: path, line: match[2].flatMap(Int.init))]
            }
            return []
        default: return []
        }
    }

    // Python: unittest -v and pytest -v --tb=line.
    private mutating func python(_ line: String) -> [TestEvent] {
        var events: [TestEvent] = []
        if let g = Self.groups(Self.unittestHeader, line), let name = g[2], let type = g[3] {
            events += closeSection()
            section = (unittestID(name, type), [])
            return events
        }
        if var current = section {
            if line.hasPrefix("-----") || line.hasPrefix("=====") {
                if !current.lines.isEmpty { events += closeSection() }
                return events
            }
            current.lines.append(line)
            section = current
            return events
        }
        if let g = Self.groups(Self.unittestResult, line), let name = g[1], let type = g[2], let state = g[3] {
            let id = unittestID(name, type)
            switch state {
            case "ok", "expected failure": return [.passed(id, duration: nil)]
            case "FAIL", "ERROR", "unexpected success": return [.failed(id, duration: nil)]
            default: return [.skipped(id)]
            }
        }
        if let g = Self.groups(Self.pytestResult, line), let path = g[1], let rest = g[2], let state = g[3] {
            let id = TestDiscovery.pythonModule(for: path) + "." + rest.replacingOccurrences(of: "::", with: ".")
            switch state {
            case "PASSED", "XFAIL": return [.passed(id, duration: nil)]
            case "FAILED", "ERROR", "XPASS": return [.failed(id, duration: nil)]
            default: return [.skipped(id)]
            }
        }
        if let g = Self.groups(Self.pytestLine, line), let file = g[1] {
            return [.issue(nil, message: g[3] ?? "", file: file, line: g[2].flatMap(Int.init))]
        }
        return []
    }

    /// unittest names a test "test_x (pkg.mod.Class)" (or "(pkg.mod.Class.test_x)" since 3.11).
    private func unittestID(_ name: String, _ qualifier: String) -> String {
        qualifier.hasSuffix("." + name) ? qualifier : qualifier + "." + name
    }

    private mutating func closeSection() -> [TestEvent] {
        guard let current = section else { return [] }
        section = nil
        let lines = current.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let frame = lines.compactMap { Self.groups(Self.pythonFrame, $0) }.last
        let message = lines.last?.trimmingCharacters(in: .whitespaces) ?? "Failed"
        let line = frame.flatMap { $0[2] }.flatMap { Int($0) }
        return [.issue(current.name, message: message, file: frame.flatMap { $0[1] }, line: line)]
    }

    // Rust: cargo test.
    private mutating func cargo(_ line: String) -> [TestEvent] {
        if let g = Self.groups(Self.cargoResult, line), let name = g[1], let state = g[2] {
            switch state {
            case "ok": return [.passed(name, duration: nil)]
            case "FAILED": return [.failed(name, duration: nil)]
            default: return [.skipped(name)]
            }
        }
        if let g = Self.groups(Self.cargoPanic, line), let name = g[1] {
            var events = closeSection()
            let inline = g[4] ?? ""
            if inline.isEmpty {
                section = ("\(name)\t\(g[2] ?? "")\t\(g[3] ?? "")", [])
            } else {
                events.append(.issue(name, message: inline, file: g[2], line: g[3].flatMap(Int.init)))
            }
            return events
        }
        if let current = section, let header = current.name {
            // The panic message is the line after "panicked at".
            let parts = header.components(separatedBy: "\t")
            section = nil
            return [.issue(parts[0], message: line.trimmingCharacters(in: .whitespaces), file: parts[1], line: Int(parts[2]))]
        }
        return []
    }

    // MARK: Jest / Vitest report

    /// The JSON report's results (ids are "relative file::full name").
    static func report(_ data: Data, root: URL) -> [TestEvent] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        let rootPath = FileWatcher.canonicalPath(root) + "/"
        var events: [TestEvent] = []
        for file in json["testResults"]?.array ?? [] {
            var path = FileWatcher.canonicalPath(URL(filePath: file["name"]?.string ?? file["testFilePath"]?.string ?? ""))
            if path.hasPrefix(rootPath) { path = String(path.dropFirst(rootPath.count)) }
            for assertion in file["assertionResults"]?.array ?? [] {
                let titles = (assertion["ancestorTitles"]?.array?.compactMap(\.string) ?? []) + [assertion["title"]?.string ?? ""]
                let id = path + "::" + titles.joined(separator: " ")
                let duration = assertion["duration"]?.number.map { $0 / 1000 }
                switch assertion["status"]?.string {
                case "passed": events.append(.passed(id, duration: duration))
                case "failed":
                    events.append(.failed(id, duration: duration))
                    let message = (assertion["failureMessages"]?.array?.compactMap(\.string).first ?? "Failed")
                    let firstLine = ProblemMatcher.stripEscapes(message).components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Failed"
                    // "at Object.<anonymous> (/abs/file.test.ts:12:5)"
                    var lineNumber = assertion["location"]?["line"]?.number.map(Int.init)
                    if let range = message.range(of: path + ":") ?? message.range(of: (file["name"]?.string ?? "\u{0}") + ":") {
                        lineNumber = Int(message[range.upperBound...].prefix { $0.isNumber }) ?? lineNumber
                    }
                    events.append(.issue(id, message: firstLine.trimmingCharacters(in: .whitespaces), file: path, line: lineNumber))
                default: events.append(.skipped(id))
                }
            }
        }
        return events
    }
}
