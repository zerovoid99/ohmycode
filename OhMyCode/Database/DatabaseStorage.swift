import AppKit
import Foundation
import Security

/// Where the database explorer keeps what isn't the project's: the connections every window
/// lists, query history and which connection each SQL file uses.
enum DatabaseStorage {
    @MainActor static var root: URL {
        AppSettings.isRunningTests
            ? FileManager.default.temporaryDirectory.appending(path: "omc-test-databases-\(ProcessInfo.processInfo.processIdentifier)")
            : URL.omcApplicationSupport.appending(path: "OhMyCode/Databases")
    }

    /// A folder's own connections (shared with whoever opens the folder; no passwords).
    static func workspaceFile(in folder: URL) -> URL {
        folder.appending(path: ".omc/databases.json")
    }

    private struct File: Codable {
        var connections: [DatabaseConnectionConfig]
    }

    static func load(_ file: URL, scope: DatabaseConnectionConfig.Scope) -> [DatabaseConnectionConfig] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoded = (try? JSONDecoder().decode(File.self, from: data).connections)
            ?? (try? JSONDecoder().decode([DatabaseConnectionConfig].self, from: data)) ?? []
        return decoded.map { config in
            var config = config
            config.scope = scope
            return config
        }
    }

    static func save(_ connections: [DatabaseConnectionConfig], to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(File(connections: connections))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

// MARK: Passwords

/// Where connection passwords are kept: the Keychain, or memory (tests, OMC_SUPPORT_DIR).
@MainActor
protocol DatabasePasswordStore: AnyObject {
    func password(for id: UUID) -> String?
    /// nil or empty removes it.
    func setPassword(_ password: String?, for id: UUID) throws
}

@MainActor
final class KeychainDatabasePasswords: DatabasePasswordStore {
    static let service = "dev.zerovoid99.ohmycode.database"

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: id.uuidString]
    }

    func password(for id: UUID) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String?, for id: UUID) throws {
        let base = query(id)
        guard let password, !password.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainKeyStore.KeychainError(status: status) }
            return
        }
        let data = Data(password.utf8)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Oh My Code database connection"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainKeyStore.KeychainError(status: status) }
    }
}

@MainActor
final class InMemoryDatabasePasswords: DatabasePasswordStore {
    private var passwords: [UUID: String] = [:]
    func password(for id: UUID) -> String? { passwords[id] }
    func setPassword(_ password: String?, for id: UUID) throws {
        passwords[id] = password?.isEmpty == false ? password : nil
    }
}

enum DatabasePasswords {
    /// Under tests and with OMC_SUPPORT_DIR: in memory, never the user's Keychain.
    @MainActor static let shared: DatabasePasswordStore = AppSettings.isRunningTests || UserDefaults.isolated
        ? InMemoryDatabasePasswords() : KeychainDatabasePasswords()
}

// MARK: History

struct DatabaseHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var sql: String
    /// Seconds.
    var duration: Double
    var rows: Int?
    var affectedRows: Int?
    var error: String?
    var file: URL?
}

/// A connection's last queries (newest first), kept between launches.
@MainActor
final class DatabaseHistory {
    static let limit = 100
    let file: URL?
    private(set) var entries: [DatabaseHistoryEntry] = []

    init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([DatabaseHistoryEntry].self, from: data)) ?? []
    }

    func add(_ entry: DatabaseHistoryEntry) {
        // The same statement again moves to the top instead of filling the list.
        entries.removeAll { $0.sql == entry.sql }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: Export

/// A result set as text: CSV, TSV, JSON, Markdown or INSERT statements.
enum DBExport {
    enum Format: String, CaseIterable, Identifiable {
        case csv = "CSV", json = "JSON", markdown = "Markdown", tsv = "TSV", insert = "SQL INSERT"
        var id: String { rawValue }
        var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .json: "json"
            case .markdown: "md"
            case .tsv: "tsv"
            case .insert: "sql"
            }
        }
    }

    static func text(_ columns: [DBColumn], _ rows: [[DBValue]], format: Format, dialect: SQLDialect = .postgres,
                     table: String = "results") -> String {
        switch format {
        case .csv: csv(columns, rows)
        case .tsv: tsv(columns, rows, header: true)
        case .json: json(columns, rows)
        case .markdown: markdown(columns, rows)
        case .insert: inserts(columns, rows, dialect: dialect, table: table)
        }
    }

    /// RFC 4180: fields with commas, quotes or line breaks quoted; null is empty.
    static func csv(_ columns: [DBColumn], _ rows: [[DBValue]]) -> String {
        func field(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        var lines = [columns.map { field($0.name) }.joined(separator: ",")]
        lines += rows.map { $0.map { field($0.plainText) }.joined(separator: ",") }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Tabs and line breaks inside values become spaces (spreadsheets paste it as cells).
    static func tsv(_ columns: [DBColumn], _ rows: [[DBValue]], header: Bool) -> String {
        func field(_ text: String) -> String {
            text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = header ? [columns.map { field($0.name) }.joined(separator: "\t")] : []
        lines += rows.map { $0.map { field($0.plainText) }.joined(separator: "\t") }
        return lines.joined(separator: "\n")
    }

    /// An array of objects; JSON cells are embedded as JSON, bytes as hex strings.
    static func json(_ columns: [DBColumn], _ rows: [[DBValue]]) -> String {
        let names = uniqueNames(columns)
        let objects = rows.map { row in
            "  {" + zip(names, row).map { name, value in "\"\(escape(name))\": \(jsonValue(value))" }.joined(separator: ", ") + "}"
        }
        return objects.isEmpty ? "[]\n" : "[\n" + objects.joined(separator: ",\n") + "\n]\n"
    }

    static func jsonValue(_ value: DBValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .float(let d): return d.isFinite ? DBValue.format(d) : "\"\(DBValue.format(d))\""
        case .decimal(let s): return Double(s) != nil && !s.contains(where: { $0.isLetter }) ? s : "\"\(escape(s))\""
        case .json(let s):
            let data = Data(s.utf8)
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil ? s : "\"\(escape(s))\""
        case .text(let s), .date(let s): return "\"\(escape(s))\""
        case .bytes: return "\"\(escape(value.displayText))\""
        }
    }

    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func markdown(_ columns: [DBColumn], _ rows: [[DBValue]]) -> String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
        }
        var lines = ["| " + columns.map { cell($0.name) }.joined(separator: " | ") + " |",
                     "|" + columns.map { _ in " --- |" }.joined()]
        lines += rows.map { "| " + $0.map { cell($0.displayText) }.joined(separator: " | ") + " |" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func inserts(_ columns: [DBColumn], _ rows: [[DBValue]], dialect: SQLDialect, table: String) -> String {
        let names = columns.map { dialect.quote($0.name) }.joined(separator: ", ")
        return rows.map { row in
            "INSERT INTO \(table) (\(names)) VALUES (" + row.map { dialect.literal($0) }.joined(separator: ", ") + ");"
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    /// Column names made unique for JSON keys (`id`, `id_2`).
    private static func uniqueNames(_ columns: [DBColumn]) -> [String] {
        var seen: [String: Int] = [:]
        return columns.map { column in
            let count = (seen[column.name] ?? 0) + 1
            seen[column.name] = count
            return count == 1 ? column.name : "\(column.name)_\(count)"
        }
    }
}
