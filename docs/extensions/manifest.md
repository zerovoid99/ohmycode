# The manifest: extension.json

Every extension is a folder with an `extension.json` at its top. It says who the extension is,
which JavaScript file to run, when to start it, what it adds to the editor and what it may do
beyond the editor. This page lists every field the editor reads.

```json
{
  "id": "acme.date-tools",
  "name": "Date Tools",
  "version": "1.2.0",
  "publisher": "Acme",
  "description": "Inserts and formats dates.",
  "main": "dist/extension.js",
  "activationEvents": ["onLanguage:markdown"],
  "contributes": {
    "commands": [{ "command": "dateTools.insertDate", "title": "Insert Date", "category": "Date Tools", "icon": "calendar" }],
    "keybindings": [{ "command": "dateTools.insertDate", "key": "ctrl+alt+d", "when": "editorTextFocus" }],
    "configuration": {
      "dateTools.format": { "type": "string", "default": "iso", "description": "iso or local." }
    },
    "languages": [],
    "grammars": [],
    "treeSitterGrammars": [],
    "snippets": [],
    "languageServers": []
  },
  "permissions": []
}
```

The file is plain JSON (no comments). Fields the editor doesn't know are ignored — so a
misspelled field is ignored too, silently: if something you declared has no effect, check its
spelling first.

## When it's checked

`extension.json` is read and checked when an extension is installed (the install dialog won't
open for one that fails), and again whenever the extensions are loaded: when a window opens a
folder, on *Extensions: Reload*, and when any extension is installed, enabled, disabled or
removed. An installed extension whose manifest has become invalid (a development folder you're
editing, say) is listed at the bottom of the Extensions sidebar with a warning sign and the reason,
and doesn't run.

The checks:

- `id` has the right form; `name`, `version` and `main` aren't empty.
- `main` is inside the folder (links are followed) and exists.
- Every path a contribution names — a language configuration, a snippets file, a grammar, a
  parser library or query — is inside the folder.
- Each language has an `id`; each grammar a `scopeName`; each tree-sitter grammar a `language`,
  `library` and `symbol`; each language server an `id`, `languages`, a `command` and the stdio
  transport.
- `languageServers` needs the `process` permission and `treeSitterGrammars` the `nativeCode`
  permission.

Files that are named but missing or broken (a grammar that isn't valid JSON) don't fail the check:
the extension runs without them, and its log says why.

## Top-level fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | yes | `publisher.name`: exactly one dot, each part letters, digits, `-` and `_` (`acme.date-tools`). Identifies the extension everywhere: its folder in the extensions folder, its settings and stored values, the install dialog's “already installed” check. |
| `name` | string | yes | What the Extensions sidebar, the install dialog, notifications (under the message) and *Settings ▸ Keyboard Shortcuts* show. |
| `version` | string | yes | Shown beside the name and in the install dialog (“Replace Date Tools 1.1.0 with 1.2.0?”). Any text is accepted; use [Semantic Versioning](https://semver.org). The editor doesn't compare versions. |
| `main` | string | yes | The JavaScript file to run, relative to the folder: CommonJS, exporting `activate` (and optionally `deactivate`). An extension with no code still needs one: an empty file will do. |
| `description` | string | no | One or two sentences, shown under the name in the sidebar and in the install dialog. |
| `publisher` | string | no | Who makes it. Kept, not shown. |
| `activationEvents` | string[] | no | When to start the extension's code. See below. Default: none (it starts for its commands and languages only). |
| `contributes` | object | no | What it adds. See below. |
| `permissions` | string[] | no | What it may do beyond the editor and the open folders. See [Permissions](#permissions). Default: none. |

There's no `engines` or `apiVersion` field: see [compatibility](publishing.md#compatibility).

## activationEvents

An extension's code isn't loaded until it's needed. These start it:

| Event | Starts the extension |
| --- | --- |
| `onStartup` | When a window opens a folder (and on every reload). |
| `*` | The same as `onStartup`. |
| `onLanguage:<id>` | When a file of language `<id>` is opened in the window, or put in that language with *Change Language Mode*. Built-in languages answer to both of their ids (`onLanguage:typescriptreact` and `onLanguage:tsx`). If such a file is already open when the extension is installed or reloaded, it starts then. |
| `onCommand:<command>` | When `<command>` is run (from the palette, a shortcut, a status bar item, a code lens or another extension's `executeCommand`). Only needed for commands that aren't in `contributes.commands`. |

Two more starts need no entry:

- **A contributed command**: running any command listed in `contributes.commands` starts the
  extension first.
- **A contributed language**: opening a file of a language the extension adds (in
  `contributes.languages`, a new id rather than a built-in one) starts it.

Other events VS Code has (`workspaceContains:`, `onView:`, …) are ignored. Each window starts its
own copy of the extension; a running extension stays running until the window closes, it's
disabled or uninstalled, or the extensions are reloaded.

Grammars, snippets, language configurations and language servers work without the extension's
code ever starting: they're read from the manifest.

## contributes

| Contribution | What it adds | Reference |
| --- | --- | --- |
| [`commands`](#commands) | Commands in the palette | below |
| [`keybindings`](#keybindings) | Default keyboard shortcuts for commands | below |
| [`configuration`](#configuration) | Settings users can change | below |
| `languages` | Languages, or more files and configuration for known ones | [Language support](language-support.md) |
| `grammars` | TextMate grammars | [Syntax highlighting](syntax-highlighting.md#textmate-grammars) |
| `treeSitterGrammars` | Tree-sitter parsers (needs `nativeCode`) | [Syntax highlighting](syntax-highlighting.md#tree-sitter-parsers) |
| `snippets` | Snippet files | [Snippets](snippets.md) |
| `languageServers` | Language servers (needs `process`) | [Language servers](language-servers.md) |

Everything else under `contributes` (VS Code's `menus`, `views`, `themes`, …) is ignored.

### commands

```json
"commands": [
  { "command": "dateTools.insertDate", "title": "Insert Date", "category": "Date Tools", "icon": "calendar" }
]
```

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `command` | string | yes | The id, as `omc.commands.registerCommand` registers it. Prefix it with something of your own (`dateTools.`): ids are shared by every extension and the built-in commands. |
| `title` | string | yes | The name in the palette. |
| `category` | string | no | Put before the title: *Date Tools: Insert Date*. |
| `icon` | string | no | An SF Symbol name shown beside it in the palette (a puzzle piece by default). |

A contributed command:

- is listed in the palette (while the extension is enabled, whether it's running or not) and in
  *Settings ▸ Keyboard Shortcuts*, where users can give it a shortcut;
- is listed under *Commands* in the extension's details in the sidebar (click one to run it);
- starts the extension when it's run.

The extension must still register it in code: running a contributed command the code didn't
register fails with *The command dateTools.insertDate isn't registered by its extension.*

Commands registered in code but not contributed work too — from shortcuts, status bar items, code
lenses and `executeCommand` — but only while the extension is running (or with an
`onCommand:<id>` activation event), and they're not in the palette.

### keybindings

```json
"keybindings": [
  { "command": "dateTools.insertDate", "key": "ctrl+alt+d", "when": "editorTextFocus" },
  { "command": "dateTools.insertDate", "key": "f6", "when": "editorLangId == markdown" }
]
```

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `command` | string | yes | The command it runs: the extension's own, contributed or registered in code. |
| `key` | string | yes | Modifiers and a key joined with `+`. |
| `when` | string | no | When the shortcut applies. Default: always (in this window). |

**Keys.** Modifiers are `cmd` (or `command`, `meta`), `ctrl` (`control`), `alt` (`option`,
`opt`) and `shift`, in any order, case doesn't matter. The key is last: a letter or digit, one of
`` ` - = [ ] \ ; ' , . / ``, `f1`–`f19`, `enter` (`return`), `tab`, `space`, `backspace`, `delete`,
`escape` (`esc`), `home`, `end`, `pageup`, `pagedown`, `left`, `right`, `up`, `down`. Keys are
matched by their place on the keyboard (as on a US layout), so `cmd+shift+1` works whatever
character Shift-1 types.

A shortcut needs `cmd`, `ctrl` or `alt` — `shift+k` alone would take over typing — unless the key
is a function key (`f6`, `shift+f6`). A key that doesn't parse is skipped, with a line in the
extension's log: *Keybinding shift+k for dateTools.insertDate ignored: “shift+k” needs cmd, ctrl
or alt (or a function key): it would take over typing.*

**`when`** is a list of terms joined with `&&`, each optionally negated with `!`:

| Term | True when |
| --- | --- |
| `editorTextFocus` | The cursor is in the window's active editor. |
| `editorLangId == <id>` | The active editor's file has language id `<id>` (the VS Code id: `typescriptreact`, `shellscript`). |
| `editorLangId != <id>` | It hasn't. |

```json
"when": "editorTextFocus && editorLangId == markdown"
"when": "!editorTextFocus"
```

Any other term (VS Code's `resourceExtname`, `||`, parentheses) is false, so a shortcut whose
`when` uses one never runs.

**Who wins.** A key a menu item already has stays the menu's: pressing it runs the menu item, and
the extension's log says *⌃⌥D is the menu's “…”: dateTools.insertDate isn't run.* A built-in
command's shortcut also wins over an extension's. Between extensions, the first in the Extensions
list (by name) wins.

**Users' changes.** The first `key` for a command is its default shortcut, shown in the palette and
in *Settings ▸ Keyboard Shortcuts*. Users can change or remove it there, or in `keybindings.json`
(`~/Library/Application Support/OhMyCode/keybindings.json`), which reads like VS Code's:

```json
[
  { "key": "cmd+alt+d", "command": "dateTools.insertDate" },
  { "key": "f6", "command": "-dateTools.insertDate" }
]
```

`-command` removes its default. A user's shortcut replaces all of the extension's for that
command; its `when` is the user's, or else the extension's first.

### configuration

```json
"configuration": {
  "dateTools.format": { "type": "string", "default": "iso", "description": "iso or local." },
  "dateTools.weekStartsOnMonday": { "type": "boolean", "default": true },
  "dateTools.offsetDays": { "type": "number", "default": 0, "description": "Added to today." }
}
```

An object whose keys are the settings' full names (prefix them with something of your own) and
whose values are:

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `type` | `"boolean"`, `"string"` or `"number"` | yes | Decides the control in the sidebar. Other types (`"array"`, `"object"`, `"integer"`) make `extension.json` unreadable. |
| `default` | any JSON value | no | The value until the user sets one. |
| `description` | string | no | Shown under the control. |

This is a flat map, not VS Code's `{ "title": …, "properties": { … } }`: in VS Code's layout,
`title` and `properties` would be read as two settings, which they aren't, and the manifest fails
the check.

**How users set values.** In the Extensions sidebar, expand the extension: *Settings* lists each
one, sorted by name — a checkbox for a boolean, a text field for a string or number (saved when
Return is pressed; a number that doesn't parse beeps). Values apply to every window and folder
(there are no per-folder values) and are kept when the extension is updated; uninstalling it
removes them.

**From code.** `omc.workspace.getConfiguration("dateTools").get("format")` reads a value (the
user's, else the `default`); `update("format", "local")` sets it, as if the user had (any key, any
JSON value — `undefined` removes the user's value). `onDidChangeConfiguration` tells the extension
when one of its settings changes, from either side. Settings are also what language servers'
`${config:…}` read ([Language servers](language-servers.md#settings-and-config)).

## permissions

```json
"permissions": ["process", "network"]
```

Without permissions, an extension works with the editor and with files inside the window's
folders. Each permission adds one thing:

| Permission | Unlocks | Shown in the install dialog as |
| --- | --- | --- |
| `process` | `omc.process.run`; `contributes.languageServers` and `omc.languages.registerLanguageServer` | Run programs on this Mac |
| `network` | `omc.net.fetch` | Make network requests |
| `fileSystem` | `omc.workspace.fs`, `openTextDocument` and `showTextDocument` outside the window's folders; writing inside `.git` folders | Read and write files outside the open folder |
| `nativeCode` | `contributes.treeSitterGrammars` (loading a parser library into the app) | Load native code into Oh My Code (a tree-sitter parser) |

Permissions are granted by installing: the install dialog lists them (“It asks to: • Run programs
on this Mac …  Only install extensions you trust.”), or says “It works only with the editor and the
open folder.” when there are none. They're listed again under *Permissions* in the extension's
details. There's no prompt later: an API call the manifest didn't ask for fails at once, with the
permission it needs in the error. Unknown permission names make `extension.json` unreadable.

What each permission really allows, and what isn't protected, is in
[Runtime and security](runtime-and-security.md#permissions).

## Paths

Every path in `extension.json` (`main`, `configuration`, `path`, `library`, queries, a server's
relative `command`) is relative to the extension's folder, may start with `./`, and must stay
inside the folder after links are followed. `../shared/grammar.json` is refused.

## See also

- [Getting started](getting-started.md): a manifest built up step by step.
- [API reference](api-reference.md): `omc.commands`, `omc.workspace.getConfiguration`.
- [Runtime and security](runtime-and-security.md): what the permissions mean.
- [Publishing](publishing.md): ids and versions when you share an extension.
