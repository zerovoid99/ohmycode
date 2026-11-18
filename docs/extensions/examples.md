# Examples

`ExtensionAPI/examples` has two complete extensions. Each is small enough to read in a few
minutes, builds with nothing but TypeScript, and has its compiled `dist/extension.js` checked in,
so it runs as soon as it's installed.

| Example | Shows |
| --- | --- |
| [`word-count`](#word-count) | A command, a setting, a status bar item that follows the active editor and edits, notifications |
| [`toy-language`](#toy-language) | A whole language: file types, a TextMate grammar, `language-configuration.json`, snippets, and completion, hover, Go to Definition and the Outline in code |

## Running an example

1. In the Extensions sidebar (the puzzle piece in the activity bar), **+** ▸ *Install for
   Development…*, and choose the example's folder (`ExtensionAPI/examples/word-count`).
2. It's listed with a **DEV** badge, and runs.

To change one, edit `src/extension.ts`, compile it, and run **Extensions: Reload**. The examples
compile against the repository's `ExtensionAPI/omc.d.ts` and have no `package.json`; with
TypeScript from npm:

```sh
cd ExtensionAPI/examples/word-count
npx -p typescript tsc -p .
```

To start an extension of your own from one, copy its folder somewhere else and change the `id` —
or, for the toy language, use **Extensions: New Language Support Extension…**, which does that
for you (with a `package.json` and its own `omc.d.ts`).

## word-count

The number of words in the active file — or in the selection — in the status bar; clicking it (or
*Word Count: Show Word Count*) says it in a notification.

**`extension.json`**:

```json
{
  "id": "examples.word-count",
  "name": "Word Count",
  "version": "1.0.0",
  "description": "Shows the words in the current file (or selection) in the status bar.",
  "main": "dist/extension.js",
  "activationEvents": ["onStartup"],
  "contributes": {
    "commands": [
      { "command": "wordCount.show", "title": "Show Word Count", "category": "Word Count" }
    ],
    "configuration": {
      "wordCount.countSelection": {
        "type": "boolean",
        "default": true,
        "description": "Count only the selected text when there is a selection."
      }
    }
  }
}
```

- `onStartup`: the count should be in the status bar as soon as the window opens, before any
  command is run.
- One boolean setting, shown as a checkbox in the extension's details.
- No `permissions`: it only reads the editor.

**`src/extension.ts`**, the parts that matter:

```ts
import * as omc from "omc";

function count(text: string): number {
  const words = text.match(/[\p{L}\p{N}_'-]+/gu);
  return words ? words.length : 0;
}

function words(): { count: number; scope: string } | undefined {
  const editor = omc.window.activeTextEditor;
  if (!editor) return undefined;
  const useSelection = omc.workspace.getConfiguration("wordCount").get("countSelection", true) && !editor.selection.isEmpty;
  const text = editor.document.getText(useSelection ? editor.selection : undefined);
  return { count: count(text), scope: useSelection ? "selection" : editor.document.fileName };
}

export function activate(context: omc.ExtensionContext) {
  const item = omc.window.createStatusBarItem(omc.StatusBarAlignment.Right, 10);
  item.command = "wordCount.show";
  item.tooltip = "Words in this file";

  const update = () => {
    const result = words();
    if (!result) { item.hide(); return; }
    item.text = `$(text.word.spacing) ${result.count}`;
    item.show();
  };

  context.subscriptions.push(
    item,
    omc.commands.registerCommand("wordCount.show", async () => {
      const result = words();
      if (!result) {
        await omc.window.showWarningMessage("Open a file to count its words.");
        return;
      }
      await omc.window.showInformationMessage(`${result.count} words in ${result.scope}.`);
    }),
    omc.window.onDidChangeActiveTextEditor(update),
    omc.workspace.onDidChangeTextDocument(update),
    omc.workspace.onDidChangeConfiguration((e) => { if (e.affectsConfiguration("wordCount")) update(); }),
  );
  update();
}
```

What to notice:

- **`activeTextEditor` is read fresh** in `words()` every time, never kept: it's a snapshot.
- **One `update` for three events** — another tab, an edit (delivered once edits settle), the
  setting — and once at the start for the editor already open.
- **The status bar item** hides when no file is open, shows an SF Symbol (`$(text.word.spacing)`),
  and runs the command on click. It's in `subscriptions`, so it goes when the extension stops.
- **`\p{L}` in the regular expression** counts words in any script — JavaScriptCore supports
  Unicode property escapes.
- Changing the selection alone doesn't update the count: there's no selection event, so the count
  catches up on the next edit or tab change. (Run the command for an exact count of a selection.)

## toy-language

Language support for `.toy` files — a tiny language with `fn`, `let`, `if … do … end` and `#`
comments — showing every declarative part of a language plus the providers that make it feel
real. `sample.toy` is a file to try it on.

```
toy-language/
├── extension.json
├── language-configuration.json   comments, brackets, auto-closing, folding, words, indentation
├── syntaxes/toy.tmLanguage.json  the TextMate grammar (colors)
├── snippets/toy.json             fn, if, region
├── src/extension.ts              completion, hover, definitions, the Outline
├── dist/extension.js
├── sample.toy
└── tsconfig.json
```

**`extension.json`**:

```json
{
  "id": "examples.toy-language",
  "name": "Toy Language",
  "version": "1.0.0",
  "main": "dist/extension.js",
  "activationEvents": ["onLanguage:toy"],
  "contributes": {
    "languages": [
      {
        "id": "toy",
        "aliases": ["Toy", "toy"],
        "extensions": [".toy"],
        "filenames": ["Toyfile"],
        "firstLine": "^#!.*\\btoy\\b",
        "configuration": "./language-configuration.json"
      }
    ],
    "grammars": [
      { "language": "toy", "scopeName": "source.toy", "path": "./syntaxes/toy.tmLanguage.json" }
    ],
    "snippets": [
      { "language": "toy", "path": "./snippets/toy.json" }
    ]
  }
}
```

- **The language** (`contributes.languages`): `.toy` files, files named `Toyfile`, and files whose
  first line is a `toy` shebang. `aliases[0]` is the name in the status bar.
  ([Language support](language-support.md))
- **The grammar** colors it: keywords, declarations, strings, numbers, calls, comments with
  `TODO` highlighted. Open `sample.toy` and run *Developer: Inspect Editor Tokens and Scopes* on a
  word to see its scopes. ([Syntax highlighting](syntax-highlighting.md))
- **`language-configuration.json`**: ⌘/ comments with `#`, `#[ … ]#` block comments, `(` and `[`
  close themselves, `# region` folds, words may contain `-`, Enter after `do` indents and typing
  `end` outdents, Enter in a comment continues it.
- **Snippets**: type `fn` and press Tab. ([Snippets](snippets.md))
- `onLanguage:toy` isn't strictly needed — a file of a language the extension adds starts it anyway
  — but says so plainly.

None of that needs code: delete `src/` and keep an empty main file, and `.toy` files still get
colors, comments, brackets, indentation and snippets.

**`src/extension.ts`** adds what needs code. All four providers share one function that finds the
file's declarations:

```ts
import * as omc from "omc";

interface Declaration {
  name: string;
  kind: "fn" | "let";
  line: number;
  /** Where the name starts on its line. */
  start: number;
  text: string;
}

/** The file's `fn` and `let` declarations, top to bottom. */
function declarations(document: omc.TextDocument): Declaration[] {
  const found: Declaration[] = [];
  for (let line = 0; line < document.lineCount; line++) {
    const text = document.lineAt(line).text;
    const match = /^(\s*)(fn|let)\s+([A-Za-z_]\w*)/.exec(text);
    if (match) {
      found.push({ name: match[3], kind: match[2] as "fn" | "let", line, start: match[0].length - match[3].length, text: text.trim() });
    }
  }
  return found;
}

export function activate(context: omc.ExtensionContext) {
  const selector: omc.DocumentSelector = { language: "toy" };
  context.subscriptions.push(
    omc.languages.registerDocumentSymbolProvider(selector, {
      provideDocumentSymbols(document) {
        return declarations(document).map((declaration) => {
          const line = document.lineAt(declaration.line).text;
          return new omc.DocumentSymbol(
            declaration.name, declaration.kind,
            declaration.kind === "fn" ? omc.SymbolKind.Function : omc.SymbolKind.Variable,
            new omc.Range(declaration.line, 0, declaration.line, line.length),
            new omc.Range(declaration.line, declaration.start, declaration.line, declaration.start + declaration.name.length),
          );
        });
      },
    }),
  );
}
```

The full file also registers:

- **Completion**: the keywords, each with Markdown documentation, and the file's own functions
  and variables — a function inserted as a snippet with a placeholder for its arguments
  (`SnippetString.appendPlaceholder`).
- **Hover**: a keyword's meaning, or a name's declaration as a code block
  (`MarkdownString.appendCodeblock`).
- **Go to Definition**: F12 or ⌘-click on a name jumps to its `fn` or `let`.
- **Document symbols**: the Outline, the breadcrumbs and *Go to Symbol in File* (above).

What to notice:

- **Language features without a language server.** For a language that has a server, the same
  providers add to the server's answers. ([Providers](providers.md))
- `lineAt` per line is fine for small files; for big ones read `getText()` once
  ([performance](debugging-and-testing.md#performance)).
- The providers return `undefined` when they have nothing to say; the editor then shows the other
  sources' answers (or nothing).

To make it yours, run **Extensions: New Language Support Extension…**: it copies this example
with a new id and name, a `package.json` and the API types, installs it for development and opens
it. Then rename `toy` throughout, and replace the grammar — or import one from a VS Code
extension's `syntaxes/` folder.

## More examples

- The [cookbook](cookbook.md) has short, complete recipes: a linter's diagnostics, a formatter
  from a CLI, a language server from npm, quick fixes, hover documentation, custom requests…
- The language guides each have examples for their part:
  [providers](providers.md), [language servers](language-servers.md),
  [syntax highlighting](syntax-highlighting.md) (with a tree-sitter parser).

## See also

- [Getting started](getting-started.md): a first extension, step by step.
- [API reference](api-reference.md).
