import CryptoKit
import Foundation

/// A value behind a lock, readable from anywhere (a driver's cancel key).
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// SCRAM-SHA-256 (RFC 5802, 7677) as Postgres uses it: the client's side of the exchange.
struct SCRAMClient {
    let password: String
    let nonce: String
    /// Postgres takes the user from the startup message: the SCRAM user name is left empty.
    var user = ""

    init(password: String, nonce: String = SCRAMClient.makeNonce(), user: String = "") {
        self.password = password
        self.nonce = nonce
        self.user = user
    }

    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// No channel binding ("n,,"): the client doesn't use it.
    static let gs2Header = "n,,"

    var clientFirstBare: String {
        let name = user.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
        return "n=\(name),r=\(nonce)"
    }

    var clientFirstMessage: String { Self.gs2Header + clientFirstBare }

    struct Final {
        var message: String
        /// What the server must answer with (`v=`), to prove it knows the password too.
        var serverSignature: Data
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The client-final message for the server's first message.
    func clientFinal(serverFirst: String) throws -> Final {
        var attributes: [Character: String] = [:]
        for part in serverFirst.split(separator: ",") where part.count >= 2 && part.dropFirst().first == "=" {
            attributes[part.first!] = String(part.dropFirst(2))
        }
        guard let serverNonce = attributes["r"], serverNonce.hasPrefix(nonce),
              let saltText = attributes["s"], let salt = Data(base64Encoded: saltText),
              let iterationText = attributes["i"], let iterations = Int(iterationText), iterations > 0 else {
            throw Failure(message: "The server's SCRAM message isn't valid.")
        }
        let salted = Self.hi(password: Data(password.utf8), salt: salt, iterations: iterations)
        let key = SymmetricKey(data: salted)
        let clientKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Client Key".utf8), using: key))
        let storedKey = Data(SHA256.hash(data: clientKey))
        let channelBinding = Data(Self.gs2Header.utf8).base64EncodedString()
        let withoutProof = "c=\(channelBinding),r=\(serverNonce)"
        let authMessage = clientFirstBare + "," + serverFirst + "," + withoutProof
        let clientSignature = Data(HMAC<SHA256>.authenticationCode(for: Data(authMessage.utf8), using: SymmetricKey(data: storedKey)))
        let proof = Data(zip(clientKey, clientSignature).map { $0 ^ $1 })
        let serverKey = Data(HMAC<SHA256>.authenticationCode(for: Data("Server Key".utf8), using: key))
        let serverSignature = Data(HMAC<SHA256>.authenticationCode(for: Data(authMessage.utf8), using: SymmetricKey(data: serverKey)))
        return Final(message: withoutProof + ",p=" + proof.base64EncodedString(), serverSignature: serverSignature)
    }

    /// Checks the server-final message (`v=…`).
    static func verify(serverFinal: String, expected: Data) throws {
        if serverFinal.hasPrefix("e=") { throw Failure(message: "SCRAM: " + serverFinal.dropFirst(2)) }
        guard serverFinal.hasPrefix("v="), let signature = Data(base64Encoded: String(serverFinal.dropFirst(2).prefix { $0 != "," })),
              signature == expected else {
            throw Failure(message: "The server's SCRAM signature doesn't match: it may not be the server it claims to be.")
        }
    }

    /// PBKDF2-HMAC-SHA-256 with one block (SCRAM's Hi()).
    static func hi(password: Data, salt: Data, iterations: Int) -> Data {
        let key = SymmetricKey(data: password)
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: block, using: key))
        var result = [UInt8](u)
        for _ in 1..<iterations {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
            for (i, byte) in u.enumerated() { result[i] ^= byte }
        }
        return Data(result)
    }
}

/// PostgreSQL over its wire protocol (v3): startup and sign-in (cleartext, MD5, SCRAM-SHA-256),
/// TLS by SSLRequest, the simple query protocol, and CancelRequest on a second connection.
actor PostgresDriver: DatabaseDriver {
    nonisolated let kind = DatabaseKind.postgres
    private let wire: WireConnection
    private let config: DatabaseConnectionConfig
    private(set) var parameters: [String: String] = [:]
    private var typeNames: [Int32: String] = [:]
    private var isBusy = false
    private var isClosed = false
    /// The backend's id and secret (for CancelRequest), readable from `cancel()`.
    private nonisolated let cancelKey = LockedValue<(Int32, Int32)?>(nil)

    private init(wire: WireConnection, config: DatabaseConnectionConfig) {
        self.wire = wire
        self.config = config
    }

    var usesTLS: Bool { wire.usesTLS }

    static func connect(_ config: DatabaseConnectionConfig) async throws -> PostgresDriver {
        let tls = try DatabaseTLS.options(mode: config.sslMode, host: config.host, rootCertificate: config.rootCertificate)
        let negotiation = config.sslMode == .disable ? nil : WireNegotiation(server: .postgres, mode: config.sslMode, tls: tls)
        let wire = try await WireConnection.open(host: config.host, port: config.effectivePort, negotiation: negotiation)
        let driver = PostgresDriver(wire: wire, config: config)
        do {
            try await driver.startup()
        } catch {
            wire.close()
            throw error
        }
        return driver
    }

    // MARK: Messages

    private func readMessage() async throws -> (type: UInt8, body: Data) {
        let header = try await wire.read(5)
        let length = Int(Int32(bitPattern: UInt32(header[1]) << 24 | UInt32(header[2]) << 16 | UInt32(header[3]) << 8 | UInt32(header[4])))
        guard length >= 4 else { throw DBError.connection("The server sent a malformed message.") }
        let body = length > 4 ? try await wire.read(length - 4) : Data()
        return (header[0], body)
    }

    private func send(_ type: UInt8, _ body: Data) async throws {
        var message = Data([type])
        message.appendInt32(Int32(body.count + 4))
        message.append(body)
        try await wire.send(message)
    }

    // MARK: Startup

    private func startup() async throws {
        var body = Data()
        body.appendInt32(196_608) // protocol 3.0
        let database = config.database.isEmpty ? config.user : config.database
        for (key, value) in [("user", config.user), ("database", database), ("application_name", "Oh My Code"),
                             ("client_encoding", "UTF8"), ("DateStyle", "ISO, MDY")] {
            body.appendCString(key)
            body.appendCString(value)
        }
        body.append(0)
        var message = Data()
        message.appendInt32(Int32(body.count + 4))
        message.append(body)
        try await wire.send(message)

        var scram: (client: SCRAMClient, expected: Data?)?
        let password = config.password ?? ""
        while true {
            let (type, body) = try await readMessage()
            var reader = ByteReader(body)
            switch type {
            case UInt8(ascii: "R"):
                let code = try reader.int32()
                switch code {
                case 0:
                    break // signed in
                case 3:
                    var answer = Data()
                    answer.appendCString(password)
                    try await send(UInt8(ascii: "p"), answer)
                case 5:
                    let salt = try reader.bytes(4)
                    let inner = Self.md5Hex(Data((password + config.user).utf8))
                    var outer = Data(inner.utf8)
                    outer.append(contentsOf: salt)
                    var answer = Data()
                    answer.appendCString("md5" + Self.md5Hex(outer))
                    try await send(UInt8(ascii: "p"), answer)
                case 10:
                    var mechanisms: [String] = []
                    while !reader.isAtEnd {
                        let name = reader.cString()
                        if name.isEmpty { break }
                        mechanisms.append(name)
                    }
                    guard mechanisms.contains("SCRAM-SHA-256") else {
                        throw DBError.connection("The server asks for \(mechanisms.joined(separator: ", ")), which isn't supported.")
                    }
                    let client = SCRAMClient(password: password)
                    scram = (client, nil)
                    var answer = Data()
                    answer.appendCString("SCRAM-SHA-256")
                    let first = Data(client.clientFirstMessage.utf8)
                    answer.appendInt32(Int32(first.count))
                    answer.append(first)
                    try await send(UInt8(ascii: "p"), answer)
                case 11:
                    guard let client = scram?.client else { throw DBError.connection("Unexpected SCRAM message.") }
                    let serverFirst = String(decoding: reader.rest(), as: UTF8.self)
                    let final: SCRAMClient.Final
                    do {
                        final = try client.clientFinal(serverFirst: serverFirst)
                    } catch {
                        throw DBError.connection(error.localizedDescription)
                    }
                    scram?.expected = final.serverSignature
                    try await send(UInt8(ascii: "p"), Data(final.message.utf8))
                case 12:
                    guard let expected = scram?.expected else { throw DBError.connection("Unexpected SCRAM message.") }
                    do {
                        try SCRAMClient.verify(serverFinal: String(decoding: reader.rest(), as: UTF8.self), expected: expected)
                    } catch {
                        throw DBError.connection(error.localizedDescription)
                    }
                default:
                    throw DBError.connection("The server asks for an unsupported sign-in method (\(code)).")
                }
            case UInt8(ascii: "E"):
                var error = Self.parseError(body, sql: nil)
                error.isConnectionError = true
                throw error
            case UInt8(ascii: "S"):
                let name = reader.cString()
                parameters[name] = reader.cString()
            case UInt8(ascii: "K"):
                let pid = try reader.int32()
                let secret = try reader.int32()
                cancelKey.value = (pid, secret)
            case UInt8(ascii: "N"), UInt8(ascii: "v"):
                break
            case UInt8(ascii: "Z"):
                await loadTypeNames()
                return
            default:
                throw DBError.connection("Unexpected message “\(Character(UnicodeScalar(type)))” while signing in.")
            }
        }
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Type names by OID (for the result columns), read once.
    private func loadTypeNames() async {
        guard let execution = try? await query("SELECT oid, typname FROM pg_catalog.pg_type", rowLimit: .max),
              let rows = execution.resultSets.first?.rows else { return }
        for row in rows {
            if case .int(let oid) = row[0] { typeNames[Int32(truncatingIfNeeded: oid)] = row[1].plainText }
        }
    }

    var serverVersion: String {
        get async { "PostgreSQL " + (parameters["server_version"] ?? "") }
    }

    // MARK: Queries

    func run(_ sql: String, rowLimit: Int) async throws -> DBExecution {
        guard !isClosed else { throw DBError.connection("The connection is closed.") }
        guard !isBusy else { throw DBError("Another query is still running on this connection.") }
        isBusy = true
        defer { isBusy = false }
        return try await withTaskCancellationHandler {
            try await query(sql, rowLimit: rowLimit)
        } onCancel: {
            cancel()
        }
    }

    private func query(_ sql: String, rowLimit: Int) async throws -> DBExecution {
        var body = Data()
        body.appendCString(sql)
        do {
            try await send(UInt8(ascii: "Q"), body)
            return try await readResults(sql: sql, rowLimit: rowLimit)
        } catch let error as DBError where error.isConnectionError {
            isClosed = true
            wire.close()
            throw error
        }
    }

    private func readResults(sql: String, rowLimit: Int) async throws -> DBExecution {
        var execution = DBExecution()
        var current: DBResultSet?
        var oids: [Int32] = []
        while true {
            let (type, body) = try await readMessage()
            switch type {
            case UInt8(ascii: "T"):
                var reader = ByteReader(body)
                let count = Int(try reader.int16())
                var set = DBResultSet()
                oids = []
                for _ in 0..<count {
                    let name = reader.cString()
                    _ = try reader.int32() // table
                    _ = try reader.int16() // column number
                    let oid = try reader.int32()
                    _ = try reader.bytes(8) // size, modifier, format
                    oids.append(oid)
                    set.columns.append(DBColumn(name: name, typeName: typeNames[oid] ?? Self.builtinTypeNames[oid] ?? "oid \(oid)"))
                }
                current = set
            case UInt8(ascii: "D"):
                guard current != nil else { continue }
                current!.totalRows += 1
                guard current!.rows.count < rowLimit else { continue }
                let bytes = [UInt8](body)
                var index = 2
                var row: [DBValue] = []
                row.reserveCapacity(oids.count)
                for column in 0..<oids.count {
                    guard index + 4 <= bytes.count else { break }
                    let length = Int(Int32(bitPattern: UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
                                                       | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])))
                    index += 4
                    if length < 0 {
                        row.append(.null)
                    } else {
                        let end = min(bytes.count, index + length)
                        row.append(Self.decode(bytes[index..<end], oid: oids[column]))
                        index = end
                    }
                }
                current!.rows.append(row)
            case UInt8(ascii: "C"):
                var reader = ByteReader(body)
                let tag = reader.cString()
                var set = current ?? DBResultSet()
                set.command = tag
                if current == nil { set.affectedRows = Self.affectedRows(tag) }
                execution.resultSets.append(set)
                current = nil
            case UInt8(ascii: "I"):
                break // an empty query
            case UInt8(ascii: "E"):
                if let set = current { execution.resultSets.append(set) }
                current = nil
                execution.error = Self.parseError(body, sql: sql)
            case UInt8(ascii: "N"):
                let notice = Self.parseError(body, sql: nil)
                let severity = Self.fields(body)["V"] ?? Self.fields(body)["S"] ?? "NOTICE"
                execution.messages.append(DBMessage(severity: severity == "WARNING" ? .warning : severity == "INFO" ? .info : .notice,
                                                    text: notice.message + (notice.detail.map { "\n" + $0 } ?? "")))
            case UInt8(ascii: "S"):
                var reader = ByteReader(body)
                let name = reader.cString()
                parameters[name] = reader.cString()
            case UInt8(ascii: "G"):
                // COPY … FROM STDIN: there's nothing to send.
                var fail = Data()
                fail.appendCString("COPY FROM STDIN isn't supported here.")
                try await send(UInt8(ascii: "f"), fail)
            case UInt8(ascii: "H"):
                current = DBResultSet(columns: [DBColumn(name: "COPY", typeName: "text")])
            case UInt8(ascii: "d"):
                guard current != nil else { continue }
                current!.totalRows += 1
                if current!.rows.count < rowLimit {
                    current!.rows.append([.text(String(decoding: body, as: UTF8.self).trimmingCharacters(in: .newlines))])
                }
            case UInt8(ascii: "Z"):
                if let set = current { execution.resultSets.append(set) }
                return execution
            default:
                break // c (CopyDone), A (notification), ParameterDescription and the like
            }
        }
    }

    /// The rows a command changed, from its tag (`INSERT 0 3`, `UPDATE 2`).
    static func affectedRows(_ tag: String) -> Int? {
        let parts = tag.split(separator: " ")
        guard let verb = parts.first, let count = parts.last.flatMap({ Int($0) }) else { return nil }
        return ["INSERT", "UPDATE", "DELETE", "MERGE", "COPY", "MOVE", "FETCH"].contains(String(verb)) ? count : nil
    }

    static func fields(_ body: Data) -> [Character: String] {
        var reader = ByteReader(body)
        var fields: [Character: String] = [:]
        while !reader.isAtEnd {
            guard let code = try? reader.byte(), code != 0 else { break }
            fields[Character(UnicodeScalar(code))] = reader.cString()
        }
        return fields
    }

    /// An ErrorResponse (or NoticeResponse) as an error; its position (1-based characters of
    /// `sql`) becomes a UTF-16 offset.
    static func parseError(_ body: Data, sql: String?) -> DBError {
        let fields = fields(body)
        var error = DBError(fields["M"] ?? "Unknown error", code: fields["C"], detail: fields["D"], hint: fields["H"])
        if let sql, let position = fields["P"].flatMap({ Int($0) }), position > 0 {
            error.position = sql.utf16Offset(ofScalar: position - 1)
        }
        if let severity = fields["V"] ?? fields["S"], severity == "FATAL" || severity == "PANIC" { error.isConnectionError = true }
        return error
    }

    static let builtinTypeNames: [Int32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 25: "text", 26: "oid",
        114: "json", 700: "float4", 701: "float8", 790: "money", 1042: "bpchar", 1043: "varchar", 1082: "date",
        1083: "time", 1114: "timestamp", 1184: "timestamptz", 1186: "interval", 1266: "timetz", 1700: "numeric",
        2950: "uuid", 3802: "jsonb", 869: "inet", 650: "cidr", 1560: "bit", 1562: "varbit",
    ]

    /// A text-format value by its type.
    static func decode(_ bytes: ArraySlice<UInt8>, oid: Int32) -> DBValue {
        let text = String(decoding: bytes, as: UTF8.self)
        switch oid {
        case 16: return .bool(text == "t")
        case 20, 21, 23, 26, 28: return Int64(text).map(DBValue.int) ?? .text(text)
        case 700, 701: return Double(text).map(DBValue.float) ?? .text(text)
        case 1700: return .decimal(text)
        case 17: return .bytes(decodeBytea(text))
        case 114, 3802: return .json(text)
        case 1082, 1083, 1114, 1184, 1186, 1266: return .date(text)
        default: return .text(text)
        }
    }

    /// bytea's hex format (`\x0102`), or the old escape format.
    static func decodeBytea(_ text: String) -> Data {
        if text.hasPrefix("\\x") {
            var data = Data()
            var high: UInt8?
            for scalar in text.unicodeScalars.dropFirst(2) {
                guard let nibble = UInt8(String(scalar), radix: 16) else { continue }
                if let h = high { data.append(h << 4 | nibble); high = nil } else { high = nibble }
            }
            return data
        }
        var data = Data()
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 92, i + 1 < bytes.count {
                if bytes[i + 1] == 92 { data.append(92); i += 2; continue }
                if i + 3 < bytes.count, let value = UInt8(String(decoding: bytes[i + 1...i + 3], as: UTF8.self), radix: 8) {
                    data.append(value); i += 4; continue
                }
            }
            data.append(bytes[i])
            i += 1
        }
        return data
    }

    // MARK: Cancel and close

    /// CancelRequest on a connection of its own (the server stops the running query; it
    /// answers on the original connection with an error 57014).
    nonisolated func cancel() {
        guard let (pid, secret) = cancelKey.value else { return }
        let host = config.host, port = config.effectivePort
        Task.detached {
            guard let wire = try? await WireConnection.open(host: host, port: port, negotiation: nil, timeout: 5) else { return }
            var request = Data()
            request.appendInt32(16)
            request.appendInt32(80_877_102)
            request.appendInt32(pid)
            request.appendInt32(secret)
            try? await wire.send(request)
            _ = try? await wire.read(1) // the server closes it once it's done
            wire.close()
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        try? await send(UInt8(ascii: "X"), Data())
        wire.close()
    }

    // MARK: Schema

    private func rows(_ sql: String) async throws -> [[DBValue]] {
        let execution = try await query(sql, rowLimit: .max)
        if let error = execution.error { throw error }
        return execution.resultSets.first?.rows ?? []
    }

    private static let userSchemas = "n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_%'"

    func catalog() async throws -> DBCatalog {
        guard !isBusy else { throw DBError("A query is running on this connection.") }
        isBusy = true
        defer { isBusy = false }
        let defaultSchema = try await rows("SELECT current_schema()").first?.first?.plainText
        var schemas: [String: DBSchema] = [:]
        for row in try await rows("SELECT n.nspname FROM pg_catalog.pg_namespace n WHERE \(Self.userSchemas) ORDER BY 1") {
            schemas[row[0].plainText] = DBSchema(name: row[0].plainText)
        }
        var tables: [String: DBTable] = [:]
        var order: [String] = []
        for row in try await rows("""
            SELECT n.nspname, c.relname, c.relkind FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f') AND \(Self.userSchemas) ORDER BY 1, 2
            """) {
            let kind: DBTable.Kind = ["v", "m"].contains(row[2].plainText) ? .view : .table
            let table = DBTable(schema: row[0].plainText, name: row[1].plainText, kind: kind)
            tables[table.id] = table
            order.append(table.id)
        }
        for row in try await rows("""
            SELECT n.nspname, c.relname, a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull,
                   pg_catalog.pg_get_expr(d.adbin, d.adrelid),
                   EXISTS (SELECT 1 FROM pg_catalog.pg_index i WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey))
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r', 'v', 'm', 'p', 'f') AND \(Self.userSchemas)
            ORDER BY 1, 2, a.attnum
            """) {
            let id = row[0].plainText + "." + row[1].plainText
            tables[id]?.columns.append(DBColumnInfo(name: row[2].plainText, type: row[3].plainText, isNullable: row[4] != .bool(true),
                                                    defaultValue: row[5].isNull ? nil : row[5].plainText, isPrimaryKey: row[6] == .bool(true)))
        }
        for row in try await rows("""
            SELECT n.nspname, t.relname, i.relname, ix.indisunique, ix.indisprimary,
                   array_to_string(ARRAY(SELECT pg_catalog.pg_get_indexdef(ix.indexrelid, k + 1, true)
                                         FROM generate_subscripts(ix.indkey, 1) k ORDER BY k), ',')
            FROM pg_catalog.pg_index ix
            JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
            JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
            WHERE \(Self.userSchemas) ORDER BY 1, 2, 3
            """) {
            let id = row[0].plainText + "." + row[1].plainText
            tables[id]?.indexes.append(DBIndex(name: row[2].plainText, columns: row[5].plainText.split(separator: ",").map(String.init),
                                               isUnique: row[3] == .bool(true), isPrimary: row[4] == .bool(true)))
        }
        for row in try await rows("""
            SELECT n.nspname, c.relname, con.conname,
                   array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(num, ord)
                                         JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.num ORDER BY k.ord), ','),
                   rn.nspname, rc.relname,
                   array_to_string(ARRAY(SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY k(num, ord)
                                         JOIN pg_catalog.pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.num ORDER BY k.ord), ',')
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_class rc ON rc.oid = con.confrelid
            JOIN pg_catalog.pg_namespace rn ON rn.oid = rc.relnamespace
            WHERE con.contype = 'f' AND \(Self.userSchemas) ORDER BY 1, 2, 3
            """) {
            let id = row[0].plainText + "." + row[1].plainText
            tables[id]?.foreignKeys.append(DBForeignKey(name: row[2].plainText, columns: row[3].plainText.split(separator: ",").map(String.init),
                                                        referencedSchema: row[4].plainText, referencedTable: row[5].plainText,
                                                        referencedColumns: row[6].plainText.split(separator: ",").map(String.init)))
        }
        for id in order {
            guard let table = tables[id] else { continue }
            schemas[table.schema, default: DBSchema(name: table.schema)].tables.append(table)
        }
        return DBCatalog(schemas: schemas.values.sorted { $0.name < $1.name }, defaultSchema: defaultSchema)
    }

    func ddl(for table: DBTable) async throws -> String {
        guard !isBusy else { throw DBError("A query is running on this connection.") }
        isBusy = true
        defer { isBusy = false }
        let dialect = SQLDialect.postgres
        let name = dialect.quote(table.schema) + "." + dialect.quote(table.name)
        let regclass = dialect.literal(name) + "::regclass"
        if table.kind == .view {
            let definition = try await rows("SELECT pg_catalog.pg_get_viewdef(\(regclass), true)").first?.first?.plainText ?? ""
            return "CREATE VIEW \(name) AS\n" + definition
        }
        var lines = try await rows("""
            SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull, pg_catalog.pg_get_expr(d.adbin, d.adrelid)
            FROM pg_catalog.pg_attribute a LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = \(regclass) AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
            """).map { row in
            var line = "    " + dialect.quote(row[0].plainText) + " " + row[1].plainText
            if !row[3].isNull { line += " DEFAULT " + row[3].plainText }
            if row[2] == .bool(true) { line += " NOT NULL" }
            return line
        }
        lines += try await rows("""
            SELECT conname, pg_catalog.pg_get_constraintdef(oid, true) FROM pg_catalog.pg_constraint
            WHERE conrelid = \(regclass) ORDER BY contype <> 'p', conname
            """).map { "    CONSTRAINT " + dialect.quote($0[0].plainText) + " " + $0[1].plainText }
        var ddl = "CREATE TABLE \(name) (\n" + lines.joined(separator: ",\n") + "\n);"
        let indexes = try await rows("""
            SELECT pg_catalog.pg_get_indexdef(i.indexrelid) FROM pg_catalog.pg_index i
            WHERE i.indrelid = \(regclass) AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c WHERE c.conindid = i.indexrelid)
            ORDER BY 1
            """)
        for index in indexes { ddl += "\n\n" + index[0].plainText + ";" }
        return ddl
    }
}
