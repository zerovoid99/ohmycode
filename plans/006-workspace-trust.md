# Plan 006: Opening a folder doesn't run its project tooling until the user trusts it

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 98c393c..HEAD -- OhMyCode/Workspace/Workspace.swift OhMyCode/Testing/TestController.swift OhMyCode/Debug/Workspace+Debug.swift OhMyCode/Tasks/Workspace+Tasks.swift OhMyCode/Views/WorkspaceView.swift OhMyCode/App/OpenRequests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: L
- **Risk**: MED
- **Depends on**: plans/001-agent-guide-and-ci.md (CI baseline), plans/002-extension-permission-boundary.md (finish first; both touch `Workspace.swift`)
- **Category**: security
- **Planned at**: commit `98c393c`, 2026-11-19

## Why this matters

Oh My Code registers the URL scheme `ohmycode://open?path=/abs/path`, so any web page can make it open a folder (e.g. one just extracted from a download). Opening a folder immediately runs tools that execute code from that folder, with no click:
- `xcodebuild -list` / `-showBuildSettings` (Xcode projects; reads project files, may resolve packages),
- `swift package describe` (compiles and runs `Package.swift`),
- language servers (rust-analyzer, gopls, sourcekit-lsp… evaluate build scripts, proc macros, package manifests).

VS Code solves this with "Workspace Trust": a new folder opens in restricted mode until the user trusts it. This plan adds a minimal version: a per-folder trust store; in untrusted folders the three automatic paths are skipped and explicit run actions ask first; a banner offers "Trust Folder". Known folders are trusted on upgrade, so existing users see nothing new for folders they already use.

## Current state

- `OhMyCode/App/OpenRequests.swift`
  - lines ~48-61, `OpenRequest.init?(external:)` accepts `ohmycode://open?path=` with any absolute path (also used by the `omc` command-line tool, `OhMyCode/Resources/CommandLine/omc:~103`).
  - lines ~268-312, `RecentFolders` (the list of recently opened folders): `static let shared = RecentFolders(defaults: AppSettings.isRunningTests ? ScratchDefaults.named("recent") : .omc)`, `private(set) var urls: [URL]`. This is the store pattern to copy (scratch defaults under tests).
- `OhMyCode/Workspace/Workspace.swift`
  - `private(set) var folders: [URL]` (line ~10) — the window's folders.
  - `openFolder(_:)` (line ~387) and `setFolders(_:names:)` (line ~462); after folders change it runs (lines ~477-481):
    ```swift
    loadProjectSettings()
    Task { await testing.discover() }
    Task { await loadLaunchConfigurations() }
    ```
    (also `Task { await testing.discover() }` at line ~434 on reset).
  - `attachLanguageServer(to document:)` (lines ~696-711) — starts or reuses a language server for a document; called from ~722, ~787, ~888, ~2611, ~2732.
- `OhMyCode/Testing/TestController.swift:~151-168`, `discover()`: reads files to find tests, and for Xcode projects runs `xcodebuild` via
  ```swift
  if XcodeProject.container(in: root.url) != nil {
      folder.xcode = await XcodeProject.load(in: root.url, environment: await ShellEnvironment.shared.environment())
      if folder.xcode != nil { folder.frameworks.insert(.xcode) }
  }
  ```
  Explicit run entry points: `run(_:)` (~284), `rerun()` (~387), `runFailed()` (~391), `runTest(at:in:)` (~494).
- `OhMyCode/Debug/Workspace+Debug.swift`, `loadLaunchConfigurations()`: reads `.omc/launch.json` (just reading — fine), and when it finds none calls `LaunchConfiguration.swiftPackage(in:environment:)` (runs `swift package describe`) and `LaunchConfiguration.xcodeProjects(in:environment:)` (runs `xcodebuild`), then `pythonCurrentFile(in:)` (reads only). Explicit entry: `startDebugging(_:)` (~138), `startOrContinueDebugging()` (~129).
- `OhMyCode/Tasks/Workspace+Tasks.swift`: `runTask(_:reveal:)` (~78) is what every task run goes through (`runBuildTask`, `runTestTask`, `rerunLastTask` call into it).
- `OhMyCode/Views/WorkspaceView.swift` — the window's layout (NavigationSplitView with the sidebar, editor area, panels). Find where other window-wide notices are shown (search for `errorMessage` / notification views) and put the banner there, matching their style.
- Test isolation rule (from the repo): any new persisted store must use `ScratchDefaults.named(...)` when `AppSettings.isRunningTests` (see `RecentFolders.shared`). Hundreds of existing tests open temporary folders and expect language servers, test discovery and launch configurations to work — under tests, trust must default to *everything trusted*.
- Paths: compare folders by `FileWatcher.canonicalPath(url)` (symlinks resolved), as the rest of the code does.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Generate project (after adding a file) | `xcodegen generate` | exit 0 |
| Build | `xcodebuild build -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| Focused tests | `xcodebuild test -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS' -only-testing:OhMyCodeTests/WorkspaceTrustTests` | `✔ … passed` |
| Full suite | `… -only-testing:OhMyCodeTests` | `✔ … passed` |

## Scope

**In scope**:
- `OhMyCode/Workspace/WorkspaceTrust.swift` (create: the store + `Workspace` extension)
- `OhMyCode/Workspace/Workspace.swift` (guard in `attachLanguageServer`, re-attach after trusting)
- `OhMyCode/Testing/TestController.swift` (skip `XcodeProject.load` when untrusted; ask before runs)
- `OhMyCode/Debug/Workspace+Debug.swift` (skip found-program discovery when untrusted; ask before `startDebugging`)
- `OhMyCode/Tasks/Workspace+Tasks.swift` (ask before `runTask`)
- `OhMyCode/Views/WorkspaceView.swift` (+ a small banner view, may live in `WorkspaceTrust.swift`)
- `OhMyCode/Palette/PaletteCommand.swift` (two commands: "Workspace: Trust Folder" and "Workspace: Restrict Folder")
- `OhMyCodeTests/WorkspaceTrustTests.swift` (create), `OhMyCode.xcodeproj/project.pbxproj` (regenerated)
- `README.md` (a short "Workspace trust" subsection under "Settings and your work"), `CHANGELOG.md`

**Out of scope**:
- git commands run on open (`git status` etc.) — separate concern; don't gate git.
- Extensions (user-installed, governed by their own permissions — plan 002).
- A confirmation dialog in the URL handler — the trust gate makes opening harmless; adding a dialog would also nag every `omc` command use.
- A global "trust everything" setting (can come later).

## Git workflow

- Branch: `advisor/006-workspace-trust`
- Commits like `feat: workspace trust — project tools wait until a new folder is trusted`. No AI trailers. Do NOT push.

## Steps

### Step 1: The trust store

Create `OhMyCode/Workspace/WorkspaceTrust.swift`:

```swift
/// Folders whose project tooling may run (language servers, `swift package`, `xcodebuild`,
/// tasks, tests, the debugger). A folder is trusted when it or a folder above it is.
@MainActor
@Observable
final class WorkspaceTrust {
    static let shared = WorkspaceTrust(defaults: AppSettings.isRunningTests ? ScratchDefaults.named("trust") : .omc,
                                       trustsEverything: AppSettings.isRunningTests)
    /// Under tests: everything is trusted unless a test turns this off.
    var trustsEverything: Bool
    private(set) var trusted: [String]   // canonical paths
    ...
    func isTrusted(_ folder: URL) -> Bool          // trustsEverything || folder or an ancestor is in `trusted`
    func trust(_ folder: URL)                      // adds the canonical path, saves
    func restrict(_ folder: URL)                   // removes it, saves
}
```

- Persist under the key `"trustedFolders"` as `[String]`.
- **Migration**: in `init`, if the key `"trustMigrated"` is absent, trust every folder in `RecentFolders.shared.urls` (and workspace files' folders as they are listed there — trust the URL as stored), then set `"trustMigrated" = true`. This keeps existing users' folders working.
- Add `extension Workspace { var isTrusted: Bool { folders.allSatisfy(WorkspaceTrust.shared.isTrusted) } }` (an empty window counts as trusted).

Run `xcodegen generate`.

**Verify**: build succeeds.

### Step 2: Skip automatic tooling in untrusted folders

- `Workspace.attachLanguageServer(to:)`: `guard isTrusted else { return }` at the top.
- `TestController.discover()`: only call `XcodeProject.load` when `workspace.isTrusted` (file-based discovery still runs, so the Testing panel still lists tests found by reading files).
- `Workspace.loadLaunchConfigurations()`: when `!isTrusted`, still read `.omc/launch.json` but skip `swiftPackage(in:)` and `xcodeProjects(in:)` (keep `pythonCurrentFile`, it only reads).

**Verify**: build succeeds; `xcodebuild test … -only-testing:OhMyCodeTests` still passes (everything is trusted under tests).

### Step 3: Ask before explicit runs

Add to `WorkspaceTrust.swift`:

In `Workspace.swift`, next to the other test hooks such as `extensionInstallConfirmation`, add the stored property:

```swift
/// Tests answer this instead of the trust dialog.
@ObservationIgnored var trustConfirmation: (() -> Bool)?
```

and in `WorkspaceTrust.swift`:

```swift
extension Workspace {
    /// Before running the folder's own code: trusted, or the user trusts it now.
    func requireTrust(to action: String) -> Bool
}
```

`requireTrust` returns true if trusted; otherwise shows an `NSAlert` ("Trust “<folder name>”?", informative text: "<action> runs this folder's own code (build scripts, manifests, tasks). Only trust folders whose code you trust.", buttons **Trust and Continue** / **Cancel**); on Trust, trusts every folder of the window, re-attaches language servers (`for document in documents where document.languageClient == nil { attachLanguageServer(to: document) }`), re-runs `testing.discover()` and `loadLaunchConfigurations()`, and returns true. Use `trustConfirmation` when set (tests).

Call it at the top of: `runTask(_:reveal:)` (return nil when refused), `startDebugging(_:)`, and `TestController.run(_:)`, `rerun()`, `runFailed()`, `runTest(at:in:)` (via `workspace?.requireTrust(to: "Running tests")`). Action strings: "Running a task", "Debugging", "Running tests".

**Verify**: build succeeds.

### Step 4: Banner and commands

- In `WorkspaceView`, when `!workspace.isTrusted`, show a slim banner at the top of the editor area: "Restricted mode — language servers, tasks, tests and the debugger wait until you trust this folder." with a **Trust Folder** button (does what `requireTrust`'s Trust branch does, without the dialog) and a "Learn more" help tooltip. Match the existing notice styling (find it in the views; use theme colors from `OhMyCode/Views/ThemeStyle.swift`).
- Palette (`PaletteCommand.swift`): `workspace.trust` "Workspace: Trust Folder" (available when untrusted) and `workspace.restrict` "Workspace: Restrict Folder" (available when trusted; restricting stops nothing that already runs — say so in the title or a notification).

**Verify**: build succeeds.

### Step 5: Tests

Create `OhMyCodeTests/WorkspaceTrustTests.swift` (`@MainActor @Suite(.serialized) struct WorkspaceTrustTests`), each test setting `WorkspaceTrust.shared.trustsEverything = false` and restoring it in `defer` (and clearing what it trusted):
1. `foldersAndTheirSubfoldersAreTrusted` — trust `/tmp/x` (a temp dir) → `isTrusted` for it and a subfolder, not for a sibling; restrict → not trusted; survives a new `WorkspaceTrust(defaults:)` on the same scratch defaults.
2. `migrationTrustsRecentFolders` — a fresh `WorkspaceTrust(defaults:)` with scratch defaults containing `"recentFolders"` trusts those paths once and sets `trustMigrated`.
3. `untrustedFolderStartsNoLanguageServer` — model on `LanguageClientTests.makeWorkspace` (`OhMyCodeTests/LSPTests.swift`) with the fake server: open an untrusted folder, open a file, wait ~1 s → `document.languageClient == nil`; trust via the banner action → a client attaches (poll).
4. `runningATaskAsksFirst` — untrusted folder with `.omc/tasks.json`; `trustConfirmation = { false }` → `runTask` returns nil and nothing runs; `{ true }` → it runs and the folder becomes trusted.

Run `xcodegen generate` after creating the file.

**Verify**: focused tests pass; full suite passes.

### Step 6: Docs

- `README.md`: a short `### Workspace trust` subsection under `## Settings and your work` (what restricted mode skips, how to trust, that recent folders were trusted on upgrade). Add it to the Contents line for that group.
- `CHANGELOG.md` → `## [Unreleased]` → `### Added`.

**Verify**: `grep -n "Workspace trust" README.md` → matches; full suite passes.

## Test plan

Step 5 (4 tests). Structural patterns: `LanguageClientTests.makeWorkspace` for an LSP-backed workspace; `RecentFolders` scratch-defaults pattern for the store.

## Done criteria

- [ ] `grep -n "isTrusted" OhMyCode/Workspace/Workspace.swift OhMyCode/Testing/TestController.swift OhMyCode/Debug/Workspace+Debug.swift` → matches in all three
- [ ] `grep -n "requireTrust" -r OhMyCode` → calls in tasks, debugging and the four test-run entry points
- [ ] New tests pass; full suite passes
- [ ] Only in-scope files changed; `project.pbxproj` regenerated
- [ ] `plans/README.md` status row updated

## STOP conditions

- More than ~5 existing tests fail after step 2 or 3 (they likely open folders outside the test-mode default) — report which instead of changing them.
- A language server is started through a path that doesn't go through `attachLanguageServer(to:)` (search `languageClient(` callers) — report it.
- The test-run or debugger entry points named above don't exist under those names — report the actual ones.
- Showing an `NSAlert` from inside `TestController` isn't possible without restructuring (it has only a weak `workspace`) — report.

## Maintenance notes

- Any NEW feature that runs code from the folder (a new build-tool integration, a new auto-discovery) must check `isTrusted` or call `requireTrust`.
- Plan 002's extension permissions are independent: a trusted folder doesn't grant extensions anything.
- Later: a global "Trust all folders" setting, and trusting a parent folder from the banner.
