import AppKit
import Observation

/// State for one editor window: the opened folder and its open documents (tabs).
@MainActor
@Observable
final class Workspace {
    private(set) var rootURL: URL?
    private(set) var rootNode: FileNode?
    /// Every open document, in any editor group.
    private(set) var documents: [EditorDocument] = []
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
    enum HistoryScope: String, CaseIterable { case file = "File", repository = "Repository" }
    var historyScope: HistoryScope = .file
    /// The repository log (pages of `repoHistoryPageSize`).
    private(set) var repoHistory: RepoHistory?
    @ObservationIgnored private var repoHistoryTask: Task<Void, Never>?
    @ObservationIgnored var repoHistoryPageSize = 200
    /// Files each commit changed, read when the commit is expanded.
    private(set) var commitFiles: [String: [CommitFile]] = [:]
    /// Tests answer these instead of a dialog: the new branch's name (nil cancels), and
    /// whether to check out a commit.
    @ObservationIgnored var branchNamePrompt: ((RepoCommit) -> String?)?
    @ObservationIgnored var checkoutConfirmation: ((RepoCommit) -> Bool)?
    /// Replaces server discovery per language (tests point a workspace at a fake server).
    @ObservationIgnored var languageServerOverrides: [SourceLanguage: LanguageServerConfig] = [:]
    /// One client per language server, shared by all documents it handles.
    private(set) var languageClients: [String: LanguageClient] = [:]
    private(set) var terminals: [TerminalSession] = []
    var activeTerminalID: TerminalSession.ID?
    private(set) var isTerminalVisible = false
    /// Bumped to move keyboard focus into the terminal.
    private(set) var terminalFocusRequest = 0
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileWatcher?
    /// Root as FSEvents reports paths (symlinks resolved).
    @ObservationIgnored private var canonicalRootPath = ""

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
        refreshGit()
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

        for event in events {
            if event.requiresRescan || event.path == canonicalRootPath {
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
            if event.isStructural {
                directoriesToReload.insert(components.dropLast().joined(separator: "/"))
                needsIndexRebuild = true
            }
        }

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
                client.onDiagnostics = { [weak self] url, diagnostics in
                    self?.document(matching: url)?.setDiagnostics(diagnostics)
                }
                languageClients[config.name] = client
            }
            document.languageClient = client
            client.didOpen(url: document.url, languageId: document.languageId,
                           text: document.textStorage.mutableString as String)
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
            let result = await Task.detached(priority: .utility) { () -> (Git.Repository, GitStatus)? in
                guard let repository = knownRepository ?? Git.repository(at: rootURL),
                      let status = Git.status(of: repository) else { return nil }
                return (repository, status)
            }.value
            guard !Task.isCancelled, self.rootURL == rootURL else { return }
            self.gitRepository = result?.0
            if self.gitStatus != result?.1 { self.gitStatus = result?.1 }
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

    private func runGit(_ operation: @escaping @Sendable (Git.Repository) throws -> Void) {
        guard let repository = gitRepository else { return }
        isRunningGitCommand = true
        Task {
            do {
                try await Task.detached { try operation(repository) }.value
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunningGitCommand = false
            refreshGit()
        }
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
        let existing = repoHistory?.commits ?? []
        let pageSize = repoHistoryPageSize
        let skip = more ? existing.count : 0
        let limit = more ? pageSize : max(pageSize, existing.count)
        repoHistory = RepoHistory(commits: existing, isLoading: true, hasMore: repoHistory?.hasMore ?? false)
        repoHistoryTask = Task {
            let page = await Task.detached(priority: .utility) {
                Git.log(in: repository, limit: limit, skip: skip)
            }.value
            guard !Task.isCancelled else { return }
            let commits = more ? existing + (page ?? []) : page ?? []
            repoHistory = RepoHistory(commits: commits, isLoading: false, hasMore: (page?.count ?? 0) == limit)
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
    var repositoryRootURL: URL? {
        guard let repository = gitRepository else { return nil }
        let depth = repository.prefix.split(separator: "/").count
        return (0..<depth).reduce(repository.root) { url, _ in url.deletingLastPathComponent() }
    }

    /// A commit's change to one file, as a diff tab.
    @discardableResult
    func openCommit(_ commit: RepoCommit, file: CommitFile) -> DiffSession? {
        guard let top = repositoryRootURL else { return nil }
        return openCommit(commit.change(to: file), for: top.appending(path: file.path))
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

    // MARK: Terminal

    func toggleTerminal() {
        if isTerminalVisible {
            isTerminalVisible = false
            activeDocument?.editor?.focus()
        } else {
            showTerminal()
        }
    }

    /// The terminal shown in the panel.
    var terminal: TerminalSession? {
        terminals.first { $0.id == activeTerminalID }
    }

    func showTerminal() {
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

    // MARK: Palette

    func showPalette(_ mode: PaletteModel.Mode) {
        if let palette {
            palette.query = mode.prefix
        } else {
            palette = PaletteModel(workspace: self, mode: mode)
        }
    }

    func closePalette() {
        guard palette != nil else { return }
        palette = nil
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
    private func openWithoutTab(_ url: URL) -> EditorDocument? {
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
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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
