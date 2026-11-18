import AppKit
import Foundation
import Security
import Testing
@testable import Oh_My_Code

private func temporaryFolder(_ name: String = "omc-db") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}

// MARK: Connection strings

struct DatabaseURLTests {
    @Test func parsesServerURLs() throws {
        let pg = try DatabaseURL.parse("postgres://us%40er:p%3Ass@db.example.com:6543/my%20db?sslmode=verify-full&sslrootcert=/tmp/ca.pem")
        #expect(pg.kind == .postgres && pg.user == "us@er" && pg.password == "p:ss" && pg.host == "db.example.com")
        #expect(pg.port == 6543 && pg.database == "my db" && pg.sslMode == .verifyFull && pg.rootCertificate == "/tmp/ca.pem")

        let local = try DatabaseURL.parse("postgresql://localhost")
        #expect(local.host == "localhost" && local.port == nil && local.effectivePort == 5432 && local.sslMode == .prefer && local.database.isEmpty)

        let mysql = try DatabaseURL.parse("mysql://root@[::1]:3307/app?ssl-mode=REQUIRED")
        #expect(mysql.kind == .mysql && mysql.host == "::1" && mysql.port == 3307 && mysql.database == "app" && mysql.sslMode == .require)
        #expect(mysql.password == nil)

        let maria = try DatabaseURL.parse("mariadb://u:p@h/db?ssl=false")
        #expect(maria.kind == .mysql && maria.effectivePort == 3306 && maria.sslMode == .disable)
        #expect(try DatabaseURL.parse("postgres://h/db?sslmode=disable").sslMode == .disable)
        #expect(try DatabaseURL.parse("mysql://h/db?ssl-mode=VERIFY_IDENTITY").sslMode == .verifyFull)
    }

    @Test func parsesSQLitePaths() throws {
        let url = try DatabaseURL.parse("sqlite:///tmp/a.db?mode=ro")
        #expect(url.kind == .sqlite && url.file == "/tmp/a.db" && url.readOnly)
        #expect(try DatabaseURL.parse("/Users/x/data.sqlite").file == "/Users/x/data.sqlite")
        #expect(try DatabaseURL.parse("data/app.db", relativeTo: URL(fileURLWithPath: "/proj")).file == "/proj/data/app.db")
        #expect(try DatabaseURL.parse("sqlite:my%20file.db", relativeTo: URL(fileURLWithPath: "/p")).file == "/p/my file.db")
    }

    @Test func rejectsWhatItCantUse() {
        #expect(throws: DatabaseURLError.self) { try DatabaseURL.parse("oracle://x/y") }
        #expect(throws: (any Error).self) { try DatabaseURL.parse("postgres://h:99999/db") }
        #expect(throws: DatabaseURLError.self) { try DatabaseURL.parse("postgres://h/db?sslmode=sometimes") }
        #expect(throws: DatabaseURLError.self) { try DatabaseURL.parse("  ") }
    }

    @Test func savedWithoutThePassword() throws {
        var config = try DatabaseURL.parse("postgres://ann:secret@h:5433/db?sslmode=require")
        config.name = "Prod"
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        #expect(!json.contains("secret") && json.contains("\"sslMode\":\"require\""))
        let decoded = try JSONDecoder().decode(DatabaseConnectionConfig.self, from: Data(json.utf8))
        #expect(decoded.password == nil && decoded.user == "ann" && decoded.port == 5433 && decoded.name == "Prod" && decoded.id == config.id)
        #expect(!config.urlString.contains("secret") && config.urlString.hasPrefix("postgres://ann@h:5433/db"))
        #expect(config.displayName == "Prod")
        config.name = ""
        #expect(config.displayName == "ann@h/db")
    }
}

// MARK: Statements

struct SQLSplitterTests {
    private func texts(_ sql: String, _ dialect: SQLDialect) -> [String] {
        SQLSplitter.split(sql, dialect: dialect).map(\.text)
    }

    @Test func stringsCommentsAndQuotedNames() {
        #expect(texts("SELECT 1; SELECT 'a;b' AS x; -- c;\nSELECT \"q;\" FROM t /* ; */;", .postgres)
            == ["SELECT 1", "SELECT 'a;b' AS x", "SELECT \"q;\" FROM t"])
        #expect(texts("SELECT 'it''s; fine'; SELECT 2", .sqlite) == ["SELECT 'it''s; fine'", "SELECT 2"])
        #expect(texts(";;  ;\n-- only a comment\n", .postgres).isEmpty)
        #expect(texts("/* a /* b; */ c; */ SELECT 1;", .postgres) == ["SELECT 1"])
        #expect(texts("SELECT [a;b] FROM t; SELECT 2", .sqlite) == ["SELECT [a;b] FROM t", "SELECT 2"])
    }

    @Test func dollarQuotesAndEscapeStrings() {
        let sql = """
            CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END; $body$ LANGUAGE plpgsql;
            SELECT $$a;b$$; SELECT E'it\\'s;'; SELECT 'a\\'; SELECT 4
            """
        let statements = texts(sql, .postgres)
        #expect(statements.count == 5)
        #expect(statements[0].hasSuffix("$body$ LANGUAGE plpgsql"))
        #expect(statements[1] == "SELECT $$a;b$$" && statements[2] == "SELECT E'it\\'s;'" && statements[3] == "SELECT 'a\\'")
        // $1 parameters aren't quotes.
        #expect(texts("SELECT $1; SELECT 2", .postgres).count == 2)
    }

    @Test func mysqlBackticksEscapesAndDelimiter() {
        let sql = """
            SELECT `a;b` FROM t;
            DELIMITER $$
            CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$
            DELIMITER ;
            SELECT 'it\\'s;'; # comment;
            SELECT "x;y"
            """
        #expect(texts(sql, .mysql) == ["SELECT `a;b` FROM t", "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
                                       "SELECT 'it\\'s;'", "SELECT \"x;y\""])
        #expect(texts("DELIMITER //\nSELECT 1//\nSELECT 2//", .mysql) == ["SELECT 1", "SELECT 2"])
    }

    @Test func sqliteTriggerBodies() {
        let sql = "CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET x = 1; INSERT INTO u VALUES (CASE WHEN 1 THEN 2 END); END; BEGIN; SELECT 1;"
        #expect(texts(sql, .sqlite) == ["CREATE TRIGGER tr AFTER INSERT ON t BEGIN UPDATE t SET x = 1; INSERT INTO u VALUES (CASE WHEN 1 THEN 2 END); END",
                                        "BEGIN", "SELECT 1"])
    }

    @Test func statementAtTheCaret() {
        let text = "SELECT 1;\n\nSELECT 2\n  FROM t;\n"
        let statements = SQLSplitter.split(text, dialect: .postgres)
        func at(_ offset: Int) -> String? { SQLSplitter.statement(at: offset, in: statements)?.text }
        #expect(at(3) == "SELECT 1")
        #expect(at(9) == "SELECT 1") // right after the ;
        #expect(at(10) == "SELECT 2\n  FROM t") // the blank line before it
        #expect(at(22) == "SELECT 2\n  FROM t")
        #expect(at((text as NSString).length) == "SELECT 2\n  FROM t")
        #expect(statements[1].range == NSRange(location: 11, length: 17))
        let selection = DatabaseWorkspace.statements(in: text, scope: .selectionOrFile, caret: 0, selection: NSRange(location: 11, length: 8), dialect: .postgres)
        #expect(selection.map(\.text) == ["SELECT 2"] && selection[0].range.location == 11)
        #expect(DatabaseWorkspace.statements(in: text, scope: .selectionOrFile, caret: 0, selection: NSRange(location: 0, length: 0), dialect: .postgres).count == 2)
    }

    @Test func highlighting() {
        let text = "SELECT count(*), 'a' -- note\nFROM \"T\" WHERE x = 1.5 AND y IS NULL /* c */" as NSString
        let names = SQLSyntax.highlights(in: text, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) + ":" + $0.name }
        #expect(names.contains("SELECT:keyword") && names.contains("count:function") && names.contains("'a':string"))
        #expect(names.contains("-- note:comment") && names.contains("\"T\":property") && names.contains("1.5:number"))
        #expect(names.contains("NULL:constant.builtin") && names.contains("/* c */:comment"))
        // A block comment that starts above the range is still a comment.
        let long = "/* one\ntwo\nthree */ SELECT 1" as NSString
        let inside = SQLSyntax.highlights(in: long, range: NSRange(location: 11, length: 5))
        #expect(inside.contains { $0.name == "comment" && $0.range.location == 0 })
    }
}

// MARK: Completion

struct SQLCompletionTests {
    private let catalog = DBCatalog(schemas: [
        DBSchema(name: "public", tables: [
            DBTable(schema: "public", name: "authors", columns: [DBColumnInfo(name: "id", type: "int4", isPrimaryKey: true),
                                                                 DBColumnInfo(name: "name", type: "text")]),
            DBTable(schema: "public", name: "books", columns: [DBColumnInfo(name: "title", type: "text"),
                                                               DBColumnInfo(name: "author_id", type: "int4")]),
        ]),
        DBSchema(name: "audit", tables: [DBTable(schema: "audit", name: "log", columns: [DBColumnInfo(name: "at", type: "timestamptz")])]),
    ], defaultSchema: "public")

    private func labels(_ text: String, at marker: String = "|") -> [String] {
        let cursor = (text as NSString).range(of: marker).location
        let clean = (text as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "") as NSString
        let lineStart = clean.lineRange(for: NSRange(location: cursor, length: 0)).location
        let line = clean.substring(to: lineStart).components(separatedBy: "\n").count - 1
        return SQLCompletion.items(text: clean, cursor: cursor, line: line, lineStart: lineStart, catalog: catalog, dialect: .postgres, firstID: 1).map(\.label)
    }

    @Test func tablesColumnsAndKeywords() {
        #expect(labels("SELECT na| FROM authors").contains("name"))
        #expect(!labels("SELECT na| FROM authors").contains("title"))
        #expect(labels("SELECT * FROM bo|").contains("books"))
        #expect(labels("SELECT * FROM au|").contains("audit"))
        #expect(labels("sel|").contains("select"))
        #expect(labels("SEL|").contains("SELECT"))
        // After "alias." and "schema.".
        #expect(labels("SELECT b.| FROM books b") == ["title", "author_id"])
        #expect(labels("SELECT a.n| FROM authors AS a JOIN books b ON true").contains("name"))
        #expect(labels("SELECT * FROM audit.|") == ["log"])
        // Not in comments or strings.
        #expect(labels("SELECT 'na|").isEmpty)
        #expect(labels("-- na|").isEmpty)
    }

    @Test func schemaContextForAI() {
        let context = DatabaseWorkspace.schemaContext(catalog, dialect: .postgres, kind: .postgres, mentioning: "select * from books", limit: 4_000)
        #expect(context.hasPrefix("Database: PostgreSQL, default schema public"))
        let lines = context.split(separator: "\n")
        #expect(lines[1] == "TABLE books(title text, author_id int4)")
        #expect(context.contains("TABLE authors(id int4 PK, name text)") && context.contains("TABLE audit.log(at timestamptz)"))
        let capped = DatabaseWorkspace.schemaContext(catalog, dialect: .postgres, kind: .postgres, mentioning: "", limit: 80)
        #expect(capped.contains("tables in all"))
    }
}

// MARK: Protocols

struct DatabaseProtocolTests {
    @Test func scramSHA256MatchesRFC7677() throws {
        let client = SCRAMClient(password: "pencil", nonce: "rOprNGfwEbeRWgbNEkqO", user: "user")
        #expect(client.clientFirstMessage == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
        let final = try client.clientFinal(serverFirst: serverFirst)
        #expect(final.message == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try SCRAMClient.verify(serverFinal: "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=", expected: final.serverSignature)
        #expect(throws: SCRAMClient.Failure.self) { try SCRAMClient.verify(serverFinal: "v=AAAA", expected: final.serverSignature) }
        #expect(throws: SCRAMClient.Failure.self) { try SCRAMClient.verify(serverFinal: "e=invalid-proof", expected: final.serverSignature) }
        // A server nonce that doesn't extend ours.
        #expect(throws: SCRAMClient.Failure.self) { try client.clientFinal(serverFirst: "r=other,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096") }
    }

    @Test func mysqlScrambles() throws {
        let scramble = Array(UInt8(1)...UInt8(20))
        let hex: ([UInt8]) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(MySQLAuth.nativePassword("secret", scramble: scramble)) == "b32bb3a583e1340c0a1108d58b1be49781ad8c2f")
        #expect(hex(MySQLAuth.cachingSHA2("secret", scramble: scramble)) == "746ebe205d56a0707acb3e796e834e0dd7b1d61743b26bd5202c7a623230c7c9")
        #expect(hex(MySQLAuth.xorPassword("secret", scramble: scramble)) == "72676076607207")
        #expect(MySQLAuth.nativePassword("", scramble: scramble).isEmpty && MySQLAuth.cachingSHA2("", scramble: scramble).isEmpty)
        #expect(PostgresDriver.md5Hex(Data("md5hex".utf8)) == "38bb196673f7136f814a22e7966e0992")
    }

    @Test func passwordsGoOnlyOverTLSOrToThisMac() {
        #expect(MySQLDriver.mayRevealPassword(usesTLS: true, host: "db.example.com"))
        #expect(!MySQLDriver.mayRevealPassword(usesTLS: false, host: "db.example.com"))
        for host in ["localhost", "127.0.0.1", "::1", "/tmp/mysql.sock", " LocalHost "] {
            #expect(MySQLDriver.mayRevealPassword(usesTLS: false, host: host), "\(host)")
        }
    }

    @Test func malformedLengthsThrowInsteadOfTrapping() {
        var huge = ByteReader(bytes: [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: DBError.self) { try huge.lengthEncodedBytes() }
        var reader = ByteReader(bytes: [1, 2, 3])
        #expect(throws: DBError.self) { try reader.bytes(Int.max) }
        #expect(throws: DBError.self) { try reader.bytes(-1) }
    }

    @Test func rsaEncryptionWithTheServersKey() throws {
        let publicPEM = """
            -----BEGIN PUBLIC KEY-----
            MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDOvipZYKUOvHPeMn6vXfX/nipF
            lZgeJoziBpOLF0sOiILm8fAl/mKutIsm+/QzcArHtpH63+QNABE+LtO7AEOuO/ea
            drG2EAPc/eUUPn1QjZYH2N/mm563+IvdKIwag+O9PFr12E7ltntoJM7PxuEuleBr
            lszyq7As23Nuy6vBtwIDAQAB
            -----END PUBLIC KEY-----
            """
        let privateDER = try #require(Data(base64Encoded: "MIICXQIBAAKBgQDOvipZYKUOvHPeMn6vXfX/nipFlZgeJoziBpOLF0sOiILm8fAl/mKutIsm+/QzcArHtpH63+QNABE+LtO7AEOuO/eadrG2EAPc/eUUPn1QjZYH2N/mm563+IvdKIwag+O9PFr12E7ltntoJM7PxuEuleBrlszyq7As23Nuy6vBtwIDAQABAoGAODysQmGypF6I2iE8KrHRb7XzY7g8h78OxZDqY4Rzi0GA8hdPrtYSu9kqnPEeTTumAwtbjDWI0Cx7hEGyoISC5A3yJAWYzhdMT0qtQtOY7QU23BQiFlyvmyiX7dq72y8Z+4GipBo6LGM669LB67DN9sxTvSVpuuz3JSlDEsBWIpECQQDvrmYw6KlEPp1pas4LStjKVy6S8Jg9+NNpKvgJCgLIjbGtWwFSnc/QAksFyodje0OLHjRGeovyspM8d8pjSPkfAkEA3NGn2Pr00Bn+eIn9z+KhYGuImPLuoRzl+pc9+YeM/4Qh/qm2GaQuZJ+VhaOArzJIz2oYR3LzeMGZ5wK1D0vsaQJBAM0dDZ0rbrfVcfamDWCClBZNF7FuLotSZvHocM2jgJBLGlPFvtMJ9K8JV1TEZqrO8RWcKpZqB1wSUIh953iiGXcCQEBqcJpdavkh/BfRuVbhd84W0Hw9sdsSAQy+/fdC0aDgPMJ7Y4HLYTU9UHLxpWJ2OsM24epF4DyDzY+UPJk/vrECQQDeyavwIH3sjrqWafL+fkCjVzUI8Z8Ut1al8t+bhTxPjTsyfwhSLdgfSYYsan5+bcfP2S1U/uYDWwQirmX0el63"))
        let plain = MySQLAuth.xorPassword("secret", scramble: Array(UInt8(1)...UInt8(20)))
        let encrypted = try MySQLAuth.rsaEncrypt(plain, publicKeyPEM: publicPEM)
        #expect(encrypted.count == 128)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        let key = try #require(SecKeyCreateWithData(privateDER as CFData, attributes as CFDictionary, nil))
        let decrypted = try #require(SecKeyCreateDecryptedData(key, .rsaEncryptionOAEPSHA1, encrypted as CFData, nil)) as Data
        #expect(Array(decrypted) == plain)
        #expect(throws: DBError.self) { try MySQLAuth.rsaEncrypt(plain, publicKeyPEM: "not a key") }
    }

    @Test func mysqlPacketPieces() throws {
        #expect(MySQLDriver.lengthEncoded(250) == [250])
        #expect(MySQLDriver.lengthEncoded(251) == [0xFC, 251, 0])
        #expect(MySQLDriver.lengthEncoded(70_000) == [0xFD, 0x70, 0x11, 0x01])
        #expect(MySQLDriver.lengthEncoded(1 << 24) == [0xFE, 0, 0, 0, 1, 0, 0, 0, 0])
        var reader = ByteReader(bytes: [0xFC, 0x10, 0x27, 0xFB, 3, 0x61, 0x62, 0x63, 0xFE, 1, 0, 0, 0, 0, 0, 0, 0])
        #expect(try reader.lengthEncodedInt() == 10_000)
        #expect(try reader.lengthEncodedInt() == nil) // NULL
        #expect(try reader.lengthEncodedString() == "abc")
        #expect(try reader.lengthEncodedInt() == 1)
        #expect(throws: DBError.self) { try reader.byte() }

        // A handshake v10 greeting.
        var greeting = Data([10])
        greeting.appendCString("9.1.0")
        greeting.append(contentsOf: [42, 0, 0, 0])
        greeting.append(contentsOf: Array(UInt8(1)...UInt8(8)))
        greeting.append(0)
        let capabilities: UInt32 = 0xFFFF_F7FF | MySQLDriver.Capability.ssl
        greeting.appendLE(UInt64(capabilities & 0xFFFF), bytes: 2)
        greeting.append(255)
        greeting.append(contentsOf: [2, 0])
        greeting.appendLE(UInt64(capabilities >> 16), bytes: 2)
        greeting.append(21)
        greeting.append(contentsOf: [UInt8](repeating: 0, count: 10))
        greeting.append(contentsOf: Array(UInt8(9)...UInt8(20)) + [0])
        greeting.appendCString("caching_sha2_password")
        let parsed = try MySQLGreeting(payload: greeting)
        #expect(parsed.serverVersion == "9.1.0" && parsed.connectionID == 42 && parsed.authPlugin == "caching_sha2_password")
        #expect(parsed.scramble == Array(UInt8(1)...UInt8(20)))
        let request = try #require(MySQLDriver.sslRequest(greetingPayload: greeting, database: true))
        #expect(request.count == 36 && Array(request.prefix(4)) == [32, 0, 0, 1])
        var flags = ByteReader(bytes: Array(request.dropFirst(4)))
        let client = UInt32(try flags.uintLE(4))
        #expect(client & MySQLDriver.Capability.ssl != 0 && client & MySQLDriver.Capability.connectWithDB != 0)
        #expect(client & MySQLDriver.Capability.deprecateEOF != 0 && client & MySQLDriver.Capability.multiStatements != 0)
        // An error instead of a greeting (too many connections, say).
        var error = Data([0xFF, 0x10, 0x04])
        error.append(contentsOf: Array("Too many connections".utf8))
        #expect(throws: DBError.self) { try MySQLGreeting(payload: error) }
    }

    @Test func mysqlErrors() {
        var packet: [UInt8] = [0xFF, 0x28, 0x04] + Array("#42000".utf8)
        packet += Array("You have an error in your SQL syntax; check the manual that corresponds to your MySQL server version for the right syntax to use near 'FRM t' at line 2".utf8)
        let error = MySQLDriver.parseError(packet, sql: "SELECT 1\nSELECT a FRM t", connection: false)
        #expect(error.code == "1064" && error.detail == "SQLSTATE 42000" && error.position == 18 && !error.isConnectionError)
        #expect(MySQLDriver.errorPosition(message: "Unknown column 'x' in 'field list'", sql: "SELECT x") == nil)
    }

    @Test func postgresMessages() {
        #expect(PostgresDriver.affectedRows("INSERT 0 3") == 3)
        #expect(PostgresDriver.affectedRows("UPDATE 2") == 2)
        #expect(PostgresDriver.affectedRows("SELECT 5") == nil)
        #expect(PostgresDriver.affectedRows("CREATE TABLE") == nil)
        var body = Data()
        for (code, value) in [("S", "ERROR"), ("V", "ERROR"), ("C", "42601"), ("M", "syntax error at or near \"y\""), ("P", "13"), ("H", "Check it")] {
            body.append(contentsOf: Array(code.utf8))
            body.appendCString(value)
        }
        body.append(0)
        let error = PostgresDriver.parseError(body, sql: "SELECT '😀' x y")
        #expect(error.code == "42601" && error.hint == "Check it" && error.position == 13 && !error.isConnectionError)
        #expect(error.fullMessage == "syntax error at or near \"y\" (42601)\nHint: Check it")
    }

    @Test func postgresTextDecoding() {
        func decode(_ text: String, _ oid: Int32) -> DBValue { PostgresDriver.decode(ArraySlice(Array(text.utf8)), oid: oid) }
        #expect(decode("t", 16) == .bool(true) && decode("f", 16) == .bool(false))
        #expect(decode("-42", 23) == .int(-42) && decode("9223372036854775807", 20) == .int(.max))
        #expect(decode("1.5e3", 701) == .float(1500))
        if case .float(let nan) = decode("NaN", 701) { #expect(nan.isNaN) } else { Issue.record("NaN") }
        #expect(decode("123.4500", 1700) == .decimal("123.4500"))
        #expect(decode("\\x00ff", 17) == .bytes(Data([0, 0xFF])))
        #expect(decode("a\\000b\\\\", 17) == .bytes(Data([97, 0, 98, 92])))
        #expect(decode("{\"a\": 1}", 3802) == .json("{\"a\": 1}"))
        #expect(decode("2024-01-02 03:04:05+07", 1184) == .date("2024-01-02 03:04:05+07"))
        #expect(decode("{1,2}", 1007) == .text("{1,2}"))
    }

    @Test func offsets() {
        #expect("a😀b".utf16Offset(ofScalar: 2) == 3)
        #expect("üx".utf16Offset(ofUTF8: 2) == 1)
        #expect(SQLDialect.postgres.quote("Order") == "\"Order\"" && SQLDialect.postgres.quote("orders") == "orders")
        #expect(SQLDialect.postgres.quote("select") == "\"select\"" && SQLDialect.mysql.quote("my`t") == "`my``t`")
        #expect(SQLDialect.mysql.literal("it's \\ ok") == "'it''s \\\\ ok'")
    }
}

// MARK: Results

struct DatabaseResultsTests {
    private let columns = [DBColumn(name: "id", typeName: "INT"), DBColumn(name: "name", typeName: "TEXT"),
                           DBColumn(name: "data", typeName: "BLOB"), DBColumn(name: "j", typeName: "JSON")]
    private let rows: [[DBValue]] = [[.int(1), .text("a,\"b\""), .bytes(Data([1, 2])), .json("{\"x\":1}")],
                                     [.int(2), .null, .null, .null]]

    @Test func exports() {
        #expect(DBExport.csv(columns, rows) == "id,name,data,j\r\n1,\"a,\"\"b\"\"\",0x0102,\"{\"\"x\"\":1}\"\r\n2,,,\r\n")
        #expect(DBExport.json(columns, rows) == """
            [
              {"id": 1, "name": "a,\\"b\\"", "data": "0x0102", "j": {"x":1}},
              {"id": 2, "name": null, "data": null, "j": null}
            ]

            """)
        #expect(DBExport.inserts(columns, rows, dialect: .postgres, table: "t") == """
            INSERT INTO t (id, name, data, j) VALUES (1, 'a,"b"', '\\x0102'::bytea, '{"x":1}');
            INSERT INTO t (id, name, data, j) VALUES (2, NULL, NULL, NULL);

            """)
        #expect(DBExport.inserts(columns, [rows[0]], dialect: .mysql, table: "`t`").contains("0x0102"))
        #expect(DBExport.inserts(columns, [rows[0]], dialect: .sqlite, table: "t").contains("X'0102'"))
        #expect(DBExport.markdown([DBColumn(name: "a|b", typeName: "")], [[.text("x\ny")], [.null]]) == "| a\\|b |\n| --- |\n| x<br>y |\n| NULL |\n")
        #expect(DBExport.tsv(columns, [[.int(1), .text("a\tb\nc"), .null, .bool(true)]], header: false) == "1\ta b c\t\ttrue")
        #expect(DBExport.json([DBColumn(name: "x", typeName: ""), DBColumn(name: "x", typeName: "")], [[.float(.infinity), .decimal("1.50")]])
            == "[\n  {\"x\": \"Infinity\", \"x_2\": 1.50}\n]\n")
    }

    @Test func valuesSortAndShow() {
        let values: [DBValue] = [.text("b10"), .null, .int(3), .float(2.5), .text("b9")]
        #expect(values.sorted(by: DBValue.ordered) == [.null, .float(2.5), .int(3), .text("b9"), .text("b10")])
        #expect(DBValue.float(3).displayText == "3" && DBValue.bytes(Data([0xAB])).displayText == "0xab" && DBValue.null.plainText.isEmpty)
    }

    @MainActor @Test func resultsTabSegmentsAndSummaries() {
        let tab = DatabaseResultsTab(key: "k", title: "Results: q.sql")
        tab.rename("other.sql")
        #expect(tab.title == "Results: other.sql")
        var first = DBStatementOutcome(sql: "SELECT 1", offset: 0)
        first.execution = DBExecution(resultSets: [DBResultSet(columns: [DBColumn(name: "a", typeName: "int")], rows: [[.int(1)]], totalRows: 1)])
        var second = DBStatementOutcome(sql: "UPDATE t SET a = 1", offset: 9)
        second.execution = DBExecution(resultSets: [DBResultSet(affectedRows: 3)])
        var third = DBStatementOutcome(sql: "SELECT * FROM big", offset: 30)
        third.execution = DBExecution(resultSets: [DBResultSet(columns: [DBColumn(name: "b", typeName: "")], rows: [[.null]], totalRows: 50)],
                                      error: DBError("boom"))
        tab.outcomes = [first, second, third]
        #expect(tab.segments.map(\.title) == ["Result 1", "Result 2"])
        #expect(tab.selectedResultSet?.rows == [[.int(1)]])
        tab.selectedSegment = 1
        #expect(tab.selectedResultSet?.totalRows == 50 && tab.selectedResultSet?.isTruncated == true)
        tab.selectedSegment = 2
        #expect(tab.selectedResultSet == nil) // Messages
        #expect(first.summary == "1 row" && second.summary == "3 rows affected" && third.summary == "1 of 50 rows — Error: boom")
        #expect(tab.firstError?.error.message == "boom")
    }

    @MainActor @Test func historyIsKeptNewestFirst() throws {
        let file = try temporaryFolder().appending(path: "h.json")
        let history = DatabaseHistory(file: file)
        for i in 0..<105 { history.add(DatabaseHistoryEntry(date: Date(), sql: "SELECT \(i)", duration: 0.1, rows: i)) }
        history.add(DatabaseHistoryEntry(date: Date(), sql: "SELECT 50", duration: 0.2, rows: 1))
        #expect(history.entries.count == DatabaseHistory.limit)
        #expect(history.entries.first?.sql == "SELECT 50" && history.entries.filter { $0.sql == "SELECT 50" }.count == 1)
        let reloaded = DatabaseHistory(file: file)
        #expect(reloaded.entries.map(\.sql) == history.entries.map(\.sql) && reloaded.entries.map(\.rows) == history.entries.map(\.rows))
        reloaded.clear()
        #expect(DatabaseHistory(file: file).entries.isEmpty)
    }
}

// MARK: SQLite, end to end

@Suite(.serialized)
struct SQLiteDriverTests {
    private func makeDatabase() async throws -> (SQLiteDriver, URL) {
        let url = try temporaryFolder().appending(path: "test.sqlite")
        var config = DatabaseConnectionConfig(kind: .sqlite)
        config.file = url.path
        let driver = try SQLiteDriver(config: config)
        let setup = try await driver.run("""
            CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL, born DATE, active BOOLEAN DEFAULT 1);
            CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id), title TEXT DEFAULT 'untitled',
                                cover BLOB, price NUMERIC);
            CREATE UNIQUE INDEX books_title ON books(title);
            CREATE VIEW titles AS SELECT title FROM books;
            INSERT INTO authors (name, born) VALUES ('Ann', '1970-01-02'), ('Bø ☃', NULL);
            """, rowLimit: 10)
        #expect(setup.error == nil)
        #expect(setup.resultSets.count == 5)
        #expect(setup.resultSets[0].command == "CREATE" && setup.resultSets[4].affectedRows == 2)
        return (driver, url)
    }

    @Test func typesAndMultipleStatements() async throws {
        let (driver, _) = try await makeDatabase()
        let execution = try await driver.run("""
            SELECT id, name, born, active, 1.5 AS f, x'00ff' AS raw, NULL AS n FROM authors ORDER BY id;
            UPDATE authors SET active = 0 WHERE id = 2;
            SELECT count(*) AS c FROM authors WHERE active
            """, rowLimit: 100)
        #expect(execution.error == nil && execution.resultSets.count == 3)
        let set = execution.resultSets[0]
        #expect(set.columns.map(\.typeName) == ["INTEGER", "TEXT", "DATE", "BOOLEAN", "REAL", "BLOB", ""])
        #expect(set.rows == [[.int(1), .text("Ann"), .date("1970-01-02"), .bool(true), .float(1.5), .bytes(Data([0, 0xFF])), .null],
                             [.int(2), .text("Bø ☃"), .null, .bool(true), .float(1.5), .bytes(Data([0, 0xFF])), .null]])
        #expect(set.columns[1].table == "authors")
        #expect(execution.resultSets[1].affectedRows == 1)
        #expect(execution.resultSets[2].rows == [[.int(1)]])
        #expect(await driver.serverVersion.hasPrefix("SQLite 3."))
    }

    @Test func errorsWithPositions() async throws {
        let (driver, _) = try await makeDatabase()
        let failed = try await driver.run("SELECT 1; SELECT * FROM nowhere", rowLimit: 10)
        #expect(failed.resultSets.count == 1)
        #expect(failed.error?.message == "no such table: nowhere")
        #expect(failed.error?.position == 24)
        let column = try await driver.run("SELECT 'ü', nope FROM authors", rowLimit: 10)
        #expect(column.error?.message == "no such column: nope" && column.error?.position == 12)
        let constraint = try await driver.run("INSERT INTO authors (id, name) VALUES (1, 'dup')", rowLimit: 1)
        #expect(constraint.error?.code?.contains("constraint") == true)
    }

    @Test func cancelAndRowLimit() async throws {
        let (driver, _) = try await makeDatabase()
        let start = ContinuousClock.now
        let task = Task { try await driver.run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c", rowLimit: 1) }
        try await Task.sleep(for: .milliseconds(200))
        driver.cancel()
        let execution = try await task.value
        #expect(execution.error == .cancelled)
        #expect(ContinuousClock.now - start < .seconds(5))
        let many = try await driver.run("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 25000) SELECT x FROM c", rowLimit: 10_000)
        #expect(many.resultSets.first?.rows.count == 10_000 && many.resultSets.first?.totalRows == 25_000)
    }

    @Test func introspectionAndDDL() async throws {
        let (driver, _) = try await makeDatabase()
        let catalog = try await driver.catalog()
        #expect(catalog.defaultSchema == "main" && catalog.schemas.count == 1)
        let tables = catalog.allTables
        #expect(tables.map(\.name) == ["authors", "books", "titles"])
        let books = tables[1]
        #expect(books.columns.map(\.name) == ["id", "author_id", "title", "cover", "price"])
        #expect(books.columns[0].isPrimaryKey && books.columns[2].defaultValue == "'untitled'")
        #expect(books.foreignKeys == [DBForeignKey(name: "fk_books_0", columns: ["author_id"], referencedSchema: "main", referencedTable: "authors", referencedColumns: ["id"])])
        #expect(books.indexes.contains { $0.name == "books_title" && $0.isUnique && $0.columns == ["title"] })
        #expect(tables[2].kind == .view && tables[2].columns.map(\.name) == ["title"])
        let ddl = try await driver.ddl(for: books)
        #expect(ddl.hasPrefix("CREATE TABLE books") && ddl.contains("CREATE UNIQUE INDEX books_title"))
    }

    @Test func readOnlyAndNotADatabase() async throws {
        let (driver, url) = try await makeDatabase()
        await driver.close()
        var config = DatabaseConnectionConfig(kind: .sqlite)
        config.file = url.path
        config.readOnly = true
        let readOnly = try SQLiteDriver(config: config)
        #expect(try await readOnly.run("INSERT INTO authors (name) VALUES ('x')", rowLimit: 1).error?.message.contains("readonly") == true)
        #expect(try await readOnly.run("SELECT count(*) FROM authors", rowLimit: 1).resultSets.first?.rows == [[.int(2)]])
        let text = url.deletingLastPathComponent().appending(path: "notes.db")
        try "just text, not a database".write(to: text, atomically: true, encoding: .utf8)
        config.file = text.path
        config.readOnly = false
        #expect(throws: DBError.self) { _ = try SQLiteDriver(config: config) }
        // Found by its header, whatever its name; a text file named .db stays text.
        let renamed = url.deletingLastPathComponent().appending(path: "data.bin")
        try FileManager.default.copyItem(at: url, to: renamed)
        #expect(FileKind.detect(renamed) == .sqlite && FileKind.detect(text) == .text)
    }
}

// MARK: The workspace

@MainActor
@Suite(.serialized)
struct DatabaseWorkspaceTests {
    private func makeWorkspace(sql: String) async throws -> (Workspace, URL, DatabaseConnectionConfig) {
        let root = try temporaryFolder("omc-db-ws")
        var config = DatabaseConnectionConfig(kind: .sqlite)
        config.file = root.appending(path: "app.sqlite").path
        let driver = try SQLiteDriver(config: config)
        _ = try await driver.run("""
            CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id), title TEXT);
            INSERT INTO authors (name) VALUES ('Ann'), ('Bob');
            """, rowLimit: 1)
        await driver.close()
        try sql.write(to: root.appending(path: "query.sql"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.database.storageRoot = root.appending(path: ".storage")
        workspace.database.passwords = InMemoryDatabasePasswords()
        return (workspace, root, config)
    }

    private func makeEditor(for document: EditorDocument) -> (EditorController, NSWindow) {
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.attach(controller)
        document.editor = controller
        return (controller, window)
    }

    private func key(_ window: NSWindow, shift: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : .command, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\r",
                                      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    @Test func openingASQLiteFileShowsItsTables() async throws {
        let (workspace, root, _) = try await makeWorkspace(sql: "")
        workspace.open(fileAt: root.appending(path: "app.sqlite"))
        let viewer = try #require(workspace.activeViewer)
        #expect(viewer.kind == .database)
        let config = try #require(workspace.database.connections.first { $0.kind == .sqlite })
        #expect(config.scope == .transient && config.displayName == "app.sqlite")
        #expect(try await eventually { workspace.database.sessions[config.id]?.catalog?.allTables.map(\.name) == ["authors", "books"] })
        // Opening it again doesn't add another connection; Open as Hex still works.
        workspace.database.openSQLiteFile(root.appending(path: "app.sqlite"))
        #expect(workspace.database.connections.count == 1)
        workspace.reopenAsHex(viewer)
        #expect(workspace.activeViewer?.kind == .hex)
    }

    @Test func commandReturnRunsTheStatementAtTheCaret() async throws {
        let (workspace, root, config) = try await makeWorkspace(sql: "SELECT 1 AS one;\n\nSELECT name FROM authors ORDER BY id;\n")
        let saved = workspace.database.openSQLiteFile(URL(fileURLWithPath: try #require(config.file)))
        workspace.open(fileAt: root.appending(path: "query.sql"))
        let document = try #require(workspace.activeSQLDocument)
        #expect(document.language == .sql)
        workspace.database.setConnection(saved.id, for: document.url)
        #expect(workspace.sqlConnectionLabel == "app.sqlite")
        let (controller, window) = makeEditor(for: document)
        controller.textView.setSelectedRange(NSRange(location: 20, length: 0))
        #expect(controller.handleLineCommandKey(try key(window)))
        #expect(document.textStorage.string == "SELECT 1 AS one;\n\nSELECT name FROM authors ORDER BY id;\n") // not Insert Line Below
        #expect(try await eventually { workspace.database.resultsTabs.first?.state == .done })
        let tab = try #require(workspace.database.resultsTabs.first)
        #expect(tab.outcomes.map(\.sql) == ["SELECT name FROM authors ORDER BY id"])
        #expect(tab.selectedResultSet?.rows == [[.text("Ann")], [.text("Bob")]])
        #expect(workspace.groups.count == 2 && workspace.groups[1].activeDocumentID == tab.id)
        #expect(workspace.tabInfo(tab.id)?.title == "Results: query.sql")

        // ⇧⌘↩: the whole file, in the same tab.
        #expect(controller.handleLineCommandKey(try key(window, shift: true)))
        #expect(try await eventually { tab.state == .done && tab.outcomes.count == 2 })
        #expect(tab.segments.count == 2 && workspace.database.resultsTabs.count == 1)
        #expect(workspace.database.history(for: saved.id).entries.first?.sql == "SELECT name FROM authors ORDER BY id")
        withExtendedLifetime(window) {}

        // The Run lens above each statement.
        #expect(try await eventually { document.codeLenses.keys.sorted() == [0, 2] })
        let lens = try #require(document.codeLenses[0]?.first)
        #expect(lens.title == "Run")
        workspace.run(lens, in: document)
        #expect(try await eventually { tab.state == .done && tab.outcomes.map(\.sql) == ["SELECT 1 AS one"] })

        for group in workspace.groups where group.contains(tab.id) { workspace.closeTab(tab.id, in: group) }
        #expect(workspace.database.resultsTabs.isEmpty)
    }

    @Test func errorsBecomeDiagnostics() async throws {
        let (workspace, root, config) = try await makeWorkspace(sql: "SELECT 1;\nSELECT * FROM nowhere;\n")
        let saved = workspace.database.openSQLiteFile(URL(fileURLWithPath: try #require(config.file)))
        workspace.open(fileAt: root.appending(path: "query.sql"))
        let document = try #require(workspace.activeSQLDocument)
        workspace.database.setConnection(saved.id, for: document.url)
        let tab = try #require(await workspace.database.run(.selectionOrFile, in: document, caret: 0, selection: NSRange(location: 0, length: 0)).value)
        #expect(tab.state == .done && tab.firstError?.error.message == "no such table: nowhere", "\(tab.state) \(tab.outcomes)")
        let diagnostic = try #require(document.diagnostics.first { $0.source == "sql" })
        #expect(diagnostic.range == LSPRange(start: LSPPosition(line: 1, character: 14), end: LSPPosition(line: 1, character: 21)))
        #expect(diagnostic.message.hasPrefix("no such table: nowhere"))
        #expect(tab.selectedSegment == tab.segments.count) // Messages, where it stopped
        // Fixed and run again: the mark goes.
        document.textStorage.replaceCharacters(in: NSRange(location: 24, length: 7), with: "authors")
        _ = await workspace.database.run(.selectionOrFile, in: document, caret: 0, selection: NSRange(location: 0, length: 0)).value
        #expect(!document.diagnostics.contains { $0.source == "sql" })
        #expect(tab.firstError == nil && tab.segments.count == 2)
    }

    @Test func savedConnectionsBindingsAndPasswords() async throws {
        let (workspace, root, _) = try await makeWorkspace(sql: "")
        let database = workspace.database
        var shared = try DatabaseURL.parse("postgres://ann@db.example.com/app?sslmode=require")
        shared.name = "Team DB"
        shared.scope = .workspace
        try database.save(shared, password: "s3cret", savePassword: true)
        var mine = try DatabaseURL.parse("mysql://me@localhost/test")
        mine.scope = .global
        try database.save(mine, password: "typed", savePassword: false)
        let file = try String(contentsOf: root.appending(path: ".omc/databases.json"), encoding: .utf8)
        #expect(file.contains("Team DB") && !file.contains("s3cret") && !file.contains("me@localhost"))
        #expect(database.password(for: shared) == "s3cret" && database.password(for: mine) == "typed")
        #expect(database.passwords.password(for: mine.id) == nil) // not saved

        // Another window on the folder reads both, and the file's connection.
        let query = root.appending(path: "query.sql")
        database.setConnection(shared.id, for: query)
        let other = DatabaseWorkspace(workspace: workspace)
        other.storageRoot = root.appending(path: ".storage")
        #expect(other.connections.map(\.displayName) == ["Team DB", "me@localhost/test"])
        #expect(other.connections.map(\.scope) == [.workspace, .global])
        #expect(other.connectionID(for: query) == shared.id)

        database.delete(shared)
        #expect(database.connections.count == 1 && database.passwords.password(for: shared.id) == nil)
        #expect(database.connectionID(for: query) == nil)
    }

    @Test func treeActions() async throws {
        let (workspace, root, config) = try await makeWorkspace(sql: "")
        let database = workspace.database
        let saved = database.openSQLiteFile(URL(fileURLWithPath: try #require(config.file)))
        #expect(try await eventually { database.sessions[saved.id]?.catalog != nil })
        let authors = try #require(database.sessions[saved.id]?.catalog?.table(named: "authors"))

        let tab = try #require(await database.selectTop(authors, on: saved.id)?.value)
        #expect(workspace.activeSQLDocument?.textStorage.string == "SELECT * FROM authors LIMIT 100;\n")
        #expect(tab.selectedResultSet?.rows.count == 2)

        // Completion knows the tables now.
        let document = try #require(workspace.activeSQLDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: document.textStorage.length), with: "SELECT na FROM authors")
        #expect(document.sqlCompletions(at: 9, firstID: 1).contains { $0.label == "name" })
        #expect(database.schemaContext(for: document)?.contains("TABLE authors(id INTEGER PK, name TEXT)") == true)

        // Drop asks first.
        var asked: String?
        database.confirmAction = { asked = $0; return false }
        #expect(database.destroy(authors, on: saved.id, .drop) == nil)
        #expect(asked?.contains("DROP TABLE authors") == true)
        let books = try #require(database.sessions[saved.id]?.catalog?.table(named: "books"))
        database.confirmAction = { _ in true }
        let dropped = try #require(await database.destroy(books, on: saved.id, .drop)?.value)
        #expect(dropped.firstError == nil)
        #expect(try await eventually { database.sessions[saved.id]?.catalog?.table(named: "books") == nil })
        _ = await database.destroy(authors, on: saved.id, .truncate)?.value
        let count = try #require(await database.run(sql: "SELECT count(*) FROM authors", on: saved.id, title: "check").value)
        #expect(count.selectedResultSet?.rows == [[.int(0)]])
        _ = root
    }
}
