# Runtime and security

How an extension's code runs, what it can reach, what stops it, and what the permissions protect
— and don't. Read this before you rely on a Node habit, and before you install someone else's
extension.

## How extensions run

- **One JavaScriptCore virtual machine per extension, per window.** Each extension gets a
  context of its own in a virtual machine of its own: extensions can't see each other's globals or
  objects. Each window runs its own copy: with three windows open, an extension that starts on
  startup runs three times — once per window, each seeing that window's folders and documents.
- **Off the main thread.** Each extension runs on a serial queue of its own. The editor never
  waits for an extension to draw, type or scroll; extensions don't wait for each other.
- **Calls into the editor.** The `omc` functions that return a value at once (`getText`,
  `activeTextEditor`, `getConfiguration().get`) are answered on the editor's main thread, which the
  extension's queue waits for. Those that return a promise (dialogs, edits, files, processes,
  requests) don't hold the extension up: it carries on and the promise settles later.
- **Events.** Document opened, closed, saved and changed, the active editor, settings and folders
  are delivered to running extensions on their queue. Changes are delivered once edits settle
  (about 150 ms after the last one).
- **Lifecycle.** An extension starts on its [activation events](manifest.md#activationevents),
  runs `activate`, and stays until the window closes, it's disabled, uninstalled or updated, or the
  extensions are reloaded; then `deactivate` runs, its subscriptions are disposed, its timers
  cleared and its context thrown away. Nothing of its JavaScript state survives a restart: keep
  what must last in [`context.storage`](#data-and-storage) or in files.

## Modules

The main file is loaded as CommonJS: it's wrapped in a function with `exports`, `require`,
`module`, `__filename` and `__dirname`, and its `exports.activate` is called.

`require("omc")` is the only thing `require` answers. Anything else — a relative `./util`, an npm
package, Node's `fs` — throws *Cannot find module 'x': only 'omc' is available, bundle other
dependencies into the extension.*

So an extension is one JavaScript file. One TypeScript file compiled with `tsc` is one; several
files, or npm packages, need bundling into one with esbuild ([how](getting-started.md#building-with-esbuild)).
ES modules (`import`/`export` in the output) aren't supported: compile to CommonJS.

## What's available

The language is the JavaScript of the system's JavaScriptCore — ES2022 and more on the macOS
versions Oh My Code runs on (classes, `async`/`await`, optional chaining, `BigInt`, `WeakRef`, Unicode regular
expressions with `\p{…}`). Compile to ES2020 or later.

| Available | Not available |
| --- | --- |
| The language's built-ins: `Promise`, `Map`, `Set`, `JSON`, `Math`, `Date`, `RegExp`, `Proxy`, `Reflect`, typed arrays, `Intl` (dates and numbers formatted for the user's locale), `WebAssembly`, `globalThis` | Node's modules and globals: `fs`, `path`, `child_process`, `process`, `Buffer`, `require` of anything but `omc` |
| `console.log` / `info` / `debug` / `warn` / `error` (to the extension's log) | Browser APIs: `fetch`, `XMLHttpRequest`, `WebSocket`, `URL`, `URLSearchParams`, `TextEncoder`, `TextDecoder`, `atob`, `btoa`, `crypto`, `structuredClone`, `queueMicrotask`, `AbortController`, `Worker`, the DOM |
| `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval` | `setImmediate`, `requestAnimationFrame` |
| `omc`: files ([`workspace.fs`](api-reference.md#workspacefs)), programs ([`process.run`](api-reference.md#process)), requests ([`net.fetch`](api-reference.md#net)) | |

Where an npm package needs one of the missing pieces, a small polyfill bundled with it usually
does (`URL` and `TextEncoder` have pure-JavaScript implementations). Packages that need Node's
file system or child processes won't work: use the `omc` equivalents.

## Limits

| Limit | Value | What happens |
| --- | --- | --- |
| JavaScript running without returning | 5 s | The run is stopped and *Stopped after running 5 seconds without a break (an endless loop?)* is logged. The extension keeps running: the next event or call goes through. |
| `activate()` | 10 s | Includes the promise it returns. Past it, the extension is *Failed* (*activate() didn't finish within 10 seconds.*) and what it registered is removed. |
| `deactivate()` | 3 s | Past it, the extension is left behind, still busy, and the log says so; the editor goes on without it. |
| A provider's answer | 1.5 s | Its token is cancelled, its answer left out, and the log says it didn't answer in time. |
| `process.run` | 60 s by default (`timeout` option) | The program is killed and the promise rejects. |
| Log | 500 lines (the sidebar shows the last 200) | Older lines drop off. |

The 5-second limit is per stretch of synchronous JavaScript: time spent waiting for a promise
(a file read, a program, a request) doesn't count. Work that really takes longer can be cut into
pieces with `setTimeout(next, 0)` between them.

There's no memory limit beyond the Mac's: a virtual machine grows as the extension allocates. An
extension that keeps big caches should key them by document `version` and drop them on
`onDidCloseTextDocument`.

## Crashes and isolation

- An exception in an extension's code — in `activate`, a command, a listener, a timer, a
  provider — is caught and logged; the extension and the editor go on.
- An extension stuck in a loop is stopped after 5 seconds (above). This uses a JavaScriptCore
  facility found at run time; if a future macOS removes it, a loop would block only that
  extension's queue, never the editor.
- Extensions can't reach into each other: separate virtual machines, and nothing shared but
  commands (whose arguments and results are copied as JSON).
- **Native code isn't isolated.** A tree-sitter parser (`nativeCode`) runs inside the app: a crash
  in it is a crash of the app. Language servers and programs from `process.run` are separate
  processes; when one crashes, the editor carries on (a language server is restarted, up to three
  times in three minutes).

## Permissions

An extension's code can only reach the Mac through the `omc` API, and the API checks the
manifest's [`permissions`](manifest.md#permissions) on every call:

| Without any permission, an extension can | With a permission it can also |
| --- | --- |
| Use the editor: commands, documents and edits, notifications, quick picks, status bar items, settings and storage, language features, diagnostics | `process`: run any program, as you, and start language servers |
| Read and write files in the window's folders (except writing inside `.git`) | `network`: make HTTP and HTTPS requests anywhere |
| Talk to running language servers (`getLanguageServer`) | `fileSystem`: read and write files anywhere you can, and inside `.git` |
| Ship grammars, snippets and language configurations | `nativeCode`: load a tree-sitter parser library into the app |

A missing permission makes the call fail at once: *This extension didn't ask to run programs on
this Mac: add "process" to "permissions" in its extension.json.* Permissions are shown in the
install dialog and in the extension's details, and granted by installing; changing them means
installing the new version (which shows them again).

### What each permission really means

The permissions say what an extension *can* do, so users can decide whether to trust it. They are
not a sandbox for a determined extension:

- **`process` is everything.** A program can do anything you can: read any file, open network
  connections, change settings. An extension with `process` effectively has every other
  permission. Ask for it only when you run programs, and run only what you need.
- **`nativeCode` is everything too**: a parser library runs inside the editor, with the editor's
  access to your files. (The editor allows libraries from other developers to load — that's what
  makes parsers possible — and keeps the library inside the extension's folder.)
- **`network`** lets an extension send whatever it can read — the files in your open folders — to
  any server. That's the reason it's separate.
- **`fileSystem`** opens your home folder, your keys and other projects.
- The app isn't sandboxed by macOS: these checks are the editor's own, made in the API.

### Files: inside and outside

“Inside” means inside one of the window's folders, after following links: a link in your project
that points to `~/.ssh` is outside. With no folder open, nothing is inside. Relative paths start
at the first folder.

### The `.git` folder

Inside the open folder, one place is still protected: changing anything inside a `.git` folder (or
a worktree's `.git` file) — with `workspace.fs.writeFile`, `TextEditor.edit` or `document.save` —
fails without `fileSystem`: *… is inside .git: changing it needs the "fileSystem" permission in
the extension's extension.json.* Git runs programs named in `.git/config` (`core.fsmonitor`,
aliases) and `.git/hooks`, so writing there would let any extension run code. Reading `.git` is
allowed (to show the branch, say). The check ignores case and follows links.

## Data and storage

| Where | What | Scope | Removed |
| --- | --- | --- | --- |
| [`context.storage`](api-reference.md#the-extensions-context) | Any JSON values | The extension (every window and folder) | On uninstall |
| [Settings](manifest.md#configuration) | Values the user (or code) sets | The extension (every window and folder) | On uninstall |
| Files in the workspace (`.myextension/` in the folder) | Per-project data | The folder | When you delete them |
| Files elsewhere (`fileSystem`) | Caches, downloads | Wherever you put them | When you delete them |

Storage and settings are kept in the app's preferences (`UserDefaults`), as JSON text: fine for
small values (a last choice, a counter, a list of recent items), wrong for large data — write
files for that. There's no per-folder storage: key values by `omc.workspace.rootPath` if you need
it. Both survive updates (installing a new version) and both go when the extension is
uninstalled.

The extension's own folder (`context.extensionPath`) is replaced on every update: don't write
there.

## Secrets

There's no secret storage in the API. Don't put tokens or passwords in `context.storage` or in
settings: both are plain text in the app's preferences file, which backups and other apps can
read.

- Best: don't hold the secret. Use the credentials tools already have (`gh auth token`, `git
  credential fill`, a CLI's own login) through `omc.process.run`.
- Or keep it in the macOS Keychain with the `security` tool (needs `process`):

```ts
import * as omc from "omc";

const SERVICE = "acme.date-tools";

/** The token saved in the login keychain, if there is one. */
export async function readToken(): Promise<string | undefined> {
  const found = await omc.process.run("security", ["find-generic-password", "-s", SERVICE, "-w"]);
  return found.code === 0 ? found.stdout.trim() : undefined;
}

/** Saves (or replaces) the token in the login keychain. */
export async function saveToken(token: string): Promise<void> {
  const saved = await omc.process.run("security", ["add-generic-password", "-U", "-s", SERVICE, "-a", "token", "-w", token]);
  if (saved.code !== 0) throw new Error(saved.stderr.trim());
}
```

  The token is on `security`'s command line for the moment it runs, where other programs of
  yours could see it; for most tokens that's acceptable, for high-value ones prefer the first
  option.
- Ask for the secret with `showInputBox` (it isn't hidden while typed: say so in the prompt),
  never log it, and send it only over HTTPS.

## Before installing someone else's extension

- Read the permissions in the install dialog. No permissions: it can only work with the editor and
  the files in your open folders. `process` or `nativeCode`: it can do anything you can.
- The code is right there: the extension's folder (Extensions sidebar → right-click → *Reveal in
  Finder*) holds the JavaScript it runs.

## See also

- [The manifest](manifest.md#permissions): declaring permissions.
- [API reference](api-reference.md): which calls need which permission.
- [Debugging and testing](debugging-and-testing.md): the errors these limits produce.
