import CryptoKit
import Foundation
import Security

/// MySQL's (and MariaDB's) sign-in scrambles and the RSA step of caching_sha2_password.
enum MySQLAuth {
    /// mysql_native_password: SHA1(password) XOR SHA1(scramble + SHA1(SHA1(password))).
    static func nativePassword(_ password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = Array(Insecure.SHA1.hash(data: Data(password.utf8)))
        let stage2 = Array(Insecure.SHA1.hash(data: Data(stage1)))
        let mixed = Array(Insecure.SHA1.hash(data: Data(scramble + stage2)))
        return zip(stage1, mixed).map { $0 ^ $1 }
    }

    /// caching_sha2_password: SHA256(password) XOR SHA256(SHA256(SHA256(password)) + scramble).
    static func cachingSHA2(_ password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = Array(SHA256.hash(data: Data(password.utf8)))
        let stage2 = Array(SHA256.hash(data: Data(stage1)))
        let mixed = Array(SHA256.hash(data: Data(stage2 + scramble)))
        return zip(stage1, mixed).map { $0 ^ $1 }
    }

    /// The password (NUL-terminated) XOR the scramble, repeated: what's RSA-encrypted.
    static func xorPassword(_ password: String, scramble: [UInt8]) -> [UInt8] {
        let bytes = Array(password.utf8) + [0]
        guard !scramble.isEmpty else { return bytes }
        return bytes.enumerated().map { $0.element ^ scramble[$0.offset % scramble.count] }
    }

    /// RSA-OAEP (SHA-1) with the server's public key (PEM, "PUBLIC KEY" or "RSA PUBLIC KEY").
    static func rsaEncrypt(_ data: [UInt8], publicKeyPEM: String) throws -> Data {
        let der: Data
        if let spki = PEM.blocks(publicKeyPEM, label: "PUBLIC KEY").first {
            der = try rsaPublicKey(fromSubjectPublicKeyInfo: spki)
        } else if let pkcs1 = PEM.blocks(publicKeyPEM, label: "RSA PUBLIC KEY").first {
            der = pkcs1
        } else {
            throw DBError.connection("The server's public key couldn't be read.")
        }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw DBError.connection("The server's public key couldn't be used: \(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data(data) as CFData, &error) else {
            throw DBError.connection("Couldn't encrypt the password: \(error?.takeRetainedValue().localizedDescription ?? "")")
        }
        return encrypted as Data
    }

    /// The PKCS#1 key inside a SubjectPublicKeyInfo (the BIT STRING after the algorithm).
    static func rsaPublicKey(fromSubjectPublicKeyInfo der: Data) throws -> Data {
        var reader = DERReader(bytes: [UInt8](der))
        let outer = try reader.element(tag: 0x30)
        var inner = DERReader(bytes: outer)
        _ = try inner.element(tag: 0x30) // the algorithm
        let bits = try inner.element(tag: 0x03)
        guard bits.first == 0 else { throw DBError.connection("The server's public key isn't valid.") }
        return Data(bits.dropFirst())
    }

    private struct DERReader {
        let bytes: [UInt8]
        var index = 0

        mutating func element(tag: UInt8) throws -> [UInt8] {
            guard index + 2 <= bytes.count, bytes[index] == tag else { throw DBError.connection("The server's public key isn't valid.") }
            index += 1
            var length = Int(bytes[index])
            index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 4, index + count <= bytes.count else { throw DBError.connection("The server's public key isn't valid.") }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(bytes[index]); index += 1 }
            }
            guard index + length <= bytes.count else { throw DBError.connection("The server's public key isn't valid.") }
            defer { index += length }
            return Array(bytes[index..<index + length])
        }
    }
}

/// The server's greeting (handshake v10).
struct MySQLGreeting: Equatable {
    var protocolVersion: UInt8
    var serverVersion: String
    var connectionID: UInt32
    var capabilities: UInt32
    var characterSet: UInt8
    var scramble: [UInt8]
    var authPlugin: String

    init(payload: Data) throws {
        var reader = ByteReader(payload)
        protocolVersion = try reader.byte()
        if protocolVersion == 0xFF {
            throw MySQLDriver.parseError(Array(payload), sql: nil, connection: true)
        }
        guard protocolVersion == 10 else { throw DBError.connection("Unsupported MySQL protocol version \(protocolVersion).") }
        serverVersion = reader.cString()
        connectionID = UInt32(try reader.uintLE(4))
        var scramble = try reader.bytes(8)
        _ = try reader.byte()
        capabilities = UInt32(try reader.uintLE(2))
        characterSet = 0
        authPlugin = "mysql_native_password"
        if !reader.isAtEnd {
            characterSet = try reader.byte()
            _ = try reader.uintLE(2) // status
            capabilities |= UInt32(try reader.uintLE(2)) << 16
            let authLength = Int(try reader.byte())
            _ = try reader.bytes(10)
            if capabilities & MySQLDriver.Capability.secureConnection != 0 {
                let count = max(13, authLength - 8)
                scramble += try reader.bytes(min(count, reader.remaining))
                if scramble.last == 0 { scramble.removeLast() }
            }
            if capabilities & MySQLDriver.Capability.pluginAuth != 0 { authPlugin = reader.cString() }
        }
        self.scramble = scramble
    }
}

/// MySQL and MariaDB over the client/server protocol: handshake v10, sign-in with
/// mysql_native_password or caching_sha2_password (RSA without TLS), TLS when the server
/// offers it, COM_QUERY with several statements and results, and KILL QUERY to cancel.
actor MySQLDriver: DatabaseDriver {
    enum Capability {
        static let longPassword: UInt32 = 0x1
        static let longFlag: UInt32 = 0x4
        static let connectWithDB: UInt32 = 0x8
        static let protocol41: UInt32 = 0x200
        static let ssl: UInt32 = 0x800
        static let transactions: UInt32 = 0x2000
        static let secureConnection: UInt32 = 0x8000
        static let multiStatements: UInt32 = 0x10000
        static let multiResults: UInt32 = 0x20000
        static let psMultiResults: UInt32 = 0x40000
        static let pluginAuth: UInt32 = 0x80000
        static let pluginAuthLenencData: UInt32 = 0x200000
        static let deprecateEOF: UInt32 = 0x1000000
    }

    static let maxPacket = 0xFF_FFFF
    /// utf8mb4_general_ci: both MySQL and MariaDB know it.
    static let characterSet: UInt8 = 45
    static let moreResults: UInt16 = 0x0008

    nonisolated let kind = DatabaseKind.mysql
    private let wire: WireConnection
    private let config: DatabaseConnectionConfig
    private var sequence: UInt8 = 0
    private var capabilities: UInt32 = 0
    private(set) var greeting: MySQLGreeting?
    /// How the last sign-in went: the plugin, and for caching_sha2 "fast", "full (TLS)" or
    /// "full (RSA)" (tests check each path).
    private(set) var signInPath = ""
    private var isBusy = false
    private var isClosed = false
    private nonisolated let connectionID = LockedValue<UInt32?>(nil)
    private nonisolated let cancelRequested = LockedValue(false)

    private init(wire: WireConnection, config: DatabaseConnectionConfig) {
        self.wire = wire
        self.config = config
    }

    var usesTLS: Bool { wire.usesTLS }

    static func clientFlags(server: UInt32, database: Bool, ssl: Bool) -> UInt32 {
        var flags = Capability.longPassword | Capability.longFlag | Capability.protocol41 | Capability.transactions
            | Capability.secureConnection | Capability.multiStatements | Capability.multiResults | Capability.psMultiResults
            | Capability.pluginAuth | Capability.pluginAuthLenencData | Capability.deprecateEOF
        if database { flags |= Capability.connectWithDB }
        if ssl { flags |= Capability.ssl }
        return flags & server
    }

    /// The SSL request packet (header included, sequence 1) for a greeting.
    static func sslRequest(greetingPayload: Data, database: Bool) -> Data? {
        guard let greeting = try? MySQLGreeting(payload: greetingPayload), greeting.capabilities & Capability.ssl != 0 else { return nil }
        var payload = Data()
        payload.appendLE(UInt64(clientFlags(server: greeting.capabilities, database: database, ssl: true)), bytes: 4)
        payload.appendLE(UInt64(maxPacket), bytes: 4)
        payload.append(characterSet)
        payload.append(contentsOf: [UInt8](repeating: 0, count: 23))
        var packet = Data()
        packet.appendLE(UInt64(payload.count), bytes: 3)
        packet.append(1)
        packet.append(payload)
        return packet
    }

    static func connect(_ config: DatabaseConnectionConfig) async throws -> MySQLDriver {
        let tls = try DatabaseTLS.options(mode: config.sslMode, host: config.host, rootCertificate: config.rootCertificate)
        let hasDatabase = !config.database.isEmpty
        // Without TLS too, the framer reads the greeting: one path for both.
        let negotiation = WireNegotiation(server: .mysql, mode: config.sslMode, tls: tls) { greeting in
            sslRequest(greetingPayload: greeting, database: hasDatabase)
        }
        let wire = try await WireConnection.open(host: config.host, port: config.effectivePort, negotiation: negotiation)
        let driver = MySQLDriver(wire: wire, config: config)
        do {
            try await driver.handshake()
        } catch {
            wire.close()
            throw error
        }
        return driver
    }

    // MARK: Packets

    /// A packet's payload (joined when it spans several).
    private func readPacket() async throws -> [UInt8] {
        var payload: [UInt8] = []
        while true {
            let header = try await wire.read(4)
            let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16
            sequence = header[3] &+ 1
            if length > 0 { payload += try await wire.read(length) }
            if length < Self.maxPacket { return payload }
        }
    }

    private func writePacket(_ payload: Data) async throws {
        var data = Data()
        var offset = 0
        repeat {
            let count = min(Self.maxPacket, payload.count - offset)
            data.appendLE(UInt64(count), bytes: 3)
            data.append(sequence)
            sequence &+= 1
            data.append(payload[payload.startIndex + offset..<payload.startIndex + offset + count])
            offset += count
            if count < Self.maxPacket { break }
        } while true
        try await wire.send(data)
    }

    // MARK: Sign-in

    private func handshake() async throws {
        guard let payload = wire.negotiation?.greeting else { throw DBError.connection("The server sent no greeting.") }
        let greeting = try MySQLGreeting(payload: payload)
        self.greeting = greeting
        connectionID.value = greeting.connectionID
        sequence = wire.usesTLS ? 2 : 1
        capabilities = Self.clientFlags(server: greeting.capabilities, database: !config.database.isEmpty, ssl: wire.usesTLS)
        guard capabilities & Capability.protocol41 != 0 else { throw DBError.connection("This server is too old (no protocol 4.1).") }
        let password = config.password ?? ""
        var plugin = greeting.authPlugin
        var scramble = greeting.scramble
        var response = try authResponse(plugin: plugin, password: password, scramble: scramble)
        signInPath = plugin

        var packet = Data()
        packet.appendLE(UInt64(capabilities), bytes: 4)
        packet.appendLE(UInt64(Self.maxPacket), bytes: 4)
        packet.append(Self.characterSet)
        packet.append(contentsOf: [UInt8](repeating: 0, count: 23))
        packet.appendCString(config.user)
        if capabilities & Capability.pluginAuthLenencData != 0 {
            packet.append(contentsOf: Self.lengthEncoded(UInt64(response.count)))
        } else {
            packet.append(UInt8(response.count))
        }
        packet.append(contentsOf: response)
        if capabilities & Capability.connectWithDB != 0 { packet.appendCString(config.database) }
        if capabilities & Capability.pluginAuth != 0 { packet.appendCString(plugin) }
        try await writePacket(packet)

        while true {
            let reply = try await readPacket()
            guard let first = reply.first else { throw DBError.connection("The server sent an empty reply.") }
            switch first {
            case 0x00:
                return
            case 0xFF:
                throw Self.parseError(reply, sql: nil, connection: true)
            case 0xFE:
                // Auth switch: another method, with a new scramble.
                var reader = ByteReader(bytes: reply)
                _ = try reader.byte()
                plugin = reader.cString()
                scramble = reader.rest()
                if scramble.last == 0 { scramble.removeLast() }
                response = try authResponse(plugin: plugin, password: password, scramble: scramble)
                signInPath = plugin
                try await writePacket(Data(response))
            case 0x01:
                let more = Array(reply.dropFirst())
                if more == [0x03] {
                    signInPath = plugin + " fast"
                    continue // fast path: the server had the password cached; OK follows
                } else if more == [0x04] {
                    // Full authentication: the password in clear over TLS, else RSA-encrypted.
                    signInPath = plugin + (wire.usesTLS ? " full (TLS)" : " full (RSA)")
                    try requirePasswordSafe()
                    if wire.usesTLS {
                        try await writePacket(Data(Array(password.utf8) + [0]))
                    } else {
                        try await writePacket(Data([0x02]))
                    }
                } else if let pem = String(bytes: more, encoding: .utf8), pem.contains("BEGIN") {
                    try requirePasswordSafe()
                    let encrypted = try MySQLAuth.rsaEncrypt(MySQLAuth.xorPassword(password, scramble: scramble), publicKeyPEM: pem)
                    try await writePacket(encrypted)
                } else {
                    throw DBError.connection("Unexpected reply while signing in.")
                }
            default:
                throw DBError.connection("Unexpected reply while signing in.")
            }
        }
    }

    /// Whether the password (in clear, or encrypted with a key the server sends) may go to this
    /// server: over TLS, or to this Mac itself, where nobody sits in between. MySQL's own client
    /// refuses both otherwise, unless asked to.
    static func mayRevealPassword(usesTLS: Bool, host: String) -> Bool {
        if usesTLS { return true }
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("/")
    }

    private func requirePasswordSafe() throws {
        guard Self.mayRevealPassword(usesTLS: wire.usesTLS, host: config.host) else {
            throw DBError.connection("The server needs the full password, which is only sent over an encrypted connection. Turn on SSL (Require or Verify Full) for this connection.")
        }
    }

    private func authResponse(plugin: String, password: String, scramble: [UInt8]) throws -> [UInt8] {
        switch plugin {
        case "mysql_native_password": return MySQLAuth.nativePassword(password, scramble: scramble)
        case "caching_sha2_password": return MySQLAuth.cachingSHA2(password, scramble: scramble)
        case "mysql_clear_password":
            guard Self.mayRevealPassword(usesTLS: wire.usesTLS, host: config.host) else {
                throw DBError.connection("The server asks for the password in clear text without an encrypted connection. Turn on SSL (Require or Verify Full) for this connection.")
            }
            return Array(password.utf8) + [0]
        default: throw DBError.connection("The server asks for the “\(plugin)” sign-in method, which isn't supported.")
        }
    }

    static func lengthEncoded(_ value: UInt64) -> [UInt8] {
        var data = Data()
        switch value {
        case ..<251: data.append(UInt8(value))
        case ..<0x1_0000: data.append(0xFC); data.appendLE(value, bytes: 2)
        case ..<0x100_0000: data.append(0xFD); data.appendLE(value, bytes: 3)
        default: data.append(0xFE); data.appendLE(value, bytes: 8)
        }
        return [UInt8](data)
    }

    var serverVersion: String {
        get async {
            let version = greeting?.serverVersion ?? ""
            return (version.lowercased().contains("mariadb") ? "MariaDB " : "MySQL ") + version
        }
    }

    // MARK: Queries

    func run(_ sql: String, rowLimit: Int) async throws -> DBExecution {
        guard !isClosed else { throw DBError.connection("The connection is closed.") }
        guard !isBusy else { throw DBError("Another query is still running on this connection.") }
        isBusy = true
        cancelRequested.value = false
        defer { isBusy = false }
        var execution = try await withTaskCancellationHandler {
            try await query(sql, rowLimit: rowLimit)
        } onCancel: {
            cancel()
        }
        if cancelRequested.value {
            if execution.error?.code == "1317" { execution.error = .cancelled }
            else if execution.error == nil { execution.messages.append(DBMessage(severity: .notice, text: "Cancelled.")) }
        }
        return execution
    }

    private func query(_ sql: String, rowLimit: Int) async throws -> DBExecution {
        do {
            sequence = 0
            var packet = Data([0x03])
            packet.append(contentsOf: Array(sql.utf8))
            try await writePacket(packet)
            return try await readResults(sql: sql, rowLimit: rowLimit)
        } catch let error as DBError where error.isConnectionError {
            isClosed = true
            wire.close()
            throw error
        }
    }

    private struct ColumnDefinition {
        var name: String
        var table: String
        var characterSet: UInt16
        var length: UInt32
        var type: UInt8
        var flags: UInt16
        var decimals: UInt8
    }

    private func readResults(sql: String, rowLimit: Int) async throws -> DBExecution {
        var execution = DBExecution()
        let deprecateEOF = capabilities & Capability.deprecateEOF != 0
        while true {
            let first = try await readPacket()
            guard let header = first.first else { throw DBError.connection("The server sent an empty reply.") }
            var status: UInt16 = 0
            if header == 0x00 {
                var reader = ByteReader(bytes: first)
                _ = try reader.byte()
                let affected = try reader.lengthEncodedInt() ?? 0
                _ = try reader.lengthEncodedInt()
                status = UInt16(try reader.uintLE(2))
                let warnings = try reader.uintLE(2)
                let info = String(decoding: reader.rest(), as: UTF8.self)
                execution.resultSets.append(DBResultSet(affectedRows: Int(affected), command: info.isEmpty ? nil : info))
                if warnings > 0 { execution.messages.append(DBMessage(severity: .warning, text: "\(warnings) warning\(warnings == 1 ? "" : "s")")) }
            } else if header == 0xFF {
                execution.error = Self.parseError(first, sql: sql, connection: false)
                return execution
            } else if header == 0xFB {
                // LOAD DATA LOCAL INFILE: no file is sent.
                try await writePacket(Data())
                continue
            } else {
                var reader = ByteReader(bytes: first)
                guard let count = Int(exactly: try reader.lengthEncodedInt() ?? 0) else {
                    throw DBError.connection("A message from the server was cut short.")
                }
                guard count <= 4096 else { throw DBError.connection("The server sent a malformed result.") }
                var columns: [ColumnDefinition] = []
                for _ in 0..<count {
                    var r = ByteReader(bytes: try await readPacket())
                    _ = try r.lengthEncodedString() // catalog
                    _ = try r.lengthEncodedString() // schema
                    let table = try r.lengthEncodedString()
                    _ = try r.lengthEncodedString() // original table
                    let name = try r.lengthEncodedString()
                    _ = try r.lengthEncodedString() // original name
                    _ = try r.lengthEncodedInt()
                    let charset = UInt16(try r.uintLE(2))
                    let length = UInt32(try r.uintLE(4))
                    let type = try r.byte()
                    let flags = UInt16(try r.uintLE(2))
                    let decimals = try r.byte()
                    columns.append(ColumnDefinition(name: name, table: table, characterSet: charset, length: length, type: type,
                                                    flags: flags, decimals: decimals))
                }
                if !deprecateEOF { _ = try await readPacket() }
                var set = DBResultSet(columns: columns.map { DBColumn(name: $0.name, typeName: Self.typeName($0), table: $0.table.isEmpty ? nil : $0.table) })
                while true {
                    let packet = try await readPacket()
                    if packet.first == 0xFE, packet.count < Self.maxPacket, deprecateEOF || packet.count < 9 {
                        var r = ByteReader(bytes: packet)
                        _ = try r.byte()
                        if deprecateEOF {
                            _ = try r.lengthEncodedInt()
                            _ = try r.lengthEncodedInt()
                            status = UInt16(try r.uintLE(2))
                        } else {
                            _ = try r.uintLE(2)
                            status = UInt16(try r.uintLE(2))
                        }
                        break
                    }
                    if packet.first == 0xFF {
                        execution.resultSets.append(set)
                        execution.error = Self.parseError(packet, sql: sql, connection: false)
                        return execution
                    }
                    set.totalRows += 1
                    guard set.rows.count < rowLimit else { continue }
                    var r = ByteReader(bytes: packet)
                    var row: [DBValue] = []
                    row.reserveCapacity(columns.count)
                    for column in columns {
                        if let bytes = try r.lengthEncodedBytes() {
                            row.append(Self.decode(bytes, column: column))
                        } else {
                            row.append(.null)
                        }
                    }
                    set.rows.append(row)
                }
                execution.resultSets.append(set)
            }
            if status & Self.moreResults == 0 { return execution }
        }
    }

    private static func typeName(_ column: ColumnDefinition) -> String {
        let unsigned = column.flags & 32 != 0 ? " UNSIGNED" : ""
        let binary = column.characterSet == 63
        switch column.type {
        case 0, 246: return "DECIMAL"
        case 1: return "TINYINT" + unsigned
        case 2: return "SMALLINT" + unsigned
        case 3: return "INT" + unsigned
        case 4: return "FLOAT"
        case 5: return "DOUBLE"
        case 6: return "NULL"
        case 7: return "TIMESTAMP"
        case 8: return "BIGINT" + unsigned
        case 9: return "MEDIUMINT" + unsigned
        case 10, 14: return "DATE"
        case 11: return "TIME"
        case 12: return "DATETIME"
        case 13: return "YEAR"
        case 15, 253: return binary ? "VARBINARY" : "VARCHAR"
        case 16: return "BIT"
        case 245: return "JSON"
        case 247: return "ENUM"
        case 248: return "SET"
        case 249, 250, 251, 252: return binary ? "BLOB" : "TEXT"
        case 254: return column.flags & 256 != 0 ? "ENUM" : column.flags & 2048 != 0 ? "SET" : binary ? "BINARY" : "CHAR"
        case 255: return "GEOMETRY"
        default: return "TYPE \(column.type)"
        }
    }

    private static func decode(_ bytes: [UInt8], column: ColumnDefinition) -> DBValue {
        let binary = column.characterSet == 63
        switch column.type {
        case 1, 2, 3, 8, 9, 13:
            let text = String(decoding: bytes, as: UTF8.self)
            if let value = Int64(text) { return .int(value) }
            return .decimal(text) // unsigned past Int64
        case 4, 5:
            let text = String(decoding: bytes, as: UTF8.self)
            return Double(text).map(DBValue.float) ?? .text(text)
        case 0, 246:
            return .decimal(String(decoding: bytes, as: UTF8.self))
        case 7, 10, 11, 12, 14:
            return .date(String(decoding: bytes, as: UTF8.self))
        case 245:
            return .json(String(decoding: bytes, as: UTF8.self))
        case 16:
            if bytes.count <= 8 { return .int(Int64(bitPattern: bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })) }
            return .bytes(Data(bytes))
        case 255:
            return .bytes(Data(bytes))
        case 6:
            return .null
        default:
            return binary ? .bytes(Data(bytes)) : .text(String(decoding: bytes, as: UTF8.self))
        }
    }

    /// An ERR packet. MySQL gives no position, but "… near 'x' at line N": that place.
    static func parseError(_ packet: [UInt8], sql: String?, connection: Bool) -> DBError {
        var reader = ByteReader(bytes: packet)
        _ = try? reader.byte()
        let code = (try? reader.uintLE(2)).map { Int($0) } ?? 0
        var state: String?
        if reader.remaining > 0, reader.data[reader.index] == UInt8(ascii: "#") {
            _ = try? reader.byte()
            state = (try? reader.bytes(5)).map { String(decoding: $0, as: UTF8.self) }
        }
        let message = String(decoding: reader.rest(), as: UTF8.self)
        var error = DBError(message, code: String(code), detail: state.map { "SQLSTATE \($0)" }, isConnectionError: connection)
        if let sql { error.position = errorPosition(message: message, sql: sql) }
        return error
    }

    static func errorPosition(message: String, sql: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"near '(.*)' at line (\d+)"#, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: message, range: NSRange(location: 0, length: (message as NSString).length)),
              let line = Int((message as NSString).substring(with: match.range(at: 2))) else { return nil }
        let near = (message as NSString).substring(with: match.range(at: 1))
        let ns = sql as NSString
        var lineStart = 0
        var current = 1
        while current < line, lineStart < ns.length {
            let range = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(range)
            current += 1
        }
        guard lineStart <= ns.length else { return nil }
        if !near.isEmpty {
            // MySQL quotes up to 80 characters of what follows: find them from that line on.
            let probe = String(near.prefix(40))
            let found = ns.range(of: probe, options: [], range: NSRange(location: lineStart, length: ns.length - lineStart))
            if found.location != NSNotFound { return found.location }
        } else {
            return max(0, ns.length - 1) // "near ''": at the end
        }
        return lineStart
    }

    // MARK: Cancel and close

    /// KILL QUERY on a connection of its own.
    nonisolated func cancel() {
        guard let id = connectionID.value else { return }
        cancelRequested.value = true
        let config = config
        Task.detached {
            guard let killer = try? await MySQLDriver.connect(config) else { return }
            _ = try? await killer.run("KILL QUERY \(id)", rowLimit: 0)
            await killer.close()
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        sequence = 0
        try? await writePacket(Data([0x01]))
        wire.close()
    }

    // MARK: Schema

    private func rows(_ sql: String) async throws -> [[DBValue]] {
        let execution = try await query(sql, rowLimit: .max)
        if let error = execution.error { throw error }
        return execution.resultSets.first?.rows ?? []
    }

    private static let systemSchemas = "('mysql', 'information_schema', 'performance_schema', 'sys')"

    func catalog() async throws -> DBCatalog {
        guard !isBusy else { throw DBError("A query is running on this connection.") }
        isBusy = true
        defer { isBusy = false }
        let current = try await rows("SELECT DATABASE()").first?.first
        var schemas: [String: DBSchema] = [:]
        for row in try await rows("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN \(Self.systemSchemas) ORDER BY 1") {
            schemas[row[0].plainText] = DBSchema(name: row[0].plainText)
        }
        var tables: [String: DBTable] = [:]
        var order: [String] = []
        for row in try await rows("""
            SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA NOT IN \(Self.systemSchemas) ORDER BY 1, 2
            """) {
            let table = DBTable(schema: row[0].plainText, name: row[1].plainText, kind: row[2].plainText.contains("VIEW") ? .view : .table)
            tables[table.id] = table
            order.append(table.id)
        }
        for row in try await rows("""
            SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY
            FROM information_schema.COLUMNS WHERE TABLE_SCHEMA NOT IN \(Self.systemSchemas)
            ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
            """) {
            let id = row[0].plainText + "." + row[1].plainText
            tables[id]?.columns.append(DBColumnInfo(name: row[2].plainText, type: row[3].plainText, isNullable: row[4].plainText == "YES",
                                                    defaultValue: row[5].isNull ? nil : row[5].plainText, isPrimaryKey: row[6].plainText == "PRI"))
        }
        var indexOrder: [String] = []
        var indexes: [String: (table: String, index: DBIndex)] = [:]
        for row in try await rows("""
            SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, NON_UNIQUE, COLUMN_NAME FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA NOT IN \(Self.systemSchemas) ORDER BY 1, 2, 3, SEQ_IN_INDEX
            """) {
            let table = row[0].plainText + "." + row[1].plainText
            let key = table + "\u{0}" + row[2].plainText
            if indexes[key] == nil {
                indexOrder.append(key)
                indexes[key] = (table, DBIndex(name: row[2].plainText, columns: [], isUnique: row[3].number == 0, isPrimary: row[2].plainText == "PRIMARY"))
            }
            indexes[key]?.index.columns.append(row[4].plainText)
        }
        for key in indexOrder { if let entry = indexes[key] { tables[entry.table]?.indexes.append(entry.index) } }
        var keyOrder: [String] = []
        var keys: [String: (table: String, key: DBForeignKey)] = [:]
        for row in try await rows("""
            SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE REFERENCED_TABLE_NAME IS NOT NULL AND TABLE_SCHEMA NOT IN \(Self.systemSchemas)
            ORDER BY 1, 2, 3, ORDINAL_POSITION
            """) {
            let table = row[0].plainText + "." + row[1].plainText
            let id = table + "\u{0}" + row[2].plainText
            if keys[id] == nil {
                keyOrder.append(id)
                keys[id] = (table, DBForeignKey(name: row[2].plainText, columns: [], referencedSchema: row[4].plainText,
                                                referencedTable: row[5].plainText, referencedColumns: []))
            }
            keys[id]?.key.columns.append(row[3].plainText)
            keys[id]?.key.referencedColumns.append(row[6].plainText)
        }
        for id in keyOrder { if let entry = keys[id] { tables[entry.table]?.foreignKeys.append(entry.key) } }
        for id in order {
            guard let table = tables[id] else { continue }
            schemas[table.schema, default: DBSchema(name: table.schema)].tables.append(table)
        }
        let defaultSchema = current.flatMap { $0.isNull ? nil : $0.plainText }
        return DBCatalog(schemas: schemas.values.sorted { $0.name < $1.name }, defaultSchema: defaultSchema)
    }

    func ddl(for table: DBTable) async throws -> String {
        guard !isBusy else { throw DBError("A query is running on this connection.") }
        isBusy = true
        defer { isBusy = false }
        let name = SQLDialect.mysql.quote(table.schema) + "." + SQLDialect.mysql.quote(table.name)
        let row = try await rows("SHOW CREATE \(table.kind == .view ? "VIEW" : "TABLE") \(name)").first
        return (row.map { $0.count > 1 ? $0[1].plainText : "" } ?? "") + ";"
    }
}
