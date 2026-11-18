import AppKit
import Observation

/// One connection's live state in a window: its driver once connected, and the schema.
@MainActor
@Observable
final class DatabaseSession: Identifiable {
    enum State: Equatable {
        case disconnected, connecting, connected
        case failed(String)
    }

    let id: UUID
    var config: DatabaseConnectionConfig
    private(set) var state = State.disconnected
    private(set) var catalog: DBCatalog?
    private(set) var catalogError: String?
    private(set) var serverVersion: String?
    private(set) var isLoadingCatalog = false
    @ObservationIgnored private(set) var driver: (any DatabaseDriver)?
    @ObservationIgnored private var connecting: Task<any DatabaseDriver, Error>?
    /// The last thing given to the driver: each waits for the one before (a connection runs one
    /// thing at a time).
    @ObservationIgnored private var tail: Task<Void, Never>?

    init(config: DatabaseConnectionConfig) {
        id = config.id
        self.config = config
    }

    var isConnected: Bool { state == .connected }

    /// The driver, connecting (and signing in with `password`) first when needed.
    func connect(password: String?) async throws -> any DatabaseDriver {
        if let driver { return driver }
        if let connecting {
            // Whichever waiter resumes first keeps it (the one that started may not have yet).
            let driver = try await connecting.value
            if self.driver == nil {
                self.driver = driver
                state = .connected
            }
            return driver
        }
        state = .connecting
        var config = config
        config.password = password
        let task = Task { try await DatabaseDrivers.connect(config) }
        connecting = task
        defer { connecting = nil }
        do {
            let driver = try await task.value
            if self.driver == nil {
                self.driver = driver
                state = .connected
            }
            serverVersion = await driver.serverVersion
            return driver
        } catch {
            state = .failed((error as? DBError)?.message ?? error.localizedDescription)
            throw error
        }
    }

    /// Runs `operation` once everything given to the driver before it is done.
    func serialized<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    func loadCatalog() async {
        guard let driver else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            catalog = try await serialized { try await driver.catalog() }
            catalogError = nil
        } catch {
            catalogError = (error as? DBError)?.message ?? error.localizedDescription
            if (error as? DBError)?.isConnectionError == true { connectionLost() }
        }
    }

    /// The connection dropped (the server went away): connect again next time.
    func connectionLost() {
        driver = nil
        state = .disconnected
    }

    func disconnect() async {
        let driver = self.driver
        self.driver = nil
        catalog = nil
        catalogError = nil
        serverVersion = nil
        state = .disconnected
        await driver?.close()
    }
}

/// A statement that ran (or was about to) in a results tab.
struct DBStatementOutcome: Identifiable, Equatable {
    let id = UUID()
    var sql: String
    /// Where the statement is in its file (UTF-16 offset), for errors.
    var offset: Int
    var execution: DBExecution?
    var duration: TimeInterval = 0
    var isRunning = false

    var error: DBError? { execution?.error }

    /// What it did, in a few words.
    var summary: String {
        guard let execution else { return isRunning ? "Running…" : "Not run" }
        if let error = execution.error, execution.resultSets.isEmpty { return "Error: " + error.message }
        let parts = execution.resultSets.map { set -> String in
            if set.hasRows {
                return set.isTruncated ? "\(set.rows.count) of \(set.totalRows) rows" : "\(set.totalRows) row\(set.totalRows == 1 ? "" : "s")"
            }
            if let affected = set.affectedRows { return "\(affected) row\(affected == 1 ? "" : "s") affected" }
            return set.command ?? "Done"
        }
        return parts.joined(separator: ", ") + (execution.error.map { " — Error: " + $0.message } ?? "")
    }
}

/// A results tab: what a SQL file's last run gave (each run of the same file shows here again,
/// unless it's pinned).
@MainActor
@Observable
final class DatabaseResultsTab: Identifiable {
    enum State: Equatable {
        case running, done, cancelled
        case failed(String)
    }

    let id = UUID()
    /// The file it's for.
    let key: String
    private(set) var title: String
    var isPinned = false
    var state = State.running
    var connectionID: UUID?
    var connectionName = ""
    var dialect = SQLDialect.postgres
    var outcomes: [DBStatementOutcome] = []
    /// The result set shown (`segments` index; `segments.count` is Messages).
    var selectedSegment = 0
    var sourceFile: URL?
    var startedAt = Date()
    var duration: TimeInterval = 0
    var rowLimit = 10_000
    /// Explain Query's explanation, while its popover shows.
    var explanation: AIExplainModel?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var cancelRequested = false

    init(key: String, title: String) {
        self.key = key
        self.title = title
    }

    func rename(_ name: String) { title = "Results: \(name)" }
    var help: String { connectionName.isEmpty ? title : "\(title) — \(connectionName)" }
    var isRunning: Bool { state == .running }

    struct Segment: Equatable {
        var outcome: Int
        var resultSet: Int
        var title: String
    }

    /// The result sets with rows, one segment each.
    var segments: [Segment] {
        var segments: [Segment] = []
        for (o, outcome) in outcomes.enumerated() {
            for (s, set) in (outcome.execution?.resultSets ?? []).enumerated() where set.hasRows {
                segments.append(Segment(outcome: o, resultSet: s, title: "Result \(segments.count + 1)"))
            }
        }
        return segments
    }

    var selectedResultSet: DBResultSet? {
        let segments = segments
        guard selectedSegment < segments.count else { return nil }
        let segment = segments[selectedSegment]
        return outcomes[segment.outcome].execution?.resultSets[segment.resultSet]
    }

    var firstError: (outcome: DBStatementOutcome, error: DBError)? {
        for outcome in outcomes { if let error = outcome.error { return (outcome, error) } }
        return nil
    }

    var messages: [DBMessage] { outcomes.flatMap { $0.execution?.messages ?? [] } }
}

/// The window's database explorer: saved connections, their sessions, the connection each SQL
/// file uses, runs and their results tabs, and query history.
@MainActor
@Observable
final class DatabaseWorkspace {
    @ObservationIgnored private weak var workspace: Workspace?
    /// The folder's connections, then the global ones, then those opened for now.
    private(set) var connections: [DatabaseConnectionConfig] = []
    private(set) var sessions: [UUID: DatabaseSession] = [:]
    private(set) var resultsTabs: [DatabaseResultsTab] = []
    /// The add/edit sheet's connection.
    var editing: DatabaseConnectionDraft?
    /// Expanded tree rows (connection, schema and table ids).
    var expanded: Set<String> = []
    /// Bumped when a file's connection changes (the status bar follows).
    private(set) var bindingVersion = 0

    // Swappable in tests.
    @ObservationIgnored var passwords: DatabasePasswordStore = DatabasePasswords.shared
    @ObservationIgnored var storageRoot: URL? { didSet { bindingsCache = nil; historyCache = [:]; reload() } }
    @ObservationIgnored var rowLimit = 10_000
    @ObservationIgnored var confirmAction: ((String) -> Bool)?
    @ObservationIgnored var quickPick: (([QuickPickItem], String) async -> Int?)?

    init(workspace: Workspace) {
        self.workspace = workspace
        reload()
    }

    // MARK: Storage

    private var root: URL { storageRoot ?? DatabaseStorage.root }
    private var globalFile: URL { root.appending(path: "connections.json") }
    private var workspaceFile: URL? { workspace?.rootURL.map(DatabaseStorage.workspaceFile(in:)) }

    private var storageFolder: URL {
        root.appending(path: HTTPStorage.key(folders: workspace?.folders ?? [], workspaceFile: workspace?.workspaceFile))
    }

    /// Reads the saved connections again (the folder's and the global ones).
    func reload() {
        let transient = connections.filter { $0.scope == .transient }
        var loaded = workspaceFile.map { DatabaseStorage.load($0, scope: .workspace) } ?? []
        loaded += DatabaseStorage.load(globalFile, scope: .global).filter { config in !loaded.contains { $0.id == config.id } }
        connections = loaded + transient.filter { config in !loaded.contains { $0.id == config.id } }
        for (id, session) in sessions {
            if let config = connections.first(where: { $0.id == id }) { session.config = config }
        }
    }

    private func persist(scope: DatabaseConnectionConfig.Scope) throws {
        switch scope {
        case .workspace:
            guard let workspaceFile else { throw DatabaseURLError(message: "Open a folder to keep connections in it.") }
            try DatabaseStorage.save(connections.filter { $0.scope == .workspace }, to: workspaceFile)
        case .global:
            try DatabaseStorage.save(connections.filter { $0.scope == .global }, to: globalFile)
        case .transient:
            break
        }
    }

    func connection(id: UUID?) -> DatabaseConnectionConfig? {
        guard let id else { return nil }
        return connections.first { $0.id == id }
    }

    /// Adds or updates a connection (its password to the Keychain when `savePassword`).
    func save(_ config: DatabaseConnectionConfig, password: String?, savePassword: Bool) throws {
        var config = config
        let previous = connections.first { $0.id == config.id }
        config.password = nil
        if let index = connections.firstIndex(where: { $0.id == config.id }) {
            connections[index] = config
        } else {
            connections.append(config)
        }
        if let previous, previous.scope != config.scope { try persist(scope: previous.scope) }
        try persist(scope: config.scope)
        if config.kind != .sqlite {
            if savePassword {
                try passwords.setPassword(password, for: config.id)
            } else {
                try passwords.setPassword(nil, for: config.id)
                sessionPasswords[config.id] = password
            }
        }
        if let session = sessions[config.id], previous != config || session.state != .connected {
            Task { await session.disconnect() }
            session.config = config
        }
    }

    func delete(_ config: DatabaseConnectionConfig) {
        connections.removeAll { $0.id == config.id }
        try? persist(scope: config.scope)
        try? passwords.setPassword(nil, for: config.id)
        if let session = sessions.removeValue(forKey: config.id) { Task { await session.disconnect() } }
    }

    /// Passwords typed for this run only (not saved).
    @ObservationIgnored private var sessionPasswords: [UUID: String] = [:]

    func password(for config: DatabaseConnectionConfig) -> String? {
        config.password ?? sessionPasswords[config.id] ?? passwords.password(for: config.id)
    }

    func session(for id: UUID) -> DatabaseSession? {
        if let session = sessions[id] { return session }
        guard let config = connection(id: id) else { return nil }
        let session = DatabaseSession(config: config)
        sessions[id] = session
        return session
    }

    /// Connects (when it isn't), then reads the schema in the background.
    @discardableResult
    func connect(_ id: UUID) async -> (any DatabaseDriver)? {
        guard let session = session(for: id) else { return nil }
        if let driver = session.driver { return driver }
        do {
            let driver = try await session.connect(password: password(for: session.config))
            Task { await session.loadCatalog() }
            return driver
        } catch {
            workspace?.errorMessage = "Couldn't connect to “\(session.config.displayName)”: " + ((error as? DBError)?.message ?? error.localizedDescription)
            return nil
        }
    }

    func disconnect(_ id: UUID) {
        guard let session = sessions[id] else { return }
        Task { await session.disconnect() }
    }

    func refresh(_ id: UUID) {
        Task {
            guard await connect(id) != nil, let session = sessions[id] else { return }
            await session.loadCatalog()
        }
    }

    /// Tries a connection (the sheet's Test Connection): the server's version, or why not.
    nonisolated static func test(_ config: DatabaseConnectionConfig) async -> Result<String, DBError> {
        do {
            let driver = try await DatabaseDrivers.connect(config)
            let version = await driver.serverVersion
            await driver.close()
            return .success(version)
        } catch let error as DBError {
            return .failure(error)
        } catch {
            return .failure(DBError.connection(error.localizedDescription))
        }
    }

    // MARK: SQLite files

    /// Opens a SQLite file as a connection (kept for this window, not saved), connects, and
    /// shows it in the Database panel.
    @discardableResult
    func openSQLiteFile(_ url: URL, readOnly: Bool = false) -> DatabaseConnectionConfig {
        let path = url.standardizedFileURL.path
        if let existing = connections.first(where: { $0.kind == .sqlite && $0.file.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path }) {
            expanded.insert(existing.id.uuidString)
            Task { await connect(existing.id) }
            return existing
        }
        var config = DatabaseConnectionConfig(kind: .sqlite)
        config.file = path
        config.readOnly = readOnly
        config.scope = .transient
        connections.append(config)
        expanded.insert(config.id.uuidString)
        Task { await connect(config.id) }
        return config
    }

    // MARK: Files and their connections

    private struct Bindings: Codable {
        var files: [String: UUID] = [:]
    }

    @ObservationIgnored private var bindingsCache: Bindings?

    private var bindings: Bindings {
        get {
            if let bindingsCache { return bindingsCache }
            let file = storageFolder.appending(path: "bindings.json")
            let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Bindings.self, from: $0) } ?? Bindings()
            bindingsCache = loaded
            return loaded
        }
        set {
            bindingsCache = newValue
            let file = storageFolder.appending(path: "bindings.json")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(newValue).write(to: file, options: .atomic)
        }
    }

    /// The connection a SQL file runs on (remembered per file).
    func connectionID(for file: URL) -> UUID? {
        _ = bindingVersion
        guard let id = bindings.files[file.standardizedFileURL.path], connection(id: id) != nil else { return nil }
        return id
    }

    func setConnection(_ id: UUID?, for file: URL) {
        bindings.files[file.standardizedFileURL.path] = id
        bindingVersion += 1
        workspace?.document(matching: file)?.refreshSQLLenses()
        if let id { Task { await connect(id) } }
    }

    private func pick(_ items: [QuickPickItem], placeholder: String) async -> Int? {
        if let quickPick { return await quickPick(items, placeholder) }
        return await workspace?.showQuickPick(items, placeholder: placeholder)
    }

    /// Choose Connection: a pick of the saved ones (and "Add Connection…").
    @discardableResult
    func chooseConnection(for file: URL) async -> UUID? {
        let current = connectionID(for: file)
        var items = connections.map { config in
            QuickPickItem(label: config.displayName, description: config.id == current ? "current" : config.kind.title, detail: config.summary)
        }
        items.append(QuickPickItem(label: "Add Connection…"))
        guard let index = await pick(items, placeholder: "Connection for \(file.lastPathComponent)") else { return nil }
        if index == connections.count {
            beginAdding()
            return nil
        }
        let id = connections[index].id
        setConnection(id, for: file)
        return id
    }

    // MARK: Running

    enum RunScope {
        /// The statement at the caret (⌘↩).
        case statementAtCaret
        /// The selection, or the whole file without one (⇧⌘↩).
        case selectionOrFile
    }

    /// The statements to run, with their offsets in the file.
    nonisolated static func statements(in text: String, scope: RunScope, caret: Int, selection: NSRange, dialect: SQLDialect) -> [SQLStatement] {
        switch scope {
        case .statementAtCaret:
            let all = SQLSplitter.split(text, dialect: dialect)
            return SQLSplitter.statement(at: caret, in: all).map { [$0] } ?? []
        case .selectionOrFile:
            if selection.length > 0 {
                let selected = (text as NSString).substring(with: selection)
                return SQLSplitter.split(selected, dialect: dialect).map { statement in
                    var statement = statement
                    statement.range.location += selection.location
                    statement.extent.location += selection.location
                    return statement
                }
            }
            return SQLSplitter.split(text, dialect: dialect)
        }
    }

    /// Runs statements of a SQL file on its connection (asking which, the first time): the
    /// results show in the file's results tab, beside it; an error with a position is marked
    /// in the file.
    @discardableResult
    func run(_ scope: RunScope, in document: EditorDocument, caret: Int? = nil, selection: NSRange? = nil,
             beside group: EditorGroup? = nil) -> Task<DatabaseResultsTab?, Never> {
        let textView = document.editor?.textView
        let selection = selection ?? textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        let caret = caret ?? selection.location
        let text = document.textStorage.string
        return Task {
            var id = connectionID(for: document.url)
            if id == nil { id = await chooseConnection(for: document.url) }
            guard let id, let config = connection(id: id) else { return nil }
            let statements = Self.statements(in: text, scope: scope, caret: caret, selection: selection, dialect: config.kind.dialect)
            guard !statements.isEmpty else {
                workspace?.errorMessage = "There's no SQL statement to run here."
                return nil
            }
            let tab = resultsTab(for: document.url, beside: group)
            await execute(statements, on: config, in: tab, document: document)
            return tab
        }
    }

    /// Runs SQL that isn't from a file (Select Top 100 on a scratch file uses `run`).
    @discardableResult
    func run(sql: String, on id: UUID, title: String) -> Task<DatabaseResultsTab?, Never> {
        Task {
            guard let config = connection(id: id) else { return nil }
            let statements = SQLSplitter.split(sql, dialect: config.kind.dialect)
            let tab = resultsTab(key: "sql#" + title, title: title, beside: nil)
            await execute(statements, on: config, in: tab, document: nil)
            return tab
        }
    }

    func resultsTab(for file: URL, beside group: EditorGroup?) -> DatabaseResultsTab {
        resultsTab(key: file.standardizedFileURL.path, title: file.lastPathComponent, beside: group)
    }

    private func resultsTab(key: String, title: String, beside group: EditorGroup?) -> DatabaseResultsTab {
        let tab: DatabaseResultsTab
        if let existing = resultsTabs.last(where: { $0.key == key && !$0.isPinned }) {
            tab = existing
            tab.rename(title)
        } else {
            tab = DatabaseResultsTab(key: key, title: "Results: \(title)")
            resultsTabs.append(tab)
        }
        workspace?.showBeside(tab.id, of: group)
        return tab
    }

    private func execute(_ statements: [SQLStatement], on config: DatabaseConnectionConfig, in tab: DatabaseResultsTab,
                         document: EditorDocument?, rowLimit limit: Int? = nil) async {
        tab.task?.cancel()
        await tab.task?.value
        tab.state = .running
        tab.cancelRequested = false
        tab.connectionID = config.id
        tab.connectionName = config.displayName
        tab.dialect = config.kind.dialect
        tab.sourceFile = document?.url
        tab.outcomes = statements.map { DBStatementOutcome(sql: $0.text, offset: $0.range.location) }
        tab.selectedSegment = 0
        tab.explanation = nil
        tab.startedAt = Date()
        tab.duration = 0
        tab.rowLimit = limit ?? rowLimit
        if let document { setRunDiagnostics([], in: document) }
        let task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            await self.perform(statements, config: config, tab: tab, document: document)
        }
        tab.task = task
        await task.value
    }

    private func perform(_ statements: [SQLStatement], config: DatabaseConnectionConfig, tab: DatabaseResultsTab, document: EditorDocument?) async {
        let started = Date()
        defer { tab.duration = Date().timeIntervalSince(started) }
        guard let driver = await connect(config.id), let session = sessions[config.id] else {
            tab.state = .failed(sessions[config.id].flatMap { if case .failed(let m) = $0.state { m } else { nil } } ?? "Couldn't connect.")
            return
        }
        let limit = tab.rowLimit
        let history = history(for: config.id)
        var changedSchema = false
        for (index, statement) in statements.enumerated() {
            if tab.cancelRequested || Task.isCancelled {
                tab.state = .cancelled
                return
            }
            tab.outcomes[index].isRunning = true
            let start = Date()
            let sql = statement.text
            do {
                let execution = try await session.serialized { try await driver.run(sql, rowLimit: limit) }
                tab.outcomes[index].execution = execution
            } catch {
                let failure = (error as? DBError) ?? DBError.connection(error.localizedDescription)
                tab.outcomes[index].execution = DBExecution(error: failure)
                if failure.isConnectionError { session.connectionLost() }
            }
            let duration = Date().timeIntervalSince(start)
            tab.outcomes[index].duration = duration
            tab.outcomes[index].isRunning = false
            let outcome = tab.outcomes[index]
            history.add(DatabaseHistoryEntry(date: start, sql: sql, duration: duration,
                                             rows: outcome.execution?.resultSets.last(where: \.hasRows)?.totalRows,
                                             affectedRows: outcome.execution?.resultSets.compactMap(\.affectedRows).reduce(nil) { ($0 ?? 0) + $1 },
                                             error: outcome.error?.message, file: document?.url))
            if Self.changesSchema(sql) { changedSchema = true }
            if let error = outcome.error {
                if let document { markError(error, statement: statement, in: document) }
                tab.state = error == .cancelled || tab.cancelRequested ? .cancelled : .done
                if changedSchema { Task { await session.loadCatalog() } }
                // Show where it stopped: Messages, unless it gave rows before.
                tab.selectedSegment = tab.segments.isEmpty ? 0 : tab.segments.count
                return
            }
        }
        tab.state = tab.cancelRequested ? .cancelled : .done
        if tab.segments.isEmpty { tab.selectedSegment = 0 }
        if changedSchema { Task { await session.loadCatalog() } }
    }

    /// DDL changes what completion and the tree know.
    nonisolated static func changesSchema(_ sql: String) -> Bool {
        let first = sql.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first?.uppercased() ?? ""
        return ["CREATE", "ALTER", "DROP", "RENAME", "TRUNCATE", "ATTACH", "DETACH"].contains(first)
    }

    func cancel(_ tab: DatabaseResultsTab) {
        guard tab.isRunning else { return }
        tab.cancelRequested = true
        if let id = tab.connectionID { sessions[id]?.driver?.cancel() }
    }

    /// Run again: from the file as it is now (the same statements' text), or as they were.
    func rerun(_ tab: DatabaseResultsTab, rowLimit limit: Int? = nil) {
        guard let id = tab.connectionID, let config = connection(id: id) else { NSSound.beep(); return }
        let statements = tab.outcomes.map { outcome in
            SQLStatement(range: NSRange(location: outcome.offset, length: (outcome.sql as NSString).length),
                         extent: NSRange(location: outcome.offset, length: (outcome.sql as NSString).length), text: outcome.sql)
        }
        let document = tab.sourceFile.flatMap { workspace?.document(matching: $0) }
        let valid = document.map { doc in
            statements.allSatisfy { NSMaxRange($0.range) <= doc.textStorage.length && (doc.textStorage.string as NSString).substring(with: $0.range) == $0.text }
        } ?? false
        Task { await execute(statements, on: config, in: tab, document: valid ? document : nil, rowLimit: limit ?? tab.rowLimit) }
    }

    // MARK: Errors in the file

    /// Marks a statement's error: at its position (the word there), else its first line.
    private func markError(_ error: DBError, statement: SQLStatement, in document: EditorDocument) {
        let text = document.textStorage.mutableString
        guard NSMaxRange(statement.range) <= text.length else { return }
        var range: NSRange
        if let position = error.position, position >= 0, position <= statement.range.length {
            let start = statement.range.location + position
            var end = start
            while end < NSMaxRange(statement.range), EditorDocument.isWordUnit(text.character(at: end)) { end += 1 }
            if end == start { end = min(NSMaxRange(statement.range), start + 1) }
            range = NSRange(location: start, length: end - start)
        } else {
            let line = text.lineRange(for: NSRange(location: statement.range.location, length: 0))
            range = NSIntersectionRange(NSRange(location: statement.range.location, length: NSMaxRange(line) - statement.range.location),
                                        statement.range)
            if range.length == 0 { range = statement.range }
        }
        let diagnostic = Diagnostic(range: LSPRange(start: document.lspPosition(at: range.location), end: document.lspPosition(at: NSMaxRange(range))),
                                    severity: .error, message: error.fullMessage, source: "sql")
        setRunDiagnostics([diagnostic], in: document)
    }

    func setRunDiagnostics(_ diagnostics: [Diagnostic], in document: EditorDocument) {
        document.setExtensionDiagnostics(diagnostics, collection: SQLSyntax.problemSource)
        guard let workspace else { return }
        workspace.problems.set(diagnostics, for: workspace.workspaceURL(for: document.url), source: SQLSyntax.problemSource)
    }

    // MARK: Tabs

    func resultsTab(id: UUID?) -> DatabaseResultsTab? {
        guard let id else { return nil }
        return resultsTabs.first { $0.id == id }
    }

    func closeResultsTab(_ tab: DatabaseResultsTab, in group: EditorGroup) {
        group.remove(tab.id)
        if !(workspace?.groups.contains { $0.contains(tab.id) } ?? false) {
            cancel(tab)
            tab.task?.cancel()
            resultsTabs.removeAll { $0 === tab }
        }
        workspace?.tabClosed(in: group)
    }

    // MARK: History

    @ObservationIgnored private var historyCache: [UUID: DatabaseHistory] = [:]

    func history(for id: UUID) -> DatabaseHistory {
        if let cached = historyCache[id] { return cached }
        let history = DatabaseHistory(file: root.appending(path: "History/\(id.uuidString).json"))
        historyCache[id] = history
        return history
    }

    /// Query History: a pick of the connection's past statements, then Run Again or Open.
    func showHistory(for id: UUID) async {
        let entries = history(for: id).entries
        guard !entries.isEmpty else {
            _ = await pick([QuickPickItem(label: "No queries run yet")], placeholder: "History")
            return
        }
        let items = entries.map { entry in
            QuickPickItem(label: entry.sql.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(120).description,
                          description: entry.error != nil ? "failed" : entry.rows.map { "\($0) rows" } ?? entry.affectedRows.map { "\($0) affected" },
                          detail: entry.date.formatted(date: .abbreviated, time: .shortened) + " · " + Self.duration(entry.duration))
        }
        guard let index = await pick(items, placeholder: "Queries on \(connection(id: id)?.displayName ?? "") (newest first)") else { return }
        let entry = entries[index]
        guard let action = await pick([QuickPickItem(label: "Run Again"), QuickPickItem(label: "Open in Editor")], placeholder: "History") else { return }
        if action == 0 {
            run(sql: entry.sql, on: id, title: connection(id: id)?.displayName ?? "Query")
        } else {
            newQuery(on: id, text: entry.sql)
        }
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    // MARK: Tree actions

    /// New Query: a scratch SQL file bound to the connection (kept with the app's data).
    @discardableResult
    func newQuery(on id: UUID, text: String = "") -> EditorDocument? {
        guard let config = connection(id: id) else { return nil }
        let folder = root.appending(path: "Scratches")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = String(config.displayName.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(30))
        let url = folder.appending(path: "\(safe)-\(UUID().uuidString.prefix(6)).sql")
        do {
            try Data(text.utf8).write(to: url)
        } catch {
            workspace?.errorMessage = error.localizedDescription
            return nil
        }
        setConnection(id, for: url)
        workspace?.open(fileAt: url)
        return workspace?.document(matching: url)
    }

    func selectTopSQL(_ table: DBTable, on config: DatabaseConnectionConfig, limit: Int = 100) -> String {
        let dialect = config.kind.dialect
        let catalog = sessions[config.id]?.catalog
        return "SELECT * FROM \(dialect.qualified(table, defaultSchema: catalog?.defaultSchema)) LIMIT \(limit);\n"
    }

    /// Select Top 100: a scratch query, run.
    @discardableResult
    func selectTop(_ table: DBTable, on id: UUID) -> Task<DatabaseResultsTab?, Never>? {
        guard let config = connection(id: id), let document = newQuery(on: id, text: selectTopSQL(table, on: config)) else { return nil }
        return run(.selectionOrFile, in: document, caret: 0, selection: NSRange(location: 0, length: 0))
    }

    /// Show DDL: the table's CREATE statement in a scratch file.
    func showDDL(_ table: DBTable, on id: UUID) {
        Task {
            guard let driver = await connect(id), let session = sessions[id] else { return }
            do {
                let ddl = try await session.serialized { try await driver.ddl(for: table) }
                newQuery(on: id, text: ddl + "\n")
            } catch {
                workspace?.errorMessage = (error as? DBError)?.fullMessage ?? error.localizedDescription
            }
        }
    }

    private func confirm(_ message: String) -> Bool {
        if let confirmAction { return confirmAction(message) }
        if let confirmation = workspace?.confirmation { return confirmation(message) }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = "This can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    enum Destructive { case drop, truncate }

    /// Drop or Truncate, after a confirmation naming the table.
    @discardableResult
    func destroy(_ table: DBTable, on id: UUID, _ action: Destructive) -> Task<DatabaseResultsTab?, Never>? {
        guard let config = connection(id: id) else { return nil }
        let dialect = config.kind.dialect
        let name = dialect.qualified(table, defaultSchema: sessions[id]?.catalog?.defaultSchema)
        let sql: String
        switch action {
        case .drop: sql = "DROP \(table.kind == .view ? "VIEW" : "TABLE") \(name)"
        case .truncate: sql = dialect == .sqlite ? "DELETE FROM \(name)" : "TRUNCATE TABLE \(name)"
        }
        let verb = action == .drop ? "Drop" : "Empty"
        guard confirm("\(verb) \(table.kind == .view ? "view" : "table") “\(table.name)” on \(config.displayName)?\n\n\(sql)") else { return nil }
        return run(sql: sql + ";", on: id, title: config.displayName)
    }

    func beginAdding(kind: DatabaseKind = .postgres) {
        editing = DatabaseConnectionDraft(config: DatabaseConnectionConfig(kind: kind), password: "", isNew: true,
                                          canSaveInWorkspace: workspace?.rootURL != nil)
        workspace?.sidebarMode = .database
        workspace?.sidebarVisibility = .all
    }

    func beginEditing(_ config: DatabaseConnectionConfig) {
        editing = DatabaseConnectionDraft(config: config, password: password(for: config) ?? "", isNew: false,
                                          canSaveInWorkspace: workspace?.rootURL != nil)
    }

    // MARK: AI context

    /// The schema of the file's connection, for ⌘I (tables the text names first; capped).
    func schemaContext(for document: EditorDocument, limit: Int = 8_000) -> String? {
        guard let id = connectionID(for: document.url), let config = connection(id: id),
              let catalog = sessions[id]?.catalog else { return nil }
        return Self.schemaContext(catalog, dialect: config.kind.dialect, kind: config.kind, mentioning: document.textStorage.string, limit: limit)
    }

    nonisolated static func schemaContext(_ catalog: DBCatalog, dialect: SQLDialect, kind: DatabaseKind, mentioning text: String, limit: Int) -> String {
        let lower = text.lowercased()
        let tables = catalog.allTables.sorted { a, b in
            let am = lower.contains(a.name.lowercased()), bm = lower.contains(b.name.lowercased())
            return am != bm ? am : a.id < b.id
        }
        var result = "Database: \(kind.title)" + (catalog.defaultSchema.map { ", default schema \($0)" } ?? "") + "\n"
        for table in tables {
            let columns = table.columns.map { column in
                column.name + " " + column.type + (column.isPrimaryKey ? " PK" : "") + (table.isForeignKey(column.name) ? " FK" : "")
            }
            var line = "\(table.kind == .view ? "VIEW" : "TABLE") \(table.schema == catalog.defaultSchema ? table.name : table.id)(\(columns.joined(separator: ", ")))"
            for key in table.foreignKeys {
                line += "; \(key.columns.joined(separator: ",")) -> \(key.referencedTable)(\(key.referencedColumns.joined(separator: ",")))"
            }
            if result.count + line.count > limit {
                result += "… (\(tables.count) tables in all)\n"
                break
            }
            result += line + "\n"
        }
        return result
    }
}

/// The add/edit sheet's state.
struct DatabaseConnectionDraft: Identifiable {
    var id: UUID { config.id }
    var config: DatabaseConnectionConfig
    var password: String
    var isNew: Bool
    var canSaveInWorkspace: Bool
    var savePassword = true
}

// MARK: Workspace

extension Workspace {
    /// The active document when it's a SQL file.
    var activeSQLDocument: EditorDocument? {
        activeDocument.flatMap { $0.language == .sql ? $0 : nil }
    }

    var activeResultsTab: DatabaseResultsTab? { database.resultsTab(id: activeGroup.activeDocumentID) }

    private func sqlGroup(of document: EditorDocument) -> EditorGroup? {
        activeGroup.contains(document.id) ? activeGroup : groups.first { $0.contains(document.id) }
    }

    /// ⌘↩ / ⇧⌘↩ in a SQL file.
    @discardableResult
    func runSQL(_ scope: DatabaseWorkspace.RunScope, in document: EditorDocument? = nil) -> Task<DatabaseResultsTab?, Never>? {
        guard let document = document ?? activeSQLDocument else { NSSound.beep(); return nil }
        return database.run(scope, in: document, beside: sqlGroup(of: document))
    }

    /// The status bar's connection item for a SQL file.
    var sqlConnectionLabel: String? {
        guard let document = activeSQLDocument else { return nil }
        return database.connection(id: database.connectionID(for: document.url))?.displayName ?? "No Connection"
    }

    /// Explain Query: the statement at the caret (and its error, if the last run failed),
    /// explained in the results tab.
    func explainSQL(_ tab: DatabaseResultsTab? = nil) {
        guard let tab = tab ?? activeResultsTab ?? database.resultsTabs.last, let outcome = tab.firstError?.outcome ?? tab.outcomes.first else {
            NSSound.beep()
            return
        }
        var text = "SQL (\(tab.dialect.rawValue)):\n\(outcome.sql)\n"
        if let error = outcome.error { text += "\nError:\n\(error.fullMessage)\n" }
        if let id = tab.connectionID, let config = database.connection(id: id), let catalog = database.sessions[id]?.catalog {
            text += "\nSchema:\n" + DatabaseWorkspace.schemaContext(catalog, dialect: config.kind.dialect, kind: config.kind, mentioning: outcome.sql, limit: 4_000)
        }
        tab.explanation = outputExplanation(text, source: "SQL Query", command: nil)
    }

    /// Fix Query with AI: the failed statement's diagnostic, through ⌘I's fix.
    func fixSQLWithAI(_ tab: DatabaseResultsTab? = nil) {
        guard let tab = tab ?? activeResultsTab, let file = tab.sourceFile, let document = document(matching: file),
              let diagnostic = document.diagnostics.first(where: { $0.source == "sql" }) else { NSSound.beep(); return }
        open(fileAt: file)
        fixWithAI(diagnostic, in: file)
    }

    static let databasePaletteCommands: [PaletteCommand] = [
        PaletteCommand(id: "sql.runStatement", title: "SQL: Run Statement at Cursor", icon: "play", key: nil,
                       isAvailable: { $0.activeSQLDocument != nil }, perform: { $0.runSQL(.statementAtCaret) }),
        PaletteCommand(id: "sql.runAll", title: "SQL: Run Selection or File", icon: "play.fill", key: nil,
                       isAvailable: { $0.activeSQLDocument != nil }, perform: { $0.runSQL(.selectionOrFile) }),
        PaletteCommand(id: "sql.chooseConnection", title: "SQL: Choose Connection", icon: "cylinder", key: nil,
                       isAvailable: { $0.activeSQLDocument != nil },
                       perform: { workspace in
                           guard let url = workspace.activeSQLDocument?.url else { return }
                           Task { await workspace.database.chooseConnection(for: url) }
                       }),
        PaletteCommand(id: "sql.cancel", title: "SQL: Cancel Query", icon: "stop.circle", key: nil,
                       isAvailable: { $0.database.resultsTabs.contains(where: \.isRunning) },
                       perform: { workspace in workspace.database.resultsTabs.filter(\.isRunning).forEach { workspace.database.cancel($0) } }),
        PaletteCommand(id: "database.addConnection", title: "Database: Add Connection…", icon: "plus", key: nil,
                       isAvailable: { _ in true }, perform: { $0.database.beginAdding() }),
        PaletteCommand(id: "database.show", title: "View: Show Database", icon: "cylinder.split.1x2", key: nil,
                       isAvailable: { _ in true }, perform: { $0.sidebarMode = .database; $0.sidebarVisibility = .all }),
        PaletteCommand(id: "sql.explain", title: "SQL: Explain Query with AI", icon: "sparkles", key: nil,
                       isAvailable: { !$0.database.resultsTabs.isEmpty && AISettings.shared.isConfigured }, perform: { $0.explainSQL() }),
        PaletteCommand(id: "sql.fix", title: "SQL: Fix Query with AI", icon: "wand.and.stars", key: nil,
                       isAvailable: { $0.activeResultsTab?.firstError != nil && AISettings.shared.isConfigured }, perform: { $0.fixSQLWithAI() }),
    ]
}

// MARK: Editor

extension Workspace {
    /// A Run lens: the statement it's on.
    func runSQLLens(_ lens: CodeLens, in document: EditorDocument) {
        guard let offset = (lens.command?["arguments"] as? [Any])?.first as? Int else { NSSound.beep(); return }
        database.run(.statementAtCaret, in: document, caret: offset, selection: NSRange(location: offset, length: 0),
                     beside: groups.first { $0.contains(document.id) })
    }
}

extension EditorDocument {
    /// The Run lenses of a SQL file (after edits).
    func refreshSQLLenses() {
        guard language == .sql else { return }
        guard projectSettings.showsCodeLens ?? AppSettings.shared.showsCodeLens else {
            setCodeLenses([:])
            return
        }
        var dialect = SQLDialect.postgres
        if let database = workspace?.database, let id = database.connectionID(for: url) {
            dialect = database.connection(id: id)?.kind.dialect ?? .postgres
        }
        setCodeLenses(SQLSyntax.codeLenses(textStorage.string, dialect: dialect, lineIndex: lineIndex))
    }

    /// Completion items for a SQL file at `cursor`: its connection's tables and columns, and
    /// keywords.
    func sqlCompletions(at cursor: Int, firstID: Int) -> [CompletionItem] {
        let line = lineIndex.line(containing: cursor)
        var catalog: DBCatalog?
        var dialect = SQLDialect.postgres
        if let database = workspace?.database, let id = database.connectionID(for: url) {
            catalog = database.sessions[id]?.catalog
            dialect = database.connection(id: id)?.kind.dialect ?? .postgres
        }
        return SQLCompletion.items(text: textStorage.mutableString, cursor: cursor, line: line, lineStart: lineIndex.lineStarts[line],
                                   catalog: catalog, dialect: dialect, firstID: firstID)
    }
}
