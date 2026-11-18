import Foundation

// MARK: Connections

enum DatabaseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sqlite, postgres, mysql

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sqlite: "SQLite"
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL / MariaDB"
        }
    }

    var defaultPort: Int {
        switch self {
        case .sqlite: 0
        case .postgres: 5432
        case .mysql: 3306
        }
    }

    var dialect: SQLDialect {
        switch self {
        case .sqlite: .sqlite
        case .postgres: .postgres
        case .mysql: .mysql
        }
    }
}

/// How a server connection uses TLS, as libpq names it (MySQL's modes map onto these).
enum DatabaseSSLMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Never.
    case disable
    /// When the server offers it, without checking its certificate.
    case prefer
    /// Always, without checking the certificate.
    case require
    /// Always, with the certificate checked against the trusted roots (or `rootCertificate`)
    /// and the host name.
    case verifyFull = "verify-full"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disable: "Disable"
        case .prefer: "Prefer"
        case .require: "Require"
        case .verifyFull: "Verify Full"
        }
    }

    /// From a URL's `sslmode` / `ssl-mode` / `ssl` value (libpq's and MySQL's names).
    init?(parameter: String) {
        switch parameter.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "disable", "disabled", "false", "0", "off": self = .disable
        case "allow", "prefer", "preferred": self = .prefer
        case "require", "required", "true", "1", "on": self = .require
        case "verify-ca", "verify-full", "verify-identity": self = .verifyFull
        default: return nil
        }
    }
}

/// A saved connection. The password is never written with it: it's in the Keychain.
struct DatabaseConnectionConfig: Codable, Equatable, Identifiable, Hashable, Sendable {
    enum Scope: String, Codable, Sendable {
        /// In the folder's `.omc/databases.json` (can be shared with the project).
        case workspace
        /// In Application Support: every window lists it.
        case global
        /// Opened for now (a SQLite file from the Explorer): not saved.
        case transient
    }

    var id = UUID()
    var name = ""
    var kind: DatabaseKind
    var host = "127.0.0.1"
    var port: Int?
    var user = ""
    var database = ""
    var sslMode = DatabaseSSLMode.prefer
    /// A PEM file of the certificate authority to trust for verify-full.
    var rootCertificate: String?
    /// The SQLite file.
    var file: String?
    var readOnly = false
    /// Not saved with it (the Keychain has it); set when parsed from a URL or typed in.
    var password: String?
    var scope = Scope.global

    enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, user, database, sslMode, rootCertificate, file, readOnly
    }

    init(kind: DatabaseKind) {
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decode(DatabaseKind.self, forKey: .kind)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        database = try c.decodeIfPresent(String.self, forKey: .database) ?? ""
        sslMode = (try? c.decodeIfPresent(DatabaseSSLMode.self, forKey: .sslMode)) ?? .prefer
        rootCertificate = try c.decodeIfPresent(String.self, forKey: .rootCertificate)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        if kind == .sqlite {
            try c.encodeIfPresent(file, forKey: .file)
        } else {
            try c.encode(host, forKey: .host)
            try c.encodeIfPresent(port, forKey: .port)
            try c.encode(user, forKey: .user)
            try c.encode(database, forKey: .database)
            try c.encode(sslMode, forKey: .sslMode)
            try c.encodeIfPresent(rootCertificate, forKey: .rootCertificate)
        }
        if readOnly { try c.encode(readOnly, forKey: .readOnly) }
    }

    var effectivePort: Int { port ?? kind.defaultPort }

    /// The name shown: the given one, else what it connects to.
    var displayName: String {
        if !name.isEmpty { return name }
        if kind == .sqlite { return file.map { ($0 as NSString).lastPathComponent } ?? "SQLite" }
        let db = database.isEmpty ? "" : "/\(database)"
        return "\(user.isEmpty ? "" : user + "@")\(host)\(db)"
    }

    /// What it connects to, for tooltips and the header (no password).
    var summary: String {
        if kind == .sqlite { return (file ?? "") + (readOnly ? " (read-only)" : "") }
        return "\(kind.title) · \(user.isEmpty ? "" : user + "@")\(host):\(effectivePort)\(database.isEmpty ? "" : "/" + database)"
    }

    /// As a URL (without the password), for Copy URL and history.
    var urlString: String {
        if kind == .sqlite { return "sqlite://" + (file ?? "") }
        var components = URLComponents()
        components.scheme = kind == .postgres ? "postgres" : "mysql"
        components.user = user.isEmpty ? nil : user
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.path = database.isEmpty ? "" : "/" + database
        var items = [URLQueryItem(name: "sslmode", value: sslMode.rawValue)]
        if let rootCertificate { items.append(URLQueryItem(name: "sslrootcert", value: rootCertificate)) }
        components.queryItems = items
        return components.string ?? ""
    }
}

struct DatabaseURLError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Connection strings: `postgres://user:pass@host:5432/db?sslmode=require`, `mysql://…`
/// (`mariadb://`), `sqlite:///path/to/file.db` or a plain file path.
enum DatabaseURL {
    static func parse(_ input: String, relativeTo base: URL? = nil) throws -> DatabaseConnectionConfig {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DatabaseURLError(message: "Empty connection string.") }
        let lower = text.lowercased()
        if lower.hasPrefix("sqlite:") || lower.hasPrefix("file:") || !text.contains("://") {
            return try sqlite(text, relativeTo: base)
        }
        guard let schemeEnd = text.range(of: "://") else { throw DatabaseURLError(message: "Not a connection URL: \(text)") }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        let kind: DatabaseKind
        switch scheme {
        case "postgres", "postgresql", "pgsql": kind = .postgres
        case "mysql", "mariadb", "mysqlx": kind = .mysql
        default: throw DatabaseURLError(message: "Unknown database type “\(scheme)”: use postgres://, mysql:// or sqlite://.")
        }
        // URLComponents wants a scheme it can parse the authority of: give it a neutral one.
        guard let components = URLComponents(string: "db" + text[schemeEnd.lowerBound...]) else {
            throw DatabaseURLError(message: "Not a valid connection URL (a password with “@”, “/” or “:” must be percent-encoded).")
        }
        var config = DatabaseConnectionConfig(kind: kind)
        var host = components.percentEncodedHost.map { $0.removingPercentEncoding ?? $0 } ?? ""
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        config.host = host.isEmpty ? "127.0.0.1" : host
        config.port = components.port
        config.user = components.percentEncodedUser.map { $0.removingPercentEncoding ?? $0 } ?? ""
        config.password = components.percentEncodedPassword.map { $0.removingPercentEncoding ?? $0 }
        let path = components.percentEncodedPath
        config.database = String(path.drop { $0 == "/" }).removingPercentEncoding ?? ""
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "sslmode", "ssl-mode", "ssl_mode", "ssl", "tls", "useSSL".lowercased():
                guard let mode = DatabaseSSLMode(parameter: value) else {
                    throw DatabaseURLError(message: "Unknown SSL mode “\(value)”.")
                }
                config.sslMode = mode
            case "sslrootcert", "ssl-ca", "sslca": config.rootCertificate = value
            case "user": config.user = value
            case "password": config.password = value
            case "host": config.host = value
            case "port": config.port = Int(value)
            case "dbname", "database": config.database = value
            default: break
            }
        }
        if let port = config.port, !(1...65535).contains(port) {
            throw DatabaseURLError(message: "Port \(port) is out of range.")
        }
        return config
    }

    private static func sqlite(_ text: String, relativeTo base: URL?) throws -> DatabaseConnectionConfig {
        var config = DatabaseConnectionConfig(kind: .sqlite)
        var path = text
        var query = ""
        if let question = path.firstIndex(of: "?"), path.lowercased().hasPrefix("sqlite:") || path.lowercased().hasPrefix("file:") {
            query = String(path[path.index(after: question)...])
            path = String(path[..<question])
        }
        for prefix in ["sqlite3://", "sqlite://", "sqlite:", "file://", "file:"] where path.lowercased().hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
            break
        }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        guard !path.isEmpty else { throw DatabaseURLError(message: "A SQLite connection needs a file path.") }
        if !path.hasPrefix("/"), let base { path = base.appending(path: path).standardizedFileURL.path }
        config.file = path
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1].lowercased() : ""
            if parts[0] == "mode", value == "ro" { config.readOnly = true }
            if parts[0] == "readonly" || parts[0] == "read_only", value != "0" && value != "false" { config.readOnly = true }
        }
        return config
    }
}

// MARK: Results

/// One cell, as the server sent it (typed by the column's type).
enum DBValue: Sendable, Equatable, Hashable {
    case null
    case text(String)
    case int(Int64)
    case float(Double)
    /// Exact numbers (NUMERIC, DECIMAL): kept as written.
    case decimal(String)
    case bool(Bool)
    case bytes(Data)
    /// Dates, times, timestamps, intervals: as the server wrote them.
    case date(String)
    case json(String)

    var isNull: Bool { self == .null }

    /// For the grid and copying (bytes as hex, `NULL` only for null).
    var displayText: String {
        switch self {
        case .null: "NULL"
        case .text(let s), .decimal(let s), .date(let s), .json(let s): s
        case .int(let i): String(i)
        case .float(let d): Self.format(d)
        case .bool(let b): b ? "true" : "false"
        case .bytes(let data): "0x" + data.prefix(4096).map { String(format: "%02x", $0) }.joined() + (data.count > 4096 ? "…" : "")
        }
    }

    /// For CSV and TSV: null is empty.
    var plainText: String { isNull ? "" : displayText }

    var isNumeric: Bool {
        switch self {
        case .int, .float, .decimal: true
        default: false
        }
    }

    static func format(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    /// Orders cells for sorting a column: nulls first, numbers by value, the rest by text.
    static func ordered(_ a: DBValue, _ b: DBValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return false
        case (.null, _): return true
        case (_, .null): return false
        default: break
        }
        if let x = a.number, let y = b.number { return x < y }
        if case .bool(let x) = a, case .bool(let y) = b { return !x && y }
        return a.displayText.localizedStandardCompare(b.displayText) == .orderedAscending
    }

    var number: Double? {
        switch self {
        case .int(let i): Double(i)
        case .float(let d): d
        case .decimal(let s): Double(s)
        default: nil
        }
    }
}

struct DBColumn: Sendable, Equatable, Hashable {
    var name: String
    /// The server's name for its type (`int4`, `VARCHAR`, `TEXT`…).
    var typeName: String
    var table: String?

    init(name: String, typeName: String, table: String? = nil) {
        self.name = name
        self.typeName = typeName
        self.table = table
    }
}

/// One statement's answer: rows (for a query) or a count of changed rows.
struct DBResultSet: Sendable, Equatable {
    var columns: [DBColumn] = []
    var rows: [[DBValue]] = []
    /// Rows changed (INSERT/UPDATE/DELETE…), when the server says.
    var affectedRows: Int?
    /// The server's command tag (`SELECT 3`, `INSERT 0 1`), for Postgres.
    var command: String?
    /// Rows the server sent: more than `rows` holds when it stopped at the row limit.
    var totalRows = 0
    var isTruncated: Bool { totalRows > rows.count }
    var hasRows: Bool { !columns.isEmpty }
}

struct DBMessage: Sendable, Equatable {
    enum Severity: String, Sendable { case info, notice, warning }
    var severity: Severity
    var text: String
}

/// A statement's error, or not being able to connect.
struct DBError: Error, LocalizedError, Sendable, Equatable {
    var message: String
    /// SQLSTATE (or the server's error number) when there is one.
    var code: String?
    /// Where in the statement it went wrong: a UTF-16 offset into the text sent.
    var position: Int?
    var detail: String?
    var hint: String?
    /// The connection failed or was lost (rather than a statement).
    var isConnectionError = false

    init(_ message: String, code: String? = nil, position: Int? = nil, detail: String? = nil, hint: String? = nil,
         isConnectionError: Bool = false) {
        self.message = message
        self.code = code
        self.position = position
        self.detail = detail
        self.hint = hint
        self.isConnectionError = isConnectionError
    }

    static func connection(_ message: String) -> DBError { DBError(message, isConnectionError: true) }
    static let cancelled = DBError("Cancelled.", code: "57014")

    var errorDescription: String? { fullMessage }

    var fullMessage: String {
        var text = message
        if let code { text += " (\(code))" }
        if let detail, !detail.isEmpty { text += "\n" + detail }
        if let hint, !hint.isEmpty { text += "\nHint: " + hint }
        return text
    }
}

/// What running some SQL gave: a result set per statement, the server's notices, and the
/// error that stopped it (after the result sets before it).
struct DBExecution: Sendable, Equatable {
    var resultSets: [DBResultSet] = []
    var messages: [DBMessage] = []
    var error: DBError?
}

// MARK: Schema

struct DBColumnInfo: Sendable, Equatable, Hashable, Identifiable {
    var name: String
    var type: String
    var isNullable = true
    var defaultValue: String?
    var isPrimaryKey = false
    var id: String { name }
}

struct DBIndex: Sendable, Equatable, Hashable, Identifiable {
    var name: String
    var columns: [String]
    var isUnique = false
    var isPrimary = false
    var id: String { name }
}

struct DBForeignKey: Sendable, Equatable, Hashable, Identifiable {
    var name: String
    var columns: [String]
    var referencedSchema: String?
    var referencedTable: String
    var referencedColumns: [String]
    var id: String { name }
}

struct DBTable: Sendable, Equatable, Hashable, Identifiable {
    enum Kind: String, Sendable { case table, view }
    var schema: String
    var name: String
    var kind = Kind.table
    var columns: [DBColumnInfo] = []
    var indexes: [DBIndex] = []
    var foreignKeys: [DBForeignKey] = []
    var id: String { schema + "." + name }

    func isForeignKey(_ column: String) -> Bool { foreignKeys.contains { $0.columns.contains(column) } }
}

struct DBSchema: Sendable, Equatable, Identifiable {
    var name: String
    var tables: [DBTable] = []
    var id: String { name }
}

/// What a connection's database holds (user schemas only).
struct DBCatalog: Sendable, Equatable {
    var schemas: [DBSchema] = []
    /// The schema unqualified names mean (`public`, the MySQL database, `main`).
    var defaultSchema: String?

    var allTables: [DBTable] { schemas.flatMap(\.tables) }

    func table(named name: String, schema: String? = nil) -> DBTable? {
        let lower = name.lowercased()
        let candidates = allTables.filter { $0.name.lowercased() == lower }
        if let schema { return candidates.first { $0.schema.lowercased() == schema.lowercased() } }
        return candidates.first { $0.schema == defaultSchema } ?? candidates.first
    }
}

// MARK: Drivers

/// A connection to one database. Runs one thing at a time; `cancel()` may be called from
/// anywhere while something runs.
protocol DatabaseDriver: AnyObject, Sendable {
    var kind: DatabaseKind { get }
    /// Runs `sql` (one statement, or several where the server allows), keeping at most
    /// `rowLimit` rows of each result (the rest are read and counted). Statement errors come
    /// back in the execution; a lost connection throws.
    func run(_ sql: String, rowLimit: Int) async throws -> DBExecution
    /// Stops what's running (the server's own cancel: a query keeps running otherwise).
    func cancel()
    func catalog() async throws -> DBCatalog
    /// The CREATE statement (or a description) of a table or view.
    func ddl(for table: DBTable) async throws -> String
    var serverVersion: String { get async }
    func close() async
}

enum DatabaseDrivers {
    /// Connects (and signs in).
    static func connect(_ config: DatabaseConnectionConfig) async throws -> any DatabaseDriver {
        switch config.kind {
        case .sqlite: try SQLiteDriver(config: config)
        case .postgres: try await PostgresDriver.connect(config)
        case .mysql: try await MySQLDriver.connect(config)
        }
    }
}

// MARK: Quoting

extension SQLDialect {
    /// An identifier quoted when it needs to be.
    func quote(_ identifier: String) -> String {
        let plain = identifier.first.map { $0.isLetter || $0 == "_" } ?? false
            && identifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && (self == .mysql || identifier == identifier.lowercased() || self == .sqlite)
            && !SQLKeywords.reserved.contains(identifier.uppercased())
        if plain { return identifier }
        switch self {
        case .mysql: return "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
        default: return "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    func qualified(_ table: DBTable, defaultSchema: String?) -> String {
        if self == .sqlite && table.schema == "main" || table.schema == defaultSchema || table.schema.isEmpty {
            return quote(table.name)
        }
        return quote(table.schema) + "." + quote(table.name)
    }

    /// A string literal.
    func literal(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "'", with: "''")
        if self == .mysql { escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + escaped + "'"
    }

    /// A cell as a literal for an INSERT.
    func literal(_ value: DBValue) -> String {
        switch value {
        case .null: return "NULL"
        case .int, .float, .decimal: return value.displayText
        case .bool(let b): return self == .sqlite ? (b ? "1" : "0") : (b ? "TRUE" : "FALSE")
        case .bytes(let data):
            let hex = data.map { String(format: "%02x", $0) }.joined()
            switch self {
            case .postgres: return "'\\x\(hex)'::bytea"
            case .mysql: return data.isEmpty ? "''" : "0x" + hex
            case .sqlite: return "X'\(hex)'"
            }
        case .text(let s), .date(let s), .json(let s): return literal(s)
        }
    }
}

extension String {
    /// The UTF-16 offset of the `index`th Unicode scalar (Postgres reports positions in
    /// characters of the query).
    func utf16Offset(ofScalar index: Int) -> Int {
        var offset = 0
        var count = 0
        for scalar in unicodeScalars {
            if count == index { return offset }
            offset += scalar.utf16.count
            count += 1
        }
        return offset
    }

    /// The UTF-16 offset of a UTF-8 byte offset (SQLite's error offsets).
    func utf16Offset(ofUTF8 byteOffset: Int) -> Int {
        var bytes = 0
        var offset = 0
        for scalar in unicodeScalars {
            if bytes >= byteOffset { return offset }
            bytes += scalar.utf8.count
            offset += scalar.utf16.count
        }
        return offset
    }
}
