# API reference

Everything an extension's code can use: the `omc` module, namespace by namespace, and the few
globals the runtime adds. The types are in `ExtensionAPI/omc.d.ts` (API version 0.3.0); this page
says what each part does when it runs.

```ts
import * as omc from "omc";
```

`omc` is the only module an extension can `require` (see
[Runtime and security](runtime-and-security.md#modules)).

- [Conventions](#conventions): positions, paths and URIs, several folders, snapshots, errors
- [Disposables and events](#disposables-and-events)
- [The extension's context](#the-extensions-context): `activate`, `deactivate`, `subscriptions`, `storage`
- [`commands`](#commands)
- [`window`](#window): the active editor, messages, quick pick, input box, status bar
- [`TextEditor`](#texteditor)
- [`workspace`](#workspace): folders, documents, settings, events, files
- [`TextDocument`](#textdocument)
- [`languages`](#languages): providers, [diagnostics](#diagnostics), [language servers](#language-servers)
- [`process`](#process), [`net`](#net)
- [Value types](#value-types): `Position`, `Range`, `Uri`, `Location`, edits, Markdown, snippets,
  cancellation, enums
- [Globals](#globals): `console`, timers

## Conventions

**Positions** are zero-based: line 0 is the first line, and `character` counts UTF-16 code units
from the start of the line — as JavaScript string indices do, and as the Language Server
Protocol does. An emoji is two characters; `"é"` is one or two depending on how it's encoded.

**Paths** are strings. Absolute paths are used as they are; relative paths are relative to the
window's first folder (`omc.workspace.rootPath`). Everything inside any of the window's folders
is open to every extension; anything outside needs the `fileSystem` permission (and changing
anything inside a `.git` folder needs it too). Links are followed when deciding what's inside.

**URIs** appear where VS Code's API has them (`Location`, `WorkspaceEdit`, `DocumentLink`). Only
`file://` URIs exist. Wherever a URI is taken, a `UriLike` works: a `"file:///…"` string, a path,
a document's `uri`, an `omc.Uri`, or any `{ path }`.

**Several folders.** A window can have several folders (a multi-root workspace).
`workspace.folders` lists them, `workspace.getWorkspaceFolder(path)` says which one a file is in,
and `workspace.onDidChangeWorkspaceFolders` reports folders added and removed. `rootPath` and
relative paths use the first folder.

**Snapshots.** A `TextDocument` or `TextEditor` you're given describes the document or editor when
it was made: `isDirty`, `lineCount`, `version`, `selection` don't change afterwards. Ask again
(`window.activeTextEditor`, `workspace.textDocuments`) for fresh ones. `getText()` and `lineAt()`
are different: they read the document as it is now.

**Calls into the app.** Functions that return a value directly (`activeTextEditor`, `getText`,
`getConfiguration().get`, `createStatusBarItem`…) wait for the editor's main thread, briefly. The
ones that return a promise (dialogs, edits, files, processes, requests) don't block: the extension
keeps running and the promise settles later. A failed call throws, or rejects its promise, with an
`Error` whose message says why: *dist/notes.md is outside the open folder.*

**JSON.** Whatever crosses into the app — command arguments and results between extensions,
settings, stored values, language server messages — is copied as JSON: functions and class
instances arrive as plain data.

## Disposables and events

### Disposable

```typescript
class Disposable {
  constructor(callOnDispose: () => void);
  dispose(): void;
  static from(...disposables: { dispose(): unknown }[]): Disposable;
}
```

Every registration returns one. `dispose()` undoes it (once; later calls do nothing).
`Disposable.from(a, b)` disposes several together.

### Event and EventEmitter

```typescript
type Event<T> = (listener: (e: T) => unknown, thisArg?: unknown, disposables?: Disposable[]) => Disposable;

class EventEmitter<T> {
  readonly event: Event<T>;
  fire(data: T): void;
  dispose(): void;
}
```

An `Event` is a function you call with a listener; it returns the `Disposable` that stops
listening. Pass an array as the third argument to have the disposable pushed into it.

```ts
const listener = omc.workspace.onDidSaveTextDocument((document) => {
  console.log("Saved", document.fileName);
});
context.subscriptions.push(listener);
```

`EventEmitter` makes events of your own. `fire` calls the listeners in the order they were added;
one that throws is logged and the others still run. `dispose` drops every listener.

```ts
const emitter = new omc.EventEmitter<number>();
const onDidCount: omc.Event<number> = emitter.event;
context.subscriptions.push(onDidCount((n) => console.log("counted", n)), emitter);
emitter.fire(42);
```

## The extension's context

The main file is a CommonJS module. The editor calls its exported functions:

```typescript
export function activate(context: ExtensionContext): void | Promise<void>;
export function deactivate(): void | Promise<void>;   // optional
```

- **`activate`** runs once, when the extension starts ([activation events](manifest.md#activationevents)).
  It may be `async`: the extension counts as started when the promise resolves. It has 10 seconds;
  if it throws, rejects or takes longer, the extension is marked *Failed* with the reason in its
  log, and whatever it had registered is removed. Running one of its commands later tries again.
- **`deactivate`** runs when the extension stops: the window closes, the extension is disabled,
  uninstalled or updated, or the extensions are reloaded. It has 3 seconds. Then
  `context.subscriptions` are disposed and timers cleared.

```typescript
interface ExtensionContext {
  readonly extensionId: string;     // "acme.date-tools"
  readonly extensionPath: string;   // its folder, absolute
  readonly subscriptions: { dispose(): unknown }[];
  readonly storage: {
    get<T>(key: string, defaultValue?: T): T | undefined;
    update(key: string, value: unknown): Promise<void>;
  };
}
```

- **`subscriptions`**: push every disposable here. They're disposed when the extension stops, in
  order; one that throws is logged and the rest still go. (The editor removes the extension's
  commands, providers, status bar items, diagnostics and servers when it stops anyway; disposing
  is how your own clean-up — an `EventEmitter`, a cache — runs.)
- **`storage`**: values kept across restarts, as JSON. `get` returns the stored value or
  `defaultValue`; `update(key, undefined)` removes it. Stored values belong to the extension, not
  to a folder: every window and folder sees the same ones. They're kept when the extension is
  updated and removed when it's uninstalled. Writes are saved at once (the promise is already
  resolved). Keep them small — they live in the app's preferences — and don't put secrets in them
  ([why](runtime-and-security.md#secrets)).
- **`extensionPath`**: where the extension is installed (for one installed for development, the
  link to your folder). Reading files there with `omc.workspace.fs` counts as outside the open
  folders and needs `fileSystem`; bundle the data into the main file instead
  ([cookbook](cookbook.md#hover-documentation-from-a-json-file)).

```ts
import * as omc from "omc";

export async function activate(context: omc.ExtensionContext) {
  const runs = context.storage.get<number>("runs", 0)! + 1;
  await context.storage.update("runs", runs);
  console.log(`${context.extensionId} started ${runs} times, from ${context.extensionPath}`);
}
```

## commands

```typescript
namespace commands {
  function registerCommand(command: string, callback: (...args: any[]) => unknown, thisArg?: unknown): Disposable;
  function executeCommand<T = unknown>(command: string, ...args: unknown[]): Promise<T>;
  function getCommands(): Promise<string[]>;
}
```

### registerCommand

Gives a command id its code. The callback gets the arguments the command was run with (none from
the palette, a shortcut or the status bar; a code lens's or completion item's `arguments`; whatever
`executeCommand` passed) and may return a value or a promise. An error it throws (or a promise it
rejects) is shown in an alert when the user ran the command, and rejects `executeCommand` when
code ran it.

Registering an id the extension already registered throws *The command … is already registered*.
List the id under [`contributes.commands`](manifest.md#commands) to put it in the palette.

```ts
context.subscriptions.push(
  omc.commands.registerCommand("dateTools.daysUntil", (isoDate: string) => {
    const days = Math.ceil((Date.parse(isoDate) - Date.now()) / 86_400_000);
    return days;
  }),
);
```

### executeCommand

Runs a command and resolves with its result:

- **The extension's own** command: called directly, with the arguments as they are.
- **Another extension's**: that extension is started if needed; arguments and result are copied
  as JSON.
- **A built-in command** — any id in the palette's list, such as `edit.format` (Format Document),
  `file.save`, `view.toggleTerminal`, `editor.changeLanguageMode`: it's started, arguments are
  ignored, and the promise resolves with `undefined` at once (not when the command's work is done).

An unknown id rejects with *There's no command “…”.*

```ts
const days = await omc.commands.executeCommand<number>("dateTools.daysUntil", "2027-01-01");
await omc.commands.executeCommand("file.save");
```

### getCommands

Every command id: the built-in ones, and the commands of enabled extensions (contributed, and
registered by running ones), sorted.

## window

```typescript
namespace window {
  const activeTextEditor: TextEditor | undefined;
  const onDidChangeActiveTextEditor: Event<TextEditor | undefined>;
  function showInformationMessage(message: string, ...items: string[]): Promise<string | undefined>;
  function showWarningMessage(message: string, ...items: string[]): Promise<string | undefined>;
  function showErrorMessage(message: string, ...items: string[]): Promise<string | undefined>;
  function showInputBox(options?: { prompt?: string; value?: string; placeHolder?: string }): Promise<string | undefined>;
  function showQuickPick<T extends string | QuickPickItem>(items: T[] | Promise<T[]>, options?: { placeHolder?: string }): Promise<T | undefined>;
  function showTextDocument(document: TextDocument | string): Promise<TextEditor | undefined>;
  function createStatusBarItem(alignment?: StatusBarAlignment, priority?: number): StatusBarItem;
}
```

### activeTextEditor, onDidChangeActiveTextEditor

`activeTextEditor` is the editor of the window's active tab — a fresh [`TextEditor`](#texteditor)
each time you read it — or `undefined` when no file is open (or the active tab isn't a text file).
`onDidChangeActiveTextEditor` fires when another tab becomes active (with its editor, or
`undefined`); several changes at once arrive as one.

### Messages

`showInformationMessage`, `showWarningMessage` and `showErrorMessage` show a notification in the
window's bottom-right corner, with an icon for its kind and the extension's name under the
message. With `items`, they're buttons, and the notification stays until one is clicked (the
promise resolves with its text) or it's closed (`undefined`). Without items it goes away after 8
seconds and resolves with `undefined`. At most four are shown; a fifth closes the oldest.

```ts
const answer = await omc.window.showWarningMessage("The build is out of date.", "Rebuild", "Ignore");
if (answer === "Rebuild") await omc.commands.executeCommand("dateTools.rebuild");
```

### showInputBox

Asks for a line of text in the palette: `prompt` above it, `value` already typed, `placeHolder`
when it's empty. Resolves with the text when Return is pressed, `undefined` on Escape. (There's no
validation callback or password mode.)

```ts
const name = await omc.window.showInputBox({ prompt: "Name of the new component", placeHolder: "Button" });
if (name) console.log("Creating", name);
```

### showQuickPick

Lets the user pick one item in the palette, which filters as they type. Items are strings or
`{ label, description?, detail? }`; `items` may be a promise. Resolves with the item picked (the
same object you passed) or `undefined`. One item only (no `canPickMany`).

```ts
const picked = await omc.window.showQuickPick(
  [{ label: "main", description: "default branch" }, { label: "develop" }],
  { placeHolder: "Branch to compare with" },
);
if (picked) console.log(picked.label);
```

### showTextDocument

Opens a file in a tab and makes it active: a [`TextDocument`](#textdocument), or a path (relative
to the first folder, or absolute; outside the folders needs `fileSystem`). Resolves with the
active editor.

```ts
const editor = await omc.window.showTextDocument("README.md");
editor?.select(new omc.Range(0, 0, 0, 0));
```

### createStatusBarItem

```typescript
enum StatusBarAlignment { Left = 1, Right = 2 }

interface StatusBarItem {
  text: string;        // "$(symbol)" shows an SF Symbol: "$(clock) 3 min"
  tooltip?: string;    // the text by default
  command?: string;    // a command id run on click
  show(): void;
  hide(): void;
  dispose(): void;
}
```

Makes an item for the status bar, hidden until `show()`. `alignment` puts it on the left or right
side (right by default); on each side, items with a higher `priority` come first. Changing `text`,
`tooltip` or `command` while it's shown updates it. `$(name)` anywhere in the text is the SF
Symbol `name` (`$(checkmark.circle)`, `$(exclamationmark.triangle)`); VS Code's codicon names
aren't SF Symbols, so check them in Apple's SF Symbols app. `dispose()` removes it for good.

```ts
const item = omc.window.createStatusBarItem(omc.StatusBarAlignment.Left, 10);
item.text = "$(hammer) Build";
item.tooltip = "Run the build";
item.command = "dateTools.rebuild";
item.show();
context.subscriptions.push(item);
```

## TextEditor

```typescript
interface TextEditor {
  readonly document: TextDocument;
  readonly selection: Range;      // the first selection
  readonly selections: Range[];   // every selection or cursor
  edit(callback: (edit: TextEditorEdit) => void): Promise<boolean>;
  edit(edits: { range: Range; text: string }[]): Promise<boolean>;
  select(range: Range | Range[]): void;
}

interface TextEditorEdit {
  replace(range: Range, text: string): void;
  insert(position: Position, text: string): void;
  delete(range: Range): void;
}
```

A snapshot of an editor (see [Conventions](#conventions)).

- **`edit`** makes changes as one undoable step, named after the extension in *Edit ▸ Undo*. Build
  them in the callback (which runs at once) or pass a list. Ranges are in the document as it was
  when you made the edits; they mustn't overlap (*The edits overlap.*). Resolves `true` when the
  text changed, `false` when the edits changed nothing. The document must be open; editing a file
  inside `.git` needs `fileSystem`.
- **`select`** sets the selections (the first range scrolled into view). An empty range is a
  cursor.

```ts
const editor = omc.window.activeTextEditor;
if (editor) {
  const upper = editor.selections.map((range) => ({ range, text: editor.document.getText(range).toUpperCase() }));
  await editor.edit(upper);
}
```

## workspace

```typescript
namespace workspace {
  const rootPath: string | undefined;
  const folders: WorkspaceFolder[];
  function getWorkspaceFolder(path: string): WorkspaceFolder | undefined;
  const textDocuments: TextDocument[];
  function openTextDocument(path: string): Promise<TextDocument>;
  function getConfiguration(section?: string): Configuration;
  const onDidOpenTextDocument: Event<TextDocument>;
  const onDidCloseTextDocument: Event<TextDocument>;
  const onDidSaveTextDocument: Event<TextDocument>;
  const onDidChangeTextDocument: Event<{ document: TextDocument }>;
  const onDidChangeConfiguration: Event<{ affectsConfiguration(section: string): boolean }>;
  const onDidChangeWorkspaceFolders: Event<{ added: WorkspaceFolder[]; removed: WorkspaceFolder[] }>;
  namespace fs { /* below */ }
}

interface WorkspaceFolder {
  readonly path: string;    // absolute
  readonly name: string;    // its label in the Explorer
  readonly index: number;   // its place in `folders`
}
```

### Folders

- **`rootPath`**: the first folder's path.
- **`folders`**: every folder of the window, in order.
- **`getWorkspaceFolder(path)`**: the folder a file or folder is in — the innermost, when folders
  nest — or `undefined`. A relative path is taken from the first folder.
- **`onDidChangeWorkspaceFolders`**: folders added to or removed from the window.

```ts
for (const folder of omc.workspace.folders) {
  const hasPackage = await omc.workspace.fs.exists(folder.path + "/package.json");
  console.log(folder.name, hasPackage ? "is a Node project" : "");
}
```

### Documents

- **`textDocuments`**: every document open in the window (one per tab's file).
- **`openTextDocument(path)`**: the document of a file — opened in a tab behind the active one if
  it isn't open yet (the active tab stays). Resolves with its `TextDocument`.
- **`onDidOpenTextDocument`**, **`onDidCloseTextDocument`**: a file was opened or closed in the
  window. *Change Language Mode* closes and reopens a document, so listeners see its new
  `languageId`. Documents already open when the extension starts don't fire: read `textDocuments`
  in `activate`.
- **`onDidSaveTextDocument`**: a document was saved.
- **`onDidChangeTextDocument`**: a document's text changed — once edits settle (about 150 ms after
  the last one), not on every keystroke. It carries the document, not the changes.

```ts
const check = (document: omc.TextDocument) => {
  if (document.languageId === "markdown") console.log(document.fileName, document.lineCount, "lines");
};
omc.workspace.textDocuments.forEach(check);
context.subscriptions.push(
  omc.workspace.onDidOpenTextDocument(check),
  omc.workspace.onDidChangeTextDocument((event) => check(event.document)),
);
```

### Settings

```typescript
interface Configuration {
  get<T>(key: string, defaultValue?: T): T | undefined;
  update(key: string, value: unknown): Promise<void>;
}
```

`getConfiguration(section)` reads the extension's own settings ([`contributes.configuration`](manifest.md#configuration));
`section` is put before keys with a dot, so `getConfiguration("dateTools").get("format")` and
`getConfiguration().get("dateTools.format")` are the same. `get` returns the user's value, else
the manifest's `default`, else `defaultValue`. `update` sets the user's value (`undefined` removes
it) for every window. An extension can only read and write its own settings, not the editor's or
other extensions'.

`onDidChangeConfiguration` fires when one of the extension's settings changes (in the sidebar or
through `update`); `affectsConfiguration("dateTools")` or `("dateTools.format")` is true for
`dateTools.format`.

```ts
const config = omc.workspace.getConfiguration("dateTools");
if (config.get<boolean>("weekStartsOnMonday", true)) console.log("Monday first");
context.subscriptions.push(omc.workspace.onDidChangeConfiguration((event) => {
  if (event.affectsConfiguration("dateTools.format")) console.log("now", config.get("format"));
}));
```

### workspace.fs

```typescript
namespace fs {
  function readFile(path: string): Promise<string>;
  function writeFile(path: string, text: string): Promise<void>;
  function readDirectory(path: string): Promise<{ name: string; isDirectory: boolean }[]>;
  function exists(path: string): Promise<boolean>;
}
```

Files as text, read and written off the main thread. Paths are [as everywhere](#conventions):
inside the window's folders, or anywhere with `fileSystem`.

- **`readFile`**: the file's text, as UTF-8 (a file that isn't valid UTF-8 rejects). It reads the
  file on disk, not unsaved changes in an open tab: use the document's `getText()` for those.
- **`writeFile`**: replaces the file (or creates it; its folder must exist) atomically, on disk.
  To change a file that's open, prefer `TextEditor.edit`, which the user can undo. Writing inside
  `.git` needs `fileSystem`.
- **`readDirectory`**: the entries of a folder, hidden ones included, sorted by name.
- **`exists`**: whether a file or folder is there.

There's no delete, rename or create-folder: run a program for those (`process` permission).

```ts
const root = omc.workspace.rootPath;
if (root) {
  const entries = await omc.workspace.fs.readDirectory(root);
  const notes = entries.filter((e) => !e.isDirectory && e.name.endsWith(".md")).map((e) => e.name);
  await omc.workspace.fs.writeFile("NOTES-INDEX.md", notes.map((n) => `- [${n}](${n})`).join("\n") + "\n");
}
```

## TextDocument

```typescript
interface TextDocument {
  readonly path: string;         // absolute
  readonly fileName: string;     // the last part of the path
  readonly languageId: string;   // "typescript", "toy"
  readonly isDirty: boolean;
  readonly lineCount: number;
  readonly version: number;      // goes up with every edit
  readonly uri: Uri;
  getText(range?: Range): string;
  lineAt(line: number | Position): { lineNumber: number; text: string };
  getWordRangeAtPosition(position: Position, regex?: RegExp): Range | undefined;
  save(): Promise<boolean>;
}
```

- **`getText(range?)`**: the whole text or a range of it, as it is now (unsaved changes included).
- **`lineAt(line)`**: a line's text, without its line break. A line out of range throws.
- **`getWordRangeAtPosition(position, regex?)`**: the word the position is in or touches: by
  default a run of letters, digits, `_` and `$`; with `regex`, a match of it on the line.
- **`save()`**: saves the document; resolves `true` when it was saved.
- **`version`** increases with each edit: use it to cache work per version.

These read the document in the window: it must be open (`openTextDocument` first, else *… isn't
open: open it with omc.workspace.openTextDocument first.*).

```ts
const document = await omc.workspace.openTextDocument("package.json");
const name = /"name":\s*"([^"]+)"/.exec(document.getText())?.[1];
console.log(document.languageId, name, document.lineAt(0).text);
```

## languages

### Providers

Every language feature the editor has can be provided in code. Each `register…` function takes a
[document selector](providers.md#registering) (a language id, `"*"`, `{ language, scheme,
pattern }`, or a list) and a provider object, and returns a `Disposable`:

| Function | Feature |
| --- | --- |
| `registerCompletionItemProvider(selector, provider, ...triggerCharacters)` | [Completion](providers.md#completion) |
| `registerHoverProvider` | [Hover](providers.md#hover) |
| `registerSignatureHelpProvider(selector, provider, ...triggerCharacters)` or `(selector, provider, { triggerCharacters, retriggerCharacters })` | [Signature help](providers.md#signature-help) |
| `registerDefinitionProvider`, `registerTypeDefinitionProvider`, `registerImplementationProvider` | [Go to Definition and the others](providers.md#definitions-type-definitions-implementations) |
| `registerReferenceProvider` | [Find All References](providers.md#references) |
| `registerDocumentSymbolProvider` | [Outline, breadcrumbs](providers.md#document-symbols) |
| `registerWorkspaceSymbolProvider(provider)` (no selector) | [Go to Symbol in Workspace](providers.md#workspace-symbols) |
| `registerCodeActionsProvider(selector, provider, { providedCodeActionKinds }?)` | [Quick fixes, refactorings](providers.md#code-actions) |
| `registerCodeLensProvider` | [Code lenses](providers.md#code-lenses) |
| `registerRenameProvider` | [Rename](providers.md#rename) |
| `registerDocumentHighlightProvider` | [Symbol highlights](providers.md#document-highlights) |
| `registerDocumentLinkProvider` | [Links](providers.md#document-links) |
| `registerFoldingRangeProvider` | [Folding](providers.md#folding-ranges) |
| `registerInlayHintsProvider` | [Inlay hints](providers.md#inlay-hints) |
| `registerDocumentSemanticTokensProvider(selector, provider, legend)` | [Semantic colors](providers.md#semantic-tokens) |
| `registerDocumentFormattingEditProvider`, `registerDocumentRangeFormattingEditProvider`, `registerOnTypeFormattingEditProvider(selector, provider, firstTrigger, ...more)` | [Formatting](providers.md#formatting) |

Every provider method gets a [`CancellationToken`](#cancellation) and has **1.5 seconds** to answer;
its answer is merged with the language server's. [Language feature providers](providers.md) covers
each one, with examples.

### Diagnostics

```typescript
function createDiagnosticCollection(name?: string): DiagnosticCollection;

interface DiagnosticCollection {
  readonly name: string;
  set(document: TextDocument | string, diagnostics: Diagnostic[]): void;
  delete(document: TextDocument | string): void;
  clear(): void;
  dispose(): void;
}

interface Diagnostic {
  range: Range;
  message: string;
  severity?: DiagnosticSeverity;   // Error (the default), Warning, Information, Hint
  source?: string;                 // shown with the message; the collection's name by default
  code?: string | number;
}
```

A collection holds problems by file. `set` replaces the file's problems from this collection (a
document, or a path); `delete` removes them; `clear` removes all of them. They're shown like a
language server's — underlined in the editor and listed in the Problems panel — beside the
server's, for files whether they're open or not. They're removed when the extension stops.
`code` is accepted but not shown.

```ts
const collection = omc.languages.createDiagnosticCollection("todo-check");
context.subscriptions.push(collection);
const editor = omc.window.activeTextEditor;
if (editor) {
  const problems: omc.Diagnostic[] = [];
  for (let line = 0; line < editor.document.lineCount; line++) {
    const at = editor.document.lineAt(line).text.indexOf("FIXME");
    if (at >= 0) problems.push({ range: new omc.Range(line, at, line, at + 5), message: "Fix me", severity: omc.DiagnosticSeverity.Warning });
  }
  collection.set(editor.document, problems);
}
```

### Language servers

```typescript
function registerLanguageServer(definition: LanguageServerDefinition): Disposable;
function getLanguageServer(id: string): LanguageServer;

interface LanguageServer {
  readonly id: string;
  sendRequest<R = unknown>(method: string, params?: unknown): Promise<R>;
  sendNotification(method: string, params?: unknown): void;
  onNotification(method: string, handler: (params: any) => void): Disposable;
  onRequest(method: string, handler: (params: any) => unknown): Disposable;
}
```

- **`registerLanguageServer`** starts a server for its languages, as
  [`contributes.languageServers`](language-servers.md#declaring-a-server) does, with a command line
  worked out in code. Needs `process`. Disposing it stops the server.
- **`getLanguageServer(id)`** talks to a running server — declared or registered by any extension,
  or built in (`rust-analyzer`, `gopls`…) — in its own protocol. `sendRequest` rejects with *The
  language server “…” isn't running: open a file it handles first.* until a file of its languages
  is open.

See [Language servers](language-servers.md#custom-requests-and-notifications).

### Languages of documents

```typescript
function getLanguages(): Promise<string[]>;
function setTextDocumentLanguage(document: TextDocument, languageId: string): Promise<TextDocument>;
```

`getLanguages` lists every language id the editor knows, built in and contributed.
`setTextDocumentLanguage` puts an open document in another language, as *Change Language Mode*
does (for as long as the window is open), and resolves with the document as it is then.

```ts
const editor = omc.window.activeTextEditor;
if (editor && editor.document.fileName.endsWith(".tpl") && (await omc.languages.getLanguages()).includes("html")) {
  await omc.languages.setTextDocumentLanguage(editor.document, "html");
}
```

## process

```typescript
namespace process {
  function run(command: string, args?: string[], options?: { cwd?: string; input?: string; timeout?: number }):
    Promise<{ code: number; stdout: string; stderr: string }>;
}
```

Needs the `process` permission. Runs a program and resolves when it exits, with its exit code and
everything it wrote (as UTF-8 text).

- `command` is a program name, found on the login shell's `PATH` (as in Terminal, so Homebrew's
  and version managers' programs are found), or a path. It's run directly, not through a shell:
  arguments aren't split or expanded. For pipes or globs, run `"/bin/sh", ["-c", "…"]`.
- `cwd`: where it runs (a path as everywhere; outside the folders needs `fileSystem`). Default:
  the first folder.
- `input`: written to its standard input, which is then closed. Without it, standard input is
  empty.
- `timeout`: in milliseconds, default 60,000. A program still running then is killed and the
  promise rejects with *The program didn't finish within 60 seconds and was stopped.*
- A non-zero exit code doesn't reject: check `code`. A program that can't be started (not found)
  resolves with code 127 and the reason in `stderr`.

```ts
const result = await omc.process.run("git", ["log", "-1", "--format=%an: %s"], { timeout: 5000 });
if (result.code === 0) await omc.window.showInformationMessage(result.stdout.trim());
else console.error(result.stderr);
```

## net

```typescript
namespace net {
  function fetch(url: string, options?: { method?: string; headers?: Record<string, string>; body?: string }): Promise<{
    status: number; ok: boolean; headers: Record<string, string>; text(): Promise<string>; json<T = unknown>(): Promise<T>;
  }>;
}
```

Needs the `network` permission. An HTTP or HTTPS request (other schemes reject). `method`
defaults to `GET`; `body` is text. Redirects are followed. The response's `headers` have
lowercase names; `ok` is true for status 200–299; the body is read whole, as UTF-8 text (binary
bodies aren't supported). A network failure rejects; an HTTP error status doesn't.

```ts
const response = await omc.net.fetch("https://api.github.com/repos/zerovoid99/ohmycode/releases/latest", {
  headers: { Accept: "application/vnd.github+json" },
});
if (response.ok) {
  const release = await response.json<{ tag_name: string }>();
  console.log("Latest release:", release.tag_name);
}
```

## Value types

### Position and Range

```typescript
class Position { constructor(line: number, character: number); readonly line: number; readonly character: number; }
class Range {
  constructor(start: Position, end: Position);
  constructor(startLine: number, startCharacter: number, endLine: number, endCharacter: number);
  readonly start: Position; readonly end: Position; readonly isEmpty: boolean;
}
```

Zero-based, UTF-16 ([Conventions](#conventions)). `end` is exclusive. Unlike VS Code's, they have
no methods (`translate`, `contains`…): compare `line` and `character` yourself.

### Uri

```typescript
interface Uri { readonly scheme: string; readonly path: string; readonly fsPath: string; toString(): string; }
namespace Uri { function file(path: string): Uri; function parse(value: string): Uri; }
```

`Uri.file("/a/b c.txt").toString()` is `"file:///a/b%20c.txt"`. `Uri.parse("file:///a/b%20c.txt")`
gives `path` `"/a/b c.txt"`. Only file URIs are meaningful: `scheme` is always `"file"`.

### Location and LocationLink

`new Location(uri, rangeOrPosition)` — a place in a file, for definitions, references and symbols.
`LocationLink` (`{ originSelectionRange?, targetUri, targetRange, targetSelectionRange? }`) works
wherever locations do.

### TextEdit and WorkspaceEdit

`TextEdit.replace(range, text)`, `TextEdit.insert(position, text)`, `TextEdit.delete(range)` — for
formatting providers and completion items' `additionalTextEdits`. A `WorkspaceEdit` collects edits
to one or more files (`replace`, `insert`, `delete`, `set(uri, edits)`, `get`, `has`, `entries`,
`size`), for code actions and rename. An extension applies edits to the active editor with
[`TextEditor.edit`](#texteditor); a `WorkspaceEdit` is applied by the editor when a code action or
rename returns it.

### MarkdownString and SnippetString

`MarkdownString` (`appendText` escapes, `appendMarkdown`, `appendCodeblock(code, language)`) for
hovers, documentation and tooltips; a plain string is Markdown too. `SnippetString`
(`appendText`, `appendTabstop`, `appendPlaceholder`, `appendChoice`, `appendVariable`) for
completion items — see [Snippets](snippets.md#snippets-from-code).

### Command

`{ title, command, tooltip?, arguments? }`: a command to run from a code lens, a code action or
a completion item. `arguments` are copied as JSON.

### Cancellation

```typescript
interface CancellationToken { readonly isCancellationRequested: boolean; readonly onCancellationRequested: Event<void>; }
class CancellationTokenSource { readonly token: CancellationToken; cancel(): void; dispose(): void; }
class CancellationError extends Error {}
```

Providers get a token that's cancelled when the editor stops waiting (the user typed on, or 1.5
seconds passed). Check `isCancellationRequested` in long loops, or listen with
`onCancellationRequested` (a listener added after cancellation is called at once). A
`CancellationTokenSource` makes tokens for your own work; `CancellationError` is what to throw to
say you stopped because of one (a cancelled provider's errors aren't logged).

```ts
const source = new omc.CancellationTokenSource();
setTimeout(() => source.cancel(), 1000);
const token = source.token;
let found = 0;
for (let i = 0; i < 1e6 && !token.isCancellationRequested; i++) found += i % 7 === 0 ? 1 : 0;
console.log(found);
```

### Enums

`omc.DiagnosticSeverity`, `CompletionItemKind`, `SymbolKind`, `DocumentHighlightKind`,
`FoldingRangeKind`, `InlayHintKind`, `SignatureHelpTriggerKind`, `StatusBarAlignment` and the
`CodeActionKind` constants have VS Code's names and numbers.

### Provider classes

`Hover`, `CompletionItem`, `CompletionList`, `CodeAction`, `CodeLens`, `ParameterInformation`,
`SignatureInformation`, `SignatureHelp`, `DocumentSymbol`, `SymbolInformation`,
`DocumentHighlight`, `DocumentLink`, `FoldingRange`, `InlayHint`, `SemanticTokensLegend`,
`SemanticTokens`, `SemanticTokensBuilder`: see [Language feature providers](providers.md) and
`omc.d.ts`.

## Globals

The runtime is JavaScriptCore, not Node or a browser ([what's there](runtime-and-security.md#whats-available)).
Besides the language's own globals (`Promise`, `Map`, `JSON`, `Intl`…), extensions get:

| Global | Notes |
| --- | --- |
| `console.log`, `console.info`, `console.debug` | A line in the extension's log. Arguments are joined with spaces; objects are written as JSON, errors with their stack. |
| `console.warn` | A warning line (orange). |
| `console.error` | An error line (red). |
| `setTimeout(callback, ms, ...args)`, `clearTimeout(id)` | Run once, on the extension's queue. |
| `setInterval(callback, ms, ...args)`, `clearInterval(id)` | Repeated (at least 1 ms apart). |

Timers are cleared when the extension stops. An error thrown in a timer callback is logged.

```ts
const timer = setInterval(() => console.log("still here"), 60_000);
context.subscriptions.push({ dispose: () => clearInterval(timer) });
```

## See also

- [Language feature providers](providers.md): every provider in detail.
- [The manifest](manifest.md): commands, settings and permissions the API relies on.
- [Runtime and security](runtime-and-security.md): limits and permissions.
- [Cookbook](cookbook.md): the API put to work.
