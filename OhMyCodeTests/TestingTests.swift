import AppKit
import Testing
@testable import Oh_My_Code

struct TestDiscoveryTests {
    private let root = URL(filePath: "/work")

    @Test func findsSwiftTests() throws {
        let text = """
        import XCTest
        import Testing

        final class MathTests: XCTestCase {
            func testAdd() {}
            // func testCommented() {}
            func helper() {}
        }
        extension MathTests {
            func testMore() throws {}
        }
        @Suite("Arithmetic") struct Arithmetic {
            @Test func sums() {}
            @Test("Named test") func fails() async throws {}
            @Test(arguments: [1, 2]) func values(n: Int) {}
            struct Nested {
                @Test func deep() {}
            }
        }
        @Test func topLevel() {}
        """
        let file = try #require(TestDiscovery.discover(text, path: "Tests/LibTests/A.swift", root: root, framework: .swift))
        #expect(file.tests.map(\.id) == ["LibTests.MathTests/testAdd", "LibTests.MathTests/testMore",
                                         "LibTests.Arithmetic/sums()", "LibTests.Arithmetic/fails()", "LibTests.Arithmetic/values(n:)",
                                         "LibTests.Arithmetic.Nested/deep()", "LibTests.topLevel()"])
        #expect(file.children.map(\.label) == ["MathTests", "MathTests", "Arithmetic", "topLevel()"])
        let named = try #require(file.tests.first { $0.id.hasSuffix("fails()") })
        #expect(named.label == "Named test" && named.displayName == "\"Named test\"" && named.line == 13)
        #expect(file.tests.first?.displayName == nil && file.tests.last?.displayName == "topLevel()")
        #expect(TestDiscovery.framework(forFile: "Tests/LibTests/A.swift", in: [.swift]) == .swift)
        #expect(TestDiscovery.framework(forFile: "Sources/Lib/A.swift", in: [.swift]) == nil)
    }

    @Test func findsGoPythonJavaScriptAndRustTests() throws {
        let go = try #require(TestDiscovery.discover("package calc\n\nfunc TestAdd(t *testing.T) {}\nfunc TestMain(m *testing.M) {}\nfunc helper() {}\nfunc BenchmarkX(b *testing.B) {}\n",
                                                     path: "calc/calc_test.go", root: root, framework: .go))
        #expect(go.tests.map(\.id) == ["calc/TestAdd"] && go.tests[0].line == 2)

        let python = try #require(TestDiscovery.discover("""
        import unittest

        class MathTests(unittest.TestCase):
            def test_ok(self):
                pass

            def helper(self):
                pass

        class Other:
            def test_not(self): pass

        def test_free():
            assert True
        """, path: "tests/test_math.py", root: root, framework: .python))
        #expect(python.tests.map(\.id) == ["tests.test_math.MathTests.test_ok", "tests.test_math.test_free"])

        let js = try #require(TestDiscovery.discover("""
        import { add } from './add';
        describe('add', () => {
          it('sums (two) numbers', () => { expect(add(1, 2)).toBe(3); });
          describe("edge", () => {
            test.skip(`zero`, () => {});
          });
        });
        test('top', async () => {});
        """, path: "src/add.test.ts", root: root, framework: .jest))
        #expect(js.tests.map(\.id) == ["src/add.test.ts::add sums (two) numbers", "src/add.test.ts::add edge zero", "src/add.test.ts::top"])
        #expect(js.children.map(\.label) == ["add", "top"])
        #expect(TestDiscovery.framework(forFile: "src/add.test.ts", in: [.vitest]) == .vitest)
        #expect(TestDiscovery.framework(forFile: "node_modules/x/a.test.js", in: [.jest]) == nil)

        let rust = try #require(TestDiscovery.discover("""
        pub fn add(a: i32, b: i32) -> i32 { a + b }

        #[cfg(test)]
        mod tests {
            use super::*;

            #[test]
            fn adds() { assert_eq!(add(1, 2), 3); }

            fn helper() {}
        }
        """, path: "src/math.rs", root: root, framework: .cargo))
        #expect(rust.tests.map(\.id) == ["src/math.rs::math::tests::adds"] && TestRunner.rustName(rust.tests[0]) == "math::tests::adds")
        #expect(TestDiscovery.rustModulePath(for: "src/lib.rs") == "" && TestDiscovery.rustModulePath(for: "src/a/b.rs") == "a::b")
    }

    @Test func detectsFrameworksAndBuildsCommands() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-tf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "".write(to: folder.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try #"{ "devDependencies": { "vitest": "1" } }"#.write(to: folder.appending(path: "package.json"), atomically: true, encoding: .utf8)
        #expect(TestDiscovery.frameworks(in: folder) == [.swift, .vitest])

        let swiftTest = TestItem(id: "LibTests.Arithmetic/sums()", label: "sums()", kind: .test, framework: .swift, url: folder, line: 0)
        #expect(TestRunner.command(.swift, tests: [swiftTest], root: folder).command == #"swift test --filter '^LibTests\.Arithmetic/sums\(\)'"#)
        #expect(TestRunner.command(.swift, tests: nil, root: folder).command == "swift test")
        let goTests = [TestItem(id: "calc/TestA", label: "TestA", kind: .test, framework: .go, url: folder, line: 0),
                       TestItem(id: "./TestB", label: "TestB", kind: .test, framework: .go, url: folder, line: 0)]
        #expect(TestRunner.command(.go, tests: goTests, root: folder).command == "go test -json -run '^(TestA|TestB)$' . ./calc")
        let py = TestItem(id: "tests.test_math.MathTests.test_ok", label: "test_ok", kind: .test, framework: .python,
                          url: folder.appending(path: "tests/test_math.py"), line: 0)
        #expect(TestRunner.command(.python, tests: [py], root: folder).command == "python3 -m unittest -v 'tests.test_math.MathTests.test_ok'")
        #expect(TestRunner.command(.python, tests: [py], root: folder, hasPytest: true).command
                == "python3 -m pytest -v --tb=line -p no:cacheprovider 'tests/test_math.py::MathTests::test_ok'")
        let js = TestItem(id: "src/a.test.ts::add sums", label: "sums", kind: .test, framework: .vitest, url: folder, line: 0)
        let command = TestRunner.command(.vitest, tests: [js], root: folder)
        #expect(command.command.hasPrefix("npx vitest run --reporter=default --reporter=json --outputFile="))
        #expect(command.command.hasSuffix(" 'src/a.test.ts' -t '^add sums$'") && command.reportFile != nil)
    }
}

struct TestOutputParserTests {
    private func parse(_ framework: TestFramework, _ output: String, goModule: String? = nil) -> [TestEvent] {
        var parser = TestOutputParser(framework: framework, goModule: goModule)
        return output.components(separatedBy: "\n").flatMap { parser.consume($0) } + parser.finish()
    }

    @Test func readsSwiftOutput() {
        let events = parse(.swift, """
        Test Case '-[LibTests.MathTests testAdd]' started.
        Test Case '-[LibTests.MathTests testAdd]' passed (0.002 seconds).
        /p/Tests/LibTests/XCTests.swift:5: error: -[LibTests.MathTests testBroken] : XCTAssertEqual failed: ("3") is not equal to ("4") - wrong sum
        Test Case '-[LibTests.MathTests testBroken]' failed (0.034 seconds).
        ◇ Test run started.
        ◇ Suite Arithmetic started.
        ◇ Test sums() started.
        ✔ Test sums() passed after 0.001 seconds.
        ✘ Test "Named test" recorded an issue at NewTests.swift:5:40: Expectation failed: add(2, 2) == 5
        ✘ Test "Named test" failed after 0.001 seconds with 1 issue.
        ✘ Suite Arithmetic failed after 0.001 seconds with 1 issue.
        ✘ Test run with 3 tests in 1 suite failed after 0.001 seconds with 1 issue.
        """)
        #expect(events == [
            .started("LibTests.MathTests/testAdd"), .passed("LibTests.MathTests/testAdd", duration: 0.002),
            .issue("LibTests.MathTests/testBroken", message: #"XCTAssertEqual failed: ("3") is not equal to ("4") - wrong sum"#,
                   file: "/p/Tests/LibTests/XCTests.swift", line: 5),
            .failed("LibTests.MathTests/testBroken", duration: 0.034),
            .started("sums()"), .passed("sums()", duration: 0.001),
            .issue("\"Named test\"", message: "Expectation failed: add(2, 2) == 5", file: "NewTests.swift", line: 5),
            .failed("\"Named test\"", duration: 0.001),
        ])
    }

    @Test func readsGoPythonAndRustOutput() {
        let go = parse(.go, """
        {"Action":"run","Package":"example.com/demo/calc","Test":"TestBroken"}
        {"Action":"output","Package":"example.com/demo/calc","Test":"TestBroken","Output":"    calc_test.go:12: got 2, want 3\\n"}
        {"Action":"fail","Package":"example.com/demo/calc","Test":"TestBroken","Elapsed":0.01}
        {"Action":"pass","Package":"example.com/demo/calc","Test":"TestTable/one","Elapsed":0}
        {"Action":"pass","Package":"example.com/demo","Test":"TestRoot","Elapsed":0}
        """, goModule: "example.com/demo")
        #expect(go == [.started("calc/TestBroken"), .issue("calc/TestBroken", message: "got 2, want 3", file: "calc/calc_test.go", line: 12),
                       .failed("calc/TestBroken", duration: 0.01), .passed("./TestRoot", duration: 0)])
        #expect(TestOutputParser(framework: .go).display(#"{"Action":"output","Output":"--- PASS: TestA (0.00s)\n"}"#) == "--- PASS: TestA (0.00s)")
        #expect(TestOutputParser(framework: .go).display(#"{"Action":"pass","Test":"TestA"}"#) == nil)

        let unittest = parse(.python, """
        test_bad (tests.test_math.MathTests) ... FAIL
        test_ok (tests.test_math.MathTests.test_ok) ... ok
        test_skip (tests.test_math.MathTests) ... skipped 'later'

        ======================================================================
        FAIL: test_bad (tests.test_math.MathTests)
        ----------------------------------------------------------------------
        Traceback (most recent call last):
          File "/p/tests/test_math.py", line 8, in test_bad
            self.assertEqual(1 + 1, 3)
        AssertionError: 2 != 3

        ----------------------------------------------------------------------
        Ran 3 tests in 0.000s
        """)
        #expect(unittest == [.failed("tests.test_math.MathTests.test_bad", duration: nil), .passed("tests.test_math.MathTests.test_ok", duration: nil),
                             .skipped("tests.test_math.MathTests.test_skip"),
                             .issue("tests.test_math.MathTests.test_bad", message: "AssertionError: 2 != 3", file: "/p/tests/test_math.py", line: 8)])

        let pytest = parse(.python, """
        tests/test_math.py::MathTests::test_bad FAILED                [ 50%]
        tests/test_math.py::test_free PASSED                          [100%]
        /p/tests/test_math.py:8: AssertionError: assert 2 == 3
        """)
        #expect(pytest == [.failed("tests.test_math.MathTests.test_bad", duration: nil), .passed("tests.test_math.test_free", duration: nil),
                           .issue(nil, message: "AssertionError: assert 2 == 3", file: "/p/tests/test_math.py", line: 8)])

        let cargo = parse(.cargo, """
        test math::tests::adds ... ok
        test math::tests::breaks ... FAILED
        ---- math::tests::breaks stdout ----
        thread 'math::tests::breaks' panicked at src/math.rs:12:9:
        assertion `left == right` failed
        test math::tests::later ... ignored
        """)
        #expect(cargo == [.passed("math::tests::adds", duration: nil), .failed("math::tests::breaks", duration: nil),
                          .issue("math::tests::breaks", message: "assertion `left == right` failed", file: "src/math.rs", line: 12),
                          .skipped("math::tests::later")])
    }

    @Test func readsJestReports() {
        let report = """
        { "testResults": [{ "name": "/r/src/add.test.ts", "assertionResults": [
          { "ancestorTitles": ["add"], "title": "sums", "status": "passed", "duration": 4 },
          { "ancestorTitles": ["add"], "title": "breaks", "status": "failed", "duration": 2,
            "failureMessages": ["\\u001b[2mexpect(\\u001b[22mreceived\\u001b[2m).toBe(\\u001b[22mexpected\\u001b[2m)\\n\\n    at Object.<anonymous> (/r/src/add.test.ts:9:20)"] },
          { "ancestorTitles": [], "title": "later", "status": "pending" } ] }] }
        """
        let events = TestOutputParser.report(Data(report.utf8), root: URL(filePath: "/r"))
        #expect(events == [.passed("src/add.test.ts::add sums", duration: 0.004), .failed("src/add.test.ts::add breaks", duration: 0.002),
                           .issue("src/add.test.ts::add breaks", message: "expect(received).toBe(expected)", file: "src/add.test.ts", line: 9),
                           .skipped("src/add.test.ts::later")])
    }
}

@MainActor
struct TestControllerTests {
    private func eventually(_ timeout: Duration, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-testing-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func state(_ workspace: Workspace, _ id: String) -> TestController.State? { workspace.testing.results[id]?.state }

    @Test func runsAGoModulesTests() async throws {
        guard FileManager.default.fileExists(atPath: "/opt/homebrew/bin/go") || FileManager.default.fileExists(atPath: "/usr/local/go/bin/go") else { return }
        let root = try makeFolder([
            "go.mod": "module example.com/demo\n\ngo 1.21\n",
            "calc/calc.go": "package calc\n\nfunc Add(a, b int) int { return a + b }\n",
            "calc/calc_test.go": "package calc\n\nimport \"testing\"\n\nfunc TestAdd(t *testing.T) {\n\tif Add(1, 2) != 3 {\n\t\tt.Fatal(\"bad\")\n\t}\n}\n\nfunc TestBroken(t *testing.T) {\n\tt.Errorf(\"got %d, want %d\", Add(1, 1), 3)\n}\n",
        ])
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually(.seconds(10)) { workspace.testing.allTests.count == 2 })
        workspace.runAllTests()
        #expect(try await eventually(.seconds(120)) { !workspace.testing.runs.isEmpty && !workspace.testing.isRunning })
        #expect(state(workspace, "calc/TestAdd") == .passed && state(workspace, "calc/TestBroken") == .failed)
        let issue = try #require(workspace.testing.results["calc/TestBroken"]?.issues.first)
        #expect(issue.message == "got 2, want 3" && issue.line == 11 && issue.url?.lastPathComponent == "calc_test.go")
        // In Problems, and the Tasks panel shows Go's output rather than its JSON.
        #expect(workspace.problems.files().first?.diagnostics.first?.message == "TestBroken: got 2, want 3")
        let output = try #require(workspace.taskRuns.last).lines.map(\.text)
        #expect(output.contains { $0.hasPrefix("--- FAIL: TestBroken") } && !output.contains { $0.hasPrefix("{") })
        #expect(!workspace.isTerminalVisible) // running tests doesn't take over the panel

        // Gutter marks; running one test from its line.
        let url = root.appending(path: "calc/calc_test.go")
        #expect(workspace.testing.marks(for: url) == [4: .passed, 10: .failed])
        try "package calc\n\nimport \"testing\"\n\nfunc TestAdd(t *testing.T) {}\n\nfunc TestBroken(t *testing.T) {}\n"
            .write(to: url, atomically: true, encoding: .utf8)
        workspace.testing.update(path: "calc/calc_test.go", text: nil)
        workspace.testing.runTest(at: 6, in: url)
        #expect(try await eventually(.seconds(120)) { state(workspace, "calc/TestBroken") == .passed })
        #expect(workspace.problems.totalCount == 0)
    }

    @Test func runsPythonUnittests() async throws {
        let root = try makeFolder([
            "requirements.txt": "",
            "tests/__init__.py": "",
            "tests/test_math.py": "import unittest\n\nclass MathTests(unittest.TestCase):\n    def test_ok(self):\n        self.assertEqual(1 + 1, 2)\n\n    def test_bad(self):\n        self.assertEqual(1 + 1, 3)\n",
        ])
        let workspace = Workspace()
        workspace.testing.hasPytestOverride = false
        workspace.openFolder(root)
        #expect(try await eventually(.seconds(10)) { workspace.testing.allTests.count == 2 })
        let suite = try #require(workspace.testing.files.first?.children.first)
        workspace.testing.run([suite])
        #expect(try await eventually(.seconds(60)) { !workspace.testing.runs.isEmpty && !workspace.testing.isRunning })
        #expect(state(workspace, "tests.test_math.MathTests.test_ok") == .passed)
        #expect(state(workspace, "tests.test_math.MathTests.test_bad") == .failed)
        #expect(workspace.testing.results["tests.test_math.MathTests.test_bad"]?.issues.first?.line == 7)
        #expect(workspace.testing.state(of: suite) == .failed)
    }

    @Test func runsASwiftPackagesTests() async throws {
        let root = try makeFolder([
            "Package.swift": """
            // swift-tools-version:5.10
            import PackageDescription
            let package = Package(name: "Lib", targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])])
            """,
            "Sources/Lib/Lib.swift": "public func add(_ a: Int, _ b: Int) -> Int { a + b }\n",
            "Tests/LibTests/XCTests.swift": """
            import XCTest
            @testable import Lib
            final class MathTests: XCTestCase {
                func testAdd() { XCTAssertEqual(Lib.add(1, 2), 3) }
                func testBroken() { XCTAssertEqual(Lib.add(1, 2), 4, "wrong sum") }
            }
            """,
            "Tests/LibTests/NewTests.swift": """
            import Testing
            @testable import Lib
            struct Arithmetic {
                @Test func sums() { #expect(add(2, 2) == 4) }
                @Test("Named test") func fails() { #expect(add(2, 2) == 5) }
            }
            """,
        ])
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(try await eventually(.seconds(10)) { workspace.testing.allTests.count == 4 })
        workspace.runAllTests()
        #expect(try await eventually(.seconds(400)) { !workspace.testing.runs.isEmpty && !workspace.testing.isRunning })
        #expect(state(workspace, "LibTests.MathTests/testAdd") == .passed)
        #expect(state(workspace, "LibTests.MathTests/testBroken") == .failed)
        #expect(state(workspace, "LibTests.Arithmetic/sums()") == .passed)
        #expect(state(workspace, "LibTests.Arithmetic/fails()") == .failed)
        #expect(workspace.testing.results["LibTests.Arithmetic/fails()"]?.issues.first?.line == 4)

        // One Swift Testing test by itself (the --filter matches its id).
        workspace.testing.run([try #require(workspace.testing.item(id: "LibTests.Arithmetic/sums()"))])
        #expect(try await eventually(.seconds(400)) { !workspace.testing.isRunning && state(workspace, "LibTests.Arithmetic/sums()") == .passed })
        let output = workspace.taskRuns.last?.lines.map(\.text) ?? []
        #expect(output.contains { $0.contains("Test run with 1 test") })
    }
}
