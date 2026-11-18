# Plan 003: Notice when a file opened through a symlink changes on disk, so saving doesn't overwrite it silently

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 98c393c..HEAD -- OhMyCode/Workspace/EditorDocument.swift OhMyCodeTests/FileWatchingTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug (data loss)
- **Planned at**: commit `98c393c`, 2026-11-19

## Why this matters

Oh My Code detects edits made by other programs (git checkout, formatters, other editors) by comparing the file's modification date with the one it last read. For a file opened through a symbolic link (dotfiles, monorepo links), it reads the date of the *link*, which never changes when the target is edited. So the editor never notices the external change: the tab keeps the old text, and the next save or auto save overwrites the other program's change without the usual "changed on disk" prompt. Saving already writes through the link to the target, so the data loss is real.

## Current state

- `OhMyCode/Workspace/EditorDocument.swift` — the open document.
  - lines ~480-482, the date lookup. `FileManager.attributesOfItem(atPath:)` does NOT follow a symlink in the last path component, so this returns the link's own date:
    ```swift
    private static func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
    ```
  - lines ~442-449, where external changes are detected (called by the file watcher):
    ```swift
    func reloadFromDiskIfChanged() {
        guard let date = Self.modificationDate(of: url), date != diskModificationDate else { return }
        guard !isDirty else {
            hasExternalChanges = true
            return
        }
        reload(force: false)
    }
    ```
  - `diskModificationDate` is set from `modificationDate(of: url)` at lines ~248 (open) and ~286 (after save) and ~453 (`reload`).
  - lines ~300-306, saving writes through the link to its target:
    ```swift
    try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
    ```
- `OhMyCode/Workspace/Workspace.swift:~589` — the file watcher matches documents by `FileWatcher.canonicalPath` (which follows links), so the event for the target does reach `reloadFromDiskIfChanged()`; it's the date comparison that drops it.
- `OhMyCode/Workspace/Sessions.swift:~179, ~309` store and compare `document.diskModificationDate` for hot exit; they keep working because the date will now consistently be the target's.
- Existing tests to model on:
  - `OhMyCodeTests/OhMyCodeTests.swift:~77` `savingWritesThroughASymlinkAndKeepsPermissions()` — creates a target with `makeFile` and a link with `FileManager.default.createSymbolicLink(at:withDestinationURL:)`.
  - `OhMyCodeTests/FileWatchingTests.swift:~95-125` — the "changed on disk" flow: writes new text, bumps the date with `FileManager.default.setAttributes([.modificationDate: …], ofItemAtPath:)`, calls `document.reloadFromDiskIfChanged()`, expects `document.hasExternalChanges`, then exercises `Workspace.confirmOverwrite`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild build -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS'` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild test -project OhMyCode.xcodeproj -scheme OhMyCode -destination 'platform=macOS' -only-testing:OhMyCodeTests/FileWatchingTests -only-testing:OhMyCodeTests/EditorDocumentTests -only-testing:OhMyCodeTests/SessionTests` | `✔ … passed` |
| Full suite | `… -only-testing:OhMyCodeTests` | `✔ … passed` |

(Check the suite names with `grep -n "^struct\|@Suite" OhMyCodeTests/OhMyCodeTests.swift OhMyCodeTests/FileWatchingTests.swift OhMyCodeTests/SessionTests.swift`; use the struct names you find.)

## Scope

**In scope**:
- `OhMyCode/Workspace/EditorDocument.swift` (`modificationDate(of:)` only, plus its doc comment)
- `OhMyCodeTests/FileWatchingTests.swift` (new test)
- `CHANGELOG.md` (`### Fixed` under `## [Unreleased]`)

**Out of scope**:
- `FileWatcher`, `Workspace.swift`, `Sessions.swift` — they already behave correctly once the date is right.
- Changing how saving writes (it already writes through the link).

## Git workflow

- Branch: `advisor/003-symlinked-file-external-changes`
- Commit: `fix: notice changes on disk to files opened through a symlink` (Conventional Commits, no AI trailers).
- Do NOT push.

## Steps

### Step 1: Read the target's date

Change `modificationDate(of:)` to follow symlinks, e.g.:

```swift
/// The file's modification date, the target's for a symlink (saving writes to the target, so
/// that's the file other programs change).
private static func modificationDate(of url: URL) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.modificationDate] as? Date
}
```

**Verify**: build succeeds.

### Step 2: Regression test

In `FileWatchingTests.swift`, add `@Test func changesToASymlinksTargetAreNoticed()`:
1. Create a temp target file with text `"one\n"` and a symlink to it in the same temp dir (pattern from `savingWritesThroughASymlinkAndKeepsPermissions`).
2. Open `EditorDocument(url: link)`; make it dirty (`textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")`).
3. Write `"theirs\n"` to the **target**, then set the target's modification date forward (`setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: target.path)`).
4. Call `document.reloadFromDiskIfChanged()` → `#expect(document.hasExternalChanges)`.
5. Second part: a clean (not dirty) document on the same link, change the target again with a newer date, call `reloadFromDiskIfChanged()` → `#expect(document.textStorage.string == <new text>)`.
6. Clean up both files with `defer`.

Confirm the test FAILS before step 1 if you can (stash the one-line change and run it), then passes after.

**Verify**: the tests command above → pass, including the new test.

### Step 3: Changelog

Under `## [Unreleased]` → `### Fixed` in `CHANGELOG.md`: "A file opened through a symbolic link that another program changed is now noticed (it was overwritten by the next save without asking)."

**Verify**: full suite passes.

## Test plan

One new test (step 2), modeled on `FileWatchingTests` (changed-on-disk flow) and `savingWritesThroughASymlinkAndKeepsPermissions` (symlink setup).

## Done criteria

- [ ] `grep -n "resolvingSymlinksInPath" OhMyCode/Workspace/EditorDocument.swift` shows the date lookup using it
- [ ] New test exists and passes; full suite passes
- [ ] Only in-scope files changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- `modificationDate(of:)` has other callers that need the link's own date (check with `grep -n "modificationDate(of" -r OhMyCode`) — report them.
- The new test passes even without the fix (the premise is wrong) — report.
- Any session/hot-exit test starts failing.

## Maintenance notes

- Anything else that compares dates or sizes of an open document's file must use the resolved path too.
- If the editor ever supports "open the link itself", revisit this.
