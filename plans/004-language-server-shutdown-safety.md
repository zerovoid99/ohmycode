# Plan 004: Language servers stop without crashing the app and without leaving hung processes behind

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 98c393c..HEAD -- OhMyCode/LSP/LanguageServerConnection.swift OhMyCode/LSP/LanguageClient.swift OhMyCodeTests/LSPTests.swift OhMyCodeTests/Fixtures/fake_lsp.py`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `98c393c`, 2026-11-19

## Why this matters

Two defects in how Oh My Code stops a language server (and the coding agents, which reuse the same connection class):

1. **Crash.** `LanguageServerConnection.terminate()` does `readQueue.sync { … }`, and `deinit` calls `terminate()`. The read handler holds a strong reference while it reads, so if the last other reference is dropped while a big message is being read (stopping an agent mid-reply, closing a window while a server streams), `deinit` runs *on* `readQueue` and `dispatch_sync` onto the current queue crashes the whole app. The terminal's `PTYProcess` already guards against exactly this; the LSP connection never got the guard.
2. **Hung servers live forever.** `LanguageClient.shutdown()` waits for the server's reply to `shutdown` with no timeout before terminating it. Users restart a server *because* it's stuck; a stuck server never replies, so it keeps running (CPU, memory) next to the new one, and each restart can leave another orphan.

## Current state

- `OhMyCode/LSP/LanguageServerConnection.swift` — process + pipes for one server (also used by `OhMyCode/Agents/AgentClient.swift`).
  - line ~37: `private let readQueue = DispatchQueue(label: "omc.lsp.read")`
  - lines ~86-96, the read source; the handler keeps `self` alive while it loops:
    ```swift
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
    source.setEventHandler { [weak self] in
        guard let self else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                self.receive(Data(chunk[0..<count]))
    ```
  - line ~109: `deinit { terminate() }`
  - lines ~134-140:
    ```swift
    func terminate() {
        readQueue.sync {
            readSource?.cancel()
            readSource = nil
        }
        stderr?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    ```
- The pattern to copy, `OhMyCode/Terminal/PTYProcess.swift`:
  - line ~15: `private static let readQueueKey = DispatchSpecificKey<Void>()`
  - line ~83 (in init): `readQueue.setSpecific(key: Self.readQueueKey, value: ())`
  - lines ~120-128:
    ```swift
    func terminate() {
        // The last reference can go while the read handler runs: deinit then runs on readQueue,
        // where a sync onto it would deadlock.
        if DispatchQueue.getSpecific(key: Self.readQueueKey) != nil {
            hangUp()
        } else {
            readQueue.sync { hangUp() }
        }
    }
    ```
- `OhMyCode/LSP/LanguageClient.swift:~239-254`:
  ```swift
  func shutdown() {
      guard state == .ready else {
          state = .stopped
          failPending("\(name) was stopped")
          connection.terminate()
          return
      }
      Task {
          _ = try? await request("shutdown", params: nil)
          notify("exit", params: nil)
          connection.terminate()
          state = .stopped
          failPending("\(name) was stopped")
      }
  }
  ```
  `request(_:params:beforeReady:)` (line ~853) has no timeout. Callers: `Workspace.swift` (~446 window close, ~780, ~884 Restart Language Server, ~911) and `Sessions.swift` (~268).
- A timeout helper already exists: `ExtensionHost.within(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T?` (`OhMyCode/Extensions/ExtensionHost.swift:~245`) — returns nil on timeout. `LanguageClient` is `@MainActor`.
- Test fixture: `OhMyCodeTests/Fixtures/fake_lsp.py` — flags are plain `"--name" in sys.argv` checks (e.g. line ~145 `full_sync = "--full-sync" in sys.argv`); the `shutdown` request is answered at line ~553:
  ```python
  elif method == "shutdown":
      send({"jsonrpc": "2.0", "id": mid, "result": None})
  ```
  Its docstring (top of file) lists every flag; add the new one there.
- Tests: `OhMyCodeTests/LSPTests.swift`, struct `LanguageClientTests`; `static var fakeServer` / `fullSyncServer` show how to add a server variant with an extra flag; `writingToAnExitedServerDoesNotKillTheApp()` (lines ~35-55) creates a `LanguageServerConnection` directly and polls with a deadline — model new tests on it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild build -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| LSP tests | `xcodebuild test -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS' -only-testing:OhMyCodeTests/LanguageClientTests` | `✔ … passed` |
| Agent tests | add `-only-testing:OhMyCodeTests/AgentClientTests` | `✔ … passed` |
| Full suite | `… -only-testing:OhMyCodeTests` | `✔ … passed` |

## Scope

**In scope**:
- `OhMyCode/LSP/LanguageServerConnection.swift`
- `OhMyCode/LSP/LanguageClient.swift` (`shutdown()` only, plus a `static` timeout knob)
- `OhMyCodeTests/Fixtures/fake_lsp.py` (one new flag)
- `OhMyCodeTests/LSPTests.swift` (new tests)
- `CHANGELOG.md` (`### Fixed`)

**Out of scope**:
- `AgentClient.swift`, `PTYProcess.swift`, `DAPClient.swift` — they benefit automatically or are already correct.
- Request timeouts for other LSP methods.

## Git workflow

- Branch: `advisor/004-language-server-shutdown-safety`
- Commits like `fix(lsp): don't crash when a server connection is released while reading`, `fix(lsp): kill a server that doesn't answer shutdown`. No AI trailers. Do NOT push.

## Steps

### Step 1: Guard `terminate()` against running on `readQueue`

In `LanguageServerConnection`:
- Add `private static let readQueueKey = DispatchSpecificKey<Void>()` and, in the initializer after `readQueue` exists, `readQueue.setSpecific(key: Self.readQueueKey, value: ())`.
- Move the body of the current `readQueue.sync { … }` into a private `cancelReading()`; in `terminate()`, call it directly when `DispatchQueue.getSpecific(key: Self.readQueueKey) != nil`, else `readQueue.sync { cancelReading() }`. Copy the PTYProcess comment.
- Add an `internal` test hook: `func onReadQueue(_ body: @escaping @Sendable () -> Void)` that does `readQueue.async(execute: body)`, with a doc comment "For tests: runs `body` on the read queue."

**Verify**: build succeeds.

### Step 2: Time out the shutdown request

In `LanguageClient`:
- Add `nonisolated(unsafe) static var shutdownTimeout: Duration = .seconds(2)` with a doc comment (tests shorten it; follow the style of other `nonisolated(unsafe) static var` knobs in the codebase, e.g. `EditorController.textElementTrimDelay` in `OhMyCode/Editor/CodeEditorView.swift`).
- In `shutdown()`'s `Task`, replace the bare request with:
  ```swift
  _ = try? await ExtensionHost.within(Self.shutdownTimeout) { [self] in
      _ = try await self.request("shutdown", params: nil)
      return true
  }
  ```
  Keep the rest (`notify("exit")`, `connection.terminate()`, `state = .stopped`, `failPending`) unchanged, so a timed-out request is failed by `failPending`.
- If the closure doesn't compile because `request` returns a non-Sendable value or isolation rules reject it, use an equivalent: start the request in a child `Task`, `try? await Task.sleep(for: Self.shutdownTimeout)` in another, and proceed when either finishes (a small `OnceFlag`-style guard; `ExtensionHost.within` shows how).

**Verify**: build succeeds.

### Step 3: Fixture flag

In `fake_lsp.py`, add `--ignore-shutdown`: when present, the `shutdown` request gets no reply (and `exit` still exits). Document it in the docstring.

**Verify**: `python3 -c "import ast,sys; ast.parse(open('OhMyCodeTests/Fixtures/fake_lsp.py').read())"` → exit 0.

### Step 4: Tests

In `OhMyCodeTests/LSPTests.swift` (`LanguageClientTests`):
1. `aServerThatIgnoresShutdownIsStoppedAnyway` — set `LanguageClient.shutdownTimeout = .milliseconds(300)` (restore in `defer`); start a workspace with the fake server plus `--ignore-shutdown` (variant like `fullSyncServer`); wait until the document's client is `.ready`; call `client.shutdown()`; within 5 s (poll with a deadline as in `writingToAnExitedServerDoesNotKillTheApp`) expect `client.state == .stopped` and the server process gone. If `LanguageClient` doesn't expose whether the process runs, add `var isServerRunning: Bool { connection.isRunning }` to it (in scope).
2. `terminatingFromTheReadQueueDoesNotDeadlock` — create a `LanguageServerConnection(command: ["/bin/cat"], directory: FileManager.default.temporaryDirectory, environment: [:])`, then `await withCheckedContinuation { c in connection.onReadQueue { connection.terminate(); c.resume() } }` → the test returns (before the fix this traps or hangs). Expect `!connection.isRunning` after a short poll.

**Verify**: `xcodebuild test … -only-testing:OhMyCodeTests/LanguageClientTests -only-testing:OhMyCodeTests/AgentClientTests` → pass, including the 2 new tests.

### Step 5: Changelog

`CHANGELOG.md` → `## [Unreleased]` → `### Fixed`: "Restarting or stopping a language server that stopped answering now ends it (it kept running), and stopping an agent or server while it's sending a large message can't crash the app."

**Verify**: full suite passes.

## Test plan

Two new tests (step 4), structural pattern `writingToAnExitedServerDoesNotKillTheApp` and the `fakeServer`/`fullSyncServer` variants.

## Done criteria

- [ ] `grep -n "readQueueKey" OhMyCode/LSP/LanguageServerConnection.swift` → at least 3 matches (declaration, setSpecific, getSpecific)
- [ ] `grep -n "shutdownTimeout" OhMyCode/LSP/LanguageClient.swift` → matches
- [ ] Both new tests pass; full suite passes
- [ ] Only in-scope files changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- `LanguageServerConnection.init` can throw before `readQueue` exists in a way that makes `setSpecific` placement unclear — report.
- The new deadlock test hangs the test run even after the fix (kill it with a timeout and report).
- Shortening `shutdownTimeout` in the test makes other tests in the same run flaky (it's a static; restore it in `defer` and keep the suite `.serialized` if needed) — report if it persists.

## Maintenance notes

- Any new class that owns a serial queue and cancels work on it from `deinit` needs the same `DispatchSpecificKey` guard.
- If a future protocol needs a graceful shutdown longer than 2 s (some servers flush caches), make the timeout per server.
