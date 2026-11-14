import Foundation

enum TestFramework: String, Sendable, CaseIterable {
    case swift, go, python, jest, vitest, cargo

    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .go: "Go"
        case .python: "Python"
        case .jest: "Jest"
        case .vitest: "Vitest"
        case .cargo: "Rust"
        }
    }
}

/// A test, or a group of them (a file, a class or suite, a describe block).
struct TestItem: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case file, suite, test }

    /// Unique in the folder. For tests it's also how results are matched:
    /// Swift "Module.Suite/name()" (XCTest "Module.Class/testName"), Go "dir/TestName",
    /// Python "package.module.Class.test_name", Jest/Vitest "file::describe test",
    /// Rust "file::module::name".
    let id: String
    var label: String
    var kind: Kind
    var framework: TestFramework
    var url: URL
    /// Zero-based line of its declaration.
    var line: Int
    var children: [TestItem] = []
    /// Swift Testing's display name (`@Test("Adds numbers")`), which its output uses.
    var displayName: String?

    /// Itself and everything under it.
    var allItems: [TestItem] { [self] + children.flatMap(\.allItems) }
    /// The tests (leaves) it holds.
    var tests: [TestItem] { kind == .test ? [self] : children.flatMap(\.tests) }
}

/// Finds tests by reading test files (no build, no running).
enum TestDiscovery {
    /// Which frameworks the folder uses.
    static func frameworks(in root: URL) -> Set<TestFramework> {
        let files = FileManager.default
        func has(_ name: String) -> Bool { files.fileExists(atPath: root.appending(path: name).path) }
        var result: Set<TestFramework> = []
        if has("Package.swift") { result.insert(.swift) }
        if has("go.mod") { result.insert(.go) }
        if has("Cargo.toml") { result.insert(.cargo) }
        if let data = try? Data(contentsOf: root.appending(path: "package.json")),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
            let dependencies = ["dependencies", "devDependencies"].compactMap { json[$0]?.object?.keys }.flatMap { $0 }
            let scripts = json["scripts"]?.object?.values.compactMap(\.string).joined(separator: " ") ?? ""
            if dependencies.contains("vitest") || scripts.contains("vitest") { result.insert(.vitest) }
            else if dependencies.contains("jest") || scripts.contains("jest") || dependencies.contains("ts-jest") { result.insert(.jest) }
        }
        if has("pyproject.toml") || has("setup.py") || has("setup.cfg") || has("pytest.ini") || has("tox.ini") || has("requirements.txt") {
            result.insert(.python)
        }
        return result
    }

    /// The framework a file's tests belong to (by its name), if it's a test file.
    static func framework(forFile path: String, in frameworks: Set<TestFramework>) -> TestFramework? {
        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension
        switch ext {
        case "swift" where frameworks.contains(.swift):
            return path.hasPrefix("Tests/") || path.contains("/Tests/") ? .swift : nil
        case "go" where frameworks.contains(.go):
            return name.hasSuffix("_test.go") ? .go : nil
        case "py":
            return name.hasPrefix("test_") || name.hasSuffix("_test.py") ? .python : nil
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "mts", "cts":
            guard let framework = frameworks.contains(.vitest) ? TestFramework.vitest : frameworks.contains(.jest) ? .jest : nil else { return nil }
            let isTestFile = name.contains(".test.") || name.contains(".spec.") || path.contains("__tests__/")
            return isTestFile && !path.contains("node_modules/") ? framework : nil
        case "rs" where frameworks.contains(.cargo):
            return path.contains("target/") ? nil : .cargo
        default:
            return nil
        }
    }

    /// A test file's tests: the file, with its suites and tests under it (nil if it has none).
    static func discover(_ text: String, path: String, root: URL, framework: TestFramework) -> TestItem? {
        let url = root.appending(path: path)
        let children: [TestItem] = switch framework {
        case .swift: swift(text, path: path, url: url)
        case .go: go(text, path: path, url: url)
        case .python: python(text, path: path, url: url)
        case .jest, .vitest: javaScript(text, path: path, url: url, framework: framework)
        case .cargo: rust(text, path: path, url: url)
        }
        guard !children.isEmpty else { return nil }
        return TestItem(id: "file:" + path, label: (path as NSString).lastPathComponent, kind: .file, framework: framework,
                        url: url, line: 0, children: children)
    }

    private static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    private static func matches(_ pattern: NSRegularExpression, _ line: String) -> [String?]? {
        guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
    }

    // MARK: Swift

    private static let swiftType = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|open)\s+)*(?:class|struct|enum|actor|extension)\s+(\w+)\s*(?::\s*([\w., ]+))?"#)
    private static let swiftTestingTest = try! NSRegularExpression(
        pattern: #"^\s*@Test(?:\s*\(\s*(?:"((?:[^"\\]|\\.)*)")?[^)]*\))?\s*(?:@\w+\s+)*(?:(?:static|nonisolated|private|fileprivate|internal|public|mutating)\s+)*func\s+(\w+)\s*\(([^)]*)\)"#)
    private static let xcTest = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+\s+)*(?:(?:override|public|internal|open|final)\s+)*func\s+(test\w*)\s*\(\s*\)"#)

    /// The module of a file under Tests/<Module>/.
    static func swiftModule(for path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "Tests"), index + 1 < parts.count - 1 { return parts[index + 1] }
        return "Tests"
    }

    /// `foo(bar:baz:)` from a parameter list.
    private static func swiftSignature(_ name: String, parameters: String) -> String {
        let labels = parameters.split(separator: ",").compactMap { parameter -> String? in
            let label = parameter.split(separator: ":").first?.trimmingCharacters(in: .whitespaces).split(separator: " ").first
            return label.map { "\($0):" }
        }
        return "\(name)(\(labels.joined()))"
    }

    private static func swift(_ text: String, path: String, url: URL) -> [TestItem] {
        let module = swiftModule(for: path)
        var result: [TestItem] = []
        // Types open at a brace depth; a test belongs to the innermost one.
        var stack: [(name: String, depth: Int, isXCTestCase: Bool, line: Int, children: [TestItem])] = []
        var pendingType: (name: String, isXCTestCase: Bool, line: Int)?
        var depth = 0
        var inBlockComment = false
        var xcTestClasses = Set<String>()

        func close(_ type: (name: String, depth: Int, isXCTestCase: Bool, line: Int, children: [TestItem])) {
            guard !type.children.isEmpty else { return }
            let suiteID = module + "." + (stack.map(\.name) + [type.name]).joined(separator: ".")
            let suite = TestItem(id: suiteID, label: type.name, kind: .suite, framework: .swift, url: url, line: type.line,
                                 children: type.children)
            if stack.isEmpty { result.append(suite) } else { stack[stack.count - 1].children.append(suite) }
        }

        for (number, rawLine) in lines(text).enumerated() {
            var line = rawLine
            if inBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                line = String(line[end.upperBound...])
                inBlockComment = false
            }
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            if let start = line.range(of: "/*") {
                if line[start.upperBound...].range(of: "*/") == nil { inBlockComment = true }
                line = String(line[..<start.lowerBound])
            }

            if let groups = matches(swiftType, line), let name = groups[1] {
                let inherits = groups[2] ?? ""
                if inherits.contains("XCTestCase") { xcTestClasses.insert(name) }
                pendingType = (name, inherits.contains("XCTestCase"), number)
            }
            let suitePath = stack.map(\.name).joined(separator: ".")
            if let groups = matches(swiftTestingTest, line), let name = groups[2] {
                let signature = swiftSignature(name, parameters: groups[3] ?? "")
                let id = module + "." + (suitePath.isEmpty ? signature : suitePath + "/" + signature)
                let item = TestItem(id: id, label: groups[1] ?? signature, kind: .test, framework: .swift, url: url, line: number,
                                    displayName: groups[1].map { "\"\($0)\"" } ?? signature)
                if stack.isEmpty { result.append(item) } else { stack[stack.count - 1].children.append(item) }
            } else if let groups = matches(xcTest, line), let name = groups[1], let type = stack.last, type.isXCTestCase {
                let item = TestItem(id: "\(module).\(suitePath)/\(name)", label: name, kind: .test, framework: .swift,
                                    url: url, line: number)
                stack[stack.count - 1].children.append(item)
            }

            for character in line {
                if character == "{" {
                    depth += 1
                    if let type = pendingType {
                        stack.append((type.name, depth, type.isXCTestCase || xcTestClasses.contains(type.name), type.line, []))
                        pendingType = nil
                    }
                } else if character == "}" {
                    if let last = stack.last, last.depth == depth {
                        stack.removeLast()
                        close(last)
                    }
                    depth -= 1
                }
            }
        }
        while let last = stack.popLast() { close(last) }
        return result
    }

    // MARK: Go

    private static let goTest = try! NSRegularExpression(pattern: #"^func\s+(Test\w*|Example\w*|Benchmark\w*)\s*\(\s*\w*\s*\*?testing\.(T|M|B)?"#)

    private static func go(_ text: String, path: String, url: URL) -> [TestItem] {
        let directory = (path as NSString).deletingLastPathComponent
        let package = directory.isEmpty ? "." : directory
        return lines(text).enumerated().compactMap { number, line in
            guard let groups = matches(goTest, line), let name = groups[1], name.hasPrefix("Test"), name != "TestMain" else { return nil }
            return TestItem(id: "\(package)/\(name)", label: name, kind: .test, framework: .go, url: url, line: number)
        }
    }

    // MARK: Python

    private static let pythonClass = try! NSRegularExpression(pattern: #"^(\s*)class\s+(\w+)\s*(?:\(([^)]*)\))?\s*:"#)
    private static let pythonTest = try! NSRegularExpression(pattern: #"^(\s*)(?:async\s+)?def\s+(test\w*)\s*\("#)

    /// "tests/test_math.py" → "tests.test_math".
    static func pythonModule(for path: String) -> String {
        ((path as NSString).deletingPathExtension).replacingOccurrences(of: "/", with: ".")
    }

    private static func python(_ text: String, path: String, url: URL) -> [TestItem] {
        let module = pythonModule(for: path)
        var result: [TestItem] = []
        var currentClass: (name: String, indent: Int, line: Int, children: [TestItem])?
        func closeClass() {
            if let type = currentClass, !type.children.isEmpty {
                result.append(TestItem(id: "\(module).\(type.name)", label: type.name, kind: .suite, framework: .python, url: url,
                                       line: type.line, children: type.children))
            }
            currentClass = nil
        }
        for (number, line) in lines(text).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if let type = currentClass, indent <= type.indent { closeClass() }
            if let groups = matches(pythonClass, line), let name = groups[2] {
                if name.hasPrefix("Test") || (groups[3] ?? "").contains("TestCase") {
                    closeClass()
                    currentClass = (name, indent, number, [])
                }
                continue
            }
            if let groups = matches(pythonTest, line), let name = groups[2] {
                if let type = currentClass, indent > type.indent {
                    currentClass?.children.append(TestItem(id: "\(module).\(type.name).\(name)", label: name, kind: .test,
                                                           framework: .python, url: url, line: number))
                } else if indent == 0 {
                    result.append(TestItem(id: "\(module).\(name)", label: name, kind: .test, framework: .python, url: url, line: number))
                }
            }
        }
        closeClass()
        return result
    }

    // MARK: JavaScript / TypeScript

    private static let jsBlock = try! NSRegularExpression(
        pattern: #"^\s*(describe|it|test)(?:\.(?:only|skip|concurrent|each\([^)]*\)))?\s*\(\s*(['"`])((?:\\.|(?!\2).)*)\2"#)

    private static func javaScript(_ text: String, path: String, url: URL, framework: TestFramework) -> [TestItem] {
        var result: [TestItem] = []
        var stack: [(name: String, depth: Int, line: Int, children: [TestItem])] = []
        var depth = 0
        for (number, line) in lines(text).enumerated() {
            if let groups = matches(jsBlock, line), let kind = groups[1], let name = groups[3] {
                let fullName = (stack.map(\.name) + [name]).joined(separator: " ")
                if kind == "describe" {
                    stack.append((name, depth + 1, number, []))
                } else {
                    let item = TestItem(id: "\(path)::\(fullName)", label: name, kind: .test, framework: framework, url: url, line: number)
                    if stack.isEmpty { result.append(item) } else { stack[stack.count - 1].children.append(item) }
                }
            }
            var inString: Character?
            for character in line {
                if let quote = inString { if character == quote { inString = nil }; continue }
                if character == "'" || character == "\"" || character == "`" { inString = character; continue }
                if character == "{" || character == "(" { depth += 1 }
                if character == "}" || character == ")" {
                    if let last = stack.last, last.depth == depth {
                        stack.removeLast()
                        let fullName = (stack.map(\.name) + [last.name]).joined(separator: " ")
                        let suite = TestItem(id: "\(path)::\(fullName)/", label: last.name, kind: .suite, framework: framework,
                                             url: url, line: last.line, children: last.children)
                        if !last.children.isEmpty {
                            if stack.isEmpty { result.append(suite) } else { stack[stack.count - 1].children.append(suite) }
                        }
                    }
                    depth -= 1
                }
            }
        }
        return result
    }

    // MARK: Rust

    private static let rustModule = try! NSRegularExpression(pattern: #"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*\{"#)
    private static let rustFunction = try! NSRegularExpression(pattern: #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(\w+)"#)

    /// The module path of a file: src/lib.rs, src/main.rs → "", src/a/b.rs → "a::b", tests/x.rs → "".
    static func rustModulePath(for path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.first == "src" else { return "" }
        parts.removeFirst()
        guard var last = parts.popLast() else { return "" }
        last = (last as NSString).deletingPathExtension
        if last != "lib", last != "main", last != "mod" { parts.append(last) }
        return parts.joined(separator: "::")
    }

    private static func rust(_ text: String, path: String, url: URL) -> [TestItem] {
        var result: [TestItem] = []
        var stack: [(name: String, depth: Int, line: Int, children: [TestItem])] = []
        var depth = 0
        var pendingTest = false
        let base = rustModulePath(for: path)
        for (number, line) in lines(text).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#[test]") || trimmed.hasPrefix("#[tokio::test") || trimmed.hasPrefix("#[rstest") { pendingTest = true }
            if let groups = matches(rustModule, line), let name = groups[1] {
                stack.append((name, depth + 1, number, []))
            } else if pendingTest, let groups = matches(rustFunction, line), let name = groups[1] {
                pendingTest = false
                let modules = ([base].filter { !$0.isEmpty } + stack.map(\.name)).joined(separator: "::")
                let qualified = modules.isEmpty ? name : modules + "::" + name
                let item = TestItem(id: "\(path)::\(qualified)", label: name, kind: .test, framework: .cargo, url: url, line: number)
                if stack.isEmpty { result.append(item) } else { stack[stack.count - 1].children.append(item) }
            }
            for character in line {
                if character == "{" { depth += 1 }
                if character == "}" {
                    if let last = stack.last, last.depth == depth {
                        stack.removeLast()
                        if !last.children.isEmpty {
                            let suite = TestItem(id: "\(path)::mod:" + (stack.map(\.name) + [last.name]).joined(separator: "::"),
                                                 label: last.name, kind: .suite, framework: .cargo, url: url, line: last.line,
                                                 children: last.children)
                            if stack.isEmpty { result.append(suite) } else { stack[stack.count - 1].children.append(suite) }
                        }
                    }
                    depth -= 1
                }
            }
        }
        return result
    }
}
