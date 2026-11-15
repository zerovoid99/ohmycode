import AppKit
import Observation

/// State for one editor window: the opened folder and its open documents (tabs).
@MainActor
@Observable
final class Workspace {
    private(set) var rootURL: URL?
    private(set) var rootNode: FileNode?
    /// Every open document, in any editor group.
    private(set) var documents: [EditorDocument] = [] {
        didSet {
            for document in documents where !oldValue.contains(where: { $0 === document }) {
                attachBreakpoints(to: document)
                applyTaskProblems(to: document)
                document.workspaceRoot = rootURL
                document.workspace = self
                attachTests(to: document)
            }
            // Tell the extensions (only once they're running: opening a folder starts them).
            guard extensionsStarted else { return }
            for document in documents where !oldValue.contains(where: { $0 === document }) { extensions.documentOpened(document) }
            for document in oldValue where !documents.contains(where: { $0 === document }) { extensions.documentClosed(document) }
        }
    }
    /// Breakpoints in this folder's files.
    let breakpoints = BreakpointStore()
    /// The program being debugged (or the last one, terminated).
    var debugSession: DebugSession?
    /// What can be debugged: .omc/launch.json, or a Swift package's executables.
    var launchConfigurations: [LaunchConfiguration] = []
    var selectedLaunchName: String?
    /// Replaces the debug adapter's command (tests).
    @ObservationIgnored var debugAdapter: [String]?
    enum BottomPanel { case terminal, debugConsole, problems, tasks }
    /// The folder's declarations from syntax trees (⌘T).
    @ObservationIgnored private(set) var symbolIndex = WorkspaceSymbolIndex()
    /// The folder's tests (the Testing panel).
    @ObservationIgnored private(set) lazy var testing = TestController(workspace: self)
    /// Markdown documents shown with their preview beside them.
    private(set) var markdownPreviews: Set<EditorDocument.ID> = []
    /// Every diagnostic in the folder (the Problems panel).
    let problems = ProblemStore()
    /// Tasks run (the Tasks panel), oldest first; finished ones stay until run again or closed.
    var taskRuns: [TaskRun] = []
    var selectedTaskRunID: TaskRun.ID?
    /// Task labels, most recently run first.
    @ObservationIgnored var taskHistory: [String] = []
    /// What the bottom panel shows.
    var bottomPanel = BottomPanel.terminal
    /// The window showing this workspace (set by the window).
    @ObservationIgnored weak var window: NSWindow?
    /// The window's extensions.
    @ObservationIgnored private(set) lazy var extensions = ExtensionHost(workspace: self)
    @ObservationIgnored private var extensionsStarted = false
    /// Messages shown in the corner of the window (from extensions).
    private(set) var notifications: [AppNotification] = []
    @ObservationIgnored private var notificationReplies: [UUID: (String?) -> Void] = [:]
    /// Open diff tabs (their ids are tab ids in the groups, like document ids).
    private(set) var diffSessions: [DiffSession] = []
    /// Split editor panes, left to right; there is always at least one.
    private(set) var groups: [EditorGroup]
    var activeGroupID: EditorGroup.ID {
        didSet { if activeGroupID != oldValue { retargetEditor() } }
    }
    static let maxGroups = 4

    var activeGroup: EditorGroup { groups.first { $0.id == activeGroupID } ?? groups[0] }

    /// The active group's current tab. Setting it shows that document in the active group.
    var activeDocumentID: EditorDocument.ID? {
        get { activeGroup.activeDocumentID }
        set {
            activeGroup.show(newValue)
            retargetEditor()
        }
    }
    var errorMessage: String?
    private(set) var fileIndex: FileIndex?
    /// Most recently opened first.
    private(set) var recentFiles: [URL] = []
    private(set) var palette: PaletteModel?
    enum SidebarMode: String, CaseIterable {
        case files = "Files"
        case search = "Search"
        case sourceControl = "Source Control"
        case references = "References"
        case history = "Timeline"
        case extensions = "Extensions"
        case debug = "Run and Debug"
        case testing = "Testing"
        case outline = "Outline"
        case callHierarchy = "Call Hierarchy"
    }

    @ObservationIgnored private(set) lazy var search = SearchModel(workspace: self)

    /// ⇧⌘F (⇧⌘H with `replace`): show the search panel, seeded with the editor's selection.
    func showSearch(replace: Bool = false) {
        sidebarMode = .search
        var selected: String?
        if let editor = activeDocument?.editor, let textView = editor.textView {
            let range = textView.selectedRange()
            if range.length > 0, range.length < 200 {
                selected = (textView.string as NSString).substring(with: range)
            }
        }
        search.focus(prefill: selected, replace: replace)
    }

    /// Files for Find in Files: the quick-open index (git-aware), built first if needed.
    func searchableFiles() async -> [String] {
        if fileIndex == nil, let rootURL {
            let index = await Task.detached(priority: .userInitiated) { FileIndexer.build(root: rootURL) }.value
            if self.rootURL == rootURL, fileIndex == nil { fileIndex = index }
        }
        return fileIndex?.files.map(\.text) ?? []
    }

    var sidebarMode = SidebarMode.files
    /// Multi-file edits waiting for review (rename, replace all), shown as a sheet.
    var pendingEdit: EditPreview?
    /// Last Find All References result, shown in the sidebar.
    var references: ReferenceList?
    /// The last call hierarchy shown (the sidebar).
    var callHierarchy: CallHierarchy?
    /// Replaces the Format on Save setting (tests); nil follows Settings.
    @ObservationIgnored var formatOnSave: Bool?
    /// How long saving waits for the formatter before saving the text as it is.
    @ObservationIgnored var formatOnSaveTimeout: Duration = .seconds(2)
    /// Replaces the rename dialog (tests): gets the current name, returns the new one or nil.
    @ObservationIgnored var renamePrompt: ((String) -> String?)?
    private(set) var gitStatus: GitStatus?
    private(set) var isRunningGitCommand = false
    @ObservationIgnored private(set) var gitRepository: Git.Repository?
    @ObservationIgnored private var gitTask: Task<Void, Never>?
    /// The Timeline panel: the commits that changed a file.
    private(set) var fileHistory: FileHistory?
    @ObservationIgnored private var historyTask: Task<Void, Never>?

    /// What the Timeline panel lists: the active file's commits or the whole repository's.
    enum HistoryScope: String, CaseIterable { case file = "File", repository = "Repository", compare = "Compare" }
    /// Two refs compared (the Timeline's Compare tab); nil until one is picked.
    private(set) var comparison: RefComparison?
    private(set) var isComparing = false
    var historyScope: HistoryScope = .file
    /// The repository log (pages of `repoHistoryPageSize`), narrowed by `repoHistoryFilter`.
    private(set) var repoHistory: RepoHistory?
    /// A search in the repository log; setting it reads the log again.
    var repoHistoryFilter: LogFilter? {
        didSet {
            guard repoHistoryFilter != oldValue else { return }
            repoHistory = nil // a different list: no paging or graph from the old one
            loadRepoHistory()
        }
    }
    @ObservationIgnored private var repoHistoryTask: Task<Void, Never>?
    @ObservationIgnored var repoHistoryPageSize = 200
    @ObservationIgnored private var commitDetailsCache: [String: CommitDetails] = [:]
    /// Files each commit changed, read when the commit is expanded.
    private(set) var commitFiles: [String: [CommitFile]] = [:]
    /// Tests answer these instead of a dialog: the new branch's name (nil cancels), and
    /// whether to check out a commit.
    @ObservationIgnored var branchNamePrompt: ((RepoCommit) -> String?)?
    @ObservationIgnored var checkoutConfirmation: ((RepoCommit) -> Bool)?
    /// An interactive rebase being set up (shown as a sheet).
    var pendingRebase: RebasePlan?
    /// Stash entries, newest first (read with `git status`).
    private(set) var stashes: [GitStash] = []
    /// Files of each stash, read when it's expanded.
    private(set) var stashFiles: [String: [StashFile]] = [:]
    /// Local and remote branches, read when the branch picker opens.
    private(set) var branches: [GitBranch]?
    /// The repository's submodules (paths from its top folder), read with the status.
    private(set) var submodules: [GitSubmodule] = []
    /// The repository's worktrees, once read (see `loadWorktrees`).
    private(set) var worktrees: [GitWorktree]?
    /// Tests answer this instead of the worktree dialog: given the branch (nil: a new branch
    /// from HEAD) and the suggested folder, the folder and the new branch's name (nil cancels).
    @ObservationIgnored var worktreePrompt: ((GitBranch?, String) -> (path: String, newBranch: String?)?)?
    /// Opens a folder in a new window (set by the window; tests record the folder).
    @ObservationIgnored var openInNewWindow: ((URL) -> Void)?
    /// The repository's remotes, once read (see `loadRemotes`).
    private(set) var remotes: [GitRemote]?
    /// Tests answer this instead of the remote dialog: a name and URL, given the remote being
    /// edited (nil: a new one). Nil cancels.
    @ObservationIgnored var remotePrompt: ((GitRemote?) -> (name: String, url: String)?)?
    /// Tests answer these instead of dialogs: a name typed for a new or renamed branch (given
    /// the dialog's title), and yes/no questions (given the question).
    @ObservationIgnored var textPrompt: ((String) -> String?)?
    @ObservationIgnored var confirmation: ((String) -> Bool)?
    /// Replaces server discovery per language (tests point a workspace at a fake server).
    @ObservationIgnored var languageServerOverrides: [SourceLanguage: LanguageServerConfig] = [:]
    /// One client per language server, shared by all documents it handles.
    private(set) var languageClients: [String: LanguageClient] = [:]
    private(set) var terminals: [TerminalSession] = []
    var activeTerminalID: TerminalSession.ID?
    var isTerminalVisible = false
    /// Bumped to move keyboard focus into the terminal.
    private(set) var terminalFocusRequest = 0
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    /// Root as FSEvents reports paths (symlinks resolved).
    @ObservationIgnored private var canonicalRootPath = ""

    /// Stands in for a window's workspace once it's closed, for work that finishes after it.
    static let closed = Workspace()

    init() {
        let group = EditorGroup()
        groups = [group]
        activeGroupID = group.id
        NotificationCenter.default.addObserver(forName: .omcEditorCommand, object: nil, queue: .main) { [weak self] note in
            let document = note.object as? EditorDocument
            let command = (note.userInfo?["command"] as? String).flatMap(EditorCommand.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, let document, let command, self.documents.contains(where: { $0 === document }) else { return }
                self.perform(command, in: document)
            }
        }
    }

    var activeDocument: EditorDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    var displayName: String {
        rootURL?.lastPathComponent ?? "Oh My Code"
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openFolder(_ url: URL) {
        guard documents.allSatisfy({ confirmClose($0) }) else { return }
        RecentFolders.shared.add(url)
        rootURL = url
        rootNode = FileNode(url: url, isDirectory: true)
        documents.removeAll()
        let group = EditorGroup()
        groups = [group]
        activeGroupID = group.id
        recentFiles.removeAll()
        fileIndex = nil
        rebuildFileIndex()
        terminals.forEach { $0.terminate() }
        terminals.removeAll()
        activeTerminalID = nil
        isTerminalVisible = false

        gitStatus = nil
        gitRepository = nil
        remotes = nil
        worktrees = nil
        submodules = []
        if let session = debugSession { Task { await session.stop() } }
        debugSession = nil
        taskRuns.forEach { $0.terminate() }
        taskRuns = []
        testing.reset()
        Task { await testing.discover() }
        symbolIndex = WorkspaceSymbolIndex()
        taskHistory = []
        problems.removeAll()
        launchConfigurations = []
        breakpoints.load(for: url)
        breakpoints.onChange = { [weak self] path in self?.breakpointsChanged(in: path) }
        breakpoints.onExceptionFiltersChange = { [weak self] in self?.debugSettingsChanged(watches: false) }
        breakpoints.onWatchesChange = { [weak self] in self?.debugSettingsChanged(watches: true) }
        refreshGit()
        extensionsStarted = true
        extensions.start()
        languageClients.values.forEach { $0.shutdown() }
        languageClients.removeAll()
        // Resolve the login-shell PATH now, so the first file opened doesn't wait for it.
        Task.detached(priority: .utility) { _ = await ShellEnvironment.shared.environment() }

        canonicalRootPath = FileWatcher.canonicalPath(url)
        watcher = FileWatcher(path: canonicalRootPath) { [weak self] events in
            self?.handleFileEvents(events)
        }
    }

    /// Rebuilds the quick-open index in the background. The previous index stays usable until
    /// the new one is ready; `delay` debounces bursts of file-system events.
    func rebuildFileIndex(after delay: Duration = .zero) {
        guard let rootURL else { return }
        indexTask?.cancel()
        indexTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let index = await Task.detached(priority: .userInitiated) {
                FileIndexer.build(root: rootURL)
            }.value
            guard !Task.isCancelled, self.rootURL == rootURL else { return }
            self.fileIndex = index
            if self.palette?.mode == .files { self.palette?.refresh() }
        }
    }

    // MARK: File system changes

    func handleFileEvents(_ events: [FileWatcher.Event]) {
        guard let rootNode else { return }
        let prefix = canonicalRootPath + "/"
        var directoriesToReload = Set<String>()
        var changedPaths = Set<String>()
        var needsIndexRebuild = false
        var needsGitRefresh = false
        var editorConfigChanged = false

        for event in events {
            if event.requiresRescan || event.path == canonicalRootPath {
                editorConfigChanged = true
                rootNode.reloadLoadedSubtree()
                needsIndexRebuild = true
                changedPaths.formUnion(documents.map { FileWatcher.canonicalPath($0.url) })
                continue
            }
            guard event.path.hasPrefix(prefix) else { continue }
            let relative = String(event.path.dropFirst(prefix.count))
            let components = relative.split(separator: "/").map(String.init)
            // Git rewrites .git/index, locks etc. constantly; none of it changes the file list,
            // but it does change status (commits, staging, checkouts).
            if components.first == ".git" {
                needsGitRefresh = true
                continue
            }
            needsGitRefresh = true

            changedPaths.insert(event.path)
            if components.last == ".editorconfig" { editorConfigChanged = true }
            if event.isStructural {
                directoriesToReload.insert(components.dropLast().joined(separator: "/"))
                needsIndexRebuild = true
            }
        }

        if editorConfigChanged { documents.forEach { $0.reloadEditorConfig() } }
        for directory in directoriesToReload {
            let components = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
            rootNode.loadedNode(atRelativePath: components)?.reloadChildren()
        }
        if needsIndexRebuild {
            rebuildFileIndex(after: .milliseconds(300))
        }
        if needsGitRefresh {
            refreshGit(after: .milliseconds(300))
        }
        for document in documents where changedPaths.contains(FileWatcher.canonicalPath(document.url)) {
            document.reloadFromDiskIfChanged()
        }
        testing.filesChanged(Array(changedPaths))
        let changed = changedPaths.compactMap { relativePath(of: URL(filePath: $0)) }
        if !changed.isEmpty { Task { [symbolIndex] in await symbolIndex.invalidate(changed) } }
    }

    // MARK: Language servers

    private func attachLanguageServer(to document: EditorDocument) {
        guard let rootURL else { return }
        Task { [weak self] in
            let environment = await ShellEnvironment.shared.environment()
            guard let self, self.rootURL == rootURL, self.documents.contains(where: { $0 === document }),
                  let config = LanguageServers.config(for: document.language, path: environment["PATH"] ?? "",
                                                      overrides: self.languageServerOverrides)
            else { return }
            let client: LanguageClient
            if let existing = languageClients[config.name] {
                client = existing
            } else {
                do {
                    client = try LanguageClient(name: config.name, command: config.command, rootURL: rootURL,
                                                environment: environment)
                } catch {
                    return // server missing or failed to launch: the editor works without it
                }
                client.onInlayHintRefresh = { [weak self, weak client] in
                    self?.documents.filter { $0.languageClient === client }.forEach { $0.refreshInlayHints() }
                }
                client.onApplyEdit = { [weak self] edit, label in
                    self?.applyServerEdit(edit, actionName: label ?? "\(config.name) Edit") ?? false
                }
                let source = "lsp:" + config.name
                client.onDiagnostics = { [weak self] url, diagnostics in
                    guard let self else { return }
                    self.problems.set(diagnostics, for: self.workspaceURL(for: url), source: source)
                    self.document(matching: url)?.setDiagnostics(diagnostics)
                }
                languageClients[config.name] = client
            }
            document.languageClient = client
            client.didOpen(url: document.url, languageId: document.languageId,
                           text: document.textStorage.mutableString as String)
            // The server's symbols once it's ready (the syntax tree's until then).
            Task { [weak document, weak client] in
                while let client, client.state == .starting { try? await Task.sleep(for: .milliseconds(200)) }
                document?.refreshSymbols()
                document?.refreshInlayHints()
                document?.refreshLinks()
            }
        }
    }

    /// Servers report symlink-resolved paths (/private/var/…); map them back under the
    /// workspace root so the file isn't opened twice under different names.
    func workspaceURL(for url: URL) -> URL {
        let path = FileWatcher.canonicalPath(url)
        if let rootURL, path.hasPrefix(canonicalRootPath + "/") {
            return rootURL.appending(path: String(path.dropFirst(canonicalRootPath.count + 1)))
        }
        return URL(filePath: path)
    }

    func document(matching url: URL) -> EditorDocument? {
        let path = FileWatcher.canonicalPath(url)
        return documents.first { $0.canonicalPath == path }
    }

    func perform(_ command: EditorCommand, in document: EditorDocument) {
        switch command {
        case .goToDefinition: goToDefinition(in: document)
        case .findReferences: findReferences(in: document)
        case .goToImplementation: goToImplementation(in: document)
        case .callHierarchy: showCallHierarchy(in: document)
        case .codeActions: showCodeActions(in: document)
        case .rename: renameSymbol(in: document)
        case .format: formatDocument(document)
        case .stageSelectedLines: stageSelectedLines(in: document)
        case .revertSelectedLines: revertSelectedLines(in: document)
        }
    }

    /// Jumps to the definition of the symbol at the cursor (F12, ⌘-click).
    func goToDefinition(in target: EditorDocument? = nil) {
        guard let document = target ?? activeDocument, let client = document.languageClient,
              let selection = document.editor?.textView.selectedRange() else { return }
        let position = document.lspPosition(at: selection.location)
        Task {
            guard let location = try? await client.definition(url: document.url, position: position).first else {
                NSSound.beep()
                return
            }
            open(fileAt: workspaceURL(for: location.url))
            guard let target = activeDocument else { return }
            target.reveal(target.range(for: location.range))
        }
    }

    // MARK: Git

    /// Re-reads `git status` (debounced by `delay`), then refreshes open documents' diff bases,
    /// since staging or committing changes what their gutter markers compare against.
    func refreshGit(after delay: Duration = .zero) {
        guard let rootURL else { return }
        gitTask?.cancel()
        let knownRepository = gitRepository
        gitTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let result = await Task.detached(priority: .utility) { () -> (Git.Repository, GitStatus, [GitStash], [GitSubmodule])? in
                guard let repository = knownRepository ?? Git.repository(at: rootURL),
                      let status = Git.status(of: repository) else { return nil }
                return (repository, status, Git.stashes(in: repository) ?? [], Git.submodules(in: repository) ?? [])
            }.value
            guard !Task.isCancelled, self.rootURL == rootURL else { return }
            self.gitRepository = result?.0
            if self.gitStatus != result?.1 { self.gitStatus = result?.1 }
            if self.stashes != result?.2 ?? [] { self.stashes = result?.2 ?? [] }
            if self.submodules != result?.3 ?? [] { self.submodules = result?.3 ?? [] }
            for document in self.documents { self.loadDiffBase(for: document) }
            for session in self.diffSessions where session.mode == .staged { self.loadStaged(session) }
            // A commit may have added to the file's history.
            if self.sidebarMode == .history {
                if self.historyScope == .file, let url = self.fileHistory?.url { self.loadHistory(for: url) }
                if self.historyScope == .repository { self.loadRepoHistory() }
            }
        }
    }

    func stage(_ paths: [String]) { runGit { try Git.stage(paths, in: $0) } }

    /// Stages one change of the editor's text (unsaved edits included), leaving the rest of
    /// the file unstaged.
    func stageHunk(_ hunk: DiffHunk, of document: EditorDocument) {
        guard let base = document.diffBaseLines, let path = relativePath(of: document.url),
              hunk.oldStart + hunk.oldCount <= base.count else { NSSound.beep(); return }
        let current = LineDiff.lines(document.textStorage.mutableString as String)
        guard hunk.newStart + hunk.newCount <= current.count else { NSSound.beep(); return }
        let expected = base.joined(separator: "\n")
        let content = LineDiff.applying(hunk, old: base, new: current)
        runGit { try Git.setIndexContent(content, expected: expected, relativePath: path, in: $0) }
    }

    /// Git: Stage Selected Lines — stages the changed lines the editor's selections touch
    /// (every cursor's), leaving the rest of each change unstaged.
    func stageSelectedLines(in target: EditorDocument? = nil) {
        guard let document = target ?? activeDocument else { NSSound.beep(); return }
        let lines = selectedLines(in: document)
        stageRows(of: document) { LineDiff.rows(touching: lines, in: $0) }
    }

    /// Git: Revert Selected Lines — puts the changed lines the selections touch back to the
    /// staged version, as one undoable edit; the rest of each change stays.
    func revertSelectedLines(in target: EditorDocument? = nil) {
        guard let document = target ?? activeDocument else { NSSound.beep(); return }
        let lines = selectedLines(in: document)
        revertRows(of: document) { LineDiff.rows(touching: lines, in: $0) }
    }

    /// Reverts chosen rows of the editor's changes to the staged version (undoable). `rows`
    /// picks them from the hunks as they are now; nil or none refuses.
    func revertRows(of document: EditorDocument, _ rows: ([DiffHunk]) -> Set<DiffLinePair>?) {
        guard let base = document.diffBaseLines else { NSSound.beep(); return }
        let text = document.textStorage.mutableString
        let current = LineDiff.lines(text as String)
        let hunks = LineDiff.hunks(base: base, current: current)
        guard let selected = rows(hunks), !selected.isEmpty else { NSSound.beep(); return }
        let edits = LineDiff.revertEdits(rows: selected, hunks: hunks, old: base, new: current, text: text,
                                         lineStarts: document.lineIndex.lineStarts)
        do {
            _ = try document.apply(edits.map { TextReplacement(range: $0.range, text: $0.replacement) },
                                   actionName: "Revert Selected Lines")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Zero-based lines touched by the editor's selections (every cursor's).
    private func selectedLines(in document: EditorDocument) -> Set<Int> {
        let ranges = document.editor.map { [$0.textView.selectedRange()] + $0.extraSelections }
            ?? document.viewState.map { [$0.selection] } ?? []
        var lines = Set<Int>()
        for range in ranges {
            let first = document.lineIndex.line(containing: range.location)
            let last = document.lineIndex.line(containing: max(range.location, NSMaxRange(range) - 1))
            lines.formUnion(first...last)
        }
        return lines
    }

    /// Stages chosen rows of the editor's changes (unsaved edits included). `rows` picks them
    /// from the hunks as they are now; nil or none refuses (e.g. the diff they were picked
    /// from has changed since).
    func stageRows(of document: EditorDocument, _ rows: ([DiffHunk]) -> Set<DiffLinePair>?) {
        guard let base = document.diffBaseLines, let path = relativePath(of: document.url) else { NSSound.beep(); return }
        let current = LineDiff.lines(document.textStorage.mutableString as String)
        let hunks = LineDiff.hunks(base: base, current: current)
        guard let selected = rows(hunks), !selected.isEmpty else { NSSound.beep(); return }
        let content = LineDiff.mixing(old: base, new: current, hunks: hunks, useNew: selected.contains)
        let expected = base.joined(separator: "\n")
        runGit { try Git.setIndexContent(content, expected: expected, relativePath: path, in: $0) }
    }

    /// Takes chosen rows back out of the staged version (the working tree keeps them).
    func unstageRows(_ rows: Set<DiffLinePair>, in session: DiffSession) {
        guard session.mode == .staged, let head = session.headLines, let index = session.indexLines,
              let path = relativePath(of: session.url) else { NSSound.beep(); return }
        let hunks = session.stagedHunks
        guard !rows.isDisjoint(with: hunks.flatMap(LineDiff.pairs)) else { NSSound.beep(); return }
        let content = LineDiff.mixing(old: head, new: index, hunks: hunks, useNew: { !rows.contains($0) })
        let expected = index.joined(separator: "\n")
        if session.isNewFile && content.isEmpty {
            runGit { try Git.unstage([path], in: $0) }
        } else {
            runGit { try Git.setIndexContent(content, expected: expected, relativePath: path, in: $0) }
        }
    }

    /// Git: Stage Change at Cursor.
    func stageHunkAtCursor() {
        guard let document = activeDocument,
              let location = document.editor?.textView.selectedRange().location ?? document.viewState?.selection.location,
              let hunk = document.hunk(atLine: document.lineIndex.line(containing: location)) else {
            NSSound.beep()
            return
        }
        stageHunk(hunk, of: document)
    }

    /// Removes one change from the staged version (the working tree keeps it).
    func unstageHunk(_ hunk: DiffHunk, in session: DiffSession) {
        guard session.mode == .staged, let head = session.headLines, let index = session.indexLines,
              let path = relativePath(of: session.url),
              hunk.oldStart + hunk.oldCount <= head.count, hunk.newStart + hunk.newCount <= index.count else {
            NSSound.beep()
            return
        }
        let expected = index.joined(separator: "\n")
        let content = LineDiff.reverting(hunk, old: head, new: index)
        if session.isNewFile && content.isEmpty {
            // Unstaging all of a new file's content: drop it from the index rather than staging it empty.
            runGit { try Git.unstage([path], in: $0) }
        } else {
            runGit { try Git.setIndexContent(content, expected: expected, relativePath: path, in: $0) }
        }
    }

    /// Reverts one change in the editor to the staged version, as an undoable edit.
    func revertHunk(_ hunk: DiffHunk, in document: EditorDocument) {
        guard let edit = document.revertEdit(for: hunk) else { return }
        do {
            _ = try document.apply([TextReplacement(range: edit.range, text: edit.replacement)], actionName: "Revert Change")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    func unstage(_ paths: [String]) { runGit { try Git.unstage(paths, in: $0) } }

    /// Discards unstaged changes. Untracked files go to the Trash rather than being deleted.
    func discard(_ changes: [GitChange]) {
        guard let rootURL, !changes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = changes.count == 1
            ? "Discard changes in \(changes[0].path)?" : "Discard changes in \(changes.count) files?"
        alert.informativeText = changes.contains(where: \.isUntracked)
            ? "Untracked files will be moved to the Trash. Other changes can't be undone." : "This can't be undone."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard Self.confirmDiscard?(changes) ?? (alert.runModal() == .alertFirstButtonReturn) else { return }

        let tracked = changes.filter { !$0.isUntracked }.map(\.path)
        let untracked = changes.filter(\.isUntracked).map { rootURL.appending(path: $0.path) }
        let trash = Self.moveToTrash
        runGit { repository in
            for url in untracked { try trash(url) }
            if !tracked.isEmpty { try Git.discard(tracked, in: repository) }
        }
    }

    /// Tests replace the confirmation dialog and the Trash (so runs don't fill the user's Trash).
    @ObservationIgnored static var confirmDiscard: (([GitChange]) -> Bool)?
    @ObservationIgnored nonisolated(unsafe) static var moveToTrash: @Sendable (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }

    /// Commits what is staged. Returns false (and shows the error) if git refused.
    func commit(message: String) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let repository = gitRepository else { return false }
        isRunningGitCommand = true
        defer { isRunningGitCommand = false }
        do {
            try await Task.detached { try Git.commit(message: trimmed, in: repository) }.value
            refreshGit()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Amends the last commit with what is staged (an empty message keeps its message). Asks
    /// first if the commit was pushed: rewriting it means force-pushing later.
    func amend(message: String) async -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repository = gitRepository, gitStatus?.hasCommits == true else { return false }
        isRunningGitCommand = true
        defer { isRunningGitCommand = false }
        let pushed = await Task.detached { Git.isHeadPushed(in: repository) }.value
        if pushed, !confirm("The last commit is already pushed. Amending rewrites it, so the branch will need a force push. Amend anyway?") {
            return false
        }
        do {
            try await Task.detached { try Git.amend(message: trimmed, in: repository) }.value
            refreshGit()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Undoes the last commit, keeping its changes staged. Returns its message (to put back in
    /// the message box), or nil if nothing was undone.
    func undoLastCommit() async -> String? {
        guard let repository = gitRepository, gitStatus?.hasCommits == true else { return nil }
        isRunningGitCommand = true
        defer { isRunningGitCommand = false }
        let (last, pushed) = await Task.detached { (Git.lastCommit(in: repository), Git.isHeadPushed(in: repository)) }.value
        guard let last else { return nil }
        let question = pushed
            ? "Undo “\(last.message.prefix(60))”? It's already pushed: the branch will need a force push."
            : "Undo “\(last.message.prefix(60))”? Its changes stay staged."
        guard confirm(question) else { return nil }
        do {
            try await Task.detached { try Git.undoLastCommit(hasParent: last.hasParent, in: repository) }.value
            refreshGit()
            return last.message
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// The last commit's message, to edit and amend.
    func lastCommitMessage() async -> String? {
        guard let repository = gitRepository, gitStatus?.hasCommits == true else { return nil }
        return await Task.detached { Git.lastCommit(in: repository)?.message }.value
    }

    private func runGit(_ operation: @escaping @Sendable (Git.Repository) throws -> Void) {
        guard gitRepository != nil else { return }
        isRunningGitCommand = true
        Task { await performGit(operation) }
    }

    /// Runs a git command off the main thread, shows its error, then reads the state again.
    /// Returns whether it succeeded.
    @discardableResult
    private func performGit(_ operation: @escaping @Sendable (Git.Repository) throws -> Void) async -> Bool {
        guard let repository = gitRepository else { return false }
        isRunningGitCommand = true
        var succeeded = true
        do {
            try await Task.detached { try operation(repository) }.value
        } catch {
            errorMessage = error.localizedDescription
            succeeded = false
        }
        isRunningGitCommand = false
        refreshGit()
        if branches != nil { await loadBranches() }
        if remotes != nil { await loadRemotes() }
        if worktrees != nil { await loadWorktrees() }
        return succeeded
    }

    func gitStatus(for url: URL, isDirectory: Bool) -> GitFileStatus? {
        guard let gitStatus, let path = relativePath(of: url) else { return nil }
        return gitStatus.status(forRelativePath: path, isDirectory: isDirectory)
    }

    func relativePath(of url: URL) -> String? {
        guard let rootURL else { return nil }
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    private func loadDiffBase(for document: EditorDocument) {
        document.compareConflictAction = { [weak self, weak document] conflict in
            guard let self, let document else { return }
            self.compareConflict(conflict, in: document)
        }
        guard let repository = gitRepository, let path = relativePath(of: document.url) else {
            document.setDiffBase(nil)
            return
        }
        Task {
            let base = await Task.detached(priority: .utility) {
                Git.indexContent(ofRelativePath: path, in: repository)
            }.value
            document.setDiffBase(base)
        }
        document.blameProvider = { text in
            await Task.detached(priority: .utility) {
                Git.blame(relativePath: path, contents: text, in: repository)
            }.value
        }
        document.scheduleBlame(after: .zero)
        document.blameActions = BlameActions(
            details: { [weak self] line in await self?.commitDetails(line.commit) },
            openChanges: { [weak self] line in Task { await self?.openBlameChanges(line) } },
            showInTimeline: { [weak self] line in self?.showInTimeline(commit: line.commit) })
        document.stageHunkAction = { [weak self, weak document] hunk in
            guard let self, let document else { return }
            self.stageHunk(hunk, of: document)
        }
    }

    /// Reads HEAD's and the index's version of a staged diff's file.
    private func loadStaged(_ session: DiffSession) {
        guard let repository = gitRepository, let path = relativePath(of: session.url) else {
            session.setStaged(head: nil, index: nil)
            return
        }
        Task {
            let (head, index) = await Task.detached(priority: .utility) {
                (Git.headContent(ofRelativePath: path, in: repository), Git.indexContent(ofRelativePath: path, in: repository))
            }.value
            session.setStaged(head: head, index: index)
        }
    }

    // MARK: History

    /// The file the Timeline follows: the active editor's, or the active diff tab's.
    var activeFileURL: URL? {
        activeDocument?.url ?? diffSession(id: activeGroup.activeDocumentID)?.url
    }

    /// Git: Show File History.
    func showFileHistory() {
        sidebarMode = .history
        if let url = activeFileURL { loadHistory(for: url) }
    }

    /// Reads the file's commits (newest first), keeping the current list up until the new one
    /// is ready when it's the same file.
    func loadHistory(for url: URL) {
        historyTask?.cancel()
        guard let repository = gitRepository, let path = relativePath(of: url) else {
            fileHistory = FileHistory(url: url, commits: nil, isLoading: false)
            return
        }
        if fileHistory?.url != url { fileHistory = FileHistory(url: url, commits: nil, isLoading: true) }
        historyTask = Task {
            let commits = await Task.detached(priority: .utility) {
                Git.history(ofRelativePath: path, in: repository)
            }.value
            guard !Task.isCancelled else { return }
            fileHistory = FileHistory(url: url, commits: commits ?? [], isLoading: false)
        }
    }

    /// Waits for the history being read (tests).
    func waitForHistory() async { await historyTask?.value }

    /// A commit's changes to the file, as a diff tab (its parent's version against its own).
    @discardableResult
    func openCommit(_ commit: GitCommit, for url: URL) -> DiffSession {
        if let existing = diffSessions.first(where: { $0.mode == .commit(commit) }) {
            activeGroup.show(existing.id)
            return existing
        }
        let session = DiffSession(commit: commit, of: url)
        diffSessions.append(session)
        loadCommit(session, commit)
        activeGroup.show(session.id)
        return session
    }

    /// Shows a new diff tab.
    func addDiffSession(_ session: DiffSession) {
        diffSessions.append(session)
        activeGroup.show(session.id)
    }

    /// The file as it was in a commit against the editor's text now (live).
    @discardableResult
    func compare(_ commit: GitCommit, with url: URL) -> DiffSession? {
        let canonical = FileWatcher.canonicalPath(url)
        if let existing = diffSessions.first(where: { $0.mode == .compare(commit) && FileWatcher.canonicalPath($0.url) == canonical }) {
            activeGroup.show(existing.id)
            return existing
        }
        let wasOpen = document(matching: url) != nil
        guard let document = document(matching: url) ?? openWithoutTab(url) else { return nil }
        let session = DiffSession(document: document, ownsDocument: !wasOpen, comparingWith: commit)
        diffSessions.append(session)
        loadCommit(session, commit)
        activeGroup.show(session.id)
        return session
    }

    /// A merge conflict's current and incoming sides, side by side (as they are now; the tab
    /// doesn't follow later edits).
    @discardableResult
    func compareConflict(_ conflict: MergeConflict, in document: EditorDocument) -> DiffSession {
        let comparison = conflict.comparison(in: document.textStorage.mutableString)
        let canonical = document.canonicalPath
        if let existing = diffSessions.first(where: { $0.mode == .conflict(comparison) && FileWatcher.canonicalPath($0.url) == canonical }) {
            activeGroup.show(existing.id)
            return existing
        }
        let session = DiffSession(conflict: comparison, of: document.url)
        diffSessions.append(session)
        activeGroup.show(session.id)
        return session
    }

    /// Loads a commit's version of the file (and, to show the commit, its parent's).
    private func loadCommit(_ session: DiffSession, _ commit: GitCommit) {
        guard let repository = gitRepository else {
            session.setLoaded(base: nil, current: nil, isNewFile: false)
            return
        }
        let wantsParent: Bool
        if case .commit = session.mode { wantsParent = true } else { wantsParent = false }
        Task {
            let (parent, version) = await Task.detached(priority: .utility) { () -> (String?, String?) in
                let version = commit.path.flatMap { Git.content(atCommit: commit.sha, repositoryPath: $0, in: repository) }
                guard wantsParent, let parent = commit.parents.first, let parentPath = commit.parentPath else { return (nil, version) }
                return (Git.content(atCommit: parent, repositoryPath: parentPath, in: repository), version)
            }.value
            if wantsParent {
                // Added in the commit: nothing before; deleted: nothing after.
                session.setLoaded(base: parent ?? "", current: version ?? "", isNewFile: parent == nil)
            } else {
                session.setLoaded(base: version ?? "", current: nil, isNewFile: false)
            }
        }
    }

    // MARK: Repository history

    /// Reads the repository log: from the start (as many commits as are listed already, so a
    /// refresh keeps what was loaded), or the next page (`more`).
    func loadRepoHistory(more: Bool = false) {
        guard let repository = gitRepository else { repoHistory = nil; return }
        if more, repoHistory?.isLoading == true { return }
        repoHistoryTask?.cancel()
        let pinned = more ? repoHistory?.pinned : nil
        // Pages count from the log itself, not the hash match listed first.
        let existing = (repoHistory?.commits ?? []).filter { $0 != pinned }
        let pageSize = repoHistoryPageSize
        let filter = repoHistoryFilter
        let skip = more ? existing.count : 0
        let limit = more ? pageSize : max(pageSize, existing.count)
        repoHistory = RepoHistory(commits: repoHistory?.commits ?? [], isLoading: true, hasMore: repoHistory?.hasMore ?? false,
                                  graph: repoHistory?.graph ?? [], pinned: pinned)
        repoHistoryTask = Task {
            // The graph is laid out again for the whole list: a new page can end lanes above it.
            let (page, commits, graph, found) = await Task.detached(priority: .utility) {
                let page = Git.log(in: repository, limit: limit, skip: skip, filter: filter)
                let commits = more ? existing + (page ?? []) : page ?? []
                // Search results skip commits between them: lines there would be wrong.
                let graph = filter == nil ? CommitGraph.layout(commits.map { ($0.sha, $0.parents) }) : []
                // A search that looks like a hash also finds that commit.
                let found = more ? pinned : filter?.hashPrefix.flatMap { Git.commit(named: $0, in: repository) }
                return (page, commits, graph, found)
            }.value
            guard !Task.isCancelled else { return }
            let extra = found.flatMap { commits.contains($0) ? nil : $0 }
            repoHistory = RepoHistory(commits: (extra.map { [$0] } ?? []) + commits, isLoading: false,
                                      hasMore: (page?.count ?? 0) == limit, graph: graph, pinned: extra)
        }
    }

    /// Waits for the repository log being read (tests).
    func waitForRepoHistory() async { await repoHistoryTask?.value }

    /// Reads the files a commit changed (once).
    func loadFiles(of commit: RepoCommit) async {
        guard commitFiles[commit.sha] == nil, let repository = gitRepository else { return }
        let files = await Task.detached(priority: .utility) {
            Git.changedFiles(in: commit, repository: repository)
        }.value
        commitFiles[commit.sha] = files ?? []
    }

    /// The repository's top folder (the workspace folder may be inside it).
    var repositoryRootURL: URL? { gitRepository?.top }

    /// A commit's change to one file, as a diff tab.
    @discardableResult
    func openCommit(_ commit: RepoCommit, file: CommitFile) -> DiffSession? {
        guard let top = repositoryRootURL else { return nil }
        return openCommit(commit.change(to: file), for: top.appending(path: file.path))
    }

    // MARK: Submodules

    /// The submodule at a file tree folder, if it is one.
    func submodule(at url: URL) -> GitSubmodule? {
        guard !submodules.isEmpty, let top = repositoryRootURL else { return nil }
        let path = url.standardizedFileURL.path, topPath = top.standardizedFileURL.path
        guard path.hasPrefix(topPath + "/") else { return nil }
        let relative = String(path.dropFirst(topPath.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return submodules.first { $0.path == relative }
    }

    /// The submodule a Source Control change is about (its path is from the workspace folder).
    func submodule(for change: GitChange) -> GitSubmodule? {
        guard change.isSubmodule, let prefix = gitRepository?.prefix else { return nil }
        return submodules.first { $0.path == prefix + change.path }
    }

    /// Checks out the recorded commits of the submodules (all when empty), cloning any not
    /// initialized yet.
    func updateSubmodules(_ submodules: [GitSubmodule] = []) {
        let paths = submodules.map(\.path)
        runGit { try Git.updateSubmodules(paths, in: $0) }
    }

    func openSubmodule(_ submodule: GitSubmodule) {
        guard submodule.state != .notInitialized, let top = repositoryRootURL else { NSSound.beep(); return }
        openInNewWindow?(top.appending(path: submodule.path, directoryHint: .isDirectory))
    }

    // MARK: Worktrees

    func loadWorktrees() async {
        guard let repository = gitRepository else { worktrees = nil; return }
        worktrees = await Task.detached(priority: .userInitiated) { Git.worktrees(in: repository) }.value ?? []
    }

    /// Whether a worktree is the one this window shows.
    func isCurrent(_ worktree: GitWorktree) -> Bool {
        repositoryRootURL.map(worktree.isAt) ?? false
    }

    /// Checks `branch` out in a new worktree (nil: a new branch from HEAD), asking where, then
    /// opens it in a new window. A remote branch gets a local branch tracking it.
    func createWorktree(for branch: GitBranch?) async {
        guard let top = repositoryRootURL else { return }
        let suggestedBranch = branch?.localName ?? ""
        let folderName = top.lastPathComponent + "-" + (suggestedBranch.isEmpty ? "worktree" : suggestedBranch)
            .replacingOccurrences(of: "/", with: "-")
        let suggested = top.deletingLastPathComponent().appending(path: folderName).path
        guard let answer = worktreePrompt.map({ $0(branch, suggested) }) ?? promptForWorktree(branch, suggestedPath: suggested)
        else { return }
        let path = (answer.path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let newBranch = answer.newBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, newBranch?.isEmpty != true else { return }
        let hasLocal = branch.map { b in !b.isRemote || (branches ?? []).contains { !$0.isRemote && $0.name == b.localName } } ?? false
        let succeeded = await performGit { repository in
            if let branch, hasLocal {
                try Git.addWorktree(at: path, branch: branch.isRemote ? branch.localName : branch.name, newBranch: nil,
                                    track: false, in: repository)
            } else if let branch {
                try Git.addWorktree(at: path, branch: branch.name, newBranch: branch.localName, track: true, in: repository)
            } else {
                try Git.addWorktree(at: path, branch: nil, newBranch: newBranch, track: false, in: repository)
            }
        }
        if succeeded { openInNewWindow?(URL(filePath: path, directoryHint: .isDirectory)) }
    }

    func openWorktree(_ worktree: GitWorktree) {
        openInNewWindow?(worktree.url)
    }

    /// Removes a worktree and its folder (the branch stays). Changes not committed there are
    /// asked about before they're thrown away.
    func removeWorktree(_ worktree: GitWorktree) async {
        guard !isCurrent(worktree), !worktree.isBare,
              confirm("Remove the worktree “\(worktree.name)”? Its folder is deleted; "
                      + (worktree.branch.map { "the branch \($0) stays." } ?? "its detached commit stays in the history."))
        else { return }
        guard let repository = gitRepository else { return }
        isRunningGitCommand = true
        do {
            try await Task.detached { try Git.removeWorktree(at: worktree.path, force: false, in: repository) }.value
            isRunningGitCommand = false
            refreshGit()
            await loadWorktrees()
        } catch {
            isRunningGitCommand = false
            // Uncommitted changes (or a lock) stop git: ask before forcing.
            if confirm("“\(worktree.name)” has changes that aren't committed (or is locked). Remove it anyway? "
                       + "Those changes are lost.") {
                await performGit { try Git.removeWorktree(at: worktree.path, force: true, in: $0) }
            }
        }
    }

    private func promptForWorktree(_ branch: GitBranch?, suggestedPath: String) -> (path: String, newBranch: String?)? {
        let alert = NSAlert()
        alert.messageText = branch.map { "Open \($0.name) in a New Worktree" } ?? "New Worktree"
        alert.informativeText = (branch == nil ? "A new branch from the current commit, " : "The branch ")
            + "checked out in its own folder and opened in a new window."
        let name = NSTextField(string: "")
        name.placeholderString = "new-branch"
        let path = NSTextField(string: suggestedPath)
        path.placeholderString = "Folder"
        let fields = branch == nil ? [name, path] : [path]
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(fields.count) * 24 + CGFloat(fields.count - 1) * 8)
        for field in fields { field.widthAnchor.constraint(equalToConstant: 360).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = fields[0]
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard branch == nil else { return (path.stringValue, nil) }
        // Left as suggested: name the folder after the new branch.
        var folder = path.stringValue
        let branchName = name.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        if folder == suggestedPath, !branchName.isEmpty, folder.hasSuffix("-worktree") {
            folder = String(folder.dropLast("worktree".count)) + branchName
        }
        return (folder, name.stringValue)
    }

    // MARK: Comparing refs

    /// Compares two branches, tags or commits and shows the result in the Timeline.
    /// `sinceCommonAncestor`: what `target` changed since it diverged from `base` (as a pull
    /// request shows); otherwise every difference between the two.
    func compare(_ base: String, with target: String, sinceCommonAncestor: Bool) async {
        sidebarMode = .history
        historyScope = .compare
        guard let repository = gitRepository else { return }
        isComparing = true
        defer { isComparing = false }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<RefComparison, Git.CommandError> in
            guard let baseSHA = Git.resolveCommit(base, in: repository) else {
                return .failure(Git.CommandError(message: "“\(base)” isn't a branch, tag or commit."))
            }
            guard let targetSHA = Git.resolveCommit(target, in: repository) else {
                return .failure(Git.CommandError(message: "“\(target)” isn't a branch, tag or commit."))
            }
            var from = baseSHA
            if sinceCommonAncestor {
                guard let common = Git.mergeBase(baseSHA, targetSHA, in: repository) else {
                    return .failure(Git.CommandError(message: "\(base) and \(target) have no commit in common."))
                }
                from = common
            }
            let files = Git.changedFiles(from: from, to: targetSHA, in: repository) ?? []
            let counts = Git.aheadBehind(base: baseSHA, target: targetSHA, in: repository) ?? (0, 0)
            return .success(RefComparison(base: base, target: target, sinceCommonAncestor: sinceCommonAncestor,
                                          baseSHA: from, targetSHA: targetSHA, files: files,
                                          ahead: counts.ahead, behind: counts.behind))
        }.value
        switch result {
        case .success(let comparison): self.comparison = comparison
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    func clearComparison() { comparison = nil }

    /// One file's difference in the comparison, as a diff tab.
    @discardableResult
    func openComparison(_ file: CommitFile) -> DiffSession? {
        guard let comparison else { return nil }
        return openCommit(comparison.asCommit, file: file)
    }

    // MARK: Blame commits

    /// A commit's details, read once.
    func commitDetails(_ sha: String) async -> CommitDetails? {
        if let cached = commitDetailsCache[sha] { return cached }
        guard let repository = gitRepository else { return nil }
        let details = await Task.detached(priority: .userInitiated) { Git.commitDetails(sha, in: repository) }.value
        if let details { commitDetailsCache[sha] = details }
        return details
    }

    /// What a blamed line's commit changed in the file (under its name then), as a diff tab.
    @discardableResult
    func openBlameChanges(_ line: BlameLine) async -> DiffSession? {
        guard !line.isUncommitted, let repository = gitRepository else { return nil }
        let found = await Task.detached(priority: .userInitiated) { () -> (RepoCommit, CommitFile)? in
            guard let commit = Git.commit(named: line.commit, in: repository),
                  let files = Git.changedFiles(in: commit, repository: repository),
                  let file = files.first(where: { $0.path == line.path }) else { return nil }
            return (commit, file)
        }.value
        guard let (commit, file) = found else { NSSound.beep(); return nil }
        return openCommit(commit, file: file)
    }

    /// The repository log, searched for the commit (listed first).
    func showInTimeline(commit sha: String) {
        sidebarMode = .history
        historyScope = .repository
        repoHistoryFilter = LogFilter(kind: .message, text: sha)
    }

    /// Asks for a name, then creates a branch at the commit and switches to it.
    func createBranch(at commit: RepoCommit) {
        guard let name = (branchNamePrompt.map { $0(commit) } ?? promptForBranchName(commit))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        runGit { try Git.createBranch(name, at: commit.sha, in: $0) }
    }

    /// Checks the commit out without a branch, after confirming.
    func checkoutDetached(_ commit: RepoCommit) {
        let confirmed = checkoutConfirmation.map { $0(commit) } ?? {
            let alert = NSAlert()
            alert.messageText = "Check out \(commit.shortSHA)?"
            alert.informativeText = "“\(commit.summary)”\n\nYou'll be on a detached HEAD: new commits won't belong to a branch "
                + "until you create one. Uncommitted changes that conflict with this commit stop the checkout."
            alert.addButton(withTitle: "Check Out")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }()
        guard confirmed else { return }
        runGit { try Git.checkoutDetached(commit.sha, in: $0) }
    }

    private func promptForBranchName(_ commit: RepoCommit) -> String? {
        let alert = NSAlert()
        alert.messageText = "Create Branch"
        alert.informativeText = "New branch at \(commit.shortSHA) “\(commit.summary)”. You'll be switched to it."
        let field = NSTextField(string: "")
        field.placeholderString = "branch-name"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: Branches

    func loadBranches() async {
        guard let repository = gitRepository else { branches = nil; return }
        branches = await Task.detached(priority: .userInitiated) { Git.branches(in: repository) }.value
    }

    /// Switches branches; a remote branch gets a local one tracking it (or switches to the
    /// local one of that name). Unsaved edits are asked about first: git changes files on disk.
    func switchBranch(_ branch: GitBranch) {
        guard !branch.isCurrent, confirmUnsavedBeforeCheckout() else { return }
        let hasLocal = branches?.contains { !$0.isRemote && $0.name == branch.localName } ?? false
        if branch.isRemote && !hasLocal {
            runGit { try Git.switchToRemote(branch.name, as: branch.localName, in: $0) }
        } else {
            runGit { try Git.switchBranch(branch.localName, in: $0) }
        }
    }

    /// Git: Create Branch — from the current commit, then switches to it.
    func createBranchFromCurrent() {
        guard let name = ask("New Branch", message: "Create a branch from \(gitStatus?.branch ?? "HEAD") and switch to it.",
                             placeholder: "branch-name") else { return }
        runGit { try Git.createBranch(name, at: "HEAD", in: $0) }
    }

    func renameBranch(_ branch: GitBranch) {
        guard !branch.isRemote,
              let name = ask("Rename Branch", message: "New name for \(branch.name):", placeholder: branch.name, initial: branch.name),
              name != branch.name else { return }
        runGit { try Git.renameBranch(branch.name, to: name, in: $0) }
    }

    /// Deletes a local branch; one with unmerged commits only after a second confirmation.
    func deleteBranch(_ branch: GitBranch) {
        guard !branch.isRemote, !branch.isCurrent, let repository = gitRepository else { return }
        isRunningGitCommand = true
        Task {
            do {
                try await Task.detached { try Git.deleteBranch(branch.name, force: false, in: repository) }.value
            } catch {
                // Not merged anywhere: deleting would lose its commits (they stay in the reflog for a while).
                if confirm("Delete \(branch.name)? It has commits that aren't merged into any other branch; they'll be lost.") {
                    do {
                        try await Task.detached { try Git.deleteBranch(branch.name, force: true, in: repository) }.value
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            isRunningGitCommand = false
            refreshGit()
            await loadBranches()
        }
    }

    /// Merges `branch` into the current one. Conflicts leave a merge in progress (see `gitStatus.operation`).
    func mergeIntoCurrent(_ branch: GitBranch) {
        guard !branch.isCurrent, confirmUnsavedBeforeCheckout() else { return }
        runGit { try Git.merge(branch.name, in: $0) }
    }

    /// Replays the current branch's commits on top of `branch`.
    func rebaseCurrent(onto branch: GitBranch) {
        guard !branch.isCurrent, confirmUnsavedBeforeCheckout() else { return }
        runGit { try Git.rebase(onto: branch.name, in: $0) }
    }

    /// Continue, skip or abort the merge or rebase in progress.
    func resolveOperation(_ action: GitOperation.Action) {
        guard let operation = gitStatus?.operation else { return }
        if action == .abort, !confirm("Abort the \(operation.rawValue)? Changes it made so far are undone.") { return }
        runGit { try Git.resolve(operation, action, in: $0) }
    }

    func fetch() { runGit { try Git.fetch(in: $0) } }

    // MARK: Remotes

    func loadRemotes() async {
        guard let repository = gitRepository else { remotes = nil; return }
        remotes = await Task.detached(priority: .userInitiated) { Git.remoteList(in: repository) }.value ?? []
    }

    func fetch(from remote: GitRemote) { runGit { try Git.fetch(remote: remote.name, in: $0) } }

    /// Asks for a name and URL, then adds the remote and fetches it.
    func addRemote() {
        let suggested = remotes?.isEmpty != false ? "origin" : ""
        guard let answer = remotePrompt.map({ $0(nil) }) ?? promptForRemote(nil, suggestedName: suggested) else { return }
        let name = answer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = answer.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { return }
        runGit { repository in
            try Git.addRemote(name, url: url, in: repository)
            try Git.fetch(remote: name, in: repository)
        }
    }

    /// Asks for a new URL for the remote.
    func editRemoteURL(_ remote: GitRemote) {
        guard let answer = remotePrompt.map({ $0(remote) }) ?? promptForRemote(remote, suggestedName: remote.name) else { return }
        let url = answer.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, url != remote.fetchURL else { return }
        runGit { try Git.setRemoteURL(remote.name, url: url, in: $0) }
    }

    func renameRemote(_ remote: GitRemote) {
        guard let name = ask("Rename Remote", message: "New name for “\(remote.name)”. Its remote branches and the "
                             + "upstreams set to it follow.", placeholder: remote.name, initial: remote.name),
              name != remote.name else { return }
        runGit { try Git.renameRemote(remote.name, to: name, in: $0) }
    }

    func removeRemote(_ remote: GitRemote) {
        guard confirm("Remove the remote “\(remote.name)”? Its remote branches go from this repository and branches "
                      + "tracking it lose their upstream. Nothing changes on the server.") else { return }
        runGit { try Git.removeRemote(remote.name, in: $0) }
    }

    /// The remote dialog: a name (only for a new remote) and a URL.
    private func promptForRemote(_ remote: GitRemote?, suggestedName: String) -> (name: String, url: String)? {
        let alert = NSAlert()
        alert.messageText = remote.map { "Edit “\($0.name)” URL" } ?? "Add Remote"
        alert.informativeText = remote == nil
            ? "It's fetched right away. SSH (git@host:owner/repo.git) or HTTPS URLs work."
            : "Where the remote fetches from and pushes to."
        let name = NSTextField(string: suggestedName)
        name.placeholderString = "origin"
        let url = NSTextField(string: remote?.fetchURL ?? "")
        url.placeholderString = "git@github.com:owner/repo.git"
        let fields = remote == nil ? [name, url] : [url]
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(fields.count) * 24 + CGFloat(fields.count - 1) * 8)
        for field in fields { field.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: remote == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = remote == nil && suggestedName.isEmpty ? name : url
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (remote?.name ?? name.stringValue, url.stringValue)
    }

    func pull() {
        guard confirmUnsavedBeforeCheckout() else { return }
        runGit { try Git.pull(in: $0) }
    }

    /// Pushes the current branch; the first push of a branch sets its upstream (on "origin",
    /// or the only remote).
    func push() {
        guard let branch = gitStatus?.branch else { errorMessage = "Not on a branch (detached HEAD): nothing to push."; return }
        let hasUpstream = gitStatus?.upstream != nil
        runGit { repository in
            var remote: String?
            if !hasUpstream {
                let remotes = Git.remotes(in: repository)
                guard let chosen = remotes.contains("origin") ? "origin" : remotes.first else {
                    throw Git.CommandError(message: "This repository has no remote to push to.")
                }
                remote = chosen
            }
            try Git.push(branch: branch, settingUpstreamTo: remote, in: repository)
        }
    }

    /// Checking out rewrites files on disk; edits not saved yet would then be out of date.
    private func confirmUnsavedBeforeCheckout() -> Bool {
        let unsaved = documents.filter(\.isDirty)
        guard !unsaved.isEmpty else { return true }
        let names = unsaved.prefix(3).map(\.fileName).joined(separator: ", ") + (unsaved.count > 3 ? ", …" : "")
        return confirm("\(unsaved.count) file\(unsaved.count == 1 ? " has" : "s have") unsaved changes (\(names)). "
                       + "Files git changes on disk won't match them. Continue anyway?")
    }

    private func confirm(_ question: String) -> Bool {
        if let confirmation { return confirmation(question) }
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// A name typed in a dialog (trimmed; nil if cancelled or empty).
    private func ask(_ title: String, message: String, placeholder: String, initial: String = "") -> String? {
        let answer: String?
        if let textPrompt {
            answer = textPrompt(title)
        } else {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            let field = NSTextField(string: initial)
            field.placeholderString = placeholder
            field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            answer = alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
        let trimmed = answer?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    // MARK: Tags

    /// Tests answer this instead of the tag dialog: a name and an optional message (nil cancels).
    @ObservationIgnored var tagPrompt: ((RepoCommit?) -> (name: String, message: String)?)?

    /// Creates a tag at `commit` (nil: HEAD), asking for its name and an optional message.
    func createTag(at commit: RepoCommit?) {
        guard let answer = tagPrompt.map({ $0(commit) }) ?? promptForTag(commit) else { return }
        let name = answer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = answer.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        runGit { try Git.createTag(name, message: message, at: commit?.sha ?? "HEAD", in: $0) }
    }

    func deleteTag(_ name: String) {
        guard confirm("Delete the tag “\(name)”? (Only here: a pushed tag stays on the remote.)") else { return }
        runGit { try Git.deleteTag(name, in: $0) }
    }

    /// Pushes a tag (nil: all tags) to "origin" or the only remote.
    func pushTag(_ name: String?) {
        runGit { repository in
            guard let remote = Git.defaultRemote(in: repository) else {
                throw Git.CommandError(message: "This repository has no remote to push to.")
            }
            try Git.pushTag(name, to: remote, in: repository)
        }
    }

    func deleteRemoteTag(_ name: String) {
        guard confirm("Delete the tag “\(name)” from the remote? Others who fetched it keep their copy.") else { return }
        runGit { repository in
            guard let remote = Git.defaultRemote(in: repository) else {
                throw Git.CommandError(message: "This repository has no remote.")
            }
            try Git.deleteRemoteTag(name, from: remote, in: repository)
        }
    }

    private func promptForTag(_ commit: RepoCommit?) -> (name: String, message: String)? {
        let alert = NSAlert()
        alert.messageText = "Create Tag"
        alert.informativeText = (commit.map { "At \($0.shortSHA) “\($0.summary)”." } ?? "At the current commit.")
            + " With a message it's an annotated tag."
        let name = NSTextField(string: "")
        name.placeholderString = "v1.0.0"
        let message = NSTextField(string: "")
        message.placeholderString = "Message (optional)"
        let stack = NSStackView(views: [name, message])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        for field in [name, message] { field.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (name.stringValue, message.stringValue)
    }

    // MARK: Cherry-pick and revert

    /// Copies a commit onto the current branch. Conflicts leave a cherry-pick in progress.
    func cherryPick(_ commit: RepoCommit) {
        guard gitStatus?.operation == nil else { errorMessage = "Finish the merge or rebase in progress first."; return }
        guard confirmUnsavedBeforeCheckout() else { return }
        runGit { try Git.cherryPick(commit, in: $0) }
    }

    /// Adds a commit undoing `commit`, after asking.
    func revertCommit(_ commit: RepoCommit) {
        guard gitStatus?.operation == nil else { errorMessage = "Finish the merge or rebase in progress first."; return }
        let merge = commit.parents.count > 1 ? " It's a merge: its changes relative to the first parent are undone." : ""
        guard confirm("Revert “\(commit.summary)”? A new commit undoing its changes is added to \(gitStatus?.branch ?? "HEAD").\(merge)"),
              confirmUnsavedBeforeCheckout() else { return }
        runGit { try Git.revert(commit, in: $0) }
    }

    // MARK: Interactive rebase

    /// Sets up an interactive rebase of `commit` and everything after it on the current branch.
    func planInteractiveRebase(from commit: RepoCommit) async {
        guard let repository = gitRepository else { return }
        guard gitStatus?.operation == nil else { errorMessage = "Finish the merge or rebase in progress first."; return }
        let steps = await Task.detached { Git.rebaseCommits(from: commit, in: repository) }.value
        guard let steps, !steps.isEmpty else {
            errorMessage = "\(commit.shortSHA) isn't on the current branch, so it can't be rebased from here."
            return
        }
        pendingRebase = RebasePlan(base: commit, steps: steps)
    }

    /// Runs the rebase as planned. Rewriting pushed commits is asked about first.
    func startRebase(_ plan: RebasePlan) {
        guard RebaseStep.problem(with: plan.steps) == nil, let repository = gitRepository,
              let oldest = plan.original.first else { return }
        guard !Git.isPushed(oldest.commit.sha, in: repository) || confirm(
            "Some of these commits are already pushed. Rebasing rewrites them, so the branch will need a force push. Rebase anyway?")
        else { return }
        guard confirmUnsavedBeforeCheckout() else { return }
        pendingRebase = nil
        let steps = plan.steps, base = plan.base.parents.first
        runGit { try Git.interactiveRebase(steps, onto: base, in: $0) }
    }

    // MARK: Stash

    /// Stashes the changes, asking for an optional message. Edits not saved yet aren't
    /// stashed (git takes the files on disk), so they're asked about first.
    func stash(_ scope: GitStash.Scope) {
        guard confirmUnsavedBeforeCheckout(), let message = askStashMessage(scope) else { return }
        runGit { try Git.stash(scope, message: message, in: $0) }
    }

    /// Apply (keep the stash) or pop (drop it once applied).
    func applyStash(_ stash: GitStash, pop: Bool) {
        guard confirmUnsavedBeforeCheckout() else { return }
        runGit { try Git.applyStash(stash, pop: pop, in: $0) }
    }

    func dropStash(_ stash: GitStash) {
        guard confirm("Delete the stash “\(stash.message)”? Its changes will be lost.") else { return }
        runGit { try Git.dropStash(stash, in: $0) }
    }

    /// A new branch where the stash was made, with the stash applied there.
    func branchFromStash(_ stash: GitStash) {
        guard confirmUnsavedBeforeCheckout(),
              let name = ask("Create Branch from Stash",
                             message: "A new branch at the commit “\(stash.message)” was made on, with the stash applied and dropped.",
                             placeholder: "branch-name") else { return }
        runGit { try Git.branch(name, fromStash: stash, in: $0) }
    }

    func loadFiles(of stash: GitStash) async {
        guard stashFiles[stash.sha] == nil, let repository = gitRepository else { return }
        let files = await Task.detached(priority: .utility) { Git.files(in: stash, repository: repository) }.value
        stashFiles[stash.sha] = files ?? []
    }

    /// One stashed file's changes, as a diff tab.
    @discardableResult
    func openStashFile(_ stash: GitStash, _ file: StashFile) -> DiffSession? {
        guard let top = repositoryRootURL else { return nil }
        return openCommit(stash.change(to: file), for: top.appending(path: file.file.path))
    }

    /// nil if cancelled; "" for no message.
    private func askStashMessage(_ scope: GitStash.Scope) -> String? {
        if let textPrompt { return textPrompt("Stash").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        let alert = NSAlert()
        alert.messageText = switch scope {
        case .all: "Stash Changes"
        case .includingUntracked: "Stash Changes (Including Untracked)"
        case .staged: "Stash Staged Changes"
        }
        alert.informativeText = "A message to find it by later (optional):"
        let field = NSTextField(string: "")
        field.placeholderString = "Message"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Stash")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Terminal

    func toggleTerminal() {
        if isTerminalVisible, bottomPanel == .terminal {
            hidePanel()
        } else {
            showTerminal()
        }
    }

    /// Hides the bottom panel (whatever it shows).
    func hidePanel() {
        isTerminalVisible = false
        activeDocument?.editor?.focus()
    }

    /// The terminal shown in the panel.
    var terminal: TerminalSession? {
        terminals.first { $0.id == activeTerminalID }
    }

    func showsMarkdownPreview(_ document: EditorDocument) -> Bool {
        document.language == .markdown && markdownPreviews.contains(document.id)
    }

    /// ⇧⌘V: the rendered Markdown beside the editor (or not).
    func toggleMarkdownPreview(_ document: EditorDocument? = nil) {
        guard let document = document ?? activeDocument, document.language == .markdown else { NSSound.beep(); return }
        if markdownPreviews.contains(document.id) { markdownPreviews.remove(document.id) } else { markdownPreviews.insert(document.id) }
    }

    /// ⇧⌘M: the Problems panel (or hides it when it's showing).
    func toggleProblems() {
        if isTerminalVisible, bottomPanel == .problems {
            hidePanel()
        } else {
            showProblems()
        }
    }

    func showProblems() {
        bottomPanel = .problems
        isTerminalVisible = true
    }

    /// Opens a problem's file and selects its range.
    func open(problem diagnostic: Diagnostic, in url: URL) {
        open(fileAt: url)
        guard let document = activeDocument else { return }
        let start = document.offset(for: diagnostic.range.start)
        let end = max(start, document.offset(for: diagnostic.range.end))
        document.reveal(NSRange(location: start, length: end - start))
        document.editor?.focus()
    }

    /// Shows the debug console in the bottom panel.
    func showDebugConsole() {
        bottomPanel = .debugConsole
        isTerminalVisible = true
    }

    func showTerminal() {
        bottomPanel = .terminal
        if terminals.isEmpty {
            newTerminal()
            return
        }
        isTerminalVisible = true
        terminalFocusRequest += 1
    }

    func newTerminal() {
        guard let session = makeTerminal() else { return }
        terminals.append(session)
        selectTerminal(session)
    }

    func selectTerminal(_ session: TerminalSession) {
        activeTerminalID = session.id
        bottomPanel = .terminal
        isTerminalVisible = true
        terminalFocusRequest += 1
    }

    func closeTerminal(_ session: TerminalSession) {
        guard let index = terminals.firstIndex(where: { $0.id == session.id }) else { return }
        session.terminate()
        terminals.remove(at: index)
        if terminals.isEmpty {
            activeTerminalID = nil
            isTerminalVisible = false
            activeDocument?.editor?.focus()
        } else if activeTerminalID == session.id {
            selectTerminal(terminals[min(index, terminals.count - 1)])
        }
    }

    /// Replaces the active terminal with a fresh shell in the same tab position.
    func restartTerminal() {
        guard let current = terminal, let index = terminals.firstIndex(where: { $0.id == current.id }) else {
            return newTerminal()
        }
        guard let session = makeTerminal() else { return }
        current.terminate()
        terminals[index] = session
        selectTerminal(session)
    }

    private func makeTerminal() -> TerminalSession? {
        do {
            return try TerminalSession(directory: rootURL ?? FileManager.default.homeDirectoryForCurrentUser)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Extensions

    /// Tests answer this instead of the install dialog: the manifest and whether it replaces an
    /// installed version.
    @ObservationIgnored var extensionInstallConfirmation: ((ExtensionManifest, Bool) -> Bool)?

    /// Installs an extension folder after showing what it may do (and confirming a replacement).
    func installExtension(from folder: URL, development: Bool) {
        let store = extensions.store
        do {
            let manifest = try ExtensionManifest.load(from: folder)
            let existing = store.installed().first { $0.id == manifest.id }
            let confirmed = extensionInstallConfirmation.map { $0(manifest, existing != nil) } ?? {
                let alert = NSAlert()
                alert.messageText = existing == nil ? "Install \(manifest.name) \(manifest.version)?"
                    : "Replace \(manifest.name) \(existing!.manifest.version) with \(manifest.version)?"
                let permissions = ExtensionManifest.Permission.allCases.filter(manifest.grantedPermissions.contains)
                alert.informativeText = (manifest.description.map { $0 + "\n\n" } ?? "")
                    + (permissions.isEmpty ? "It works only with the editor and the open folder."
                       : "It asks to:\n" + permissions.map { "• " + $0.title }.joined(separator: "\n")
                         + "\n\nOnly install extensions you trust.")
                alert.addButton(withTitle: existing == nil ? "Install" : "Replace")
                alert.addButton(withTitle: "Cancel")
                return alert.runModal() == .alertFirstButtonReturn
            }()
            guard confirmed else { return }
            try store.install(from: folder, development: development, replacing: existing != nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Tests answer this instead of the folder dialog: where the new extension's folder goes.
    @ObservationIgnored var extensionFolderChooser: (() -> URL?)?

    /// Asks for a name and a place, writes a Hello World extension there, installs it for
    /// development and opens its folder in a new window.
    @discardableResult
    func createExtension() async -> URL? {
        guard let name = await showInputBox(prompt: "Name of the new extension", value: "", placeholder: "My Extension"),
              !ExtensionScaffold.slug(name).isEmpty else { return nil }
        let parent = extensionFolderChooser.map { $0() } ?? {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.message = "Choose where to create the “\(ExtensionScaffold.slug(name))” folder"
            panel.prompt = "Create Here"
            return panel.runModal() == .OK ? panel.url : nil
        }()
        guard let parent else { return nil }
        do {
            let folder = try ExtensionScaffold.create(named: name, in: parent)
            try extensions.store.install(from: folder, development: true)
            openInNewWindow?(folder)
            return folder
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func uninstallExtension(_ instance: ExtensionInstance) {
        guard confirm("Uninstall \(instance.manifest.name)? Its settings and stored data are removed too.") else { return }
        do { try extensions.uninstall(instance) } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Notifications, quick pick and input

    /// Shows a message in the corner; resolves with the item clicked, or nil when dismissed.
    /// Without items it goes away by itself after `notificationDuration`.
    func notify(_ kind: AppNotification.Kind, _ message: String, source: String?, items: [String] = []) async -> String? {
        await withCheckedContinuation { continuation in
            let notification = AppNotification(kind: kind, message: message, source: source, items: items)
            notifications.append(notification)
            notificationReplies[notification.id] = { continuation.resume(returning: $0) }
            if notifications.count > 4 { dismissNotification(notifications[0].id) }
            if items.isEmpty {
                Task {
                    try? await Task.sleep(for: notificationDuration)
                    dismissNotification(notification.id)
                }
            }
        }
    }

    @ObservationIgnored var notificationDuration: Duration = .seconds(8)

    func dismissNotification(_ id: UUID, choosing item: String? = nil) {
        notifications.removeAll { $0.id == id }
        notificationReplies.removeValue(forKey: id)?(item)
    }

    /// Lets the user pick one of `items` in the palette; nil when dismissed.
    func showQuickPick(_ items: [QuickPickItem], placeholder: String?) async -> Int? {
        await withCheckedContinuation { continuation in
            presentPrompt(PaletteModel.Prompt(kind: .pick(items), placeholder: placeholder) { reply in
                if case .index(let index) = reply { continuation.resume(returning: index) } else { continuation.resume(returning: nil) }
            }, text: "")
        }
    }

    /// Asks for text in the palette; nil when dismissed.
    func showInputBox(prompt: String?, value: String, placeholder: String?) async -> String? {
        await withCheckedContinuation { continuation in
            presentPrompt(PaletteModel.Prompt(kind: .input(prompt), placeholder: placeholder) { reply in
                if case .text(let text) = reply { continuation.resume(returning: text) } else { continuation.resume(returning: nil) }
            }, text: value)
        }
    }

    private func presentPrompt(_ prompt: PaletteModel.Prompt, text: String) {
        palette?.cancelPrompt()
        palette = PaletteModel(workspace: self, prompt: prompt, text: text)
    }

    // MARK: Palette

    func showPalette(_ mode: PaletteModel.Mode) {
        if let palette, palette.prompt == nil {
            palette.query = mode.prefix
        } else {
            palette?.cancelPrompt()
            palette = PaletteModel(workspace: self, mode: mode)
        }
    }

    func closePalette() {
        guard let palette else { return }
        self.palette = nil
        palette.cancelPrompt()
        activeDocument?.editor?.focus()
    }

    func open(fileAt url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 { recentFiles.removeLast() }

        let canonical = FileWatcher.canonicalPath(url)
        if let existing = documents.first(where: { $0.url == url || $0.canonicalPath == canonical }) {
            activeDocumentID = existing.id
            return
        }
        do {
            let document = try EditorDocument(url: url)
            documents.append(document)
            activeDocumentID = document.id
            loadDiffBase(for: document)
            attachLanguageServer(to: document)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Closes a document's tab in `group` (by default the active group, or wherever it is
    /// shown). The document itself closes, asking to save, once no group shows it.
    func close(_ document: EditorDocument, in group: EditorGroup? = nil) {
        guard let group = group ?? (activeGroup.contains(document.id) ? activeGroup
                                    : groups.first { $0.contains(document.id) }) else { return }
        let shownElsewhere = groups.contains { $0 !== group && $0.contains(document.id) }
        let inDiff = diffSessions.contains { $0.document === document }
        if !shownElsewhere && !inDiff {
            guard confirmClose(document) else { return }
            documents.removeAll { $0.id == document.id }
            document.languageClient?.didClose(url: document.url)
        }
        group.remove(document.id)
        if group.documentIDs.isEmpty { closeGroup(group) }
        retargetEditor()
    }

    func closeAll() {
        for group in groups.reversed() {
            for id in group.documentIDs.reversed() {
                closeTab(id, in: group)
                if group.contains(id) { return } // cancelled
            }
        }
    }

    /// Closes a tab of any kind.
    func closeTab(_ id: UUID, in group: EditorGroup) {
        if let document = document(id: id) {
            close(document, in: group)
        } else if let session = diffSession(id: id) {
            closeDiff(session, in: group)
        }
    }

    // MARK: Diff tabs

    func diffSession(id: UUID?) -> DiffSession? {
        guard let id else { return nil }
        return diffSessions.first { $0.id == id }
    }

    /// Title, tooltip and dirty state for a tab of any kind.
    func tabInfo(_ id: UUID) -> (title: String, help: String, isDirty: Bool, isDiff: Bool)? {
        if let document = document(id: id) { return (document.fileName, document.url.path, document.isDirty, false) }
        if let session = diffSession(id: id) { return (session.title, session.help, false, true) }
        return nil
    }

    /// Git: Open Changes — a side-by-side diff tab: the editor's text against the staged
    /// version, or (`staged`) the staged version against the last commit.
    @discardableResult
    func openChanges(for url: URL, staged: Bool = false) -> DiffSession? {
        let canonical = FileWatcher.canonicalPath(url)
        let mode: DiffSession.Mode = staged ? .staged : .workingTree
        if let existing = diffSessions.first(where: { $0.mode == mode && FileWatcher.canonicalPath($0.url) == canonical }) {
            activeGroup.show(existing.id)
            return existing
        }
        if staged {
            let session = DiffSession(stagedChangesOf: url)
            diffSessions.append(session)
            loadStaged(session)
            activeGroup.show(session.id)
            return session
        }
        let wasOpen = document(matching: url) != nil
        guard let document = document(matching: url) ?? openWithoutTab(url) else { return nil }
        let session = DiffSession(document: document, ownsDocument: !wasOpen)
        diffSessions.append(session)
        activeGroup.show(session.id)
        return session
    }

    private func closeDiff(_ session: DiffSession, in group: EditorGroup) {
        group.remove(session.id)
        if !groups.contains(where: { $0.contains(session.id) }) {
            diffSessions.removeAll { $0.id == session.id }
            // A document opened just for the diff goes too, unless it got a tab meanwhile.
            if let document = session.document, session.ownsDocument, !groups.contains(where: { $0.contains(document.id) }),
               !diffSessions.contains(where: { $0.document === document }), !document.isDirty {
                documents.removeAll { $0.id == document.id }
                document.languageClient?.didClose(url: document.url)
            }
        }
        if group.documentIDs.isEmpty { closeGroup(group) }
        retargetEditor()
    }

    /// Opens a document without giving it a tab (for a diff tab).
    func openWithoutTab(_ url: URL) -> EditorDocument? {
        do {
            let document = try EditorDocument(url: url)
            documents.append(document)
            loadDiffBase(for: document)
            return document
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func selectAdjacentDocument(offset: Int) {
        let ids = activeGroup.documentIDs
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == activeDocumentID } ?? 0
        activeDocumentID = ids[(current + offset + ids.count) % ids.count]
    }

    func document(id: EditorDocument.ID?) -> EditorDocument? {
        guard let id else { return nil }
        return documents.first { $0.id == id }
    }

    func documents(in group: EditorGroup) -> [EditorDocument] {
        group.documentIDs.compactMap { document(id: $0) }
    }

    // MARK: Editor groups (split editor)

    /// ⌘\: opens the active document in a new group to the right.
    func splitEditor() {
        guard let document = activeDocument, groups.count < Self.maxGroups,
              let index = groups.firstIndex(where: { $0.id == activeGroupID }) else { NSSound.beep(); return }
        document.editor(inGroup: activeGroup)?.saveViewState()
        let group = EditorGroup()
        if let state = activeGroup.viewStates[document.id] { group.viewStates[document.id] = state }
        group.show(document.id)
        groups.insert(group, at: index + 1)
        activeGroupID = group.id
    }

    /// Moves the active tab to the next group (`offset` 1) or previous (-1), creating a group
    /// at the edge if there is none.
    func moveActiveEditor(by offset: Int) {
        guard let document = activeDocument, let index = groups.firstIndex(where: { $0.id == activeGroupID }) else { return }
        let source = activeGroup
        let targetIndex = index + offset
        let target: EditorGroup
        if groups.indices.contains(targetIndex) {
            target = groups[targetIndex]
        } else {
            guard source.documentIDs.count > 1, groups.count < Self.maxGroups else { NSSound.beep(); return }
            target = EditorGroup()
            groups.insert(target, at: offset > 0 ? index + 1 : index)
        }
        document.editor(inGroup: source)?.saveViewState()
        if let state = source.viewStates[document.id] { target.viewStates[document.id] = state }
        target.show(document.id)
        source.remove(document.id)
        if source.documentIDs.isEmpty { closeGroup(source) }
        activeGroupID = target.id
        retargetEditor()
    }

    /// Drag and drop of a tab: reorders within a group, or moves it to another group at `index`
    /// (tab position, before the tab there). The moved tab becomes active, and a group left
    /// without tabs closes.
    func moveTab(_ documentID: EditorDocument.ID, from source: EditorGroup, to target: EditorGroup, at index: Int) {
        guard source.contains(documentID), groups.contains(where: { $0 === target }) else { return }
        if source !== target {
            if let document = document(id: documentID) { document.editor(inGroup: source)?.saveViewState() }
            if let state = source.viewStates[documentID] { target.viewStates[documentID] = state }
        }
        target.insert(documentID, at: index)
        if source !== target {
            source.remove(documentID)
            if source.documentIDs.isEmpty { closeGroup(source) }
        }
        activeGroupID = target.id
        activeDocumentID = documentID
    }

    func group(id: EditorGroup.ID) -> EditorGroup? {
        groups.first { $0.id == id }
    }

    /// ⌘1…⌘4: focuses a group's editor.
    func focusGroup(at index: Int) {
        guard groups.indices.contains(index) else { return }
        activeGroupID = groups[index].id
        activeDocument?.editor(inGroup: groups[index])?.focus()
    }

    private func closeGroup(_ group: EditorGroup) {
        guard groups.count > 1, let index = groups.firstIndex(where: { $0 === group }) else { return }
        groups.remove(at: index)
        if activeGroupID == group.id { activeGroupID = groups[max(0, index - 1)].id }
    }

    /// Cursor-based actions (go to definition, reveal) act on the active group's editor of the
    /// active document. If that group has no editor for it yet, reveals wait for the one SwiftUI
    /// is about to create. (Editors outside any group, as in tests, are left alone.)
    private func retargetEditor() {
        guard let document = activeDocument else { return }
        if let editor = document.editor(inGroup: activeGroup) {
            document.editor = editor
        } else if document.editor?.group != nil {
            document.editor = nil
        }
    }

    /// Saves every unsaved document (formatting each first, if format on save is on).
    @discardableResult
    func saveAll() -> Task<Void, Never> {
        let dirty = documents.filter(\.isDirty)
        return Task {
            for document in dirty {
                guard await formatAndSave(document).value else { return }
            }
        }
    }

    @discardableResult
    func saveActive() -> Task<Bool, Never>? {
        guard let document = activeDocument else { return nil }
        return formatAndSave(document)
    }

    @discardableResult
    func save(_ document: EditorDocument) -> Bool {
        do {
            try document.save()
            // Saved here: its files pick it up now, not when the file watcher reports it.
            if document.url.lastPathComponent == ".editorconfig" { documents.forEach { $0.reloadEditorConfig() } }
            stageIfConflictResolved(document)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// After a save: a file git still reports as conflicted, now without conflict markers, is
    /// resolved, so it's staged (marking it resolved for git, like `git add` after a merge).
    private func stageIfConflictResolved(_ document: EditorDocument) {
        guard AppSettings.shared.stagesResolvedConflicts, let path = relativePath(of: document.url),
              gitStatus?.changes.contains(where: { $0.path == path && $0.isConflicted }) == true,
              // Read the saved text now: the debounced scan may not have run since the last edit.
              ConflictParser.conflicts(in: document.textStorage.mutableString).isEmpty else { return }
        stage([path])
    }

    /// Asks to save unsaved changes. Returns `false` if the user cancelled.
    private func confirmClose(_ document: EditorDocument) -> Bool {
        guard document.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(document.fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(document)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}
