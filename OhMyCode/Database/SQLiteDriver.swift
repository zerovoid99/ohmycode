import Foundation
import SQLite3

/// A SQLite file through the system's libsqlite3. Calls run on a queue of its own (the
/// handle is used from one thread at a time); `cancel()` interrupts from anywhere.
final class SQLiteDriver: DatabaseDriver, @unchecked Sendable {
    let kind = DatabaseKind.sqlite
    let path: String
    private let queue = DispatchQueue(label: "omc.database.sqlite")
    /// Only touched on `queue`, apart from `sqlite3_interrupt` (which is safe from any thread).
    private var db: OpaquePointer?
    private let interruptLock = NSLock()

    init(config: DatabaseConnectionConfig) throws {
        guard let file = config.file, !file.isEmpty else { throw DBError.connection("No SQLite file chosen.") }
        path = (file as NSString).expandingTildeInPath
        if config.readOnly, !FileManager.default.fileExists(atPath: path) {
            throw DBError.connection("There's no file at \(path).")
        }
        let flags = config.readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "error \(status)"
            sqlite3_close(handle)
            throw DBError.connection("Couldn't open \(path): \(message)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        sqlite3_extended_result_codes(handle, 1)
        // Make sure it is a database (opening never reads the file).
        var statement: OpaquePointer?
        let check = sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_schema", -1, &statement, nil)
        sqlite3_finalize(statement)
        if check != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            db = nil
            throw DBError.connection("\((path as NSString).lastPathComponent): \(message)")
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    var serverVersion: String { get async { "SQLite " + String(cString: sqlite3_libversion()) } }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    func cancel() {
        interruptLock.withLock {
            if let db { sqlite3_interrupt(db) }
        }
    }

    func close() async {
        _ = try? await onQueue { [self] in
            interruptLock.withLock {
                if let db { sqlite3_close_v2(db) }
                db = nil
            }
        }
    }

    func run(_ sql: String, rowLimit: Int) async throws -> DBExecution {
        try await withTaskCancellationHandler {
            try await onQueue { [self] in try execute(sql, rowLimit: rowLimit) }
        } onCancel: {
            cancel()
        }
    }

    /// Prepares and steps each statement of `sql` in turn (a result set for each).
    private func execute(_ sql: String, rowLimit: Int) throws -> DBExecution {
        guard let db else { throw DBError.connection("The database is closed.") }
        var execution = DBExecution()
        let utf8 = Array(sql.utf8CString)
        utf8.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var tail: UnsafePointer<CChar>? = base
            while let current = tail, current.pointee != 0 {
                var statement: OpaquePointer?
                var next: UnsafePointer<CChar>?
                let status = sqlite3_prepare_v2(db, current, -1, &statement, &next)
                let startByte = base.distance(to: current)
                if status != SQLITE_OK {
                    execution.error = error(db, sql: sql, statementStart: startByte, prepare: true)
                    sqlite3_finalize(statement)
                    return
                }
                tail = next
                guard let statement else { continue } // only whitespace or a comment
                defer { sqlite3_finalize(statement) }
                let changesBefore = sqlite3_total_changes64(db)
                var set = DBResultSet()
                let count = Int(sqlite3_column_count(statement))
                var declared: [String] = []
                for i in 0..<count {
                    let name = sqlite3_column_name(statement, Int32(i)).map { String(cString: $0) } ?? "?"
                    let type = sqlite3_column_decltype(statement, Int32(i)).map { String(cString: $0) } ?? ""
                    declared.append(type.uppercased())
                    set.columns.append(DBColumn(name: name, typeName: type,
                                                table: sqlite3_column_table_name(statement, Int32(i)).map { String(cString: $0) }))
                }
                var typedColumns = Array(repeating: false, count: count)
                while true {
                    let step = sqlite3_step(statement)
                    if step == SQLITE_ROW {
                        set.totalRows += 1
                        if set.rows.count < rowLimit {
                            var row: [DBValue] = []
                            row.reserveCapacity(count)
                            for i in 0..<count {
                                let value = Self.value(statement, Int32(i), declared: declared[i])
                                // A column without a declared type (an expression): name it by what it holds.
                                if !typedColumns[i], declared[i].isEmpty, value != .null {
                                    set.columns[i].typeName = Self.typeName(sqlite3_column_type(statement, Int32(i)))
                                    typedColumns[i] = true
                                }
                                row.append(value)
                            }
                            set.rows.append(row)
                        }
                    } else if step == SQLITE_DONE {
                        break
                    } else {
                        if step == SQLITE_INTERRUPT {
                            execution.error = .cancelled
                        } else {
                            execution.error = error(db, sql: sql, statementStart: startByte, prepare: false)
                        }
                        if count > 0 { execution.resultSets.append(set) }
                        return
                    }
                }
                if count == 0 {
                    // Rows changed for DML; the verb (CREATE, PRAGMA…) for the rest.
                    let changed = sqlite3_total_changes64(db) - changesBefore
                    let text = sqlite3_sql(statement).map { String(cString: $0) } ?? ""
                    let verb = text.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first?.uppercased() ?? ""
                    if changed > 0 || ["INSERT", "UPDATE", "DELETE", "REPLACE"].contains(verb) {
                        set.affectedRows = Int(changed)
                    } else {
                        set.command = verb
                    }
                }
                execution.resultSets.append(set)
            }
        }
        return execution
    }

    private func error(_ db: OpaquePointer, sql: String, statementStart: Int, prepare: Bool) -> DBError {
        let code = sqlite3_extended_errcode(db)
        let message = String(cString: sqlite3_errmsg(db))
        var position: Int?
        let offset = sqlite3_error_offset(db)
        if offset >= 0 {
            position = sql.utf16Offset(ofUTF8: Int(offset) + statementStart)
        } else {
            // "no such table: x" comes without an offset: the name's first use in the statement.
            let start = sql.utf16Offset(ofUTF8: statementStart)
            position = start
            if let colon = message.range(of: ": ", options: .backwards) {
                let name = String(message[colon.upperBound...]).split(separator: ".").last.map(String.init) ?? ""
                let ns = sql as NSString
                let found = ns.range(of: name, options: .caseInsensitive, range: NSRange(location: start, length: ns.length - start))
                if !name.isEmpty, found.location != NSNotFound { position = found.location }
            }
        }
        if code == SQLITE_INTERRUPT { return .cancelled }
        return DBError(message, code: String(cString: sqlite3_errstr(code)), position: position)
    }

    private static func typeName(_ type: Int32) -> String {
        switch type {
        case SQLITE_INTEGER: "INTEGER"
        case SQLITE_FLOAT: "REAL"
        case SQLITE_BLOB: "BLOB"
        case SQLITE_NULL: ""
        default: "TEXT"
        }
    }

    private static func value(_ statement: OpaquePointer, _ i: Int32, declared: String) -> DBValue {
        switch sqlite3_column_type(statement, i) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            let value = sqlite3_column_int64(statement, i)
            if declared.hasPrefix("BOOL") { return .bool(value != 0) }
            return .int(value)
        case SQLITE_FLOAT:
            return .float(sqlite3_column_double(statement, i))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, i))
            guard count > 0, let bytes = sqlite3_column_blob(statement, i) else { return .bytes(Data()) }
            return .bytes(Data(bytes: bytes, count: count))
        default:
            let text = sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
            if declared.contains("DATE") || declared.contains("TIME") { return .date(text) }
            if declared.contains("JSON") { return .json(text) }
            if declared.hasPrefix("NUMERIC") || declared.hasPrefix("DECIMAL") { return .decimal(text) }
            return .text(text)
        }
    }

    // MARK: Schema

    private func rows(_ sql: String) throws -> [[DBValue]] {
        let execution = try execute(sql, rowLimit: .max)
        if let error = execution.error { throw error }
        return execution.resultSets.first?.rows ?? []
    }

    func catalog() async throws -> DBCatalog {
        try await onQueue { [self] in
            var tables: [DBTable] = []
            let objects = try rows("SELECT name, type FROM sqlite_schema WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name")
            for object in objects {
                let name = object[0].plainText
                var table = DBTable(schema: "main", name: name, kind: object[1].plainText == "view" ? .view : .table)
                let quoted = SQLDialect.sqlite.literal(name)
                for column in try rows("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_xinfo(\(quoted)) WHERE hidden IN (0, 2, 3)") {
                    table.columns.append(DBColumnInfo(name: column[0].plainText, type: column[1].plainText,
                                                      isNullable: column[2] != .int(1), defaultValue: column[3].isNull ? nil : column[3].plainText,
                                                      isPrimaryKey: (column[4].number ?? 0) > 0))
                }
                if table.kind == .table {
                    for index in try rows("SELECT name, \"unique\", origin FROM pragma_index_list(\(quoted))") {
                        let indexName = index[0].plainText
                        let columns = try rows("SELECT name FROM pragma_index_info(\(SQLDialect.sqlite.literal(indexName))) ORDER BY seqno").map { $0[0].plainText }
                        table.indexes.append(DBIndex(name: indexName, columns: columns, isUnique: index[1] == .int(1),
                                                     isPrimary: index[2].plainText == "pk"))
                    }
                    var keys: [Int64: DBForeignKey] = [:]
                    for key in try rows("SELECT id, \"table\", \"from\", \"to\" FROM pragma_foreign_key_list(\(quoted)) ORDER BY id, seq") {
                        guard case .int(let id) = key[0] else { continue }
                        var foreign = keys[id] ?? DBForeignKey(name: "fk_\(name)_\(id)", columns: [], referencedSchema: "main",
                                                               referencedTable: key[1].plainText, referencedColumns: [])
                        foreign.columns.append(key[2].plainText)
                        foreign.referencedColumns.append(key[3].plainText)
                        keys[id] = foreign
                    }
                    table.foreignKeys = keys.keys.sorted().compactMap { keys[$0] }
                }
                tables.append(table)
            }
            return DBCatalog(schemas: [DBSchema(name: "main", tables: tables)], defaultSchema: "main")
        }
    }

    func ddl(for table: DBTable) async throws -> String {
        let name = table.name
        return try await onQueue { [self] in
            let found = try rows("SELECT sql FROM sqlite_schema WHERE name = \(SQLDialect.sqlite.literal(name)) OR tbl_name = \(SQLDialect.sqlite.literal(name)) ORDER BY type = 'index', name")
            return found.compactMap { $0[0].isNull ? nil : $0[0].plainText + ";" }.joined(separator: "\n\n")
        }
    }
}
