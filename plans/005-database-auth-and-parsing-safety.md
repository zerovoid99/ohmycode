# Plan 005: Database connections never reveal the password without TLS, and bad server data fails the query instead of crashing the app

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 98c393c..HEAD -- OhMyCode/Database OhMyCodeTests/DatabaseTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security + bug
- **Planned at**: commit `98c393c`, 2026-11-19

## Why this matters

Oh My Code has its own PostgreSQL and MySQL wire-protocol drivers. Two problems:

1. **MySQL password exposure.** If the server asks for the `mysql_clear_password` method, the driver sends the password in plain text even without TLS. For `caching_sha2_password` "full authentication" without TLS, it encrypts the password with an RSA public key that the *server* sends, unverified. Anyone on the network path (or a hostile host named in a shared `.omc/databases.json`) can get the user's database password. The official MySQL client refuses both unless the user opts in. The default SSL mode is `prefer`, which accepts any certificate, so many connections run without verified TLS.
2. **Crashes on malformed data.** Some counts and lengths read from the server are converted to `Int` in ways that trap (a negative Postgres column count used as a range bound; a 64-bit MySQL length above `Int.max` converted with `Int(_:)`; `index + count` overflow). A broken or hostile server crashes the whole editor — every window, unsaved work restored only via hot exit — instead of failing one query.

## Current state

- `OhMyCode/Database/MySQLDriver.swift`
  - `handshake()` (lines ~245-315): computes the first auth response with `authResponse(plugin: greeting.authPlugin, …)` (so a greeting that names `mysql_clear_password` also sends cleartext in the very first packet), then loops over replies. Auth switch (`0xFE`) recomputes `authResponse` for the new plugin. Full auth (`0x01` + `[0x04]`):
    ```swift
    } else if more == [0x04] {
        // Full authentication: the password in clear over TLS, else RSA-encrypted.
        signInPath = plugin + (wire.usesTLS ? " full (TLS)" : " full (RSA)")
        if wire.usesTLS {
            try await writePacket(Data(Array(password.utf8) + [0]))
        } else {
            try await writePacket(Data([0x02]))
        }
    } else if let pem = String(bytes: more, encoding: .utf8), pem.contains("BEGIN") {
        let encrypted = try MySQLAuth.rsaEncrypt(MySQLAuth.xorPassword(password, scramble: scramble), publicKeyPEM: pem)
        try await writePacket(encrypted)
    ```
  - `authResponse(plugin:password:scramble:)` (lines ~318-325):
    ```swift
    case "mysql_clear_password": return Array(password.utf8) + [0]
    ```
  - Result set column count (line ~416): `let count = Int(try reader.lengthEncodedInt() ?? 0)` then `for _ in 0..<count`.
  - The driver has `private let config: DatabaseConnectionConfig` (line ~154) with `config.host` (a `String`, default `"127.0.0.1"`, `OhMyCode/Database/DatabaseModel.swift:~84`) and `wire.usesTLS`.
- `OhMyCode/Database/PostgresDriver.swift:~309-312`: `let count = Int(try reader.int16())` then `for _ in 0..<count` — a negative count traps.
- `OhMyCode/Database/WireConnection.swift` — `ByteReader`:
  ```swift
  mutating func bytes(_ count: Int) throws -> [UInt8] {
      guard count >= 0, index + count <= data.count else { throw DBError.connection("A message from the server was cut short.") }
      ...
  mutating func lengthEncodedBytes() throws -> [UInt8]? {
      guard let length = try lengthEncodedInt() else { return nil }
      return try bytes(Int(length))
  }
  ```
  `index + count` can overflow for a huge `count`; `Int(length)` traps above `Int.max`.
- Errors: `DBError` (`OhMyCode/Database/DatabaseModel.swift:~361`) with factory functions like `DBError.connection("…")` used everywhere above. Messages are plain user-facing English.
- `DatabaseSSLMode` (`DatabaseModel.swift:~36-48`): `disable`, `prefer` (no certificate check), `require` (no certificate check), `verifyFull`.
- PostgreSQL cleartext password (`PostgresDriver.swift:~183`, auth code 3) is accepted without TLS too — this matches libpq's default behavior and is **out of scope** (considered and left as is).
- Tests: `OhMyCodeTests/DatabaseTests.swift` has pure unit tests of auth helpers (`mysqlScrambles()` ~line 214, `rsaEncryptionWithTheServersKey()` ~line 223). `OhMyCodeTests/DatabaseServerTests.swift` runs against real servers only when `TEST_RUNNER_OMC_TEST_*` URLs are set (skipped otherwise).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild build -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| DB unit tests | `xcodebuild test -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS' -only-testing:OhMyCodeTests/DatabaseTests` | `✔ … passed` (check the suite name with `grep -n "^struct\|@Suite" OhMyCodeTests/DatabaseTests.swift`) |
| Full suite | `… -only-testing:OhMyCodeTests` | `✔ … passed` |
| Optional real servers | `eval "$(scripts/dbtest/start.sh)"`, then the DB tests with `TEST_RUNNER_OMC_TEST_MYSQL_URL="$OMC_TEST_MYSQL_URL" TEST_RUNNER_OMC_TEST_POSTGRES_URL="$OMC_TEST_POSTGRES_URL"`, then `scripts/dbtest/stop.sh "$OMC_DBTEST_DIR"` | pass |

Only start test databases with `scripts/dbtest/start.sh` (it uses a temporary folder and free ports); never `brew services`.

## Scope

**In scope**:
- `OhMyCode/Database/MySQLDriver.swift`
- `OhMyCode/Database/PostgresDriver.swift` (the column-count line only)
- `OhMyCode/Database/WireConnection.swift` (`ByteReader` only)
- `OhMyCodeTests/DatabaseTests.swift`
- `CHANGELOG.md` (`### Fixed`)

**Out of scope**:
- Changing the default SSL mode, the connection form, or `DatabaseConnectionConfig` fields.
- PostgreSQL cleartext auth (libpq-compatible; left as is).
- SCRAM channel binding.

## Git workflow

- Branch: `advisor/005-database-auth-and-parsing-safety`
- Commits like `fix(db): don't send a MySQL password without TLS`, `fix(db): fail the query on malformed counts instead of crashing`. No AI trailers. Do NOT push.

## Steps

### Step 1: A policy for exposing the password

In `MySQLDriver`, add:

```swift
/// Whether the password (in clear, or encrypted with a key the server sends) may go to this
/// server: over TLS, or to this Mac itself, where nobody sits in between. MySQL's own client
/// refuses both otherwise, unless asked to.
static func mayRevealPassword(usesTLS: Bool, host: String) -> Bool {
    if usesTLS { return true }
    let host = host.trimmingCharacters(in: .whitespaces).lowercased()
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("/")
}
```

**Verify**: build succeeds.

### Step 2: Apply it

- In `authResponse`, for `"mysql_clear_password"`: if `!Self.mayRevealPassword(usesTLS: wire.usesTLS, host: config.host)`, throw `DBError.connection("The server asks for the password in clear text without an encrypted connection. Turn on SSL (Require or Verify Full) for this connection.")`. (`authResponse` is an instance method, so it can read `wire` and `config`; if it is `static`, add parameters.)
- In the full-authentication branch: when not using TLS and `!Self.mayRevealPassword(...)`, throw `DBError.connection("The server needs the full password, which is only sent over an encrypted connection. Turn on SSL (Require or Verify Full) for this connection.")` instead of requesting the server's key (`[0x02]`). Apply the same check before using a PEM key the server sends unprompted (the `pem.contains("BEGIN")` branch).

**Verify**: build succeeds.

### Step 3: Safe integer conversions

- `ByteReader.bytes(_:)`: `guard count >= 0, count <= data.count - index else { throw … }` (no `index + count`).
- `ByteReader.lengthEncodedBytes()`: `guard let size = Int(exactly: length) else { throw DBError.connection("A message from the server was cut short.") }`.
- `MySQLDriver` column count (line ~416): convert with `Int(exactly:)` and throw the same error if nil; also refuse counts above a sane bound (e.g. `> 4096` columns) with `DBError.connection("The server sent a malformed result.")`.
- `PostgresDriver` column count: `guard count >= 0 else { throw DBError.connection("The server sent a malformed result.") }`.
- Search for other `Int(` conversions of server-provided `UInt64`/`Int16`/`Int32` values used as counts or lengths in these three files (`grep -n "Int(try" OhMyCode/Database/*.swift`) and apply the same treatment where they feed a range or `bytes(_:)`.

**Verify**: build succeeds.

### Step 4: Tests

In `OhMyCodeTests/DatabaseTests.swift` (next to `mysqlScrambles()`):
1. `passwordsGoOnlyOverTLSOrToThisMac` — table test of `MySQLDriver.mayRevealPassword`: TLS + remote host → true; no TLS + `"db.example.com"` → false; no TLS + `"localhost"`, `"127.0.0.1"`, `"::1"`, `"/tmp/mysql.sock"` → true; `" LocalHost "` → true.
2. `malformedLengthsThrowInsteadOfTrapping` — `var reader = ByteReader(bytes: [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])` → `#expect(throws: DBError.self) { try reader.lengthEncodedBytes() }`; `ByteReader(bytes: [1, 2, 3]).bytes(Int.max)` throws; `bytes(-1)` throws.
3. If the column-count parsing can be reached through a small pure function, test negative/huge counts there; if not, the reader tests suffice (don't restructure the drivers for this).

**Verify**: DB unit tests pass, including the new ones.

### Step 5: Changelog

`CHANGELOG.md` → `## [Unreleased]` → `### Fixed`: "MySQL connections no longer send the password in clear text, or encrypted with a key the server provides, without an encrypted connection (except to this Mac); malformed replies from a database server fail the query instead of closing the app."

**Verify**: full suite passes. Optionally run the real-server DB tests (commands table) — they must still pass against the local throwaway servers (loopback is allowed by the policy).

## Test plan

Step 4: two to three new pure tests in `DatabaseTests.swift`, modeled on `mysqlScrambles()`.

## Done criteria

- [ ] `grep -n "mayRevealPassword" OhMyCode/Database/MySQLDriver.swift` → declaration + at least 2 uses
- [ ] `grep -n "index + count" OhMyCode/Database/WireConnection.swift` → no matches
- [ ] New tests pass; full suite passes
- [ ] Only in-scope files changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- The local throwaway MySQL server (if you run the optional real-server tests) needs the RSA path over loopback in a way the policy blocks — report.
- `authResponse` turns out to be `static` and used from places without a connection — report before restructuring.
- Making `ByteReader` stricter breaks an existing protocol test (a legitimate message shape you didn't anticipate) — report.

## Maintenance notes

- Any new auth method that transmits a password-equivalent must go through `mayRevealPassword`.
- If an "allow public key retrieval" connection option is wanted later (as in MySQL Connector/J), add it as an explicit per-connection setting that bypasses the policy only for the RSA path.
