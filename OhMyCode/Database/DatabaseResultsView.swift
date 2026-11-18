import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A results tab: the run's state and time, a segment per result set (and Messages), and the
/// grid of the one chosen.
struct DatabaseResultsView: View {
    let tab: DatabaseResultsTab
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            DatabaseResultsHeader(tab: tab, workspace: workspace)
            Divider()
            let segments = tab.segments
            if segments.count + (tab.outcomes.isEmpty ? 0 : 1) > 1 {
                Picker("", selection: Binding(get: { min(tab.selectedSegment, segments.count) }, set: { tab.selectedSegment = $0 })) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        Text(segment.title).tag(index)
                    }
                    Text(tab.firstError == nil ? "Messages" : "Messages ⚠︎").tag(segments.count)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .editorBackground()
    }

    @ViewBuilder private var content: some View {
        if case .failed(let message) = tab.state {
            ContentUnavailableView {
                Label("Not run", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Run Again") { workspace.database.rerun(tab) }
            }
        } else if let set = tab.selectedResultSet {
            VStack(spacing: 0) {
                ResultGridView(resultSet: set, dialect: tab.dialect, tableName: set.columns.first?.table ?? "results",
                               identity: "\(tab.startedAt.timeIntervalSince1970)-\(tab.selectedSegment)-\(set.rows.count)")
                Divider()
                ResultFooter(tab: tab, set: set, workspace: workspace)
            }
        } else if tab.isRunning && tab.outcomes.allSatisfy({ $0.execution == nil }) {
            VStack(spacing: 8) {
                ProgressView()
                Text("Running on \(tab.connectionName)…").foregroundStyle(.secondary)
                Button("Cancel") { workspace.database.cancel(tab) }
            }
            .padding()
        } else {
            DatabaseMessagesView(tab: tab, workspace: workspace)
        }
    }
}

/// Connection, time, and the tab's buttons.
private struct DatabaseResultsHeader: View {
    let tab: DatabaseResultsTab
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder").foregroundStyle(.secondary)
            Text(tab.connectionName).font(.callout.weight(.semibold)).lineLimit(1)
            Text(status).font(.callout.monospacedDigit()).foregroundStyle(tab.firstError == nil ? Color.secondary : Color.red).lineLimit(1)
            if tab.isRunning {
                ProgressView().controlSize(.small)
                SwiftUI.TimelineView(.periodic(from: tab.startedAt, by: 0.5)) { context in
                    Text(DatabaseWorkspace.duration(context.date.timeIntervalSince(tab.startedAt)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if tab.isRunning {
                Button { workspace.database.cancel(tab) } label: { Label("Cancel", systemImage: "stop.circle") }
                    .help("Cancel the running query (the server stops it)")
            } else {
                Button { workspace.database.rerun(tab) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Run again")
            }
            Button { tab.isPinned.toggle() } label: { Image(systemName: tab.isPinned ? "pin.fill" : "pin") }
                .help(tab.isPinned ? "Unpin: the next run of this file shows here again" : "Pin: keep these results; the next run opens a new tab")
            if let id = tab.connectionID {
                Button { Task { await workspace.database.showHistory(for: id) } } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Query History")
            }
            Menu {
                Button("Explain Query") { workspace.explainSQL(tab) }
                if tab.firstError != nil, tab.sourceFile != nil {
                    Button("Fix Query with AI") { workspace.fixSQLWithAI(tab) }
                }
            } label: {
                Image(systemName: "sparkles")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!AISettings.shared.isConfigured || tab.outcomes.isEmpty)
            .help(AISettings.shared.isConfigured ? "Explain or fix the query with AI" : AIActions.notConfiguredHelp)
            .popover(item: Binding(get: { tab.explanation }, set: { tab.explanation = $0 }), arrowEdge: .bottom) { model in
                AIExplainView(model: model) { tab.explanation?.stop(); tab.explanation = nil }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var status: String {
        switch tab.state {
        case .running:
            let done = tab.outcomes.filter { $0.execution != nil }.count
            return tab.outcomes.count > 1 ? "Running \(done + 1) of \(tab.outcomes.count)" : "Running"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        case .done:
            let count = tab.outcomes.count
            let summary = count == 1 ? tab.outcomes[0].summary : "\(count) statements"
            return summary + "  ·  " + DatabaseWorkspace.duration(tab.duration)
        }
    }
}

/// Row count, the row-limit notice, export.
private struct ResultFooter: View {
    let tab: DatabaseResultsTab
    let set: DBResultSet
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 10) {
            if set.isTruncated {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text("Showing the first \(set.rows.count.formatted()) of \(set.totalRows.formatted()) rows")
                    .font(.callout.monospacedDigit())
                Button("Fetch More") { workspace.database.rerun(tab, rowLimit: tab.rowLimit * 10) }
                    .help("Run again keeping up to \((tab.rowLimit * 10).formatted()) rows")
            } else {
                Text("\(set.rows.count.formatted()) row\(set.rows.count == 1 ? "" : "s")").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach([DBExport.Format.csv, .json, .markdown, .tsv, .insert]) { format in
                    Button("Export as \(format.rawValue)…") { export(format) }
                }
                Divider()
                ForEach([DBExport.Format.tsv, .csv, .json, .markdown, .insert]) { format in
                    Button("Copy All as \(format.rawValue)") { copy(format) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .themedBackground(.statusBar, fallback: .bar)
    }

    private func text(_ format: DBExport.Format) -> String {
        DBExport.text(set.columns, set.rows, format: format, dialect: tab.dialect,
                      table: tab.dialect.quote(set.columns.first?.table ?? "results"))
    }

    private func copy(_ format: DBExport.Format) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(format), forType: .string)
    }

    private func export(_ format: DBExport.Format) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "results.\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text(format).utf8).write(to: url, options: .atomic)
        } catch {
            workspace.errorMessage = error.localizedDescription
        }
    }
}

/// Each statement's outcome, the server's notices, and the error that stopped the run.
private struct DatabaseMessagesView: View {
    let tab: DatabaseResultsTab
    let workspace: Workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(tab.outcomes) { outcome in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            icon(outcome)
                            Text(outcome.summary).font(.callout.weight(.medium)).textSelection(.enabled)
                            Spacer()
                            if outcome.execution != nil {
                                Text(DatabaseWorkspace.duration(outcome.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Text(outcome.sql.count > 600 ? String(outcome.sql.prefix(600)) + "…" : outcome.sql)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                        if let error = outcome.error {
                            Text(error.fullMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                            if error != .cancelled, AISettings.shared.isConfigured {
                                HStack {
                                    Button("Explain") { workspace.explainSQL(tab) }
                                    if tab.sourceFile != nil { Button("Fix with AI") { workspace.fixSQLWithAI(tab) } }
                                }
                                .controlSize(.small)
                            }
                        }
                        ForEach(Array((outcome.execution?.messages ?? []).enumerated()), id: \.offset) { _, message in
                            Label(message.text, systemImage: message.severity == .warning ? "exclamationmark.triangle" : "info.circle")
                                .font(.callout)
                                .foregroundStyle(message.severity == .warning ? Color.orange : Color.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Divider()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func icon(_ outcome: DBStatementOutcome) -> some View {
        if outcome.isRunning {
            ProgressView().controlSize(.small)
        } else if outcome.execution == nil {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        } else if outcome.error != nil {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

// MARK: The grid

/// A result set in an NSTableView, which only asks for the rows on screen: sortable by any
/// column (here, not on the server), NULL shown apart from text, cells and rows copyable.
struct ResultGridView: NSViewRepresentable {
    let resultSet: DBResultSet
    let dialect: SQLDialect
    let tableName: String
    /// Changes when it's other results (the grid is rebuilt then, not on every redraw).
    let identity: String

    func makeCoordinator() -> ResultGridCoordinator { ResultGridCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultTableView()
        table.coordinator = context.coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.rowHeight = 20
        table.style = .plain
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        context.coordinator.load(resultSet, dialect: dialect, tableName: tableName, identity: identity)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.load(resultSet, dialect: dialect, tableName: tableName, identity: identity)
    }
}

final class ResultTableView: NSTableView {
    weak var coordinator: ResultGridCoordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copyRows(.tsv)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
final class ResultGridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var table: NSTableView?
    private(set) var resultSet = DBResultSet()
    private var dialect = SQLDialect.postgres
    private var tableName = "results"
    private var identity = ""
    /// Row indices in display order (sorted, or as they came).
    private(set) var order: [Int] = []
    private static let numberColumn = NSUserInterfaceItemIdentifier("#")

    func load(_ set: DBResultSet, dialect: SQLDialect, tableName: String, identity: String) {
        guard identity != self.identity, let table else { return }
        self.identity = identity
        resultSet = set
        self.dialect = dialect
        self.tableName = tableName
        order = Array(set.rows.indices)
        for column in table.tableColumns { table.removeTableColumn(column) }
        let numbers = NSTableColumn(identifier: Self.numberColumn)
        numbers.title = ""
        numbers.width = max(32, CGFloat(String(set.rows.count).count) * 8 + 12)
        numbers.isEditable = false
        table.addTableColumn(numbers)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        for (index, column) in set.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
            tableColumn.title = column.name
            tableColumn.headerToolTip = column.typeName.isEmpty ? column.name : "\(column.name) — \(column.typeName)"
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
            let sample = set.rows.prefix(50).map { min(60, $0[safe: index]?.displayText.count ?? 0) }.max() ?? 0
            tableColumn.width = min(420, max(60, CGFloat(max(sample, column.name.count + 2)) * charWidth + 16))
            tableColumn.minWidth = 30
            table.addTableColumn(tableColumn)
        }
        table.sortDescriptors = []
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < order.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCellView ?? ResultCellView(identifier: identifier)
        if tableColumn.identifier == Self.numberColumn {
            cell.show("\(row + 1)", style: .rowNumber)
            return cell
        }
        guard let index = Int(tableColumn.identifier.rawValue), let value = resultSet.rows[order[row]][safe: index] else { return cell }
        cell.show(value.isNull ? "NULL" : String(value.displayText.prefix(500)).replacingOccurrences(of: "\n", with: "⏎"),
                  style: value.isNull ? .null : value.isNumeric ? .number : .text)
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let index = Int(key) else {
            order = Array(resultSet.rows.indices)
            tableView.reloadData()
            return
        }
        let rows = resultSet.rows
        order = Array(rows.indices).sorted { a, b in
            let x = rows[a][safe: index] ?? .null, y = rows[b][safe: index] ?? .null
            if x == y { return a < b }
            return descriptor.ascending ? DBValue.ordered(x, y) : DBValue.ordered(y, x)
        }
        tableView.reloadData()
    }

    // MARK: Copying

    private var selectedRows: [[DBValue]] {
        guard let table else { return [] }
        var indexes = table.selectedRowIndexes
        if table.clickedRow >= 0, !indexes.contains(table.clickedRow) { indexes = IndexSet(integer: table.clickedRow) }
        return indexes.compactMap { $0 < order.count ? resultSet.rows[order[$0]] : nil }
    }

    func copyRows(_ format: DBExport.Format) {
        let rows = selectedRows
        guard !rows.isEmpty else { return }
        let text: String
        switch format {
        case .tsv: text = DBExport.tsv(resultSet.columns, rows, header: false)
        default: text = DBExport.text(resultSet.columns, rows, format: format, dialect: dialect, table: dialect.quote(tableName))
        }
        Self.copy(text)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, table.clickedRow >= 0 else { return }
        let column = table.clickedColumn >= 0 ? table.tableColumns[table.clickedColumn] : nil
        if let column, let index = Int(column.identifier.rawValue), let value = resultSet.rows[order[table.clickedRow]][safe: index] {
            menu.addItem(item("Copy Value") { Self.copy(value.isNull ? "NULL" : value.displayText) })
            menu.addItem(item("Copy Column Name") { Self.copy(column.title) })
            menu.addItem(.separator())
        }
        let count = selectedRows.count
        let rows = count == 1 ? "Row" : "\(count) Rows"
        menu.addItem(item("Copy \(rows)") { [weak self] in self?.copyRows(.tsv) })
        menu.addItem(item("Copy \(rows) with Header") { [weak self] in
            guard let self else { return }
            Self.copy(DBExport.tsv(resultSet.columns, selectedRows, header: true))
        })
        menu.addItem(item("Copy \(rows) as JSON") { [weak self] in self?.copyRows(.json) })
        menu.addItem(item("Copy \(rows) as INSERT") { [weak self] in self?.copyRows(.insert) })
        menu.addItem(item("Copy \(rows) as CSV") { [weak self] in self?.copyRows(.csv) })
    }

    private func item(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        ClosureMenuItem(title) { MainActor.assumeIsolated { action() } }
    }
}

final class ResultCellView: NSTableCellView {
    enum Style { case text, number, null, rowNumber }

    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, style: Style) {
        label.stringValue = text
        switch style {
        case .null:
            label.font = NSFontManager.shared.convert(.monospacedSystemFont(ofSize: 11, weight: .regular), toHaveTrait: .italicFontMask)
            label.textColor = .tertiaryLabelColor
            label.alignment = .left
        case .number:
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .labelColor
            label.alignment = .right
        case .rowNumber:
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
        case .text:
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .labelColor
            label.alignment = .left
        }
    }
}
