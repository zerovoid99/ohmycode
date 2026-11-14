import AppKit

extension Workspace {
    // MARK: Breakpoints

    /// Connects an opened document to the breakpoints: marks in its gutter, lines that move.
    func attachBreakpoints(to document: EditorDocument) {
        // Symlinks resolved, as debug info has them (/var/… is /private/var/…).
        let path = FileWatcher.canonicalPath(document.url)
        document.breakpointMarks = { [weak self] in self?.breakpoints.marks(for: path) ?? [:] }
        document.onLinesReplaced = { [weak self] old, count in self?.breakpoints.linesReplaced(in: path, old, with: count) }
        document.toggleBreakpointAction = { [weak self, weak document] line in
            guard let self, let document else { return }
            self.toggleBreakpoint(in: document, line: line)
        }
    }

    /// Adds or removes a breakpoint on a line (zero-based) of a document.
    func toggleBreakpoint(in document: EditorDocument, line: Int) {
        breakpoints.toggle(FileWatcher.canonicalPath(document.url), line: line + 1)
    }

    /// F9: the breakpoint on the cursor's line.
    func toggleBreakpointAtCursor() {
        guard let document = activeDocument else { NSSound.beep(); return }
        toggleBreakpoint(in: document, line: document.cursorLine - 1)
    }

    /// Exception breakpoints or watches changed: a running debugger gets them.
    func debugSettingsChanged(watches: Bool) {
        guard let session = debugSession, session.isActive else { return }
        Task { if watches { await session.evaluateWatches() } else { await session.sendExceptionBreakpoints() } }
    }

    // MARK: Attaching

    /// Picks a running process (yours) and debugs it.
    func attachToProcess() async {
        let processes = await Self.runningProcesses()
        let items = processes.map { QuickPickItem(label: "\($0.name)  \($0.pid)", description: $0.executable) }
        guard let index = await showQuickPick(items, placeholder: "Process to attach to"), processes.indices.contains(index) else { return }
        let process = processes[index]
        await startDebugging(LaunchConfiguration(name: "Attach to \(process.name) (\(process.pid))", request: "attach", pid: process.pid))
    }

    struct RunningProcess: Equatable, Sendable {
        let pid: Int
        let name: String
        let executable: String
    }

    /// The current user's processes, newest first (lldb-dap lists them).
    static func runningProcesses() async -> [RunningProcess] {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcrun")
            process.arguments = ["lldb-dap", "--list-processes"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let user = Double(getuid())
            let own = ProcessInfo.processInfo.processIdentifier
            return ((try? JSONDecoder().decode(JSONValue.self, from: data))?.array ?? []).compactMap { entry -> RunningProcess? in
                guard entry["user"]?.number == user, let pid = entry["pid"]?.number.map(Int.init), pid != own,
                      let name = entry["name"]?.string else { return nil }
                return RunningProcess(pid: pid, name: name, executable: entry["executable"]?.string ?? "")
            }.sorted { $0.pid > $1.pid }
        }.value
    }

    /// A file's breakpoints changed: its gutter redraws, a running debugger gets them.
    func breakpointsChanged(in path: String) {
        document(matching: URL(filePath: path))?.redrawGutters()
        if let session = debugSession, session.isActive { Task { await session.sendBreakpoints(for: path) } }
    }

    // MARK: Launch configurations

    /// Reads .omc/launch.json, or finds a Swift package's executables.
    func loadLaunchConfigurations() async {
        guard let root = rootURL else { launchConfigurations = []; return }
        do {
            let configured = try LaunchConfiguration.load(in: root)
            if !configured.isEmpty { launchConfigurations = configured; return }
        } catch {
            errorMessage = error.localizedDescription
        }
        let environment = await ShellEnvironment.shared.environment()
        launchConfigurations = await LaunchConfiguration.swiftPackage(in: root, environment: environment)
    }

    /// Writes .omc/launch.json (for a program the editor can't find by itself) and opens it.
    func createLaunchFile() {
        guard let root = rootURL else { return }
        do {
            let url = root.appending(path: LaunchConfiguration.file)
            if !FileManager.default.fileExists(atPath: url.path) { try LaunchConfiguration.writeTemplate(in: root) }
            open(fileAt: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Debugging

    /// F5: continues a stopped program, or starts the selected configuration.
    func startOrContinueDebugging() {
        if let session = debugSession, session.isActive {
            if session.state == .stopped { session.resume() }
            return
        }
        Task { await startDebugging() }
    }

    /// Starts a configuration (the selected one by default) under the debugger.
    func startDebugging(_ chosen: LaunchConfiguration? = nil) async {
        if let session = debugSession, session.isActive { await session.stop() }
        if launchConfigurations.isEmpty { await loadLaunchConfigurations() }
        guard let root = rootURL else { return }
        guard let configuration = chosen ?? launchConfigurations.first(where: { $0.name == selectedLaunchName }) ?? launchConfigurations.first else {
            sidebarMode = .debug
            errorMessage = "There's nothing to debug yet: add a program to \(LaunchConfiguration.file) (Run and Debug → Create launch.json)."
            return
        }
        selectedLaunchName = configuration.name
        saveAll()
        let environment = await ShellEnvironment.shared.environment()
        let session = DebugSession(configuration: configuration.resolved(root: root, file: activeDocument?.url),
                                   adapter: debugAdapter, environment: environment)
        session.breakpoints = { [weak self] in self?.breakpoints.byPath ?? [:] }
        session.exceptionFilters = { [weak self] in self?.breakpoints.enabledExceptionFilters ?? [] }
        session.onExceptionFiltersOffered = { [weak self] in self?.breakpoints.setExceptionFilters($0) }
        session.watchExpressions = { [weak self] in self?.breakpoints.watches ?? [] }
        session.onBreakpointsVerified = { [weak self] path, lines in
            self?.breakpoints.setVerified(lines, for: path)
            self?.document(matching: URL(filePath: path))?.redrawGutters()
        }
        session.onStop = { [weak self] frame in self?.showExecution(at: frame) }
        session.onEnd = { [weak self] in
            guard let self else { return }
            breakpoints.clearVerified()
            for document in documents { document.executionLine = nil; document.redrawGutters() }
        }
        debugSession = session
        sidebarMode = .debug
        showDebugConsole()
        do { try await session.start() } catch { errorMessage = error.localizedDescription }
    }

    func stopDebugging() {
        guard let session = debugSession else { return }
        Task { await session.stop() }
    }

    func restartDebugging() {
        guard let session = debugSession else { return }
        let name = session.configuration.name
        Task {
            await session.stop()
            await startDebugging(launchConfigurations.first { $0.name == name })
        }
    }

    /// Marks the line a frame is at (opening its file), or clears the mark.
    private func showExecution(at frame: DebugSession.Frame?) {
        for document in documents { document.executionLine = nil }
        guard let frame, let path = frame.path, FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(filePath: path)
        open(fileAt: url)
        guard let document = document(matching: url) else { return }
        document.executionLine = frame.line - 1
        document.revealLine(frame.line)
    }
}
