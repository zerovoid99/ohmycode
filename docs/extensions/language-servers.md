# Language servers

Most of what makes a language pleasant to edit — completion, errors as you type, Go to
Definition, rename — usually comes from a language server speaking the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol/). An extension
can bring one: declare it in `extension.json` and the editor starts it for files of its
languages, keeps it running for the window, restarts it when it crashes, and shows everything it
offers through the same features the built-in servers use.

This guide covers:

- [Declaring a server](#declaring-a-server) (`contributes.languageServers`)
- [Settings](#settings-and-config) and `${config:…}`
- [Project roots](#project-roots) (`rootPatterns`)
- [Which server a file gets](#which-server-a-file-gets) and turning servers off
- [Starting a server from code](#starting-a-server-from-code)
- [Custom requests and notifications](#custom-requests-and-notifications)
- [What the editor's client supports](#what-the-client-supports)
- [Troubleshooting](#troubleshooting)

## Declaring a server

```json
{
  "id": "acme.toy",
  "name": "Toy Language",
  "version": "1.0.0",
  "main": "dist/extension.js",
  "permissions": ["process"],
  "contributes": {
    "languages": [{ "id": "toy", "extensions": [".toy"] }],
    "configuration": {
      "toy.checkLevel": { "type": "string", "default": "basic", "description": "How strict the checks are." }
    },
    "languageServers": [
      {
        "id": "toy-ls",
        "name": "Toy Language Server",
        "languages": ["toy"],
        "command": "./server/toy-ls",
        "args": ["--stdio"],
        "env": { "TOY_LOG": "info" },
        "initializationOptions": { "checkLevel": "${config:toy.checkLevel}" },
        "settings": { "toy": { "checkLevel": "${config:toy.checkLevel}", "format": { "enable": true } } },
        "rootPatterns": ["toy.json"],
        "transport": "stdio"
      }
    ]
  }
}
```

| Field | Meaning |
| --- | --- |
| `id` | The server's id: Settings ▸ Languages, `languageServers.<id>.enabled` and `omc.languages.getLanguageServer(id)` use it. Required. |
| `name` | Shown in the status bar and Settings ▸ Languages (the id by default). |
| `languages` | Language ids it serves — contributed ones or built in (`"rust"`, `"typescriptreact"`). Required. |
| `command` | The program. An absolute path; a path with a `/` in it, relative to the extension's folder (`./server/toy-ls`, `bin/server`), which must stay inside it; or a bare name (`rust-analyzer`), looked up on the login shell's `PATH` like the built-in servers. `${extensionPath}` is replaced by the extension's folder. Required. |
| `args` | Arguments. `${extensionPath}` works here too (`["${extensionPath}/server.js", "--stdio"]` with `"command": "node"`). |
| `env` | Added to the login shell's environment. |
| `initializationOptions` | Sent as `initializationOptions` in `initialize`. |
| `settings` | What the server is told its settings are (see below). |
| `rootPatterns` | Files that mark a project root (see below). |
| `transport` | Only `"stdio"` (the default): JSON-RPC with `Content-Length` headers on stdin and stdout. |

**The `process` permission is required.** Starting a server runs a program, so an
`extension.json` with `languageServers` but without `"process"` in `permissions` doesn't install
(and the permission is shown before installing, like any other).

The server starts when the first file of one of its languages opens in a window with a folder,
in the window's first folder (with every folder as `workspaceFolders`). A server that says it
takes several folders (`workspace.workspaceFolders.supported`) serves them all; otherwise a file
in another folder gets a server of its own, started there. Its working directory is the folder
it starts in. It's stopped (`shutdown`, `exit`) when the window closes; if it exits on its own,
it's started again with the files it had open — up to three times in three minutes.

## Settings and `${config:…}`

`settings` is the object the server sees as its configuration. It's used two ways, so it works
with servers that pull their settings and those that are pushed them:

- **`workspace/configuration`** requests are answered from it. Each item's `section` is a dotted
  path into it: with the settings above, `"toy"` answers the whole `toy` object,
  `"toy.format.enable"` answers `true`, and a section it doesn't have answers `null`. An item
  without a section gets all of it.
- **`workspace/didChangeConfiguration`** is sent with `{ "settings": … }` once the server is
  ready, and again whenever the settings change.

Any string in `settings` or `initializationOptions` can refer to the extension's own
configuration (its `contributes.configuration`):

- `"${config:toy.checkLevel}"` on its own becomes the setting's value, with its type (a number
  stays a number, a boolean a boolean; an unset setting without a default becomes `null`).
- Inside a longer string it's replaced by the value's text: `"level-${config:toy.checkLevel}"`.

When the user changes one of the extension's settings (Extensions sidebar → the extension →
Settings, or `omc.workspace.getConfiguration().update(…)` from code), the running servers get the
new settings at once through `workspace/didChangeConfiguration`.

## Project roots

Without `rootPatterns`, a server starts in the workspace folder. Monorepos often need it to start
in the project a file belongs to instead: with `"rootPatterns": ["Cargo.toml"]`, opening
`crates/parser/src/lib.rs` looks for `Cargo.toml` in `crates/parser/src`, then `crates/parser`,
and so on up to the workspace folder, and starts the server in the first folder that has one
(each such project gets its own server). Patterns are file names, or globs on a file name
(`"*.csproj"`). When no folder has one, the workspace folder is used.

## Which server a file gets

For a file's language, the editor uses, in order:

1. a server an extension declares or registers for the language (the first one: those declared in
   `extension.json`, in the order of the Extensions list, then those registered from code);
2. the built-in candidates: SourceKit-LSP (Swift, C, C++, Objective-C), typescript-language-server
   (TypeScript, JavaScript), Pyright then pylsp (Python), rust-analyzer (Rust), gopls (Go) — the
   first whose program is on the `PATH`.

A server can be turned off with the setting `languageServers.<id>.enabled`:

- in **Settings ▸ Languages**, with the switch beside each server (for every window), or
- in a folder's `.omc/settings.json`, for files in that folder:

```jsonc
{
  // Use the built-in rust-analyzer rather than the extension's server here.
  "languageServers.toy-ls.enabled": false,
  "languageServers.pyright.enabled": false
}
```

A server that's off is skipped, so the next one in the list is used. Built-in ids are
`sourcekit-lsp`, `typescript-language-server`, `pyright`, `pylsp`, `rust-analyzer` and `gopls`.
Changing the setting moves open files to their new server at once (and stops one nothing uses).

## Starting a server from code

When the command line depends on something only code can find out (a downloaded binary, a
version check), register the server at run time instead. It takes the same fields and needs the
same permission:

```ts
import * as omc from "omc";

export async function activate(context: omc.ExtensionContext) {
  const found = await omc.process.run("which", ["toy-ls"]);
  const command = found.code === 0 ? found.stdout.trim() : context.extensionPath + "/server/toy-ls";
  context.subscriptions.push(
    omc.languages.registerLanguageServer({
      id: "toy-ls",
      name: "Toy Language Server",
      languages: ["toy"],
      command,
      args: ["--stdio"],
      settings: { toy: { checkLevel: "${config:toy.checkLevel}" } },
    }),
  );
}
```

Files of its languages that are already open move to it right away. Disposing the returned
`Disposable` (or the extension stopping) unregisters it: the server stops and the files go back to
whatever else serves them. Registering the same id again replaces the definition.

## Custom requests and notifications

Many servers extend the protocol (rust-analyzer's `experimental/*` requests, clangd's
`textDocument/switchSourceHeader`, progress or status notifications of their own).
`omc.languages.getLanguageServer(id)` talks to a running server — declared by any extension,
registered from code, or built in:

```ts
const server = omc.languages.getLanguageServer("toy-ls");

// A request: resolves with the server's result, rejects with its error.
const tree = await server.sendRequest<string>("toy/syntaxTree", {
  textDocument: { uri: omc.window.activeTextEditor!.document.uri.toString() },
});

// A notification.
server.sendNotification("toy/reloadWorkspace");

// Notifications from the server the editor doesn't handle itself.
context.subscriptions.push(server.onNotification("toy/status", (params) => {
  statusItem.text = params.health === "ok" ? "$(check) Toy" : "$(warning) Toy";
}));

// Requests from the server the editor doesn't answer itself: return the result (or a promise).
context.subscriptions.push(server.onRequest("toy/askUser", async (params) => {
  return await omc.window.showQuickPick(params.choices);
}));
```

- `sendRequest` and `sendNotification` go to the server of the active file when it's that server,
  else to any running one. They fail with “isn't running” when no file of its languages is open
  yet (open one first, or wait for `onDidOpenTextDocument`).
- Requests sent while the server is still starting wait for it.
- Handlers are kept across restarts of the server; a request no extension handles is answered
  with “method not found”.
- Params and results are JSON: positions are zero-based lines and UTF-16 characters, URIs are
  `file://` URIs (`document.uri.toString()`).

## What the client supports

The editor's client implements what the editor shows, and these from the server's side:

| Message | What happens |
| --- | --- |
| `workspace/configuration` | Answered from `settings` (see above); `null` for built-in servers. |
| `workspace/didChangeConfiguration` | Sent once ready and on every settings change. |
| `client/registerCapability`, `client/unregisterCapability` | Registrations are kept. Features registered this way (completion, hover, definition, references, symbols, code actions, formatting, rename, signature help, semantic tokens…) count as supported, with their options (trigger characters, the tokens legend). The file's features are asked for again when registrations change. |
| `workspace/didChangeWatchedFiles` | For `workspace/didChangeWatchedFiles` registrations: files in the window's folders that are created, changed or deleted on disk are sent to the server when they match a watcher's glob (a string, or a relative pattern on a folder) and `kind`. |
| `window/showMessage` | Errors, warnings and info as notifications; log messages go to the server's log. |
| `window/showMessageRequest` | A notification with the actions as buttons; the one clicked is the answer (`null` when dismissed). |
| `window/logMessage` | Added to the server's log. |
| `window/workDoneProgress/create`, `$/progress` | The status bar shows a spinner with the title, message and percentage while work is in progress. |
| `window/showDocument` | The file opens, with the selection revealed. |
| `workspace/applyEdit` | Applied (each file one undo step), unless a file changed since the server computed it. |
| `workspace/workspaceFolders`, `workspace/didChangeWorkspaceFolders` | The window's folders, and changes to them. |
| `workspace/inlayHint/refresh`, `codeLens/refresh`, `semanticTokens/refresh` | Asked for again. |

What the server writes to stderr is kept too, with `window/logMessage`, in its log.

## Troubleshooting

Open **Settings ▸ Languages** (or *Preferences: Language Servers* in the palette). Every server is
listed — the extensions' first, then the built-in ones — with its id, where it comes from, its
languages and its status:

| Status | Meaning |
| --- | --- |
| Running | Started and initialized in some window. |
| Starting | Waiting for its `initialize` answer. |
| Failed: … | It couldn't start (the program wouldn't run) or exited, with why. After three crashes in three minutes it's left failed. |
| Not found | Its program isn't there: a relative path missing from the extension, or a name not on the login shell's `PATH` (`echo $PATH` in Terminal shows what's searched). |
| Not running | Nothing has needed it yet: no file of its languages is open. |
| Off | Turned off with its switch. |

**Log** shows what the server wrote to stderr and sent with `window/logMessage` (the last 1,000
lines), with a Copy button for bug reports. **Restart** stops every client of the server; the
files they had open start it again (with your latest changes to its program).

Other things to check:

- The extension's own log (Extensions sidebar → the extension) shows problems with
  `extension.json` and errors from `registerLanguageServer` or `getLanguageServer`.
- The file's language: the status bar shows it. If it's Plain Text, the server isn't asked —
  see [how a file's language is chosen](language-support.md#how-a-files-language-is-chosen).
- A server that needs its settings before it does anything may expect a `workspace/configuration`
  section you haven't put in `settings`: the log usually says which.

## See also

- [Language support](language-support.md): declaring the languages a server serves.
- [Language feature providers](providers.md): features in code, merged with the server's.
- [Snippets](snippets.md).
- [Syntax highlighting](syntax-highlighting.md): semantic tokens from a server, over grammar colors.
- [Cookbook](cookbook.md#a-language-server-installed-with-npm): a server installed with npm; [API reference](api-reference.md#language-servers).
