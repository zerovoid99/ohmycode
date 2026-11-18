# Plan 002: Extensions only get the permissions the user approved, and can't run code or edit outside files without them

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 98c393c..HEAD -- OhMyCode/Extensions OhMyCode/Workspace/Workspace.swift OhMyCodeTests/ExtensionTests.swift docs/extensions/runtime-and-security.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/001-agent-guide-and-ci.md (for `CLAUDE.md` rules; not a code dependency)
- **Category**: security
- **Planned at**: commit `98c393c`, 2026-11-19

## Why this matters

Oh My Code runs extensions (JavaScript in JavaScriptCore) with a permission model: `process` (run programs), `network`, `fileSystem` (files outside the open folder) and `nativeCode` (load a tree-sitter parser dylib into the app). The install dialog shows the requested permissions, but three gaps make that dialog meaningless:

1. Permissions are re-read from the manifest on disk every load and never stored, so an extension (or anything that edits its folder) can add `process` or `nativeCode` later and get it with no prompt.
2. Without `process`, an extension can still run shell commands: it may write `.omc/tasks.json` in the workspace and then call the built-in `tasks.build` command through `omc.commands.executeCommand`.
3. `editor.edit` / `document.save` work on any open document, including files outside the workspace (e.g. `~/.zshrc`), without `fileSystem`.

After this plan, an extension can only use what the user approved, and the "no permissions" promise in the install dialog ("It works only with the editor and the open folder") holds.

## Current state

Files:
- `OhMyCode/Extensions/ExtensionManifest.swift` — the manifest model. `grantedPermissions` (line 135) is just the declared list:
  ```swift
  var permissions: [Permission]?
  ...
  var grantedPermissions: Set<Permission> { Set(permissions ?? []) }
  ```
  `Permission` (lines 102-118) is `enum Permission: String, Codable, Sendable, CaseIterable { case process, network, fileSystem, nativeCode }` with a `title`. `grantedPermissions` is also used inside the manifest's validation (lines ~201, ~219: a language server needs `.process`, a tree-sitter grammar needs `.nativeCode`) and when building grammar contributions (line ~243, `permitted: grantedPermissions.contains(.nativeCode)`).
- `OhMyCode/Extensions/ExtensionStore.swift` — installed extensions on disk (`~/Library/Application Support/OhMyCode/Extensions/<id>`, a symlink for development installs) and their settings in a `UserDefaults` (`defaults`, with keys built by `Keys.settings(id)` / `Keys.storage(id)`). `installed()` (lines ~47-60) loads every folder's manifest; `install(from:development:replacing:)` (lines ~74-96) copies or links the folder; `uninstall` removes settings and storage keys.
  ```swift
  struct InstalledExtension: Sendable, Equatable, Identifiable {
      let manifest: ExtensionManifest
      let folder: URL
      let isDevelopment: Bool
      var id: String { manifest.id }
      var mainURL: URL { folder.appending(path: manifest.main) }
  }
  ```
- `OhMyCode/Workspace/Workspace.swift:2446-2470` — `installExtension(from:development:)` shows the confirmation (permissions from `manifest.grantedPermissions`), then calls `store.install(...)`. Tests bypass the alert with `extensionInstallConfirmation`.
- `OhMyCode/Extensions/ExtensionHost.swift`:
  - line ~990: `let permissions = instance.manifest.grantedPermissions` at the top of `answerAsync` (the API dispatcher); line ~941 checks `.process` for `languages.registerServer`.
  - lines ~1025-1027:
    ```swift
    case "commands.execute":
        guard let command = args["id"]?.string else { throw APIError.badArguments(method) }
        return try await executeCommand(command, arguments: args["args"]?.array ?? [])
    ```
    `executeCommand` (lines ~645-656) runs an extension command or any `PaletteCommand.all` entry (`command.perform(workspace)`). It is ALSO called by the palette/keybindings for extension commands, so the new check belongs in the `"commands.execute"` case, not in `executeCommand`.
  - lines ~1039-1044 (`fs.writeFile`): `resolve(...)` (workspace containment, `fileSystem` needed outside) then `Self.checkGitWrite(url, permissions:)` which refuses `.git` paths without `fileSystem`.
  - lines ~1097-1104: `editor.edit` and `document.save` take any open document via `openDocument(args)` and only call `checkGitWrite` — no workspace check.
  - `resolve(_:permissions:method:)` (end of file) uses `workspace.isInsideWorkspace(url)`.
  - `checkGitWrite` (end of file), the pattern to copy for the new `.omc` guard:
    ```swift
    static func checkGitWrite(_ url: URL, permissions: Set<ExtensionManifest.Permission>) throws {
        guard !permissions.contains(.fileSystem) else { return }
        let components = url.standardizedFileURL.pathComponents + url.resolvingSymlinksInPath().pathComponents
        if components.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) {
            throw APIError.gitDirectory(url.path)
        }
    }
    ```
- Built-in palette commands that run code or programs have ids starting with: `tasks.`, `test.`, `debug.`, `terminal.`, `git.` (fetch/pull/push run hooks and network), `agent.`, `extensions.` (e.g. `extensions.reload`, `extensions.new`), `ai.` (sends code to a provider). Read-only/editor commands (e.g. `go.line`, `view.*`, `editor.*`) stay allowed. An existing test uses `omc.commands.executeCommand('go.line')` (`OhMyCodeTests/ExtensionTests.swift:154`) — it must keep working without permissions.
- Tests: `OhMyCodeTests/ExtensionTests.swift`. The fixture extension is `Self.basicManifest` + `Self.basicSource` (lines ~95-168; commands registered with `register('basic.x', () => ...)`), installed with `store.install(from:)` in `makeBasic()` (lines ~170-182). Helpers: `run(workspace, id)` and `failure(workspace, id)` (returns the error text). Pattern to copy: `gitFolderNeedsTheFileSystemPermission()` (lines ~355-371) and `errorsAndPermissions()` (lines ~278-289). Store isolation: `makeStore()` (line ~15) gives a scratch store.
- The docs page `docs/extensions/runtime-and-security.md` describes permissions; it must match the new behavior.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild build -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| Extension tests | `xcodebuild test -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS' -only-testing:OhMyCodeTests/ExtensionTests` | `✔ … passed` |
| Related suites | add `-only-testing:OhMyCodeTests/GrammarContributionTests -only-testing:OhMyCodeTests/LanguageFeatureTests` | `✔ … passed` |
| Full suite | `… -only-testing:OhMyCodeTests` | `✔ … passed` |

(If you add a new Swift file, run `xcodegen generate` and commit `OhMyCode.xcodeproj/project.pbxproj`. Prefer not to add files.)

## Scope

**In scope**:
- `OhMyCode/Extensions/ExtensionStore.swift`
- `OhMyCode/Extensions/ExtensionManifest.swift`
- `OhMyCode/Extensions/ExtensionHost.swift`
- `OhMyCode/Extensions/ExtensionsView.swift` (show "asks for new permissions" + a Review button)
- `OhMyCode/Workspace/Workspace.swift` (only `installExtension` and a new small `reviewExtensionPermissions` next to it)
- `OhMyCodeTests/ExtensionTests.swift`
- `docs/extensions/runtime-and-security.md`, `CHANGELOG.md` (`### Fixed` / `### Changed` under `## [Unreleased]`)

**Out of scope**:
- The JavaScript API surface in `ExtensionAPI/omc.d.ts` — no API changes.
- Workspace trust (a separate plan: `plans/006-workspace-trust.md`).
- Removing the `disable-library-validation` entitlement.

## Git workflow

- Branch: `advisor/002-extension-permission-boundary`
- Conventional Commits, English, no AI trailers, e.g. `fix(extensions): grant only the permissions the user approved`.
- Do NOT push.

## Steps

### Step 1: Record approved permissions in the store

In `ExtensionStore.swift`:
- Add a key `static func approved(_ id: String) -> String { "extensions.approvedPermissions.\(id)" }` next to `settings`/`storage`.
- Add `func approvedPermissions(of id: String) -> Set<ExtensionManifest.Permission>?` (nil when nothing is recorded) and `func approvePermissions(_ permissions: Set<ExtensionManifest.Permission>, for id: String)` (stores the raw values sorted, as a `[String]`).
- In `install(from:development:replacing:)`, after a successful copy/link, call `approvePermissions(manifest.declaredPermissions, for: manifest.id)` — installing means the user saw and accepted the dialog.
- In `uninstall`, remove the approved key too.
- Add to `InstalledExtension` a stored `let approvedPermissions: Set<ExtensionManifest.Permission>` and a computed `var grantedPermissions: Set<…> { manifest.declaredPermissions.intersection(approvedPermissions) }` and `var pendingPermissions: Set<…> { manifest.declaredPermissions.subtracting(approvedPermissions) }`.
- In `installed()`: for each manifest, `approved = approvedPermissions(of: id)`; if nil (extensions installed before this change), **grandfather**: record `manifest.declaredPermissions` as approved and use it (so existing users are not re-prompted on upgrade).

In `ExtensionManifest.swift`: rename `grantedPermissions` to `declaredPermissions` (same body). Update every use (`grep -rn "grantedPermissions" OhMyCode OhMyCodeTests`). Inside the manifest's own validation and contribution building, keep using the declared set (validation is about what the manifest asks for); the host enforces the granted set (step 2).

**Verify**: build succeeds; `grep -rn "manifest.grantedPermissions" OhMyCode` → no matches.

### Step 2: Enforce the granted set at runtime

In `ExtensionHost.swift`, wherever permissions are read from `instance.manifest` (`answerAsync` line ~990, `languages.registerServer` line ~941, any other `grantedPermissions`/`declaredPermissions` read on an instance), use `instance.installed.grantedPermissions` instead (check how the instance exposes its `InstalledExtension`; `instance.installed.folder` is already used at line ~944). Where grammar contributions decide `permitted:` for native code, make sure a tree-sitter library is only loaded when `.nativeCode` is in the granted set — trace `permitted` to where the dylib is opened (`OhMyCode/Syntax/ContributedGrammars.swift`, `dlopen`) and pass the granted value from the installed extension, not the manifest. If that requires touching `ContributedGrammars.swift`, it is in scope for that single change.

**Verify**: build succeeds; `xcodebuild test … -only-testing:OhMyCodeTests/ExtensionTests -only-testing:OhMyCodeTests/GrammarContributionTests` → pass.

### Step 3: Ask when an extension wants more

- In `ExtensionsView.swift`, for an installed extension with non-empty `pendingPermissions`, show a line "Asks for new permissions: …" (titles from `Permission.title`) and a **Review…** button.
- In `Workspace.swift`, next to `installExtension`, add `func reviewExtensionPermissions(_ installed: InstalledExtension)` that shows an `NSAlert` listing the pending permissions ("<name> now asks to: • …  Only allow extensions you trust.") with **Allow** / **Not Now**, and on Allow calls `store.approvePermissions(installed.approvedPermissions ∪ pending, for:)` then reloads extensions the way enabling/disabling does (find the existing reload path used after install — `store.changed()` or `extensions.reload`). Make it testable the same way as `extensionInstallConfirmation`: add `@ObservationIgnored var extensionPermissionConfirmation: ((InstalledExtension) -> Bool)?`.

**Verify**: build succeeds.

### Step 4: Commands that run code need `process`

In `ExtensionHost.swift`, in `case "commands.execute":`, before calling `executeCommand`, if the id is a built-in palette command (`PaletteCommand.all.contains { $0.id == command }`) and `!permissions.contains(.process)` and the id starts with one of `["tasks.", "test.", "debug.", "terminal.", "git.", "agent.", "extensions.", "ai."]`, throw `APIError.permission(.process)` (the existing error used for `omc.process.run`). Put the prefix list in a `static let commandPrefixesNeedingProcess` with a doc comment explaining why (they run programs, scripts or hooks). Extension-registered commands are unaffected.

**Verify**: build succeeds.

### Step 5: Workspace config files and outside documents

- Generalize `checkGitWrite` into `checkProtectedWrite(_:permissions:)` that, without `.fileSystem`, refuses paths with a `.git` component (as now) **and** paths with a `.omc` or `.vscode` component (task/launch/settings files the editor runs commands from), throwing a new `APIError.protectedFolder(String)` whose message says "… is inside .omc (or .vscode, .git): changing it needs the "fileSystem" permission." Keep `checkGitWrite` as a thin wrapper or replace its call sites; keep the existing `.git` test passing.
- In `editor.edit` and `document.save`, after `openDocument(args)`, refuse with `APIError.outsideWorkspace(path)` when `!workspace.isInsideWorkspace(document.url) && !permissions.contains(.fileSystem)`, then apply `checkProtectedWrite`.

**Verify**: build succeeds.

### Step 6: Tests

In `OhMyCodeTests/ExtensionTests.swift` (extend `basicSource` with new `register(...)` commands as needed):
1. `aBuiltInCommandThatRunsCodeNeedsProcess` — `basic.runBuild` calls `omc.commands.executeCommand('tasks.build')` → failure text contains `"process"`; `basic.builtin` (`go.line`) still works.
2. `omcAndVscodeFoldersNeedTheFileSystemPermission` — writing `.omc/tasks.json` and `.vscode/tasks.json` fails with the new message; nothing is written.
3. `editingAnOpenFileOutsideTheWorkspaceNeedsFileSystem` — open a temp file outside the folder (`workspace.open(fileAt:)`), `basic.editPath` (edit via `omc.window.activeTextEditor` or a path argument — reuse what the fixture already does in `basic.upper`) is refused, file unchanged.
4. `permissionsAddedLaterAreNotGranted` — install an extension declaring no permissions, then rewrite its installed `extension.json` to add `"process"`; reload (`store.installed()`); `pendingPermissions == [.process]`, `grantedPermissions` empty, and its `omc.process.run` command fails; after `extensionPermissionConfirmation = { _ in true }` and `reviewExtensionPermissions`, it is granted.
5. `extensionsInstalledBeforeApprovalsAreGrandfathered` — write an extension folder directly into the store's directory (no `install` call), load → its declared permissions are granted and now recorded.

**Verify**: `xcodebuild test … -only-testing:OhMyCodeTests/ExtensionTests` → pass, including the 5 new tests.

### Step 7: Docs and changelog

- `docs/extensions/runtime-and-security.md`: state that (a) permissions are granted at install and an update that asks for more is held until the user reviews it in the Extensions panel; (b) built-in commands under `tasks.`, `test.`, `debug.`, `terminal.`, `git.`, `agent.`, `extensions.`, `ai.` need `process`; (c) writing in `.git`, `.omc` or `.vscode`, and editing or saving open files outside the folder, need `fileSystem`.
- `CHANGELOG.md` under `## [Unreleased]` → `### Fixed`: one entry describing the three gaps closed (no exploit details).

**Verify**: `grep -n "fileSystem" docs/extensions/runtime-and-security.md` shows the new text; full suite passes.

## Test plan

See step 6 (5 new tests in `ExtensionTests`, pattern: `gitFolderNeedsTheFileSystemPermission`). Run the full suite at the end.

## Done criteria

- [ ] `grep -rn "manifest.grantedPermissions" OhMyCode` → no matches
- [ ] `xcodebuild test … -only-testing:OhMyCodeTests` passes; the 5 new tests exist and pass
- [ ] Docs and CHANGELOG updated
- [ ] Only in-scope files changed (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- Grandfathering can't be done without re-prompting existing installs (e.g. the store can't tell old installs apart) — report before choosing another approach.
- The `nativeCode` gate turns out to be decided somewhere you can't reach from the installed extension without restructuring `ContributedGrammars.swift` beyond passing a value.
- An existing test relies on an extension running one of the newly gated commands or writing `.omc/` without permissions — report which, don't delete it.
- `executeCommand` turns out to be the only entry for both extensions and the palette with no way to tell the caller apart in the `"commands.execute"` case.

## Maintenance notes

- New built-in commands that run programs should use one of the gated prefixes, or the prefix list must be extended.
- A future "extension update" flow (install from zip/URL) must call `approvePermissions` only after showing the dialog, never silently.
- Reviewers: check that no code path reads `manifest.declaredPermissions` to *allow* something at runtime.
