import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Database panel: saved connections, and for each (once connected) its schemas, tables
/// and views, their columns and indexes.
struct DatabaseSidebarView: View {
    @Bindable var workspace: Workspace

    private var database: DatabaseWorkspace { workspace.database }

    var body: some View {
        Group {
            if database.connections.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "cylinder.split.1x2").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No connections").font(.headline)
                    Text("Connect to PostgreSQL, MySQL or MariaDB, or a SQLite file (opening one from the Explorer shows it here).")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Add Connection…") { database.beginAdding() }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(database.connections) { config in
                            ConnectionRows(config: config, workspace: workspace)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        // The folder's .omc/databases.json may have changed (or the folder opened since).
        .onAppear { database.reload() }
        .sheet(item: Binding(get: { database.editing }, set: { database.editing = $0 })) { draft in
            ConnectionEditorView(draft: draft, workspace: workspace)
        }
    }
}

/// The panel header's buttons.
struct DatabasePanelActions: View {
    let workspace: Workspace

    var body: some View {
        Button { workspace.database.beginAdding() } label: { Image(systemName: "plus") }
            .help("Add Connection…")
        Button {
            Task {
                let database = workspace.database
                let connected = database.connections.filter { database.sessions[$0.id]?.isConnected == true }
                let candidates = connected.isEmpty ? database.connections : connected
                if candidates.count == 1 { database.newQuery(on: candidates[0].id); return }
                guard !candidates.isEmpty, let index = await workspace.showQuickPick(candidates.map {
                    QuickPickItem(label: $0.displayName, description: $0.kind.title, detail: $0.summary)
                }, placeholder: "New query on…") else { return }
                database.newQuery(on: candidates[index].id)
            }
        } label: { Image(systemName: "square.and.pencil") }
            .help("New Query")
            .disabled(workspace.database.connections.isEmpty)
    }
}

private struct TreeRow<Label: View>: View {
    let depth: Int
    let isExpandable: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(isExpandable ? 1 : 0)
                .frame(width: 12)
            label
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 14 + 6)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if isExpandable { toggle() } }
    }
}

private struct ConnectionRows: View {
    let config: DatabaseConnectionConfig
    @Bindable var workspace: Workspace

    private var database: DatabaseWorkspace { workspace.database }
    private var session: DatabaseSession? { database.sessions[config.id] }
    private var key: String { config.id.uuidString }

    private func isExpanded(_ id: String) -> Bool { database.expanded.contains(id) }

    private func toggle(_ id: String) {
        if database.expanded.contains(id) { database.expanded.remove(id) } else { database.expanded.insert(id) }
    }

    var body: some View {
        TreeRow(depth: 0, isExpandable: true, isExpanded: isExpanded(key), toggle: {
            toggle(key)
            if isExpanded(key), session?.isConnected != true { Task { await database.connect(config.id) } }
        }) {
            Image(systemName: config.kind == .sqlite ? "doc.text" : "cylinder.split.1x2")
                .foregroundStyle(config.kind == .postgres ? .blue : config.kind == .mysql ? .orange : .teal)
            Text(config.displayName).lineLimit(1).truncationMode(.middle)
            if config.scope == .workspace {
                Image(systemName: "folder").font(.caption2).foregroundStyle(.secondary).help("Saved in this folder (.omc/databases.json)")
            }
            status
        }
        .help(config.summary)
        .contextMenu { connectionMenu }
        if isExpanded(key) {
            if let session, let catalog = session.catalog {
                if catalog.schemas.count == 1, let schema = catalog.schemas.first {
                    tables(schema, depth: 1)
                } else {
                    ForEach(catalog.schemas) { schema in
                        let id = key + "/" + schema.name
                        TreeRow(depth: 1, isExpandable: true, isExpanded: isExpanded(id), toggle: { toggle(id) }) {
                            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                            Text(schema.name).lineLimit(1)
                            if schema.name == catalog.defaultSchema { Text("default").font(.caption).foregroundStyle(.secondary) }
                            Text("\(schema.tables.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .contextMenu {
                            Button("Copy Name") { copy(schema.name) }
                            Button("Refresh") { database.refresh(config.id) }
                        }
                        if isExpanded(id) { tables(schema, depth: 2) }
                    }
                }
            } else if let session, case .failed(let message) = session.state {
                note(message, color: .red)
            } else if let error = session?.catalogError {
                note(error, color: .red)
            } else {
                note(session?.state == .connecting ? "Connecting…" : "Loading…", color: .secondary)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch session?.state {
        case .connecting?:
            ProgressView().controlSize(.mini)
        case .connected?:
            Circle().fill(.green).frame(width: 6, height: 6).help(session?.serverVersion ?? "Connected")
            if session?.isLoadingCatalog == true { ProgressView().controlSize(.mini) }
        case .failed(let message)?:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).help(message)
        default:
            EmptyView()
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .lineLimit(4)
            .padding(.leading, 34)
            .padding(.vertical, 3)
            .textSelection(.enabled)
    }

    @ViewBuilder private func tables(_ schema: DBSchema, depth: Int) -> some View {
        if schema.tables.isEmpty {
            note("No tables", color: .secondary)
        }
        ForEach(schema.tables) { table in
            TableRows(table: table, config: config, depth: depth, workspace: workspace)
        }
    }

    @ViewBuilder private var connectionMenu: some View {
        if session?.isConnected == true {
            Button("Disconnect") { database.disconnect(config.id) }
        } else {
            Button("Connect") { database.expanded.insert(key); Task { await database.connect(config.id) } }
        }
        Button("New Query") { database.newQuery(on: config.id) }
        Button("Refresh") { database.refresh(config.id) }
        Button("Query History…") { Task { await database.showHistory(for: config.id) } }
        Divider()
        Button(config.scope == .transient ? "Save Connection…" : "Edit Connection…") {
            var saved = config
            if saved.scope == .transient { saved.scope = .global }
            database.editing = DatabaseConnectionDraft(config: saved, password: database.password(for: config) ?? "",
                                                       isNew: config.scope == .transient, canSaveInWorkspace: workspace.rootURL != nil)
        }
        Button("Copy URL") { copy(config.urlString) }
        if config.kind == .sqlite, let file = config.file {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
        }
        Divider()
        Button(config.scope == .transient ? "Close" : "Delete Connection…", role: .destructive) {
            if config.scope == .transient || confirmDelete() { database.delete(config) }
        }
    }

    private func confirmDelete() -> Bool {
        if let confirmation = workspace.confirmation { return confirmation("Delete \(config.displayName)?") }
        let alert = NSAlert()
        alert.messageText = "Delete the connection “\(config.displayName)”?"
        alert.informativeText = "Its saved password is removed from the Keychain. The database itself isn't touched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private struct TableRows: View {
    let table: DBTable
    let config: DatabaseConnectionConfig
    let depth: Int
    @Bindable var workspace: Workspace

    private var database: DatabaseWorkspace { workspace.database }
    private var key: String { config.id.uuidString + "/" + table.id }

    private func toggle(_ id: String) {
        if database.expanded.contains(id) { database.expanded.remove(id) } else { database.expanded.insert(id) }
    }

    var body: some View {
        TreeRow(depth: depth, isExpandable: true, isExpanded: database.expanded.contains(key), toggle: { toggle(key) }) {
            Image(systemName: table.kind == .view ? "eye" : "tablecells").foregroundStyle(table.kind == .view ? .purple : .accentColor)
            Text(table.name).lineLimit(1).truncationMode(.middle)
        }
        .help("\(table.kind == .view ? "View" : "Table") \(table.id) — double-click for its first 100 rows")
        .simultaneousGesture(TapGesture(count: 2).onEnded { database.selectTop(table, on: config.id) })
        .contextMenu {
            Button("Select Top 100") { database.selectTop(table, on: config.id) }
            Button(table.kind == .view ? "Show Definition" : "Show DDL") { database.showDDL(table, on: config.id) }
            Divider()
            Button("Copy Name") { copy(table.name) }
            Button("Copy Qualified Name") {
                copy(config.kind.dialect.qualified(table, defaultSchema: nil))
            }
            Button("Refresh") { database.refresh(config.id) }
            Divider()
            if table.kind == .table {
                Button("Truncate…", role: .destructive) { database.destroy(table, on: config.id, .truncate) }
            }
            Button("Drop…", role: .destructive) { database.destroy(table, on: config.id, .drop) }
        }
        if database.expanded.contains(key) {
            ForEach(table.columns) { column in
                TreeRow(depth: depth + 1, isExpandable: false, isExpanded: false, toggle: {}) {
                    columnIcon(column)
                    Text(column.name).lineLimit(1)
                    Text(column.type + (column.isNullable ? "" : " not null")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(columnHelp(column))
                .contextMenu {
                    Button("Copy Name") { copy(column.name) }
                }
            }
            if !table.indexes.isEmpty {
                let indexesKey = key + "#indexes"
                TreeRow(depth: depth + 1, isExpandable: true, isExpanded: database.expanded.contains(indexesKey), toggle: { toggle(indexesKey) }) {
                    Image(systemName: "list.number").foregroundStyle(.secondary)
                    Text("Indexes").foregroundStyle(.secondary)
                    Text("\(table.indexes.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if database.expanded.contains(indexesKey) {
                    ForEach(table.indexes) { index in
                        TreeRow(depth: depth + 2, isExpandable: false, isExpanded: false, toggle: {}) {
                            Image(systemName: index.isPrimary ? "key.fill" : index.isUnique ? "staroflife" : "list.bullet")
                                .font(.caption).foregroundStyle(index.isPrimary ? .yellow : .secondary)
                            Text(index.name).lineLimit(1)
                            Text("(\(index.columns.joined(separator: ", ")))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contextMenu { Button("Copy Name") { copy(index.name) } }
                    }
                }
            }
        }
    }

    @ViewBuilder private func columnIcon(_ column: DBColumnInfo) -> some View {
        if column.isPrimaryKey {
            Image(systemName: "key.fill").font(.caption).foregroundStyle(.yellow).help("Primary key")
        } else if table.isForeignKey(column.name) {
            Image(systemName: "link").font(.caption).foregroundStyle(.blue).help("Foreign key")
        } else {
            Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary).frame(width: 12)
        }
    }

    private func columnHelp(_ column: DBColumnInfo) -> String {
        var parts = ["\(column.name) \(column.type)", column.isNullable ? "nullable" : "not null"]
        if let value = column.defaultValue { parts.append("default \(value)") }
        if column.isPrimaryKey { parts.append("primary key") }
        for key in table.foreignKeys where key.columns.contains(column.name) {
            parts.append("references \(key.referencedTable)(\(key.referencedColumns.joined(separator: ", ")))")
        }
        return parts.joined(separator: ", ")
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: Add / edit

/// The add/edit sheet: type, where it connects, sign-in, SSL, and where it's saved; a URL can
/// be pasted to fill it in, and Test Connection tries it.
struct ConnectionEditorView: View {
    @State var draft: DatabaseConnectionDraft
    let workspace: Workspace
    @State private var url = ""
    @State private var urlError: String?
    @State private var testResult: Result<String, DBError>?
    @State private var isTesting = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(draft: DatabaseConnectionDraft, workspace: Workspace) {
        _draft = State(initialValue: draft)
        self.workspace = workspace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.isNew ? "Add Connection" : "Edit Connection").font(.headline).padding([.top, .horizontal], 16)
            Form {
                Section {
                    HStack {
                        TextField("URL", text: $url, prompt: Text("postgres://user@host:5432/db?sslmode=require"))
                            .onSubmit(applyURL)
                        Button("Fill In", action: applyURL).disabled(url.isEmpty)
                    }
                    if let urlError { Text(urlError).font(.caption).foregroundStyle(.red) }
                }
                Section {
                    Picker("Type", selection: $draft.config.kind) {
                        ForEach(DatabaseKind.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Name", text: $draft.config.name, prompt: Text(draft.config.displayName.isEmpty ? "Optional" : draft.config.displayName))
                }
                if draft.config.kind == .sqlite {
                    Section {
                        HStack {
                            TextField("File", text: Binding(get: { draft.config.file ?? "" }, set: { draft.config.file = $0.isEmpty ? nil : $0 }),
                                      prompt: Text("/path/to/database.sqlite"))
                            Button("Choose…", action: chooseFile)
                        }
                        Toggle("Read-only", isOn: $draft.config.readOnly)
                    }
                } else {
                    Section {
                        TextField("Host", text: $draft.config.host)
                        TextField("Port", text: Binding(get: { draft.config.port.map(String.init) ?? "" }, set: { draft.config.port = Int($0) }),
                                  prompt: Text(String(draft.config.kind.defaultPort)))
                        TextField("User", text: $draft.config.user)
                        SecureField("Password", text: $draft.password)
                        Toggle("Save password in the Keychain", isOn: $draft.savePassword)
                        TextField("Database", text: $draft.config.database, prompt: Text(draft.config.kind == .postgres ? "Same as the user" : "Optional"))
                    }
                    Section {
                        Picker("SSL", selection: $draft.config.sslMode) {
                            ForEach(DatabaseSSLMode.allCases) { Text($0.title).tag($0) }
                        }
                        if draft.config.sslMode == .verifyFull {
                            HStack {
                                TextField("Root certificate", text: Binding(get: { draft.config.rootCertificate ?? "" },
                                                                            set: { draft.config.rootCertificate = $0.isEmpty ? nil : $0 }),
                                          prompt: Text("System roots"))
                                Button("Choose…", action: chooseCertificate)
                            }
                        }
                    }
                }
                Section {
                    Picker("Save in", selection: $draft.config.scope) {
                        Text("This Folder (.omc/databases.json)").tag(DatabaseConnectionConfig.Scope.workspace)
                        Text("All Windows").tag(DatabaseConnectionConfig.Scope.global)
                    }
                    .disabled(!draft.canSaveInWorkspace)
                    if draft.config.scope == .workspace {
                        Text("Shared with the project: no password is written there.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(isTesting ? "Testing…" : "Test Connection", action: test).disabled(isTesting)
                testStatus
                Spacer()
                Button("Cancel") { workspace.database.editing = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!isValid)
            }
            .padding(16)
            if let saveError { Text(saveError).foregroundStyle(.red).font(.callout).padding([.horizontal, .bottom], 16) }
        }
        .frame(width: 520)
        .onAppear {
            if draft.config.scope == .transient { draft.config.scope = .global }
            if !draft.canSaveInWorkspace, draft.config.scope == .workspace { draft.config.scope = .global }
        }
    }

    @ViewBuilder private var testStatus: some View {
        switch testResult {
        case .success(let version)?:
            Label(version, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
        case .failure(let error)?:
            Label(error.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3).help(error.fullMessage)
        default:
            EmptyView()
        }
    }

    private var isValid: Bool {
        draft.config.kind == .sqlite ? !(draft.config.file ?? "").isEmpty : !draft.config.host.isEmpty
    }

    private func applyURL() {
        do {
            var parsed = try DatabaseURL.parse(url, relativeTo: workspace.rootURL)
            parsed.id = draft.config.id
            parsed.name = draft.config.name
            parsed.scope = draft.config.scope
            if let password = parsed.password { draft.password = password }
            parsed.password = nil
            draft.config = parsed
            urlError = nil
        } catch {
            urlError = error.localizedDescription
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.config.file = url.path
    }

    private func chooseCertificate() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.config.rootCertificate = url.path
    }

    private func test() {
        var config = draft.config
        config.password = draft.password
        isTesting = true
        testResult = nil
        Task {
            testResult = await DatabaseWorkspace.test(config)
            isTesting = false
        }
    }

    private func save() {
        do {
            try workspace.database.save(draft.config, password: draft.password, savePassword: draft.savePassword)
            workspace.database.editing = nil
            workspace.database.expanded.insert(draft.config.id.uuidString)
            let id = draft.config.id
            Task { await workspace.database.connect(id) }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: A SQLite file's tab

/// A SQLite file opened from the Explorer: its tables at a glance, with New Query and the
/// hex view still a click away.
struct DatabaseFileView: View {
    let viewer: FileViewer
    let workspace: Workspace

    private var config: DatabaseConnectionConfig? {
        workspace.database.connections.first { $0.kind == .sqlite && $0.file == viewer.url.standardizedFileURL.path }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.teal)
                Text(viewer.fileName).font(.callout.weight(.semibold))
                if let id = config?.id, let version = workspace.database.sessions[id]?.serverVersion {
                    Text(version).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Query") { if let id = config?.id { workspace.database.newQuery(on: id) } }
                    .disabled(config == nil)
                Button("Show in Database Panel") {
                    workspace.sidebarMode = .database
                    workspace.sidebarVisibility = .all
                }
                Button("Open as Hex") { workspace.reopenAsHex(viewer) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 32)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .editorBackground()
        .onAppear {
            if config == nil { workspace.database.openSQLiteFile(viewer.url) }
        }
    }

    @ViewBuilder private var content: some View {
        if let config, let session = workspace.database.sessions[config.id] {
            if let catalog = session.catalog {
                let tables = catalog.allTables
                if tables.isEmpty {
                    ContentUnavailableView("No tables", systemImage: "tablecells", description: Text("This database is empty."))
                } else {
                    List(tables) { table in
                        HStack {
                            Image(systemName: table.kind == .view ? "eye" : "tablecells")
                            Text(table.name)
                            Text("\(table.columns.count) columns").foregroundStyle(.secondary)
                            Spacer()
                            Button("Select Top 100") { workspace.database.selectTop(table, on: config.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } else if case .failed(let message) = session.state {
                ContentUnavailableView {
                    Label("Couldn't open", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Open as Hex") { workspace.reopenAsHex(viewer) }
                }
            } else {
                ProgressView()
            }
        } else {
            ProgressView()
        }
    }
}

extension Workspace {
    /// A database file's tab, as bytes instead.
    func reopenAsHex(_ viewer: FileViewer) {
        let url = viewer.url
        for group in groups where group.contains(viewer.id) { closeViewer(viewer, in: group) }
        openViewer(for: url, kind: .hex)
    }
}
