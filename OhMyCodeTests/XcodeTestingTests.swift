import AppKit
import Testing
@testable import Oh_My_Code

struct XcodeProjectTests {
    @Test func readsProjectsAndBuildsCommands() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-xc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Calc.xcodeproj"), withIntermediateDirectories: true)
        #expect(XcodeProject.container(in: root)! == ("Calc.xcodeproj", false))
        // A package beside it: the package's tests are run with swift test instead.
        try "".write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        #expect(XcodeProject.container(in: root) == nil)

        let json = try JSONDecoder().decode(JSONValue.self, from: Data("""
        { "project": { "name": "Calc", "schemes": ["CalcKit", "Calc", "CalcTests"], "targets": ["Calc", "CalcTests", "CalcUITests"] } }
        """.utf8))
        let project = try #require(XcodeProject.parse(json, container: "Calc.xcodeproj", isWorkspace: false, root: root))
        #expect(project.scheme == "Calc" && project.testTargets == ["CalcTests", "CalcUITests"] && project.destination == "platform=macOS")
        #expect(project.testTarget(forFile: "CalcTests/Math/MathTests.swift") == "CalcTests")
        #expect(project.testTarget(forFile: "Calc/App.swift") == nil)

        #expect(XcodeProject.onlyTesting("CalcTests.Arithmetic/sums()") == "CalcTests/Arithmetic/sums()")
        #expect(XcodeProject.onlyTesting("CalcTests.Outer.Inner/deep()") == "CalcTests/Outer/Inner/deep()")
        #expect(XcodeProject.onlyTesting("CalcTests.MathTests/testAdd") == "CalcTests/MathTests/testAdd")
        #expect(XcodeProject.onlyTesting("CalcTests.topLevel()") == "CalcTests/topLevel()")
        let test = TestItem(id: "CalcTests.MathTests/testAdd", label: "testAdd", kind: .test, framework: .xcode, url: root, line: 0)
        #expect(project.command(tests: [test]) == "xcodebuild test -project 'Calc.xcodeproj' -scheme 'Calc' -destination 'platform=macOS' -only-testing:'CalcTests/MathTests/testAdd'")
        #expect(project.command(tests: nil) == "xcodebuild test -project 'Calc.xcodeproj' -scheme 'Calc' -destination 'platform=macOS'")

        // Test files: Swift files in a test target's folder, the target their module.
        #expect(TestDiscovery.framework(forFile: "CalcTests/MathTests.swift", in: [.xcode], xcode: project) == .xcode)
        #expect(TestDiscovery.framework(forFile: "Calc/Math.swift", in: [.xcode], xcode: project) == nil)
        let file = try #require(TestDiscovery.discover("import Testing\nstruct Arithmetic {\n    @Test func sums() {}\n}\n",
                                                       path: "CalcTests/A.swift", root: root, framework: .xcode, xcode: project))
        #expect(file.tests.map(\.id) == ["CalcTests.Arithmetic/sums()"] && file.tests.allSatisfy { $0.framework == .xcode })

        // A workspace lists no targets: its test folders stand in.
        try FileManager.default.createDirectory(at: root.appending(path: "AppTests"), withIntermediateDirectories: true)
        let workspace = try #require(XcodeProject.parse(try JSONDecoder().decode(JSONValue.self, from: Data(#"{ "workspace": { "name": "W", "schemes": ["App"] } }"#.utf8)),
                                                        container: "W.xcworkspace", isWorkspace: true, root: root))
        #expect(workspace.testTargets == ["AppTests"] && workspace.command(tests: nil).hasPrefix("xcodebuild test -workspace 'W.xcworkspace' -scheme 'App'"))
    }
}

@MainActor
struct XcodeTestRunTests {
    private func eventually(_ timeout: Duration, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/xcodegen")), .timeLimit(.minutes(6)))
    func runsAnXcodeProjectsTests() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-xcrun-\(UUID().uuidString)")
        let files = [
            "project.yml": """
            name: Calc
            options: { bundleIdPrefix: dev.example }
            targets:
              Calc:
                type: framework
                platform: macOS
                deploymentTarget: "14.0"
                sources: [Calc]
                settings: { base: { GENERATE_INFOPLIST_FILE: YES, CODE_SIGN_IDENTITY: "-" } }
              CalcTests:
                type: bundle.unit-test
                platform: macOS
                deploymentTarget: "14.0"
                sources: [CalcTests]
                dependencies: [{ target: Calc }]
                settings: { base: { GENERATE_INFOPLIST_FILE: YES, CODE_SIGN_IDENTITY: "-" } }
            schemes:
              Calc:
                build: { targets: { Calc: all, CalcTests: [test] } }
                test: { targets: [CalcTests] }
            """,
            "Calc/Calc.swift": "public func add(_ a: Int, _ b: Int) -> Int { a + b }\n",
            "CalcTests/MathTests.swift": """
            import XCTest
            @testable import Calc
            final class MathTests: XCTestCase {
                func testAdd() { XCTAssertEqual(Calc.add(1, 2), 3) }
                func testBroken() { XCTAssertEqual(Calc.add(1, 2), 4, "wrong sum") }
            }
            """,
            "CalcTests/NewTests.swift": """
            import Testing
            @testable import Calc
            struct Arithmetic {
                @Test func sums() { #expect(add(2, 2) == 4) }
                @Test func fails() { #expect(add(2, 2) == 5) }
            }
            """,
        ]
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let generate = Process()
        generate.executableURL = URL(filePath: "/opt/homebrew/bin/xcodegen")
        generate.arguments = ["generate", "-q"]
        generate.currentDirectoryURL = root
        try generate.run()
        generate.waitUntilExit()
        #expect(generate.terminationStatus == 0)

        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually(.seconds(60)) { workspace.testing.allTests.count == 4 })
        #expect(workspace.testing.xcode?.scheme == "Calc")
        #expect(Set(workspace.testing.allTests.map(\.id)) == ["CalcTests.MathTests/testAdd", "CalcTests.MathTests/testBroken",
                                                            "CalcTests.Arithmetic/sums()", "CalcTests.Arithmetic/fails()"])
        workspace.runAllTests()
        #expect(try await eventually(.seconds(300)) { !workspace.testing.runs.isEmpty && !workspace.testing.isRunning })
        let state = { (id: String) in workspace.testing.results[id]?.state }
        #expect(state("CalcTests.MathTests/testAdd") == .passed && state("CalcTests.MathTests/testBroken") == .failed)
        #expect(state("CalcTests.Arithmetic/sums()") == .passed && state("CalcTests.Arithmetic/fails()") == .failed)
        #expect(workspace.testing.results["CalcTests.MathTests/testBroken"]?.issues.first?.message.contains("wrong sum") == true)

        // One test by itself (-only-testing).
        workspace.testing.run([try #require(workspace.testing.item(id: "CalcTests.Arithmetic/sums()"))])
        #expect(try await eventually(.seconds(300)) { !workspace.testing.isRunning && state("CalcTests.Arithmetic/sums()") == .passed })
        let output = workspace.taskRuns.last?.lines.map(\.text) ?? []
        #expect(output.contains { $0.contains("-only-testing:'CalcTests/Arithmetic/sums()'") })
        #expect(!output.contains { $0.contains("Test Case '-[CalcTests.MathTests") })
    }
}
