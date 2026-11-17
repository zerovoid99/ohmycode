import AppKit
import Observation

/// The window's tests (the Testing panel): found by reading test files in each folder, run
/// through tasks in their folder, with each test's last result; failures go to Problems and
/// the editor. With several folders each one is a group in the list, and tests' ids start with
/// its label (see `TestItem.scope`).
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
    /// A folder's toolchains: what's found and run in it.
    struct Folder: Sendable {
        let url: URL
        /// Its label with several folders (its tests' scope); nil with one.
        let scope: String?
        var frameworks: Set<TestFramework> = []
        /// Its Xcode project, when it has one (its tests run with xcodebuild).
        var xcode: XcodeProject?
    }

    /// Test files, by id (every folder's).
    private(set) var files: [TestItem] = []
    /// The window's folders, in order, as last discovered.
    private(set) var folders: [Folder] = []
    private(set) var results: [String: Result] = [:]
    private(set) var isDiscovering = false
    /// Runs in progress (one per framework).
    private(set) var runs: [TaskRun] = []
    /// The tests of the last run (for Rerun).
    @ObservationIgnored private(set) var lastRun: [TestItem]?
    @ObservationIgnored private var lastRunAll = false
    /// The first folder's Xcode project, when it has one.
    var xcode: XcodeProject? { folders.first?.xcode }
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

    /// What the panel lists: the files, or with several folders a group per folder that has tests.
    var tree: [TestItem] {
        guard folders.count > 1 else { return files }
        return folders.compactMap { folder in
            let children = files.filter { $0.scope == folder.scope }
            guard let scope = folder.scope, let first = children.first else { return nil }
            return TestItem(id: "folder:" + scope, label: scope, kind: .folder, framework: first.framework, url: folder.url,
                            line: 0, children: children)
        }
    }

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

    /// Reading test files changed on disk.
    @ObservationIgnored private var diskTask: Task<Void, Never>?

    /// The folder (by index) a file is in (the innermost), and its path there.
    private func locate(_ url: URL) -> (folder: Int, path: String)? {
        let path = FileWatcher.canonicalPath(url)
        var best: (folder: Int, path: String, rootLength: Int)?
        for (index, folder) in folders.enumerated() {
            let root = FileWatcher.canonicalPath(folder.url) + "/"
            guard path.hasPrefix(root), root.count > best?.rootLength ?? 0 else { continue }
            best = (index, String(path.dropFirst(root.count)), root.count)
        }
        return best.map { ($0.folder, $0.path) }
    }

    /// The folder (by index) a path as the window writes it (see `WorkspaceRoots`) is in, and
    /// the path there.
    private func locate(windowPath path: String) -> (folder: Int, path: String)? {
        guard folders.count > 1 else { return folders.isEmpty ? nil : (0, path) }
        for (index, folder) in folders.enumerated() {
            guard let scope = folder.scope, path.hasPrefix(scope + "/") else { continue }
            return (index, String(path.dropFirst(scope.count + 1)))
        }
        return nil
    }

    /// The id of a file's item in a folder.
    private func fileID(_ path: String, in folder: Int) -> String {
        (folders[folder].scope.map { $0 + "/" } ?? "") + "file:" + path
    }

    /// A file's tests in a folder (scoped with several folders).
    nonisolated private static func discover(_ text: String, path: String, in folder: Folder, framework: TestFramework) -> TestItem? {
        let item = TestDiscovery.discover(text, path: path, root: folder.url, framework: framework, xcode: folder.xcode)
        guard let scope = folder.scope else { return item }
        return item?.scoped(scope)
    }

    /// Reads every test file in every folder, each folder with its own toolchains.
    func discover() async {
        guard let workspace, !workspace.folders.isEmpty else { files = []; folders = []; return }
        isDiscovering = true
        defer { isDiscovering = false }
        let roots = workspace.roots
        let windowPaths = await workspace.searchableFiles()
        var found: [Folder] = []
        var items: [TestItem] = []
        for root in roots.folders {
            var folder = Folder(url: root.url, scope: roots.isMultiRoot ? root.label : nil)
            folder.frameworks = TestDiscovery.frameworks(in: root.url)
            if XcodeProject.container(in: root.url) != nil {
                folder.xcode = await XcodeProject.load(in: root.url, environment: await ShellEnvironment.shared.environment())
                if folder.xcode != nil { folder.frameworks.insert(.xcode) }
            }
            let paths = roots.isMultiRoot
                ? windowPaths.compactMap { $0.hasPrefix(root.label + "/") ? String($0.dropFirst(root.label.count + 1)) : nil }
                : windowPaths
            let current = folder
            items += await Task.detached(priority: .userInitiated) { () -> [TestItem] in
                paths.compactMap { path in
                    guard let framework = TestDiscovery.framework(forFile: path, in: current.frameworks, xcode: current.xcode),
                          let text = try? String(contentsOf: current.url.appending(path: path), encoding: .utf8) else { return nil }
                    return Self.discover(text, path: path, in: current, framework: framework)
                }
            }.value
            found.append(folder)
        }
        guard workspace.roots == roots else { return }
        folders = found
        // Open files' text may be newer than the disk's.
        var byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for document in workspace.documents {
            guard let (index, path) = locate(document.url),
                  let framework = TestDiscovery.framework(forFile: path, in: found[index].frameworks, xcode: found[index].xcode) else { continue }
            byID[fileID(path, in: index)] = Self.discover(document.textStorage.string, path: path, in: found[index], framework: framework)
        }
        files = byID.keys.sorted().compactMap { byID[$0] }
        redrawGutters()
    }

    /// A file changed (on disk or in the editor; its path as the window writes it): its tests
    /// are read again.
    func update(path: String, text: String?) {
        guard let (index, relative) = locate(windowPath: path) else { return }
        update(folder: index, path: relative, text: text)
    }

    private func update(folder index: Int, path: String, text: String?) {
        let folder = folders[index]
        guard let framework = TestDiscovery.framework(forFile: path, in: folder.frameworks, xcode: folder.xcode) else { return }
        let text = text ?? (try? String(contentsOf: folder.url.appending(path: path), encoding: .utf8))
        let item = text.flatMap { Self.discover($0, path: path, in: folder, framework: framework) }
        let id = fileID(path, in: index)
        var updated = files.filter { $0.id != id }
        if let item { updated.append(item) }
        updated.sort { $0.id < $1.id }
        if updated != files {
            files = updated
            redrawGutters()
        }
    }

    /// Files on disk changed (paths as the window writes them, in any folder): the test files
    /// among them are read again off the main thread, all of them before the list changes,
    /// once. A checkout can change thousands, and one at a time each was read on the main
    /// thread and the list sorted again.
    func filesChanged(_ paths: [String]) {
        guard !files.isEmpty || folders.contains(where: { !$0.frameworks.isEmpty }), let workspace else { return }
        let folders = self.folders
        var changed = paths.compactMap { path -> (folder: Folder, path: String, framework: TestFramework, id: String)? in
            guard let (index, relative) = locate(windowPath: path),
                  let framework = TestDiscovery.framework(forFile: relative, in: folders[index].frameworks, xcode: folders[index].xcode)
            else { return nil }
            return (folders[index], relative, framework, fileID(relative, in: index))
        }
        guard !changed.isEmpty else { return }
        // Open files' tests follow the editor's text, not the disk's.
        let open = Set(workspace.documents.compactMap { document in locate(document.url).map { fileID($0.path, in: $0.folder) } })
        changed.removeAll { open.contains($0.id) }
        guard !changed.isEmpty else { return }
        let roots = folders.map(\.url)
        let previous = diskTask
        diskTask = Task { [weak self, changed] in
            await previous?.value // in the order the changes came
            let found = await Task.detached(priority: .utility) {
                changed.compactMap { file -> TestItem? in
                    guard let text = try? String(contentsOf: file.folder.url.appending(path: file.path), encoding: .utf8) else { return nil }
                    return Self.discover(text, path: file.path, in: file.folder, framework: file.framework)
                }
            }.value
            guard let self, self.folders.map(\.url) == roots else { return }
            let replaced = Set(changed.map(\.id))
            var updated = self.files.filter { !replaced.contains($0.id) }
            updated.append(contentsOf: found)
            updated.sort { $0.id < $1.id }
            if updated != self.files {
                self.files = updated
                self.redrawGutters()
            }
        }
    }

    /// Waits for test files changed on disk to be read (tests).
    func waitForFileChanges() async { await diskTask?.value }

    private func storageEdited(_ storage: NSTextStorage?) {
        guard let storage, let document = workspace?.documents.first(where: { $0.textStorage === storage }),
              let (index, path) = locate(document.url),
              TestDiscovery.framework(forFile: path, in: folders[index].frameworks, xcode: folders[index].xcode) != nil else { return }
        let id = fileID(path, in: index)
        let root = folders[index].url
        editTasks[id]?.cancel()
        editTasks[id] = Task { [weak self, weak document] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let document, let index = self.folders.firstIndex(where: { $0.url == root }) else { return }
            self.update(folder: index, path: path, text: document.textStorage.string)
        }
    }

    func reset() {
        runs.forEach { $0.terminate() }
        runs = []
        files = []
        results = [:]
        lastRun = nil
        folders = []
        publishProblems()
    }

    // MARK: Running

    /// Runs tests (nil: all of them), one command per framework in each folder, run there.
    func run(_ selection: [TestItem]?) {
        guard let workspace, !folders.isEmpty else { return }
        let tests = selection.map { $0.flatMap(\.tests) }
        lastRun = tests
        lastRunAll = selection == nil
        struct Job: Hashable {
            let folder: Int
            let framework: TestFramework
        }
        var jobs: [Job: [TestItem]?] = [:]
        if let tests {
            for test in Self.unique(tests) {
                guard let folder = folderIndex(of: test) else { continue }
                jobs[Job(folder: folder, framework: test.framework), default: []]?.append(test)
            }
        } else {
            for (index, folder) in folders.enumerated() {
                let used = Set(allTests.filter { folderIndex(of: $0) == index }.map(\.framework))
                    .union(folder.frameworks.intersection([.swift, .go, .cargo, .xcode]))
                for framework in used { jobs[Job(folder: index, framework: framework)] = .some(nil) }
            }
        }
        guard !jobs.isEmpty else {
            workspace.errorMessage = "No tests found: the Testing panel lists Swift, Go, Python, Jest, Vitest and Rust tests."
            return
        }
        for (job, list) in jobs.sorted(by: { ($0.key.folder, $0.key.framework.rawValue) < ($1.key.folder, $1.key.framework.rawValue) }) {
            let members = list ?? allTests.filter { $0.framework == job.framework && folderIndex(of: $0) == job.folder }
            for test in members { results[test.id, default: Result()].state = .queued }
            let folder = folders[job.folder]
            Task { await start(job.framework, tests: list, members: members, folder: folder) }
        }
    }

    /// The folder (by index) a test was found in.
    private func folderIndex(of test: TestItem) -> Int? {
        folders.firstIndex { $0.scope == test.scope }
    }

    private static func unique(_ tests: [TestItem]) -> [TestItem] {
        var seen = Set<String>()
        return tests.filter { seen.insert($0.id).inserted }
    }

    private func hasPytest() async -> Bool {
        if let hasPytestOverride { return hasPytestOverride }
        let environment = await ShellEnvironment.shared.environment()
        return await ProcessIO.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["python3", "-m", "pytest", "--version"]
            process.environment = environment
            process.standardError = FileHandle.nullDevice
            return (try? ProcessIO.run(process, output: Pipe(), error: nil))?.status == 0
        }
    }

    private func start(_ framework: TestFramework, tests: [TestItem]?, members: [TestItem], folder: Folder) async {
        let root = folder.url
        let pytest = framework == .python ? await hasPytest() : false
        let command = TestRunner.command(framework, tests: tests, root: root, hasPytest: pytest, xcode: folder.xcode)
        var parser = TestOutputParser(framework: framework, goModule: framework == .go ? Self.goModule(in: root) : nil)
        // One label per framework (and folder): running again replaces the last run (and its
        // task problems).
        let label = "Tests: " + framework.displayName + (folder.scope.map { " (\($0))" } ?? "")
        var definition = TaskDefinition(label: label, command: command.command, group: .test)
        definition.folder = root
        guard let workspace, let run = workspace.runTask(definition, reveal: false) else { return }
        // Its tasks panel shows the run; the Testing panel the results.
        runs.removeAll { !$0.state.isRunning }
        runs.append(run)
        let memberIDs = Set(members.map(\.id))
        run.displayLine = { line in parser.display(line) }
        run.onLine = { [weak self] line in
            guard let self else { return }
            self.apply(parser.consume(line), among: members, root: root)
        }
        run.onEnd = { [weak self] _ in
            guard let self else { return }
            self.apply(parser.finish(), among: members, root: root)
            if let report = command.reportFile {
                if let data = try? Data(contentsOf: report) { self.apply(TestOutputParser.report(data, root: root), among: members, root: root) }
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
            if let exact = members.first(where: { $0.name == name }) { return [exact] }
            var candidates = members.filter { test in
                test.displayName == name || test.name.hasSuffix("::" + name) || test.name.hasSuffix("/" + name)
            }
            if candidates.count > 1, let fileName { candidates = candidates.filter { $0.url.lastPathComponent == fileName } }
            if !candidates.isEmpty { return candidates }
        }
        // By position: the test whose declaration comes last before the line.
        guard let fileName, let line else { return [] }
        let inFile = members.filter { $0.url.lastPathComponent == fileName && $0.line < line }
        return inFile.max { $0.line < $1.line }.map { [$0] } ?? []
    }

    /// What a run in the folder `root` reported (relative paths are from there).
    private func apply(_ events: [TestEvent], among members: [TestItem], root: URL) {
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
                        return root.appending(path: path)
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
        guard let file = file(for: url) else { return [:] }
        var marks: [Int: State] = [:]
        for item in file.allItems where item.kind != .file { marks[item.line] = state(of: item) }
        return marks
    }

    /// Runs the test (or suite) declared on a line of a file.
    func runTest(at line: Int, in url: URL) {
        guard let file = file(for: url), let item = file.allItems.first(where: { $0.kind != .file && $0.line == line }) else { return }
        run([item])
    }

    /// The test or suite the cursor is in (the closest declaration above it).
    func item(at line: Int, in url: URL) -> TestItem? {
        guard let file = file(for: url) else { return nil }
        return file.allItems.filter { $0.kind != .file && $0.line <= line }.max { $0.line < $1.line }
    }

    func file(for url: URL) -> TestItem? {
        guard let (index, path) = locate(url) else { return nil }
        let id = fileID(path, in: index)
        return files.first { $0.id == id }
    }

    private func redrawGutters() {
        workspace?.documents.forEach { document in
            document.editors.forEach { $0.gutterView.updateWidth() }
            document.redrawGutters()
        }
    }
}
