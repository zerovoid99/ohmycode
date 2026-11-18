# Oh My Code extensions

Extensions add to Oh My Code what it doesn't do by itself: commands and shortcuts, status bar
items, whole languages with their colors, snippets and language servers, and language features
written in code. They are written in TypeScript (or JavaScript) against the `omc` API, and each
one runs in a JavaScriptCore context of its own, off the main thread, so a slow extension can't
freeze the editor.

This is the developer guide. It starts with a tutorial, then has a reference for the manifest
and the API, and guides for each kind of contribution.

## What an extension can do

| You want to… | With | Guide |
| --- | --- | --- |
| Add commands to the palette, with shortcuts | `contributes.commands`, `contributes.keybindings`, `omc.commands` | [Getting started](getting-started.md), [Manifest](manifest.md#commands) |
| Have settings users can change | `contributes.configuration`, `omc.workspace.getConfiguration` | [Manifest](manifest.md#configuration) |
| Show things: notifications, a quick pick, an input box, a status bar item | `omc.window` | [API reference](api-reference.md#window) |
| Read and edit documents, react to opening, editing and saving | `omc.workspace`, `TextEditor.edit` | [API reference](api-reference.md#workspace) |
| Read and write files, run programs, make web requests | `omc.workspace.fs`, `omc.process`, `omc.net` (with permissions) | [Runtime and security](runtime-and-security.md) |
| Add a language: file types, comments, brackets, indentation | `contributes.languages`, `language-configuration.json` | [Language support](language-support.md) |
| Color a language | `contributes.grammars` (TextMate), `contributes.treeSitterGrammars` | [Syntax highlighting](syntax-highlighting.md) |
| Bring a language server | `contributes.languageServers` | [Language servers](language-servers.md) |
| Completion, hover, Go to Definition, the Outline, quick fixes, formatting… in code | `omc.languages.register…Provider` | [Providers](providers.md) |
| Show problems | `omc.languages.createDiagnosticCollection` | [API reference](api-reference.md#diagnostics) |
| Add snippets | `contributes.snippets` | [Snippets](snippets.md) |

Languages, grammars, snippets and language servers need no code at all: `extension.json` and
the files it names are enough.

## Reading order

1. [Getting started](getting-started.md): a first extension from nothing — a command, a
   shortcut, a setting and a status bar item — built, reloaded and installed.
2. [The manifest](manifest.md): every field of `extension.json` and every contribution point.
3. [API reference](api-reference.md): the `omc` module, namespace by namespace.
4. [Runtime and security](runtime-and-security.md): how extensions run, their limits, the
   permissions and what they protect, where data is kept.
5. [Debugging and testing](debugging-and-testing.md): the log, common errors and what they mean,
   tests for extension code, performance.
6. [Publishing](publishing.md): packaging, versions, how people install and update.
7. [Examples](examples.md): the examples in `ExtensionAPI/examples`, explained.
8. [Cookbook](cookbook.md): short recipes for common tasks.

Language guides, for when you get there:

- [Language support](language-support.md): declaring a language and its `language-configuration.json`.
- [Syntax highlighting](syntax-highlighting.md): TextMate grammars and tree-sitter parsers.
- [Language servers](language-servers.md): starting a server for a language, its settings,
  custom requests.
- [Language feature providers](providers.md): every `register…Provider`, with examples.
- [Snippets](snippets.md): snippet files.

## What you need

- **Oh My Code**, with a folder open: extensions run in windows that have one or more folders.
- **Node.js and npm**, to build. The template's `package.json` brings TypeScript (`tsc`); add
  [esbuild](https://esbuild.github.io) when the extension has more than one source file or uses
  npm packages (see [Getting started](getting-started.md#building-with-esbuild)).
- **`ExtensionAPI/omc.d.ts`**, the API's types. *Extensions: New Extension…* copies it into every
  new extension; the app has it inside too.

Nothing is needed to *run* an extension except the app: the main file is plain JavaScript.

## API version

The API is version **0.3.0**: `omc.version` says so at run time, and `omc.d.ts` starts with it.
There's no `engines` field to declare a version in `extension.json`; an extension that needs a
newer API checks `omc.version`, or checks that a function exists, when it activates (see
[Publishing](publishing.md#compatibility)).

The API follows VS Code's where they do the same thing — `Disposable`, `EventEmitter`, `Range`,
`CompletionItem`, `WorkspaceEdit`, providers and their arguments — so VS Code knowledge and many
snippets of VS Code extension code carry over. It is not VS Code's API: only what `omc.d.ts`
declares exists.

## See also

- `ExtensionAPI/examples/word-count` and `ExtensionAPI/examples/toy-language`: complete
  extensions ([Examples](examples.md)).
- `ExtensionAPI/tools/build-tree-sitter-grammar.sh`: builds a tree-sitter parser for
  `contributes.treeSitterGrammars`.
