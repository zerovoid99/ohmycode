import Foundation
import Testing
@testable import Oh_My_Code

// Against real servers: scripts/dbtest/start.sh starts throwaway PostgreSQL and MySQL servers and
// prints the OMC_TEST_* URLs these read (pass them to xcodebuild as TEST_RUNNER_OMC_TEST_…).
// Without them every test here is skipped.

private func environment(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
}

private func config(_ name: String) throws -> DatabaseConnectionConfig {
    try DatabaseURL.parse(try #require(environment(name)))
}

private func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

@Suite(.serialized, .enabled(if: environment("OMC_TEST_POSTGRES_URL") != nil, "Postgres test server not running (scripts/dbtest/start.sh)"))
struct PostgresServerTests {
    private func connect(_ variable: String = "OMC_TEST_POSTGRES_URL", change: (inout DatabaseConnectionConfig) -> Void = { _ in }) async throws -> PostgresDriver {
        var config = try config(variable)
        change(&config)
        return try await PostgresDriver.connect(config)
    }

    @Test func scramSignInAndTypes() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        #expect(await driver.serverVersion.hasPrefix("PostgreSQL 17"))
        #expect(await driver.usesTLS == false)
        let execution = try await driver.run("""
            SELECT 1 AS one, 'héllo ☃ 日本' AS t, NULL::text AS n, true AS b, 1.5::float8 AS f, 12.345::numeric AS d,
                   '\\x00ff10'::bytea AS raw, '{"a": 1}'::jsonb AS j, DATE '2024-01-02' AS dt, 9223372036854775807::int8 AS big
            """, rowLimit: 100)
        #expect(execution.error == nil)
        let set = try #require(execution.resultSets.first)
        #expect(set.columns.map(\.name) == ["one", "t", "n", "b", "f", "d", "raw", "j", "dt", "big"])
        #expect(set.columns.map(\.typeName) == ["int4", "text", "text", "bool", "float8", "numeric", "bytea", "jsonb", "date", "int8"])
        #expect(set.rows == [[.int(1), .text("héllo ☃ 日本"), .null, .bool(true), .float(1.5), .decimal("12.345"),
                              .bytes(Data([0, 0xFF, 0x10])), .json(#"{"a": 1}"#), .date("2024-01-02"), .int(.max)]])
    }

    @Test func md5AndCleartextSignInAndWrongPassword() async throws {
        let md5 = try await connect("OMC_TEST_POSTGRES_MD5_URL")
        #expect(try await md5.run("SELECT current_user", rowLimit: 1).resultSets.first?.rows == [[.text("omc_md5")]])
        await md5.close()
        let plain = try await connect("OMC_TEST_POSTGRES_PLAIN_URL")
        #expect(try await plain.run("SELECT current_user", rowLimit: 1).resultSets.first?.rows == [[.text("omc_plain")]])
        await plain.close()
        await #expect(throws: DBError.self) { _ = try await connect { $0.password = "wrong" } }
        do {
            _ = try await connect { $0.password = "wrong" }
        } catch let error as DBError {
            #expect(error.message.contains("password authentication failed"))
            #expect(error.code == "28P01")
        }
    }

    @Test func tlsModes() async throws {
        // verify-full against the test server's own root.
        let verified = try await connect("OMC_TEST_POSTGRES_TLS_URL")
        #expect(await verified.usesTLS)
        #expect(try await verified.run("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", rowLimit: 1).resultSets.first?.rows == [[.bool(true)]])
        await verified.close()
        // require: TLS without checking the certificate.
        let required = try await connect { $0.sslMode = .require }
        #expect(await required.usesTLS)
        await required.close()
        let preferred = try await connect { $0.sslMode = .prefer }
        #expect(await preferred.usesTLS)
        await preferred.close()
        // verify-full without the root: the self-signed certificate isn't trusted.
        await #expect(throws: DBError.self) {
            _ = try await connect("OMC_TEST_POSTGRES_TLS_URL") { $0.rootCertificate = nil }
        }
    }

    @Test func multipleResultSetsNoticesAndErrors() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        let execution = try await driver.run("""
            SELECT 1; SELECT 2 AS a, 3 AS b; CREATE TEMP TABLE t (x int); INSERT INTO t VALUES (1), (2);
            DO $$ BEGIN RAISE NOTICE 'hello from %', 'plpgsql'; END $$;
            """, rowLimit: 100)
        #expect(execution.error == nil)
        #expect(execution.resultSets.count == 5)
        #expect(execution.resultSets[1].rows == [[.int(2), .int(3)]])
        #expect(execution.resultSets[2].command == "CREATE TABLE")
        #expect(execution.resultSets[3].affectedRows == 2)
        #expect(execution.messages.first?.text == "hello from plpgsql")

        let failed = try await driver.run("SELECT 1;\nSELECT * FROM nowhere", rowLimit: 10)
        #expect(failed.resultSets.count == 1)
        #expect(failed.error?.code == "42P01")
        #expect(failed.error?.position == 24) // "nowhere"
        let syntax = try await driver.run("SELECT 'ü' FRM t", rowLimit: 10)
        #expect(syntax.error?.code == "42601")
        #expect(syntax.error?.position == 15) // characters, not bytes
        // Still usable.
        #expect(try await driver.run("SELECT 42", rowLimit: 1).resultSets.first?.rows == [[.int(42)]])
    }

    @Test func cancelsALongQuery() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        let start = ContinuousClock.now
        let task = Task { try await driver.run("SELECT pg_sleep(10)", rowLimit: 1) }
        try await Task.sleep(for: .milliseconds(500))
        driver.cancel()
        let execution = try await task.value
        #expect(execution.error?.code == "57014")
        #expect(elapsed(start) < 5)
        #expect(try await driver.run("SELECT 1", rowLimit: 1).resultSets.first?.rows == [[.int(1)]])
    }

    @Test func manyRowsStopAtTheLimit() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        let execution = try await driver.run("SELECT g, md5(g::text) FROM generate_series(1, 50000) g", rowLimit: 10_000)
        let set = try #require(execution.resultSets.first)
        #expect(set.rows.count == 10_000 && set.totalRows == 50_000 && set.isTruncated)
        #expect(set.rows.last?.first == .int(10_000))
    }

    @Test func introspection() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        let schema = "omc_t\(UInt32.random(in: 0...999_999))"
        let setup = try await driver.run("""
            CREATE SCHEMA \(schema);
            CREATE TABLE \(schema).authors (id serial PRIMARY KEY, name text NOT NULL, born date);
            CREATE TABLE \(schema).books (id bigint PRIMARY KEY, author_id int REFERENCES \(schema).authors(id), title varchar(200) DEFAULT 'untitled');
            CREATE UNIQUE INDEX books_title ON \(schema).books (title);
            CREATE VIEW \(schema).titles AS SELECT title FROM \(schema).books;
            """, rowLimit: 1)
        #expect(setup.error == nil)
        defer { Task { _ = try? await driver.run("DROP SCHEMA \(schema) CASCADE", rowLimit: 0) } }
        let catalog = try await driver.catalog()
        #expect(catalog.defaultSchema == "public")
        let tables = try #require(catalog.schemas.first { $0.name == schema }).tables
        #expect(tables.map(\.name) == ["authors", "books", "titles"])
        let books = tables[1]
        #expect(books.columns.map(\.name) == ["id", "author_id", "title"])
        #expect(books.columns[0].isPrimaryKey && !books.columns[0].isNullable)
        #expect(books.columns[2].type == "character varying(200)" && books.columns[2].defaultValue?.contains("untitled") == true)
        #expect(books.foreignKeys.first?.referencedTable == "authors" && books.foreignKeys.first?.columns == ["author_id"])
        #expect(books.indexes.contains { $0.name == "books_title" && $0.isUnique && $0.columns == ["title"] })
        #expect(tables[2].kind == .view)
        let ddl = try await driver.ddl(for: books)
        #expect(ddl.contains("CREATE TABLE \(schema).books") && ddl.contains("FOREIGN KEY (author_id)") && ddl.contains("CREATE UNIQUE INDEX books_title"))
        #expect(try await driver.ddl(for: tables[2]).contains("SELECT title"))
    }
}

@Suite(.serialized, .enabled(if: environment("OMC_TEST_MYSQL_URL") != nil, "MySQL test server not running (scripts/dbtest/start.sh)"))
struct MySQLServerTests {
    private func connect(_ variable: String = "OMC_TEST_MYSQL_URL", change: (inout DatabaseConnectionConfig) -> Void = { _ in }) async throws -> MySQLDriver {
        var config = try config(variable)
        change(&config)
        return try await MySQLDriver.connect(config)
    }

    @Test func cachingSHA2FullAndFastSignIn() async throws {
        // Empty the server's cache, so the next sign-in is a full one.
        let first = try await connect("OMC_TEST_MYSQL_TLS_URL")
        #expect(try await first.run("FLUSH PRIVILEGES", rowLimit: 0).error == nil)
        await first.close()
        let rsa = try await connect()
        #expect(await rsa.signInPath == "caching_sha2_password full (RSA)")
        #expect(await rsa.usesTLS == false)
        await rsa.close()
        let fast = try await connect()
        #expect(await fast.signInPath == "caching_sha2_password fast")
        await fast.close()
        // Over TLS the full sign-in sends the password itself.
        let flush = try await connect()
        _ = try await flush.run("FLUSH PRIVILEGES", rowLimit: 0)
        await flush.close()
        let tls = try await connect("OMC_TEST_MYSQL_TLS_URL")
        #expect(await tls.signInPath == "caching_sha2_password full (TLS)")
        await tls.close()
        do {
            _ = try await connect { $0.password = "wrong" }
            Issue.record("signed in with a wrong password")
        } catch let error as DBError {
            #expect(error.code == "1045" && error.message.contains("Access denied"))
        }
    }

    @Test func nativePasswordUser() async throws {
        guard environment("OMC_TEST_MYSQL_NATIVE_URL") != nil else { return } // removed from MySQL 9
        let driver = try await connect("OMC_TEST_MYSQL_NATIVE_URL")
        #expect(await driver.signInPath == "mysql_native_password")
        await driver.close()
    }

    @Test func tls() async throws {
        let driver = try await connect("OMC_TEST_MYSQL_TLS_URL")
        #expect(await driver.usesTLS)
        let cipher = try await driver.run("SHOW SESSION STATUS LIKE 'Ssl_cipher'", rowLimit: 1).resultSets.first?.rows.first?.last
        #expect(cipher?.plainText.isEmpty == false)
        await driver.close()
        let preferred = try await connect { $0.sslMode = .prefer }
        #expect(await preferred.usesTLS)
        await preferred.close()
    }

    @Test func typesMultipleResultsAndErrors() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        #expect(await driver.serverVersion.hasPrefix("MySQL"))
        let execution = try await driver.run("""
            SELECT 1 AS one, 'héllo ☃ 日本' AS t, NULL AS n, 1.5e0 AS f, CAST(12.345 AS DECIMAL(10,3)) AS d, X'00FF10' AS raw,
                   CAST('{"a": 1}' AS JSON) AS j, DATE '2024-01-02' AS dt, CAST(18446744073709551615 AS UNSIGNED) AS big;
            CREATE TEMPORARY TABLE t (id INT PRIMARY KEY, b BLOB);
            INSERT INTO t VALUES (1, X'00FF'), (2, NULL);
            SELECT * FROM t ORDER BY id
            """, rowLimit: 100)
        #expect(execution.error == nil)
        #expect(execution.resultSets.count == 4)
        let row = try #require(execution.resultSets.first?.rows.first)
        #expect(row[0] == .int(1) && row[1] == .text("héllo ☃ 日本") && row[2] == .null && row[3] == .float(1.5))
        #expect(row[4] == .decimal("12.345") && row[5] == .bytes(Data([0, 0xFF, 0x10])) && row[6] == .json(#"{"a": 1}"#))
        #expect(row[7] == .date("2024-01-02") && row[8] == .decimal("18446744073709551615"))
        #expect(execution.resultSets[2].affectedRows == 2)
        #expect(execution.resultSets[3].rows == [[.int(1), .bytes(Data([0, 0xFF]))], [.int(2), .null]])
        #expect(execution.resultSets[3].columns.map(\.typeName) == ["INT", "BLOB"])

        let failed = try await driver.run("SELECT 1;\nSELEC 2", rowLimit: 10)
        #expect(failed.resultSets.count == 1)
        #expect(failed.error?.code == "1064")
        #expect(failed.error?.position == 10)
        let missing = try await driver.run("SELECT * FROM nowhere_at_all", rowLimit: 1)
        #expect(missing.error?.code == "1146")
        #expect(try await driver.run("SELECT 42", rowLimit: 1).resultSets.first?.rows == [[.int(42)]])
    }

    @Test func cancelsALongQuery() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        let start = ContinuousClock.now
        let task = Task { try await driver.run("SELECT SLEEP(10)", rowLimit: 1) }
        try await Task.sleep(for: .milliseconds(500))
        driver.cancel()
        let execution = try await task.value
        #expect(elapsed(start) < 5)
        #expect(execution.error == .cancelled || execution.messages.contains { $0.text == "Cancelled." })
        #expect(try await driver.run("SELECT 1", rowLimit: 1).resultSets.first?.rows == [[.int(1)]])
    }

    @Test func manyRowsStopAtTheLimit() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        let execution = try await driver.run("""
            SET SESSION cte_max_recursion_depth = 100000;
            WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 20000) SELECT n, CONCAT('row ', n) FROM s
            """, rowLimit: 5_000)
        #expect(execution.error == nil)
        let set = try #require(execution.resultSets.last)
        #expect(set.rows.count == 5_000)
        #expect(set.totalRows == 20_000)
    }

    @Test func introspection() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        let setup = try await driver.run("""
            DROP TABLE IF EXISTS books; DROP TABLE IF EXISTS authors; DROP VIEW IF EXISTS titles;
            CREATE TABLE authors (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL);
            CREATE TABLE books (id BIGINT PRIMARY KEY, author_id INT, title VARCHAR(200) DEFAULT 'untitled',
                                UNIQUE KEY books_title (title), CONSTRAINT books_author FOREIGN KEY (author_id) REFERENCES authors(id));
            CREATE VIEW titles AS SELECT title FROM books;
            """, rowLimit: 1)
        #expect(setup.error == nil)
        let catalog = try await driver.catalog()
        #expect(catalog.defaultSchema == "omc_test")
        let tables = try #require(catalog.schemas.first { $0.name == "omc_test" }).tables
        let books = try #require(tables.first { $0.name == "books" })
        #expect(books.columns.map(\.name) == ["id", "author_id", "title"])
        #expect(books.columns[0].isPrimaryKey && books.columns[2].type == "varchar(200)" && books.columns[2].defaultValue == "untitled")
        #expect(books.foreignKeys == [DBForeignKey(name: "books_author", columns: ["author_id"], referencedSchema: "omc_test",
                                                   referencedTable: "authors", referencedColumns: ["id"])])
        #expect(books.indexes.contains { $0.name == "books_title" && $0.isUnique })
        #expect(books.indexes.contains { $0.isPrimary })
        #expect(tables.first { $0.name == "titles" }?.kind == .view)
        #expect(try await driver.ddl(for: books).contains("CREATE TABLE `books`"))
        _ = try await driver.run("DROP VIEW titles; DROP TABLE books; DROP TABLE authors", rowLimit: 0)
    }
}
