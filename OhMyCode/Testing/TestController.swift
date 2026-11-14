import AppKit
import Observation

/// The folder's tests (the Testing panel): found by reading test files, run through tasks,
/// with each test's last result; failures go to Problems and the editor.
@MainActor
@Observable
final class TestController {
    enum State: Equatable {
        case unknown, queued, running, passed, failed, skipped
        /// The run ended without a result for it (the build failed, or it wasn't found).
        case notRun
    }

    struct Issue: Equatable {
        var message: String
        var url: URL?
        /// Zero-based.
        var line: Int?
    }

    struct Result: Equatable {
        var state: State = .unknown
        var duration: Double?
        var issues: [Issue] = []
    }

    @ObservationIgnored private weak var workspace: Workspace?
    /// Test files, by path.
    private(set) var files: [TestItem] = []
    private(set) var results: [String: Result] = [:]
    private(set) var isDiscovering = false
    /// Runs in progress (one per framework).
    private(set) var runs: [TaskRun] = []
    /// The tests of the last run (for Rerun).
    @ObservationIgnored private(set) var lastRun: [TestItem]?
    @ObservationIgnored private var lastRunAll = false
    @ObservationIgnored private var frameworks: Set<TestFramework> = []
    @ObservationIgnored private var editTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var publishedProblemURLs: Set<URL> = []
    /// Replaces the pytest check (tests).
    @ObservationIgnored var hasPytestOverride: Bool?

    static let problemSource = "tests"

    init(workspace: Workspace) {
        self.workspace = workspace
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let storage = note.object
            MainActor.assumeIsolated { self?.storageEdited(storage as? NSTextStorage) }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isRunning: Bool { runs.contains { $0.state.isRunning } }
    var allTests: [TestItem] { files.flatMap(\.tests) }

    func item(id: String) -> TestItem? {
        for file in files { if let found = file.allItems.first(where: { $0.id == id }) { return found } }
        return nil
    }

    /// A group's state: failed if any test failed, running if any runs, passed if all passed.
    func state(of item: TestItem) -> State {
        if item.kind == .test { return results[item.id]?.state ?? .unknown }
        let states = item.tests.map { results[$0.id]?.state ?? .unknown }
        if states.contains(.running) { return .running }
        if states.contains(.queued) { return .queued }
        if states.contains(.failed) { return .failed }
        if states.contains(.notRun) { return .notRun }
        if !states.isEmpty, states.allSatisfy({ $0 == .passed || $0 == .skipped }) { return states.contains(.passed) ? .passed : .skipped }
        return .unknown
    }

    var counts: (passed: Int, failed: Int, total: Int) {
        let tests = allTests
        return (tests.count { results[$0.id]?.state == .passed }, tests.count { results[$0.id]?.state == .failed }, tests.count)
    }

    // MARK: Discovery

    private var root: URL? { workspace?.rootURL }

    private func relativePath(_ url: URL) -> String? {
        guard let root else { return nil }
        let rootPath = FileWatcher.canonicalPath(root) + "/"
        let path = FileWatcher.canonicalPath(url)
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : nil
    }

    /// Reads every test file in the folder.
    func discover() async {
        guard let workspace, let root = workspace.rootURL else { files = []; return }
        isDiscovering = true
        defer { isDiscovering = false }
        let paths = await workspace.searchableFiles()
        let frameworks = TestDiscovery.frameworks(in: root)
        self.frameworks = frameworks
        let found = await Task.detached(priority: .userInitiated) { () -> [TestItem] in
            paths.compactMap { path in
                guard let framework = TestDiscovery.framework(forFile: path, in: frameworks),
                      let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { return nil }
                return TestDiscovery.discover(text, path: path, root: root, framework: framework)
            }
        }.value
        guard workspace.rootURL == root else { return }
        // Open files' text may be newer than the disk's.
        var byPath = Dictionary(found.map { (String($0.id.dropFirst(5)), $0) }, uniquingKeysWith: { first, _ in first })
        for document in workspace.documents {
            guard let path = relativePath(document.url), let framework = TestDiscovery.framework(forFile: path, in: frameworks) else { continue }
            byPath[path] = TestDiscovery.discover(document.textStorage.string, path: path, root: root, framework: framework)
        }
        files = byPath.keys.sorted().compactMap { byPath[$0] }
        redrawGutters()
    }

    /// A file changed (on disk or in the editor): its tests are read again.
    func update(path: String, text: String?) {
        guard let root, let framework = TestDiscovery.framework(forFile: path, in: frameworks) else { return }
        let text = text ?? (try? String(contentsOf: root.appending(path: path), encoding: .utf8))
        let item = text.flatMap { TestDiscovery.discover($0, path: path, root: root, framework: framework) }
        var updated = files.filter { $0.id != "file:" + path }
        if let item { updated.append(item) }
        updated.sort { $0.id < $1.id }
        if updated != files {
            files = updated
            redrawGutters()
        }
    }

    /// Files on disk changed.
    func filesChanged(_ paths: [String]) {
        guard !files.isEmpty || !frameworks.isEmpty else { return }
        for path in paths {
            guard let relative = relativePath(URL(filePath: path)),
                  workspace?.document(matching: URL(filePath: path)) == nil else { continue }
            update(path: relative, text: nil)
        }
    }

    private func storageEdited(_ storage: NSTextStorage?) {
        guard let storage, let document = workspace?.documents.first(where: { $0.textStorage === storage }),
              let path = relativePath(document.url), TestDiscovery.framework(forFile: path, in: frameworks) != nil else { return }
        editTasks[path]?.cancel()
        editTasks[path] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let document else { return }
            self.update(path: path, text: document.textStorage.string)
        }
    }

    func reset() {
        runs.forEach { $0.terminate() }
        runs = []
        files = []
        results = [:]
        lastRun = nil
        frameworks = []
        publishProblems()
    }

    // MARK: Running

    /// Runs tests (nil: all of them), one command per framework.
    func run(_ selection: [TestItem]?) {
        guard let workspace, let root = workspace.rootURL else { return }
        let tests = selection.map { $0.flatMap(\.tests) }
        lastRun = tests
        lastRunAll = selection == nil
        let byFramework: [TestFramework: [TestItem]?]
        if let tests {
            byFramework = Dictionary(grouping: Self.unique(tests), by: \.framework).mapValues { Optional($0) }
        } else {
            let used = Set(allTests.map(\.framework)).union(frameworks.intersection([.swift, .go, .cargo]))
            byFramework = Dictionary(uniqueKeysWithValues: used.map { ($0, nil) })
        }
        guard !byFramework.isEmpty else {
            workspace.errorMessage = "No tests found: the Testing panel lists Swift, Go, Python, Jest, Vitest and Rust tests."
            return
        }
        for (framework, list) in byFramework.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let members = list ?? allTests.filter { $0.framework == framework }
            for test in members { results[test.id, default: Result()].state = .queued }
            Task { await start(framework, tests: list, members: members, root: root) }
        }
    }

    private static func unique(_ tests: [TestItem]) -> [TestItem] {
        var seen = Set<String>()
        return tests.filter { seen.insert($0.id).inserted }
    }

    private func hasPytest() async -> Bool {
        if let hasPytestOverride { return hasPytestOverride }
        let environment = await ShellEnvironment.shared.environment()
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["python3", "-m", "pytest", "--version"]
            process.environment = environment
            process.standardError = FileHandle.nullDevice
            return (try? ProcessIO.run(process, output: Pipe(), error: nil))?.status == 0
        }.value
    }

    private func start(_ framework: TestFramework, tests: [TestItem]?, members: [TestItem], root: URL) async {
        let pytest = framework == .python ? await hasPytest() : false
        let command = TestRunner.command(framework, tests: tests, root: root, hasPytest: pytest)
        var parser = TestOutputParser(framework: framework, goModule: framework == .go ? Self.goModule(in: root) : nil)
        // One label per framework: running again replaces the last run (and its task problems).
        let label = "Tests: " + framework.displayName
        guard let workspace, let run = workspace.runTask(TaskDefinition(label: label, command: command.command, group: .test), reveal: false) else { return }
        // Its tasks panel shows the run; the Testing panel the results.
        runs.removeAll { !$0.state.isRunning }
        runs.append(run)
        let memberIDs = Set(members.map(\.id))
        run.displayLine = { line in parser.display(line) }
        run.onLine = { [weak self] line in
            guard let self else { return }
            self.apply(parser.consume(line), among: members)
        }
        run.onEnd = { [weak self] _ in
            guard let self else { return }
            self.apply(parser.finish(), among: members)
            if let report = command.reportFile {
                if let data = try? Data(contentsOf: report) { self.apply(TestOutputParser.report(data, root: root), among: members) }
                try? FileManager.default.removeItem(at: report)
            }
            var anyResult = false
            for id in memberIDs {
                if [.queued, .running].contains(self.results[id]?.state) { self.results[id]?.state = .notRun } else { anyResult = true }
            }
            // Tests ran, so the build worked: errors the output matched are the failures, which
            // Problems lists as tests' already. (A failed build's errors stay.)
            if anyResult { self.workspace?.clearTaskProblems(source: Workspace.taskSource(label)) }
            self.publishProblems()
            self.redrawGutters()
        }
    }

    static func goModule(in root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appending(path: "go.mod"), encoding: .utf8) else { return nil }
        return text.components(separatedBy: .newlines).first { $0.hasPrefix("module ") }
            .map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
    }

    /// Re-runs the last run's tests.
    func rerun() {
        if lastRunAll { run(nil) } else if let lastRun { run(lastRun) }
    }

    func runFailed() {
        let failed = allTests.filter { results[$0.id]?.state == .failed }
        if !failed.isEmpty { run(failed) }
    }

    func cancel() {
        runs.forEach { $0.terminate() }
    }

    // MARK: Results

    /// The tests an event's name means.
    private func resolve(_ name: String?, file: String?, line: Int?, among members: [TestItem]) -> [TestItem] {
        let fileName = file.map { ($0 as NSString).lastPathComponent }
        if let name {
            if let exact = members.first(where: { $0.id == name }) { return [exact] }
            var candidates = members.filter { test in
                test.displayName == name || test.id.hasSuffix("::" + name) || test.id.hasSuffix("/" + name)
            }
            if candidates.count > 1, let fileName { candidates = candidates.filter { $0.url.lastPathComponent == fileName } }
            if !candidates.isEmpty { return candidates }
        }
        // By position: the test whose declaration comes last before the line.
        guard let fileName, let line else { return [] }
        let inFile = members.filter { $0.url.lastPathComponent == fileName && $0.line < line }
        return inFile.max { $0.line < $1.line }.map { [$0] } ?? []
    }

    private func apply(_ events: [TestEvent], among members: [TestItem]) {
        guard !events.isEmpty else { return }
        for event in events {
            switch event {
            case .started(let name):
                for test in resolve(name, file: nil, line: nil, among: members) {
                    results[test.id] = Result(state: .running)
                }
            case .passed(let name, let duration):
                for test in resolve(name, file: nil, line: nil, among: members) {
                    results[test.id, default: Result()].state = .passed
                    results[test.id]?.duration = duration
                    results[test.id]?.issues = []
                }
            case .failed(let name, let duration):
                for test in resolve(name, file: nil, line: nil, among: members) {
                    results[test.id, default: Result()].state = .failed
                    results[test.id]?.duration = duration
                }
            case .skipped(let name):
                for test in resolve(name, file: nil, line: nil, among: members) { results[test.id, default: Result()].state = .skipped }
            case .issue(let name, let message, let file, let line):
                for test in resolve(name, file: file, line: line, among: members) {
                    let url = file.map { path -> URL in
                        if path.hasPrefix("/") { return URL(filePath: path) }
                        if (path as NSString).lastPathComponent == path { return test.url } // a bare file name: the test's
                        return root?.appending(path: path) ?? URL(filePath: path)
                    }
                    let issue = Issue(message: message, url: url ?? test.url, line: line.map { max(0, $0 - 1) })
                    var result = results[test.id] ?? Result()
                    if !result.issues.contains(issue) { result.issues.append(issue) }
                    if result.state != .passed { result.state = .failed }
                    results[test.id] = result
                }
            }
        }
        publishProblems()
        redrawGutters()
    }

    /// Failures in Problems and the editor ("tests").
    private func publishProblems() {
        guard let workspace else { return }
        var byURL: [URL: [Diagnostic]] = [:]
        for test in allTests {
            guard let result = results[test.id], result.state == .failed else { continue }
            let issues = result.issues.isEmpty ? [Issue(message: "Failed", url: test.url, line: test.line)] : result.issues
            for issue in issues {
                let url = workspace.workspaceURL(for: issue.url ?? test.url)
                let line = issue.line ?? test.line
                let range = LSPRange(start: LSPPosition(line: line, character: 0), end: LSPPosition(line: line, character: 1))
                byURL[url, default: []].append(Diagnostic(range: range, severity: .error,
                                                          message: "\(test.label): \(issue.message)", source: "test"))
            }
        }
        for url in publishedProblemURLs.union(byURL.keys) {
            let list = byURL[url] ?? []
            workspace.problems.set(list, for: url, source: Self.problemSource)
            workspace.document(matching: url)?.setExtensionDiagnostics(list, collection: Self.problemSource)
        }
        publishedProblemURLs = Set(byURL.keys)
    }

    // MARK: Editor

    /// The gutter marks of a file's tests and suites (by zero-based line).
    func marks(for url: URL) -> [Int: State] {
        guard let path = relativePath(url), let file = files.first(where: { $0.id == "file:" + path }) else { return [:] }
        var marks: [Int: State] = [:]
        for item in file.allItems where item.kind != .file { marks[item.line] = state(of: item) }
        return marks
    }

    /// Runs the test (or suite) declared on a line of a file.
    func runTest(at line: Int, in url: URL) {
        guard let path = relativePath(url), let file = files.first(where: { $0.id == "file:" + path }),
              let item = file.allItems.first(where: { $0.kind != .file && $0.line == line }) else { return }
        run([item])
    }

    /// The test or suite the cursor is in (the closest declaration above it).
    func item(at line: Int, in url: URL) -> TestItem? {
        guard let path = relativePath(url), let file = files.first(where: { $0.id == "file:" + path }) else { return nil }
        return file.allItems.filter { $0.kind != .file && $0.line <= line }.max { $0.line < $1.line }
    }

    func file(for url: URL) -> TestItem? {
        guard let path = relativePath(url) else { return nil }
        return files.first { $0.id == "file:" + path }
    }

    private func redrawGutters() {
        workspace?.documents.forEach { document in
            document.editors.forEach { $0.gutterView.updateWidth() }
            document.redrawGutters()
        }
    }
}
