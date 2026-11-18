# Cookbook

Short recipes for common tasks. Each has the goal, the part of `extension.json` it needs, the
code, and notes. The code is complete: put it in `src/extension.ts` (or merge it into yours),
build, and run **Extensions: Reload**. Ids use the publisher `acme`; use your own.

1. [A command with a keyboard shortcut](#a-command-with-a-keyboard-shortcut)
2. [Read and write files in the workspace](#read-and-write-files-in-the-workspace)
3. [Run a program and show its output](#run-a-program-and-show-its-output)
4. [A status bar item](#a-status-bar-item)
5. [React to saves](#react-to-saves)
6. [Diagnostics from a linter](#diagnostics-from-a-linter)
7. [A formatter that calls a program](#a-formatter-that-calls-a-program)
8. [A language with a TextMate grammar](#a-language-with-a-textmate-grammar)
9. [A language server installed with npm](#a-language-server-installed-with-npm)
10. [A custom language server request](#a-custom-language-server-request)
11. [Snippets](#snippets)
12. [A quick fix](#a-quick-fix)
13. [Hover documentation from a JSON file](#hover-documentation-from-a-json-file)
14. [Ask, and remember the answer](#ask-and-remember-the-answer)
15. [Call a web API](#call-a-web-api)

## A command with a keyboard shortcut

**Goal:** ⌃⌥W wraps the selection in an HTML tag the user types.

```json
"contributes": {
  "commands": [{ "command": "acme.wrapInTag", "title": "Wrap in Tag", "category": "Acme" }],
  "keybindings": [{ "command": "acme.wrapInTag", "key": "ctrl+alt+w", "when": "editorTextFocus" }]
}
```

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.commands.registerCommand("acme.wrapInTag", async () => {
      const editor = omc.window.activeTextEditor;
      if (!editor) return;
      const tag = await omc.window.showInputBox({ prompt: "Tag", value: "div" });
      if (!tag) return;
      const edits = editor.selections.map((range) => ({
        range,
        text: `<${tag}>${editor.document.getText(range)}</${tag.split(" ")[0]}>`,
      }));
      await editor.edit(edits);
    }),
  );
}
```

- The command is in the palette as *Acme: Wrap in Tag*, and starts the extension on first use.
- Every selection is wrapped, in one undoable step.
- `editor` is a snapshot from before the input box: its `selections` are where they were when the
  command started. Read `omc.window.activeTextEditor` again if that matters.
- [Keybindings](manifest.md#keybindings) lists the keys and `when` terms.

## Read and write files in the workspace

**Goal:** *Add Line to TODO.md* appends the current line, with its file and line number, to
`TODO.md` in the file's folder.

```json
"contributes": {
  "commands": [{ "command": "acme.addTodo", "title": "Add Line to TODO.md", "category": "Acme" }]
}
```

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.commands.registerCommand("acme.addTodo", async () => {
      const editor = omc.window.activeTextEditor;
      if (!editor) return;
      const document = editor.document;
      // With several folders, use the one the file is in.
      const folder = omc.workspace.getWorkspaceFolder(document.path) ?? omc.workspace.folders[0];
      if (!folder) return;
      const todo = folder.path + "/TODO.md";
      const line = editor.selection.start.line;
      const relative = document.path.slice(folder.path.length + 1);
      const entry = `- [ ] ${document.lineAt(line).text.trim()} (${relative}:${line + 1})\n`;

      const existing = (await omc.workspace.fs.exists(todo)) ? await omc.workspace.fs.readFile(todo) : "# TODO\n\n";
      await omc.workspace.fs.writeFile(todo, existing + entry);
      await omc.window.showInformationMessage(`Added to ${folder.name}/TODO.md`);
    }),
  );
}
```

- No permission needed: the file is inside the window's folders.
- `readFile` reads what's on disk. If `TODO.md` is open with unsaved changes, write through the
  editor instead (`openTextDocument`, then `showTextDocument` and `edit`), or the file on disk and
  the tab disagree.
- `writeFile` doesn't create folders; there's no delete or rename (run a program for those).

## Run a program and show its output

**Goal:** *Who Changed This Line?* shows the last commit that touched the current line.

```json
"contributes": {
  "commands": [{ "command": "acme.blameLine", "title": "Who Changed This Line?", "category": "Acme" }]
},
"permissions": ["process"]
```

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.commands.registerCommand("acme.blameLine", async () => {
      const editor = omc.window.activeTextEditor;
      if (!editor) return;
      const document = editor.document;
      const line = editor.selection.start.line + 1;
      const folder = omc.workspace.getWorkspaceFolder(document.path);
      const result = await omc.process.run(
        "git", ["blame", "--porcelain", "-L", `${line},${line}`, "--", document.path],
        { cwd: folder?.path, timeout: 10_000 },
      );
      if (result.code !== 0) {
        await omc.window.showErrorMessage(result.stderr.trim() || "git blame failed");
        return;
      }
      const field = (name: string) => new RegExp(`^${name} (.*)$`, "m").exec(result.stdout)?.[1] ?? "";
      const when = new Date(Number(field("author-time")) * 1000).toLocaleDateString();
      await omc.window.showInformationMessage(`${field("author")}, ${when}: ${field("summary")}`);
    }),
  );
}
```

- `process.run` finds `git` on the login shell's `PATH`, runs it without a shell (arguments are
  passed as they are, so spaces in paths are fine), and resolves when it exits — a non-zero `code`
  doesn't reject.
- For a long-running program, set `timeout` (60 s by default); for pipes or globs, run
  `/bin/sh -c "…"`.
- Output is returned whole when the program exits; there's no streaming.

## A status bar item

**Goal:** the current git branch, at the left of the status bar, without running git.

```json
"activationEvents": ["onStartup"]
```

```ts
import * as omc from "omc";

/** The branch in `folder`'s .git/HEAD, or a short commit id when detached. */
async function branch(folder: string): Promise<string | undefined> {
  const head = folder + "/.git/HEAD";
  if (!(await omc.workspace.fs.exists(head))) return undefined; // not a repository (or a worktree)
  const text = (await omc.workspace.fs.readFile(head)).trim();
  return text.startsWith("ref: refs/heads/") ? text.slice(16) : text.slice(0, 7);
}

export function activate(context: omc.ExtensionContext) {
  const item = omc.window.createStatusBarItem(omc.StatusBarAlignment.Left, 100);
  item.tooltip = "Current branch";
  const update = async () => {
    const document = omc.window.activeTextEditor?.document;
    const folder = (document && omc.workspace.getWorkspaceFolder(document.path)) ?? omc.workspace.folders[0];
    const name = folder && (await branch(folder.path));
    if (!name) { item.hide(); return; }
    item.text = `$(arrow.triangle.branch) ${name}`;
    item.show();
  };
  const timer = setInterval(update, 10_000); // a checkout in Terminal
  context.subscriptions.push(
    item,
    { dispose: () => clearInterval(timer) },
    omc.window.onDidChangeActiveTextEditor(() => void update()),
    omc.workspace.onDidChangeWorkspaceFolders(() => void update()),
  );
  void update();
}
```

- Reading inside `.git` is allowed without permissions; writing there isn't.
- `$(arrow.triangle.branch)` is an SF Symbol. Higher `priority` goes first on its side.
- `onStartup` because the item should be there from the start. A timer every 10 seconds per
  window is cheap; one every 100 ms isn't.

## React to saves

**Goal:** a warning when a saved `.json` file isn't valid JSON.

```json
"activationEvents": ["onLanguage:json"]
```

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.workspace.onDidSaveTextDocument(async (document) => {
      if (document.languageId !== "json" || document.fileName.endsWith(".jsonc")) return;
      try {
        JSON.parse(document.getText());
      } catch (error) {
        const choice = await omc.window.showWarningMessage(`${document.fileName} isn't valid JSON: ${(error as Error).message}`, "Show");
        if (choice === "Show") await omc.window.showTextDocument(document);
      }
    }),
  );
}
```

- `onLanguage:json` starts the extension with the first JSON file; listeners only hear events
  while the extension runs.
- The event's document is a snapshot taken at the save; `getText()` reads the text now.
- Avoid editing the document in a save listener: the edit makes it unsaved again.

## Diagnostics from a linter

**Goal:** [Ruff](https://docs.astral.sh/ruff/)'s findings as problems in Python files, on open
and save.

```json
"activationEvents": ["onLanguage:python"],
"permissions": ["process"]
```

```ts
import * as omc from "omc";

interface RuffFinding {
  code: string | null;
  message: string;
  location: { row: number; column: number };
  end_location: { row: number; column: number };
}

export function activate(context: omc.ExtensionContext) {
  const collection = omc.languages.createDiagnosticCollection("ruff");

  const lint = async (document: omc.TextDocument) => {
    if (document.languageId !== "python") return;
    const folder = omc.workspace.getWorkspaceFolder(document.path);
    const result = await omc.process.run(
      "ruff", ["check", "--output-format=json", "--stdin-filename", document.path, "-"],
      { cwd: folder?.path, input: document.getText(), timeout: 15_000 },
    );
    if (result.code > 1) { // 0: clean, 1: findings, 2: ruff failed
      console.error(result.stderr);
      return;
    }
    const findings = JSON.parse(result.stdout || "[]") as RuffFinding[];
    collection.set(document, findings.map((finding) => ({
      // Ruff counts rows and columns from 1; the editor from 0.
      range: new omc.Range(finding.location.row - 1, finding.location.column - 1,
                           finding.end_location.row - 1, finding.end_location.column - 1),
      message: finding.code ? `${finding.code}: ${finding.message}` : finding.message,
      severity: omc.DiagnosticSeverity.Warning,
    })));
  };

  omc.workspace.textDocuments.forEach((document) => void lint(document));
  context.subscriptions.push(
    collection,
    omc.workspace.onDidOpenTextDocument((document) => void lint(document)),
    omc.workspace.onDidSaveTextDocument((document) => void lint(document)),
    omc.workspace.onDidCloseTextDocument((document) => collection.delete(document)),
  );
}
```

- The text is piped in (`input`), so unsaved changes are linted too; `--stdin-filename` lets Ruff
  find the project's configuration.
- Problems show underlined, in the Problems panel, with `ruff` as their source, beside the
  language server's.
- Linting on every change (`onDidChangeTextDocument`) works too, but starts a process per pause in
  typing: debounce it, and drop results for an older `document.version`.
- Lines and columns: most tools count from 1 and some count bytes, not characters. Convert
  carefully; the editor counts UTF-16 characters from 0.

## A formatter that calls a program

**Goal:** *Format Document* for shell scripts, with [shfmt](https://github.com/mvdan/sh).

```json
"activationEvents": ["onLanguage:shellscript"],
"permissions": ["process"]
```

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.languages.registerDocumentFormattingEditProvider("shellscript", {
      async provideDocumentFormattingEdits(document, options, token) {
        // -i 0 indents with tabs; -i N with N spaces.
        const indent = options.insertSpaces ? String(options.tabSize) : "0";
        const text = document.getText();
        const result = await omc.process.run("shfmt", ["-i", indent], { input: text, timeout: 1000 });
        if (token.isCancellationRequested) return undefined;
        if (result.code !== 0) {
          console.warn(result.stderr.trim()); // a syntax error: leave the file as it is
          return undefined;
        }
        if (result.stdout === text) return [];
        const last = document.lineAt(document.lineCount - 1);
        const whole = new omc.Range(0, 0, document.lineCount - 1, last.text.length);
        return [omc.TextEdit.replace(whole, result.stdout)];
      },
    }),
  );
}
```

- Used by *Format Document* (⇧⌥F) and format on save, before the language server's formatter.
- A provider has 1.5 seconds: a formatter that's slow to start may need a language server
  instead.
- Replacing the whole text is simplest; the edit is one undo step, and the editor keeps the
  cursor near where it was.

## A language with a TextMate grammar

**Goal:** `.ini` files with comments, sections and keys colored, and ⌘/ commenting — no code.

```json
{
  "id": "acme.ini",
  "name": "INI Files",
  "version": "1.0.0",
  "main": "extension.js",
  "contributes": {
    "languages": [{
      "id": "ini", "aliases": ["INI"], "extensions": [".ini", ".cfg"],
      "configuration": "./language-configuration.json"
    }],
    "grammars": [{ "language": "ini", "scopeName": "source.ini", "path": "./syntaxes/ini.tmLanguage.json" }]
  }
}
```

`extension.js` is an empty file: the extension has no code.

`language-configuration.json`:

```json
{
  "comments": { "lineComment": ";" },
  "brackets": [["[", "]"]],
  "autoClosingPairs": [{ "open": "[", "close": "]" }, { "open": "\"", "close": "\"", "notIn": ["string"] }]
}
```

`syntaxes/ini.tmLanguage.json`:

```json
{
  "scopeName": "source.ini",
  "patterns": [
    { "match": "^\\s*[;#].*$", "name": "comment.line.ini" },
    { "match": "^\\s*\\[([^\\]]*)\\]", "captures": { "1": { "name": "entity.name.section.ini" } } },
    {
      "match": "^\\s*([^=;#]+?)\\s*(=)\\s*(.*)$",
      "captures": {
        "1": { "name": "variable.other.key.ini" },
        "2": { "name": "keyword.operator.assignment.ini" },
        "3": { "name": "string.unquoted.value.ini" }
      }
    }
  ]
}
```

- Install it, open an `.ini` file, and check the colors with *Developer: Inspect Editor Tokens and
  Scopes*.
- VS Code's grammars work as they are: for a real language, copy one from a VS Code extension
  (or use *Extensions: Import VS Code Language Extension…*).
- [Language support](language-support.md) and [Syntax highlighting](syntax-highlighting.md) cover
  every field.

## A language server installed with npm

**Goal:** completion, hover, diagnostics and more for shell scripts from
[bash-language-server](https://github.com/bash-lsp/bash-language-server).

```json
{
  "id": "acme.bash-ls",
  "name": "Bash Language Server",
  "version": "1.0.0",
  "main": "extension.js",
  "permissions": ["process"],
  "contributes": {
    "languageServers": [{
      "id": "bash-language-server",
      "name": "Bash Language Server",
      "languages": ["shellscript"],
      "command": "bash-language-server",
      "args": ["start"]
    }]
  }
}
```

- The user installs the server once: `npm install -g bash-language-server`. The editor looks
  `bash-language-server` up on the login shell's `PATH`; *Settings ▸ Languages* says *Not found*
  until it's there.
- To ship the server with the extension instead, `npm install bash-language-server` in the
  extension's folder, keep that `node_modules` when you [package](publishing.md#what-to-ship), and
  point at it: `"command": "./node_modules/.bin/bash-language-server"`. (Users still need Node.js:
  the script starts with `#!/usr/bin/env node`.)
- No code is needed. `settings` (with `${config:…}` for the extension's own settings) and
  `rootPatterns` are in [Language servers](language-servers.md).

## A custom language server request

**Goal:** *Go to Parent Module* in Rust files, with rust-analyzer's `experimental/parentModule`
request.

```json
"contributes": {
  "commands": [{ "command": "acme.parentModule", "title": "Go to Parent Module", "category": "Rust" }]
}
```

```ts
import * as omc from "omc";

type Target = { uri: string; range: omc.Range } | { targetUri: string; targetSelectionRange: omc.Range };

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.commands.registerCommand("acme.parentModule", async () => {
      const editor = omc.window.activeTextEditor;
      if (!editor || editor.document.languageId !== "rust") return;
      const server = omc.languages.getLanguageServer("rust-analyzer");
      const answer = await server.sendRequest<Target | Target[] | null>("experimental/parentModule", {
        textDocument: { uri: editor.document.uri.toString() },
        position: { line: editor.selection.start.line, character: editor.selection.start.character },
      });
      const first = Array.isArray(answer) ? answer[0] : answer;
      if (!first) {
        await omc.window.showInformationMessage("This is the crate's root.");
        return;
      }
      const uri = "targetUri" in first ? first.targetUri : first.uri;
      const range = "targetUri" in first ? first.targetSelectionRange : first.range;
      const target = await omc.window.showTextDocument(omc.Uri.parse(uri).path);
      target?.select(new omc.Range(range.start.line, range.start.character, range.start.line, range.start.character));
    }),
  );
}
```

- `getLanguageServer` reaches built-in servers (`rust-analyzer`, `gopls`, `sourcekit-lsp`…) and
  any extension's. The request goes to the server of the active file.
- Params and results are the protocol's JSON: `file://` URIs, zero-based positions. Turn a URI
  into a path with `omc.Uri.parse(uri).path`.
- Before a Rust file has started the server, `sendRequest` rejects with *isn't running*.
- `onNotification` and `onRequest` handle messages from the server
  ([Language servers](language-servers.md#custom-requests-and-notifications)).

## Snippets

**Goal:** a `log` snippet in JavaScript and TypeScript files, without code.

```json
"main": "extension.js",
"contributes": {
  "snippets": [
    { "language": "javascript", "path": "./snippets/js.json" },
    { "language": "typescript", "path": "./snippets/js.json" }
  ]
}
```

`snippets/js.json`:

```json
{
  "Log a value": {
    "prefix": "log",
    "body": ["console.log(\"${1:value}:\", ${1:value});$0"],
    "description": "console.log with a label"
  }
}
```

- Type `log` and press Tab (or pick it from the completion list).
- The same `$1` twice is edited in both places at once.
- [Snippets](snippets.md) has the whole syntax and variables. In code, completion items use
  `SnippetString`.

## A quick fix

**Goal:** trailing whitespace shown as a hint, with a quick fix (⌘.) that removes it.

```json
"activationEvents": ["onStartup"]
```

```ts
import * as omc from "omc";

/** The ranges of trailing spaces and tabs in a document's text. */
function trailing(text: string): omc.Range[] {
  const ranges: omc.Range[] = [];
  text.split("\n").forEach((line, number) => {
    const match = /[ \t]+\r?$/.exec(line);
    if (match) ranges.push(new omc.Range(number, match.index, number, match.index + match[0].replace("\r", "").length));
  });
  return ranges;
}

export function activate(context: omc.ExtensionContext) {
  const collection = omc.languages.createDiagnosticCollection("trailing-space");
  const check = (document: omc.TextDocument) => collection.set(document, trailing(document.getText()).map((range) => ({
    range, message: "Trailing whitespace", severity: omc.DiagnosticSeverity.Hint,
  })));

  omc.workspace.textDocuments.forEach(check);
  context.subscriptions.push(
    collection,
    omc.workspace.onDidOpenTextDocument(check),
    omc.workspace.onDidChangeTextDocument((event) => check(event.document)),
    omc.workspace.onDidCloseTextDocument((document) => collection.delete(document)),
    omc.languages.registerCodeActionsProvider("*", {
      provideCodeActions(document, range) {
        const all = trailing(document.getText());
        const here = all.filter((r) => r.start.line >= range.start.line && r.start.line <= range.end.line);
        if (here.length === 0) return [];
        const fixHere = new omc.CodeAction("Remove trailing whitespace", omc.CodeActionKind.QuickFix);
        fixHere.edit = new omc.WorkspaceEdit();
        for (const r of here) fixHere.edit.delete(document.uri, r);
        fixHere.isPreferred = true;
        const fixAll = new omc.CodeAction("Remove all trailing whitespace in the file", omc.CodeActionKind.QuickFix);
        fixAll.edit = new omc.WorkspaceEdit();
        fixAll.edit.set(document.uri, all.map((r) => omc.TextEdit.delete(r)));
        return [fixHere, fixAll];
      },
    }, { providedCodeActionKinds: [omc.CodeActionKind.QuickFix] }),
  );
}
```

- The provider is asked for the selection or the cursor's line when the user presses ⌘., and
  when the cursor rests on a line with a problem (the lightbulb).
- `context.diagnostics` has the problems in the range, from every source; here the provider
  checks the text itself, which is simpler and always current.
- The `WorkspaceEdit` is applied as one undo step; `isPreferred` lists it first.
- `onDidChangeTextDocument` fires once edits settle, so checking on every change is cheap enough
  for a regular expression.

## Hover documentation from a JSON file

**Goal:** hovering over a function name in Toy files shows its documentation from a
`docs.json` shipped with the extension.

`src/docs.json`:

```json
{
  "print": "Prints its arguments, separated by spaces.\n\n```toy\nprint(\"a\", 1)\n```",
  "len": "The length of a string or a list."
}
```

```ts
import * as omc from "omc";
import docs from "./docs.json";

const entries = docs as Record<string, string>;

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.languages.registerHoverProvider("toy", {
      provideHover(document, position) {
        const range = document.getWordRangeAtPosition(position);
        const text = range && entries[document.getText(range)];
        return text ? new omc.Hover(new omc.MarkdownString(text), range) : undefined;
      },
    }),
  );
}
```

- Build with [esbuild](getting-started.md#building-with-esbuild): it puts the JSON into
  `dist/extension.js`. For `tsc --noEmit` to accept the import, add `"resolveJsonModule": true`
  and `"esModuleInterop": true` to `tsconfig.json`.
- Why not read the file at run time? `context.extensionPath` is outside the open folders, so
  `omc.workspace.fs.readFile` there needs the `fileSystem` permission — too much to ask for
  reading your own data.
- For data that belongs to the project (a team's glossary), read it from the workspace instead:
  `omc.workspace.fs.readFile(".toy/docs.json")`, cached and re-read on save.

## Ask, and remember the answer

**Goal:** *Insert License Header* asks for the license (offering the last one first) and the
author (remembered), and inserts the header at the top of the file.

```json
"contributes": {
  "commands": [{ "command": "acme.licenseHeader", "title": "Insert License Header", "category": "Acme" }]
}
```

```ts
import * as omc from "omc";

const LICENSES = ["MIT", "Apache-2.0", "GPL-3.0-or-later", "BSD-3-Clause"];

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.commands.registerCommand("acme.licenseHeader", async () => {
      const editor = omc.window.activeTextEditor;
      if (!editor) return;
      const last = context.storage.get<string>("license");
      const ordered = last ? [last, ...LICENSES.filter((l) => l !== last)] : LICENSES;
      const license = await omc.window.showQuickPick(ordered, { placeHolder: "License" });
      if (!license) return;
      const author = await omc.window.showInputBox({ prompt: "Copyright holder", value: context.storage.get<string>("author", "") });
      if (author === undefined) return;
      await context.storage.update("license", license);
      await context.storage.update("author", author);

      const header = `SPDX-License-Identifier: ${license}\nCopyright ${new Date().getFullYear()} ${author}`;
      const comment = editor.document.languageId === "python" || editor.document.languageId === "shellscript" ? "# " : "// ";
      const text = header.split("\n").map((line) => comment + line).join("\n") + "\n\n";
      await editor.edit((edit) => edit.insert(new omc.Position(0, 0), text));
    }),
  );
}
```

- `context.storage` keeps values across restarts, for every window. It's for small things — not
  for secrets ([why](runtime-and-security.md#secrets)).
- A setting (`contributes.configuration`) is the better home for a value users should see and
  change; storage is for what the extension remembers by itself.

## Call a web API

**Goal:** in a `package.json`, *Latest Version of This Package* looks up the dependency under
the cursor on the npm registry.

```json
"contributes": {
  "commands": [{ "command": "acme.npmLatest", "title": "Latest Version of This Package", "category": "npm" }]
},
"permissions": ["network"]
```

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.commands.registerCommand("acme.npmLatest", async () => {
      const editor = omc.window.activeTextEditor;
      if (!editor || editor.document.fileName !== "package.json") return;
      const line = editor.document.lineAt(editor.selection.start.line).text;
      const name = /^\s*"([^"]+)"\s*:\s*"[^"]*"/.exec(line)?.[1];
      if (!name) {
        await omc.window.showWarningMessage("Put the cursor on a dependency's line.");
        return;
      }
      try {
        const response = await omc.net.fetch(`https://registry.npmjs.org/${name.replace("/", "%2F")}/latest`);
        if (!response.ok) throw new Error(`the registry answered ${response.status}`);
        const info = await response.json<{ version: string }>();
        await omc.window.showInformationMessage(`${name}: ${info.version}`);
      } catch (error) {
        await omc.window.showErrorMessage(`Couldn't look up ${name}: ${(error as Error).message}`);
      }
    }),
  );
}
```

- `omc.net.fetch` (not the browser's `fetch`, which doesn't exist) needs `network`, which the
  install dialog shows.
- An HTTP error status doesn't reject: check `ok`. A network failure does.
- The body is read as text; JSON with `json()`. There's no streaming or binary data.

## See also

- [API reference](api-reference.md): every function used here.
- [Language feature providers](providers.md): more providers, with their examples.
- [Debugging and testing](debugging-and-testing.md): when a recipe doesn't work for you.
