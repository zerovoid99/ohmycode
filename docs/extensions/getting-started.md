# Getting started

This tutorial builds a small extension from nothing: a command in the palette, a keyboard
shortcut for it, a setting, a status bar item and a notification. Along the way it shows how to
build, reload, read the log and, at the end, install the finished extension for good.

It takes about fifteen minutes. You need Oh My Code and Node.js (with npm).

## 1. Create the extension

1. Open any folder in Oh My Code (extensions run in windows with a folder).
2. Open the palette (⇧⌘P) and run **Extensions: New Extension…** — or click the puzzle piece in
   the activity bar to show the Extensions sidebar, then **+** ▸ *New Extension…*.
3. Type a name, `Date Tools`, and press Return.
4. Choose where its folder goes and click **Create Here**.

The editor writes a `date-tools` folder there, installs it *for development* (the Extensions
sidebar shows it with a **DEV** badge) and opens the folder in a new window.

The extension already works: open the palette in the new window and run **Date Tools: Hello
World**. A notification says “Hello from Date Tools!”.

> *Extensions: New Language Support Extension…* does the same from a working toy language
> (grammar, snippets, completion, hover, definitions and the Outline): see
> [Examples](examples.md#toy-language).

## 2. What's in the folder

```
date-tools/
├── extension.json     the manifest: id, commands, settings, permissions…
├── src/extension.ts   the code
├── dist/extension.js  the code, compiled (what the editor runs)
├── omc.d.ts           the API's types
├── tsconfig.json      compiles src/ to dist/
├── package.json       npm run build / npm run watch
├── README.md
└── .gitignore
```

`extension.json`:

```json
{
  "activationEvents": [],
  "contributes": {
    "commands": [{ "category": "Date Tools", "command": "dateTools.helloWorld", "title": "Hello World" }]
  },
  "description": "",
  "id": "local.date-tools",
  "main": "dist/extension.js",
  "name": "Date Tools",
  "permissions": [],
  "version": "0.0.1"
}
```

- `id` is `publisher.name`. `local` is a placeholder: change it to your name or organization
  before you share the extension (see [Publishing](publishing.md#the-id)).
- `main` is the compiled JavaScript the editor loads.
- Commands under `contributes.commands` are listed in the palette as *Category: Title*, and
  running one starts the extension if it isn't running yet. That's why `activationEvents` can
  stay empty.

`src/extension.ts`:

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.commands.registerCommand("dateTools.helloWorld", async () => {
      await omc.window.showInformationMessage("Hello from " + "Date Tools" + "!");
    }),
  );
}

export function deactivate() {}
```

`activate` runs when the extension starts. Everything it creates that should go away when the
extension stops — commands, listeners, status bar items, providers — goes into
`context.subscriptions`. `deactivate` is optional.

## 3. Build it

In the extension's folder (the new window has a terminal: ⌃\`):

```sh
npm install
npm run build        # or: npm run watch, to rebuild on every save
```

`npm run build` runs `tsc -p .`, which type-checks `src/extension.ts` against `omc.d.ts` and
writes `dist/extension.js`. The editor doesn't build anything itself: it runs whatever
`dist/extension.js` is.

## 4. A first command of your own

Replace `src/extension.ts`:

```ts
import * as omc from "omc";

/** Today's date, as the "dateTools.format" setting says. */
function today(): string {
  const format = omc.workspace.getConfiguration("dateTools").get<string>("format", "iso");
  const now = new Date();
  return format === "local" ? now.toLocaleDateString() : now.toISOString().slice(0, 10);
}

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.commands.registerCommand("dateTools.insertDate", async () => {
      const editor = omc.window.activeTextEditor;
      if (!editor) {
        await omc.window.showWarningMessage("Open a file to insert the date into.");
        return;
      }
      const text = today();
      await editor.edit((edit) => {
        for (const selection of editor.selections) edit.replace(selection, text);
      });
    }),
  );
}
```

and list the command in `extension.json`, with a shortcut and a setting:

```json
{
  "id": "local.date-tools",
  "name": "Date Tools",
  "version": "0.0.1",
  "description": "Inserts today's date.",
  "main": "dist/extension.js",
  "activationEvents": [],
  "contributes": {
    "commands": [
      { "command": "dateTools.insertDate", "title": "Insert Date", "category": "Date Tools", "icon": "calendar" }
    ],
    "keybindings": [
      { "command": "dateTools.insertDate", "key": "ctrl+alt+d", "when": "editorTextFocus" }
    ],
    "configuration": {
      "dateTools.format": {
        "type": "string",
        "default": "iso",
        "description": "iso (2026-11-18) or local (as macOS writes dates)."
      }
    }
  },
  "permissions": []
}
```

- **The command**: `registerCommand` gives the id its code; the `contributes.commands` entry puts
  it in the palette (with an SF Symbol as its icon) and makes it start the extension.
- **The shortcut**: ⌃⌥D runs it while the cursor is in an editor (`"when": "editorTextFocus"`).
  A key needs ⌘, ⌃ or ⌥ (function keys excepted). Users can change it in *Settings ▸ Keyboard
  Shortcuts*. See [keybindings](manifest.md#keybindings) for the key names and `when`.
- **The setting**: `getConfiguration("dateTools").get("format")` reads `dateTools.format` — the
  user's value, or the `default`. Users change it in the Extensions sidebar: expand the extension,
  and its settings are under *Settings*.
- **The edit**: `editor.edit` replaces every selection (or inserts at every cursor) in one undoable
  step.

## 5. Reload and try it

Build again (`npm run build`, or let `npm run watch` do it), then run **Extensions: Reload** from
the palette — or **+** ▸ *Reload Extensions* in the Extensions sidebar. The editor never notices a
rebuilt main file or an edited `extension.json` by itself; *Reload* restarts the extensions in
that window with what's on disk now.

Now put the cursor in a file and press ⌃⌥D, or run **Date Tools: Insert Date**.

## 6. Read the log

Show the Extensions sidebar (the puzzle piece in the activity bar) and click the disclosure arrow
beside *Date Tools*. Its details list its id, permissions, commands, settings and its **Log**:
`console.log`, `console.warn` and `console.error` from your code, and every error — an exception
in a command, a provider that failed, activation that didn't finish.

Try it: add `console.log("Inserted", text);` after the edit, rebuild, reload, run the command.
The line shows in the log. The state under the name says whether the extension is *Running*,
*Starts when needed*, *Disabled* or *Failed: see the log*.

[Debugging and testing](debugging-and-testing.md) lists the errors you're likely to meet.

## 7. A status bar item

Show the date format in the status bar, and let a click insert the date. Add this to `activate`
(shown here on its own):

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  const item = omc.window.createStatusBarItem(omc.StatusBarAlignment.Right, 50);
  item.command = "dateTools.insertDate";
  item.tooltip = "Insert today's date";

  const update = () => {
    const format = omc.workspace.getConfiguration("dateTools").get<string>("format", "iso");
    item.text = `$(calendar) ${format}`;
    item.show();
  };
  update();

  context.subscriptions.push(
    item,
    omc.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("dateTools.format")) update();
    }),
  );
}
```

`$(calendar)` shows the SF Symbol named `calendar`. `onDidChangeConfiguration` fires when the
user changes one of the extension's settings, so the item follows the setting.

A status bar item only exists while the extension runs, and so far the extension starts on the
first *Insert Date*. To have the item there from the moment the window opens, start the extension
then:

```json
"activationEvents": ["onStartup"]
```

Use `onStartup` only when the extension really has something to show at once: every extension
started with the window costs a little time and memory in every window. The other activation
events are in [the manifest reference](manifest.md#activationevents).

## 8. Ask, and tell

Commands often ask something first. A second command that lets the user pick the format (again
shown on its own):

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.commands.registerCommand("dateTools.chooseFormat", async () => {
      const picked = await omc.window.showQuickPick(
        [
          { label: "iso", description: "2026-11-18" },
          { label: "local", description: "as macOS writes dates" },
        ],
        { placeHolder: "Date format" },
      );
      if (!picked) return; // dismissed
      await omc.workspace.getConfiguration("dateTools").update("format", picked.label);
      await omc.window.showInformationMessage(`Dates are now ${picked.label}.`);
    }),
  );
}
```

(List `dateTools.chooseFormat` under `contributes.commands` too.) The quick pick shows in the
palette; the notification shows in the window's bottom-right corner, with the extension's name
under the message, and goes away after a few seconds.

## 9. Iterate

The loop from here on:

1. Edit `src/` (or `extension.json`).
2. `npm run build` (or keep `npm run watch` running).
3. **Extensions: Reload**.
4. Try it; read the log.

Reload restarts the extensions of the window you run it in. Other windows keep running the code
they loaded until they're reloaded too (or reopened).

## 10. Install it for good

An extension installed for development is a link to its folder: the editor runs it from there, so
the folder has to stay. When it's done, install a copy instead:

1. Build it.
2. In the Extensions sidebar, **+** ▸ *Install from Folder…*, and choose the extension's folder.
3. The dialog shows its name, version, description and the permissions it asks for. Click
   **Replace** (or **Install** if it wasn't installed).

The folder is copied into `~/Library/Application Support/OhMyCode/Extensions/<id>`. Its
settings and stored values are kept. [Publishing](publishing.md) covers making a clean copy to
share (without `node_modules`).

## Making one by hand

*New Extension…* is a shortcut; any folder with an `extension.json` and its main file is an
extension:

```sh
mkdir date-tools && cd date-tools
mkdir src
cp /path/to/ohmycode/ExtensionAPI/omc.d.ts .
npm init -y
npm install --save-dev typescript
```

`tsconfig.json` — the same as the template's:

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "types": [],
    "lib": ["ES2020"]
  },
  "files": ["omc.d.ts", "src/extension.ts"]
}
```

- `"module": "commonjs"`: the editor loads the main file as a CommonJS module and calls its
  exported `activate`.
- `"types": []` and `"lib": ["ES2020"]`: the extension doesn't run in Node or a browser, so
  their globals (`fs`, `document`, `fetch`) aren't there; `omc.d.ts` declares what is (`console`,
  the timers).

Add `"build": "tsc -p ."` to `package.json`'s scripts, write `extension.json` and
`src/extension.ts`, build, and use **+** ▸ *Install for Development…* in the Extensions sidebar to
link the folder (the folder must have the built main file: installing checks).

## Building with esbuild

`tsc` compiles each source file to its own JavaScript file, and the editor's `require` only knows
`"omc"`: an extension whose `extension.ts` imports `./parser` fails with *Cannot find module
'./parser'*. As soon as the code is in more than one file, or uses an npm package, bundle it into
one file with esbuild:

```sh
npm install --save-dev esbuild
```

```json
"scripts": {
  "build": "tsc -p . --noEmit && esbuild src/extension.ts --bundle --format=cjs --platform=neutral --main-fields=module,main --target=es2020 --external:omc --outfile=dist/extension.js",
  "watch": "esbuild src/extension.ts --bundle --format=cjs --platform=neutral --main-fields=module,main --target=es2020 --external:omc --outfile=dist/extension.js --watch"
}
```

- `--external:omc` leaves `require("omc")` for the editor to answer.
- `--platform=neutral` (with `--main-fields`) because the extension runs in neither Node nor a
  browser: a package that needs Node's modules (`fs`, `path`, `child_process`) fails to bundle,
  rather than failing later at run time. Use `omc.workspace.fs` and `omc.process` instead.
- `tsc --noEmit` still type-checks; esbuild only strips the types.

Bundling also lets you import JSON (`import data from "./data.json"`) — see the
[cookbook](cookbook.md#hover-documentation-from-a-json-file).

## See also

- [The manifest](manifest.md): everything `extension.json` can say.
- [API reference](api-reference.md): everything `omc` has.
- [Cookbook](cookbook.md): more things to build next.
- [Debugging and testing](debugging-and-testing.md).
