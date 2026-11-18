# Debugging and testing

There's no debugger attached to extensions: you work with the log, quick reloads, the editor's
own inspection tools, and tests of your logic run in Node. This page shows each, lists the errors
you're likely to meet with what they mean, and ends with performance advice.

## The log

Every extension has a log: Extensions sidebar (the puzzle piece in the activity bar) → the
disclosure arrow beside the extension → **Log**.

| Written by | Level (color) |
| --- | --- |
| `console.log`, `console.info`, `console.debug` | info |
| `console.warn` | warning (orange) |
| `console.error` | error (red) |
| An uncaught exception in a listener, timer or `EventEmitter` listener, with its stack | error |
| A provider that threw or didn't answer in time | error |
| Activation that failed or timed out | error |
| A keybinding that doesn't parse, a shortcut a menu already has, a grammar or language configuration that can't be read | warning |

Objects passed to `console.log` are written as JSON, errors with their stack (file and line in
your compiled `dist/extension.js`). The log keeps the last 500 lines (the sidebar shows the last
200), is selectable for copying, and has **Clear Log**. It lives in memory, per window: it starts
empty when the window opens.

The row's state says where the extension is: *Starts when needed* (installed, not started yet),
*Starting…*, *Running*, *Failed: see the log*, *Disabled*.

**Tip:** log generously while developing, behind a setting, so users can turn it on to send you
a log:

```ts
import * as omc from "omc";

function trace(...parts: unknown[]) {
  if (omc.workspace.getConfiguration("dateTools").get<boolean>("trace", false)) console.log(...parts);
}

export function activate(context: omc.ExtensionContext) {
  trace("activated", context.extensionPath, omc.version);
}
```

## Reloading

After rebuilding, run **Extensions: Reload** (palette) or **+** ▸ *Reload Extensions* in the
Extensions sidebar. It stops every extension in the window (`deactivate`, then disposal) and
starts them again from disk — main file and `extension.json` both. The editor doesn't watch your
files; nothing changes until you reload. Reload acts on the window it's run in.

Install your extension *for development* (**+** ▸ *Install for Development…*, or *New
Extension…*, which does it for you) so that reloading picks up your folder's latest build; an
extension installed *from folder* is a copy, which only changes when you install it again.

What doesn't need a reload:

- **Snippets** are read again the next time completion is asked for.
- **Settings** are read when your code reads them; `onDidChangeConfiguration` tells you.

A rebuilt **tree-sitter parser library** needs the app restarted: a loaded library can't be
replaced ([Syntax highlighting](syntax-highlighting.md#debugging)).

## Inspecting what the editor sees

- **Developer: Inspect Editor Tokens and Scopes** (palette): for the text under the caret, the
  language, which highlighting colors it, the TextMate scopes or tree-sitter captures, the
  semantic token over it, and which theme rule decides the color. The way to debug a grammar or
  semantic tokens provider ([Syntax highlighting](syntax-highlighting.md#debugging)).
- **The status bar's language**: the file's language id is what your selectors and
  `onLanguage:` events see. Click it for *Change Language Mode*.
- **Settings ▸ Languages** (or *Preferences: Language Servers*): every language server, the
  extensions' first, with its status (*Running*, *Starting*, *Failed: …*, *Not found*, *Not
  running*, *Off*), **Restart**, and its **Log** — what it wrote to stderr and sent with
  `window/logMessage`, with a Copy button ([Language servers](language-servers.md#troubleshooting)).
- **Settings ▸ Keyboard Shortcuts**: your commands with their shortcuts, as users' changes leave
  them.
- **The Problems panel** (*View: Toggle Problems*): your diagnostics, with their `source`.

## Common errors

### Installing and loading

Shown in an alert when installing, or beside the folder (with a warning sign) at the bottom of the
Extensions sidebar.

| Message | Cause |
| --- | --- |
| *extension.json can't be read: missing “id”* | A required field (`id`, `name`, `version`, `main`) is missing. |
| *extension.json can't be read: wrong type at “contributes.commands”* | A field has the wrong type (a string where a list is expected…). |
| *extension.json can't be read: … invalid String value …* | A value not in the list: a setting `type` other than `boolean`, `string`, `number`; an unknown permission. |
| *extension.json can't be read: The given data was not valid JSON.* | Not valid JSON: a trailing comma, a comment. |
| *“acme” isn't a valid id: use publisher.name (letters, digits, - and _).* | The id needs exactly one dot. |
| *The main file dist/extension.js doesn't exist (build the extension first?).* | Build it; check `main`. |
| *“main” (../x.js) must be inside the extension's folder.* / *“…” must be inside the extension's folder.* | A path leaves the folder. |
| *A language server needs "process" in “permissions”.* / *A tree-sitter grammar needs "nativeCode" in “permissions”.* | Add the permission. |
| *extension.json: a language server needs an “id”, “languages” and a “command” (and the stdio transport).* | An incomplete `languageServers` entry. |

### Starting

In the extension's log; the row says *Failed: see the log*.

| Message | Cause |
| --- | --- |
| *Activation failed: Cannot find module './util': only 'omc' is available, bundle other dependencies into the extension.* | The main file requires another file or a package: [bundle it](getting-started.md#building-with-esbuild). |
| *Activation failed: activate() didn't finish within 10 seconds.* | `activate` (or its promise) takes too long: start slow work without awaiting it, or on first use. |
| *Activation failed: SyntaxError: …* | The main file isn't valid JavaScript for JavaScriptCore — ES modules output (`export` in `dist/`), or a target newer than the system supports. Compile to CommonJS, ES2020. |
| *Activation failed: ReferenceError: Can't find variable: fetch* (or `require`, `process`, `URL`, `TextEncoder`) | A Node or browser global: see [what's available](runtime-and-security.md#whats-available). |
| *&lt;Name&gt; couldn't start: see its log in Extensions.* (alert) | A command was run but the extension failed to start. |

### Running

| Message | Cause |
| --- | --- |
| *The command dateTools.insertDate isn't registered by its extension.* | It's in `contributes.commands` but `activate` didn't register it (check the id's spelling). |
| *There's no command “…”.* | No enabled extension contributes or registers it, and it isn't built in. |
| *The command … is already registered* | `registerCommand` twice for one id (a second `activate`? a duplicate line?). |
| *This extension didn't ask to run programs on this Mac: add "process" to "permissions" in its extension.json.* | Likewise for *make network requests* (`network`), *read and write files outside the open folder* (`fileSystem`). |
| *… is outside the open folder.* | A path outside the window's folders, without `fileSystem`. A relative path is taken from the *first* folder. |
| *… is inside .git: changing it needs the "fileSystem" permission …* | [The `.git` protection](runtime-and-security.md#the-git-folder). |
| *… isn't open: open it with omc.workspace.openTextDocument first.* | `getText`, `lineAt`, `edit` or `save` on a document that was closed. |
| *Wrong arguments for document.getLine.* | `lineAt` past the last line (or before 0). |
| *The edits overlap.* | Two ranges in one `edit` overlap. |
| *The program didn't finish within 60 seconds and was stopped.* | `process.run` timed out: pass a longer `timeout`. |
| *Stopped after running 5 seconds without a break (an endless loop?).* | Synchronous code ran too long; it was stopped. |
| *completion provider: didn't answer within 1.5 s* (and the like) | A provider took longer than the 1.5 s allowed. |
| *The language server “…” isn't running: open a file it handles first.* | `sendRequest` before the server has started. |
| *Keybinding … for … ignored: …* | The key doesn't parse ([keys](manifest.md#keybindings)). |
| *⌃⌥D is the menu's “…”: … isn't run.* | A menu item has the shortcut: pick another. |
| *deactivate() didn't finish within 3 seconds; …* | `deactivate` is too slow; make it quick or drop it. |

When something silently does nothing, check: a misspelled field in `extension.json` (unknown
fields are ignored), a `when` with an unsupported term (always false), a selector naming the wrong
language id, an extension that never activates (no activation event fits — add `onStartup` while
you investigate).

## Testing

The `omc` module exists only inside the editor, so test the parts of your extension that don't
need it, in Node, and keep the parts that do need it thin.

### Structure the code for it

Put the logic — parsing, computing ranges, building text — in modules that don't import `omc`
at run time, and keep `extension.ts` to wiring: read from the editor, call the logic, write the
result back.

```
src/
├── extension.ts   imports omc: registers commands and providers, calls todos.ts
└── todos.ts       pure functions: text in, data out
test/
└── todos.test.ts
```

`src/todos.ts` — `import type` is erased when compiled, so the module can name `omc`'s types
without requiring it:

```ts
import type { TextDocument } from "omc";

export interface Todo {
  line: number;
  character: number;
  text: string;
}

/** The TODO comments in `text`, with where each starts. */
export function findTodos(text: string): Todo[] {
  const todos: Todo[] = [];
  text.split("\n").forEach((line, number) => {
    const match = /\bTODO\b:?\s*(.*)$/.exec(line);
    if (match) todos.push({ line: number, character: match.index, text: match[1].trim() });
  });
  return todos;
}

/** The same, for an open document. */
export function todosIn(document: TextDocument): Todo[] {
  return findTodos(document.getText());
}
```

`test/todos.test.ts`, with Node's built-in test runner:

```ts
import { test } from "node:test";
import * as assert from "node:assert/strict";
import { findTodos } from "../src/todos";

test("finds TODOs with their position", () => {
  assert.deepEqual(findTodos("let a = 1\n  // TODO: rename\n"), [{ line: 1, character: 5, text: "rename" }]);
});

test("ignores words that only contain TODO", () => {
  assert.deepEqual(findTodos("const TODOS = []"), []);
});
```

### Running the tests

Compile the tests with their own TypeScript configuration, which adds Node's types (and leaves
`extension.ts` out), then run them:

```sh
npm install --save-dev @types/node
```

`tsconfig.test.json`:

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "outDir": "out",
    "rootDir": ".",
    "types": ["node"],
    "skipLibCheck": true
  },
  "files": ["omc.d.ts"],
  "include": ["src/**/*.ts", "test/**/*.ts"],
  "exclude": ["src/extension.ts"]
}
```

`skipLibCheck` is there because `omc.d.ts` and Node's types both declare `console` and the timers.
In `package.json`:

```json
"scripts": {
  "build": "esbuild src/extension.ts --bundle --format=cjs --platform=neutral --main-fields=module,main --target=es2020 --external:omc --outfile=dist/extension.js",
  "test": "tsc -p tsconfig.test.json && node --test out/test/"
}
```

```sh
npm test
```

(With more than one source file, the extension needs [esbuild](getting-started.md#building-with-esbuild)
to build; add `out/` to `.gitignore`.)

### Testing code that uses the editor's types

When logic needs a document, pass it something shaped like one. A fake `TextDocument` for tests:

```ts
import type { TextDocument, Position, Range } from "omc";

/** Enough of a TextDocument for tests: the text, the language, the lines. */
export function fakeDocument(text: string, languageId = "plaintext"): TextDocument {
  const lines = text.split("\n");
  return {
    path: "/test/file", fileName: "file", languageId, isDirty: false, lineCount: lines.length, version: 1,
    uri: { scheme: "file", path: "/test/file", fsPath: "/test/file", toString: () => "file:///test/file" },
    getText: (range?: Range) => {
      if (!range) return text;
      const offset = (p: Position) => lines.slice(0, p.line).reduce((n, l) => n + l.length + 1, 0) + p.character;
      return text.slice(offset(range.start), offset(range.end));
    },
    lineAt: (line: number | Position) => {
      const lineNumber = typeof line === "number" ? line : line.line;
      return { lineNumber, text: lines[lineNumber] };
    },
    getWordRangeAtPosition: () => undefined,
    save: async () => true,
  };
}
```

Classes from `omc` (`Range`, `Position`, `CompletionItem`) exist only in the editor; logic that
builds them takes them as a parameter, or returns plain data that `extension.ts` turns into them —
which is usually the simpler design anyway.

### Trying it in the editor

For what tests can't reach — the wiring, the timing — keep a sample folder with files that
exercise every feature (the toy language's `sample.toy` is one), open it in a window, and go
through it after each reload.

## Performance

- **Start late.** Prefer `onLanguage:`, `onCommand:` and contributed commands to `onStartup`: an
  extension that isn't needed isn't loaded, in any window.
- **Keep `activate` short.** Register, then return. Load caches or start programs on first use, or
  without awaiting them.
- **Fewer calls into the editor.** Each `getText`, `lineAt` or `activeTextEditor` waits for the main
  thread. In a loop over a big file, call `document.getText()` once and split it, rather than
  `lineAt` per line.
- **Cache by version.** `document.version` changes with every edit: keep results keyed by path and
  version, and drop them on `onDidCloseTextDocument`.
- **Respect cancellation.** Providers have 1.5 seconds; check `token.isCancellationRequested` in
  loops, and return early.
- **Don't parse twice.** Several providers (symbols, folding, semantic tokens) often need the same
  parse: share it through the cache above.
- **Programs are slow to start.** `process.run` launches a process each time; run linters on save
  rather than on every change, or keep one server running as a language server.
- **Timers.** An interval that runs every second, in every window, adds up: use events
  (`onDidSaveTextDocument`, `onDidChangeActiveTextEditor`) where they exist.

## See also

- [Runtime and security](runtime-and-security.md): the limits behind the errors.
- [Getting started](getting-started.md): the build and reload loop.
- [Publishing](publishing.md): before you share it.
