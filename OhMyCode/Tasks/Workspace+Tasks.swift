import AppKit

extension Workspace {
    /// The folder's tasks: .omc/tasks.json's, then the ones its build files define.
    func loadTasks() -> [TaskDefinition] {
        guard let root = rootURL else { return [] }
        do {
            return try TaskDefinition.all(in: root)
        } catch {
            errorMessage = error.localizedDescription
            return TaskDefinition.detect(in: root)
        }
    }

    /// Terminal → Run Task…: picks one of the folder's tasks.
    func pickAndRunTask(group: TaskDefinition.Group? = nil) async {
        let all = loadTasks()
        let tasks = group.map { group in all.filter { $0.group == group } } ?? all
        guard !tasks.isEmpty else {
            if all.isEmpty {
                errorMessage = "This folder has no tasks yet: Terminal → Configure Tasks… writes \(TaskDefinition.file)."
            } else {
                // No task in the group: offer them all.
                await pickAndRunTask()
            }
            return
        }
        let recent = taskHistory
        let ordered = tasks.sorted { (recent.firstIndex(of: $0.label) ?? .max) < (recent.firstIndex(of: $1.label) ?? .max) }
        let items = ordered.map { task in
            QuickPickItem(label: task.label, description: [task.group?.rawValue, task.detail ?? "tasks.json"].compactMap { $0 }.joined(separator: " · "),
                          detail: task.command)
        }
        let placeholder = switch group {
        case .build: "Build task to run"
        case .test: "Test task to run"
        case nil: "Task to run"
        }
        guard let index = await showQuickPick(items, placeholder: placeholder), ordered.indices.contains(index) else { return }
        runTask(ordered[index])
    }

    /// ⇧⌘B: the default build task (or a pick among the build tasks).
    func runBuildTask() { runGroupTask(.build) }

    func runTestTask() { runGroupTask(.test) }

    private func runGroupTask(_ group: TaskDefinition.Group) {
        let tasks = loadTasks().filter { $0.group == group }
        if let task = tasks.first(where: { $0.isDefault == true }) ?? (tasks.count == 1 ? tasks.first : nil) {
            runTask(task)
        } else {
            Task { await pickAndRunTask(group: group) }
        }
    }

    /// Runs the last task again.
    func rerunLastTask() {
        guard let label = taskHistory.first, let task = loadTasks().first(where: { $0.label == label }) else {
            Task { await pickAndRunTask() }
            return
        }
        runTask(task)
    }

    /// Starts a task (stopping an earlier run of it), showing its output and problems.
    @discardableResult
    func runTask(_ task: TaskDefinition) -> TaskRun? {
        guard let root = rootURL else { return nil }
        if let running = taskRuns.first(where: { $0.task.label == task.label && $0.state.isRunning }) { running.terminate() }
        taskHistory.removeAll { $0 == task.label }
        taskHistory.insert(task.label, at: 0)
        saveAll()

        let run = TaskRun(task: task.resolved(root: root, file: activeDocument?.url))
        let source = Self.taskSource(task.label)
        clearTaskProblems(source: source)
        run.onProblems = { [weak self] problems in self?.setTaskProblems(problems, source: source) }
        // Earlier finished runs of the same task make way for this one.
        taskRuns.removeAll { $0.task.label == task.label && !$0.state.isRunning }
        taskRuns.append(run)
        selectedTaskRunID = run.id
        bottomPanel = .tasks
        isTerminalVisible = true
        Task {
            let environment = await ShellEnvironment.shared.environment()
            run.start(environment: environment)
        }
        return run
    }

    func terminateTask(_ run: TaskRun? = nil) {
        guard let run = run ?? selectedTaskRun ?? taskRuns.last(where: { $0.state.isRunning }) else { return }
        run.terminate()
    }

    /// Picks a running task to stop (or stops the only one).
    func terminateRunningTask() async {
        let running = taskRuns.filter { $0.state.isRunning }
        if running.count <= 1 { running.first?.terminate(); return }
        let items = running.map { QuickPickItem(label: $0.task.label, description: nil, detail: $0.task.command) }
        guard let index = await showQuickPick(items, placeholder: "Task to terminate"), running.indices.contains(index) else { return }
        running[index].terminate()
    }

    /// Removes a finished run from the panel (and its problems).
    func closeTaskRun(_ run: TaskRun) {
        run.terminate()
        clearTaskProblems(source: Self.taskSource(run.task.label))
        taskRuns.removeAll { $0.id == run.id }
        if selectedTaskRunID == run.id { selectedTaskRunID = taskRuns.last?.id }
    }

    var selectedTaskRun: TaskRun? { taskRuns.first { $0.id == selectedTaskRunID } ?? taskRuns.last }

    func showTasks() {
        bottomPanel = .tasks
        isTerminalVisible = true
    }

    /// Terminal → Configure Tasks…: opens .omc/tasks.json, writing it first with the found tasks.
    func configureTasks() {
        guard let root = rootURL else { return }
        do {
            let url = root.appending(path: TaskDefinition.file)
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = try TaskDefinition.writeTemplate(in: root, tasks: TaskDefinition.detect(in: root))
            }
            open(fileAt: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opens the file and position a line of task output reports.
    func open(_ problem: ProblemMatcher.Problem) {
        open(problem: problem.diagnostic, in: workspaceURL(for: problem.url))
    }

    // MARK: Problems

    static func taskSource(_ label: String) -> String { "task:" + label }

    private func setTaskProblems(_ problems: [ProblemMatcher.Problem], source: String) {
        let byFile = Dictionary(grouping: problems) { workspaceURL(for: $0.url) }
        for (url, list) in byFile {
            let diagnostics = list.map { problem in
                var diagnostic = problem.diagnostic
                diagnostic.source = String(source.dropFirst("task:".count))
                return diagnostic
            }
            self.problems.set(diagnostics, for: url, source: source)
            document(matching: url)?.setExtensionDiagnostics(diagnostics, collection: source)
        }
    }

    private func clearTaskProblems(source: String) {
        for document in documents where !problems.diagnostics(for: document.url, source: source).isEmpty {
            document.setExtensionDiagnostics([], collection: source)
        }
        problems.clear(source: source)
    }

    /// A document just opened gets the problems tasks found in it.
    func applyTaskProblems(to document: EditorDocument) {
        for (source, diagnostics) in problems.sources(for: document.url) where source.hasPrefix("task:") {
            document.setExtensionDiagnostics(diagnostics, collection: source)
        }
    }
}
