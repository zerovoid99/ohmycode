# Language feature providers

Providers are how an extension answers the editor's questions about a file in code: what can be
typed here, where is this defined, what's in this file, how can this problem be fixed. Every
feature the editor gets from a language server can also come from an extension, through
`omc.languages.register…Provider`. Providers work for any language — your own, or one the editor
knows — and their answers are shown together with the language server's.

This guide covers [how providers work](#how-providers-work) (selectors, merging, cancellation,
timeouts, the types they use), then each provider in turn:

| Feature in the editor | Provider |
| --- | --- |
| Completion list | [`registerCompletionItemProvider`](#completion) |
| Hover | [`registerHoverProvider`](#hover) |
| Signature help (parameter hints) | [`registerSignatureHelpProvider`](#signature-help) |
| Go to Definition (F12, ⌘-click), Type Definition, Implementation (⌘F12) | [`registerDefinitionProvider` and the others](#definitions-type-definitions-implementations) |
| Find All References (⇧F12) | [`registerReferenceProvider`](#references) |
| Outline, breadcrumbs, Go to Symbol in File | [`registerDocumentSymbolProvider`](#document-symbols) |
| Go to Symbol in Workspace | [`registerWorkspaceSymbolProvider`](#workspace-symbols) |
| Quick fixes and refactorings (⌘. and the lightbulb) | [`registerCodeActionsProvider`](#code-actions) |
| Code lenses (clickable text after a line) | [`registerCodeLensProvider`](#code-lenses) |
| Rename Symbol (F2) | [`registerRenameProvider`](#rename) |
| Symbol highlights | [`registerDocumentHighlightProvider`](#document-highlights) |
| Links (⌘-click) | [`registerDocumentLinkProvider`](#document-links) |
| Folding | [`registerFoldingRangeProvider`](#folding-ranges) |
| Inlay hints | [`registerInlayHintsProvider`](#inlay-hints) |
| Semantic colors | [`registerDocumentSemanticTokensProvider`](#semantic-tokens) |
| Format Document, Format Selection, on-type formatting | [the formatting providers](#formatting) |

## How providers work

### Registering

Each `register…` function takes a **document selector** and a provider object, and returns a
`Disposable`. Push it into `context.subscriptions` so it goes when the extension stops (it goes
anyway, but disposing is how you remove one earlier):

```ts
import * as omc from "omc";

export function activate(context: omc.ExtensionContext) {
  context.subscriptions.push(
    omc.languages.registerHoverProvider("toy", {
      provideHover(document, position, token) {
        const range = document.getWordRangeAtPosition(position);
        return range && new omc.Hover(`**${document.getText(range)}**`, range);
      },
    }),
  );
}
```

A **selector** says which documents the provider is for:

| Selector | Matches |
| --- | --- |
| `"toy"` | Documents whose language id is `toy` (built-in languages by either id: `"typescriptreact"` or `"tsx"`). |
| `"*"` | Every document. |
| `{ language: "toy" }` | The same as `"toy"`. |
| `{ pattern: "**/*.spec.toy" }` | Documents whose path matches the glob (`**`, `*`, `?`, `{a,b}`, `[abc]`). |
| `{ language: "json", pattern: "**/toy.json" }` | Both must match. |
| `{ scheme: "file" }` | Files on disk (the only scheme documents have). |
| `["toy", { pattern: "**/Toyfile" }]` | Any of them. |

### Merging with the language server

When a document has both a language server and extension providers, the editor asks them at the
same time and combines the answers:

| Feature | How answers combine |
| --- | --- |
| Completion, hover | All items / all hover sections, the server's first. |
| Definitions, type definitions, implementations, references | All locations, the server's first, each place once. One location jumps there; several are listed in the sidebar. |
| Document symbols | The server's, when it lists any; otherwise the first provider that does. |
| Workspace symbols, code actions, code lenses, highlights, links, inlay hints | All of them. |
| Semantic tokens | Both, the extension's drawn over the server's where both color a range. |
| Signature help | The server's, when it has any; otherwise the first provider's. |
| Folding | The server's; then the providers'; then the syntax tree's; then `folding.markers`. |
| Rename, formatting | An extension's provider, when there is one (installing it is a choice); otherwise the server's. |

Without a language server, the extension's answers are all there is — that's how a language
with no server gets an Outline or Go to Definition.

### Cancellation and timeouts

Every provider method gets a `CancellationToken` (for completion, the third argument is the token
and also carries the context's `triggerCharacter`; the context itself is the fourth). The token is
cancelled when the editor no longer needs the answer:

- the user typed on, moved the cursor or closed the file while you were working, or
- the provider took longer than **1.5 seconds** (its answer is then left out, and the extension's
  log says it didn't answer in time).

Check `token.isCancellationRequested` in long loops, or listen for it:

```ts
provideWorkspaceSymbols(query, token) {
  return new Promise((resolve) => {
    const work = startIndexing(query, resolve);
    token.onCancellationRequested(() => { work.stop(); resolve([]); });
  });
}
```

A cancelled provider's answer is ignored, whatever it returns. JavaScript that runs 5 seconds
without returning (an endless loop) is stopped; the extension keeps running.

### Answers

Providers may return their answer, `undefined`/`null` for none, or a promise of either. An error
thrown (or a rejected promise) counts as no answer and is written to the extension's log.

The types follow VS Code's API (`omc.d.ts` has them all, with documentation):

- `Position` (zero-based `line`, `character` in UTF-16 code units) and `Range`.
- `Location(uri, range)`: `uri` is a `file://` URI, a path (relative paths are from the first
  workspace folder), a document's `uri`, or `omc.Uri.file(path)`. `LocationLink`s
  (`{ targetUri, targetRange, targetSelectionRange }`) work wherever locations do.
- `TextEdit.replace/insert/delete` and `WorkspaceEdit` (`edit.replace(uri, range, text)`, for
  several files).
- `MarkdownString` (or a plain string, which is Markdown too) and `SnippetString`
  (`$1`, `${2:default}`, `${3|a,b|}`, `$0`).
- `Command`: `{ title, command, arguments }`, for the extension's own commands
  (`omc.commands.registerCommand`) or built-in ones. Commands from code actions, code lenses and
  completion items run in the extension that provided them.

## Completion

```ts
registerCompletionItemProvider(selector, provider, ...triggerCharacters): Disposable

interface CompletionItemProvider {
  provideCompletionItems(document, position, token & context, context):
    (CompletionItem | string)[] | CompletionList;
  resolveCompletionItem?(item, token): CompletionItem;
}
```

**Called** while typing a word (after a short pause), on a trigger character (`.`, `@`, …), and on Esc. The list is filtered as the user types on; a `CompletionList` with
`isIncomplete: true` is asked again on every keystroke instead.

`CompletionItem` fields: `label`, `kind` (`CompletionItemKind`), `detail` (beside the label),
`documentation` (Markdown, shown when the item is pointed at), `insertText` (a string or a
`SnippetString`), `filterText`, `sortText`, `preselect`, `range` (what it replaces: by default the
word before the cursor, as `wordPattern` defines it), `additionalTextEdits` (an import elsewhere),
`commitCharacters` (typing one accepts the item first, then types it) and `command` (run after
insertion).

**`resolveCompletionItem`** fills in what's expensive when the item is accepted: return the item
with `documentation` or `additionalTextEdits` added. Additional edits from resolving are applied
only above the insertion (where the text hasn't changed).

```ts
omc.languages.registerCompletionItemProvider("toy", {
  provideCompletionItems(document, position) {
    const call = new omc.CompletionItem("print", omc.CompletionItemKind.Function);
    call.insertText = new omc.SnippetString("print(").appendPlaceholder("value").appendText(")");
    call.commitCharacters = ["("];
    return [call, { label: "math", kind: omc.CompletionItemKind.Module }];
  },
  resolveCompletionItem(item) {
    item.documentation = new omc.MarkdownString(`Docs for **${item.label}**`);
    if (item.label === "math") item.additionalTextEdits = [omc.TextEdit.insert(new omc.Position(0, 0), "use math\n")];
    return item;
  },
}, ".");
```

The language's snippets (from the user, the folder and [`contributes.snippets`](snippets.md)) are
added to the list by the editor; providers don't need to return them.

## Hover

```ts
registerHoverProvider(selector, { provideHover(document, position, token): Hover | MarkupContent | MarkupContent[] })
```

**Called** when the pointer rests on text, or for *Show Hover*. Several sections (from the server
and providers) are shown one after another. A `{ language, value }` section is shown as code.

```ts
omc.languages.registerHoverProvider("toy", {
  provideHover(document, position) {
    const range = document.getWordRangeAtPosition(position);
    if (!range) return;
    return new omc.Hover(new omc.MarkdownString().appendCodeblock(`fn ${document.getText(range)}()`, "toy"), range);
  },
});
```

## Signature help

```ts
registerSignatureHelpProvider(selector, provider, "(", ",")
registerSignatureHelpProvider(selector, provider, { triggerCharacters: ["("], retriggerCharacters: [","] })

provideSignatureHelp(document, position, token, context): SignatureHelp
```

**Called** when a trigger character is typed (it opens the hint), when a retrigger character is
typed or the cursor moves while it's open (it updates), and for ⇧⌘Space. `context.triggerKind` is
1 (invoked), 2 (trigger character) or 3 (content change); `context.isRetrigger` is true while it's
open.

```ts
omc.languages.registerSignatureHelpProvider("toy", {
  provideSignatureHelp(document, position) {
    const before = document.lineAt(position.line).text.slice(0, position.character);
    if (!/\badd\([^)]*$/.test(before)) return;
    const signature = new omc.SignatureInformation("add(a, b)", "Adds two numbers.");
    signature.parameters = [new omc.ParameterInformation("a"), new omc.ParameterInformation("b", "The second number")];
    const help = new omc.SignatureHelp();
    help.signatures = [signature];
    help.activeParameter = before.split("add(").pop()!.split(",").length - 1;
    return help;
  },
}, { triggerCharacters: ["("], retriggerCharacters: [","] });
```

A parameter's `label` is its text in the signature's label, or `[start, end]` offsets into it
(more precise when a name appears twice).

## Definitions, type definitions, implementations

```ts
registerDefinitionProvider(selector, { provideDefinition(document, position, token): Location | Location[] | LocationLink[] })
registerTypeDefinitionProvider(selector, { provideTypeDefinition(…) })
registerImplementationProvider(selector, { provideImplementation(…) })
```

**Called** for Go to Definition (F12, ⌘-click), Go to Type Definition and Go to Implementation
(⌘F12). One location opens; several are listed in the sidebar.

```ts
omc.languages.registerDefinitionProvider("toy", {
  provideDefinition(document, position) {
    const range = document.getWordRangeAtPosition(position);
    if (!range) return;
    const name = document.getText(range);
    for (let line = 0; line < document.lineCount; line++) {
      const at = document.lineAt(line).text.indexOf(`fn ${name}(`);
      if (at >= 0) return new omc.Location(document.uri, new omc.Range(line, at + 3, line, at + 3 + name.length));
    }
  },
});
```

## References

```ts
registerReferenceProvider(selector, { provideReferences(document, position, context: { includeDeclaration }, token): Location[] })
```

**Called** for Find All References (⇧F12); the results are listed in the sidebar, by file.

```ts
omc.languages.registerReferenceProvider("toy", {
  async provideReferences(document, position, context, token) {
    const name = document.getText(document.getWordRangeAtPosition(position)!);
    const found: omc.Location[] = [];
    for (const path of await toyFilesInWorkspace()) {
      if (token.isCancellationRequested) return;
      const text = await omc.workspace.fs.readFile(path);
      text.split("\n").forEach((line, number) => {
        for (const match of line.matchAll(new RegExp(`\\b${name}\\b`, "g"))) {
          found.push(new omc.Location(path, new omc.Range(number, match.index!, number, match.index! + name.length)));
        }
      });
    }
    return found;
  },
});
```

## Document symbols

```ts
registerDocumentSymbolProvider(selector, { provideDocumentSymbols(document, token): DocumentSymbol[] | SymbolInformation[] })
```

**Called** when a file opens and shortly after edits; the symbols are the Outline, the breadcrumbs,
*Go to Symbol in File* and the names *Go to Symbol in Workspace* knows in open files. A
`DocumentSymbol`'s `range` is the whole declaration and `selectionRange` its name; `children`
nest. Kinds are `SymbolKind` (`Function`, `Class`, `Variable`, …).

```ts
omc.languages.registerDocumentSymbolProvider("toy", {
  provideDocumentSymbols(document) {
    const symbols: omc.DocumentSymbol[] = [];
    for (let line = 0; line < document.lineCount; line++) {
      const match = /^fn (\w+)/.exec(document.lineAt(line).text);
      if (match) {
        symbols.push(new omc.DocumentSymbol(match[1], "function", omc.SymbolKind.Function,
          new omc.Range(line, 0, line, match[0].length), new omc.Range(line, 3, line, 3 + match[1].length)));
      }
    }
    return symbols;
  },
});
```

## Workspace symbols

```ts
registerWorkspaceSymbolProvider({ provideWorkspaceSymbols(query, token): SymbolInformation[] })
```

No selector: it's for the whole workspace. **Called** as the user types in *Go to Symbol in
Workspace*; the editor fuzzy-matches and sorts what you return, so return candidates generously.

```ts
omc.languages.registerWorkspaceSymbolProvider({
  provideWorkspaceSymbols(query) {
    return index.search(query).map((entry) =>
      new omc.SymbolInformation(entry.name, omc.SymbolKind.Function, entry.module, new omc.Location(entry.path, entry.range)));
  },
});
```

## Code actions

```ts
registerCodeActionsProvider(selector, provider, { providedCodeActionKinds: [omc.CodeActionKind.QuickFix] })

provideCodeActions(document, range, context: { diagnostics, only?, triggerKind }, token): (CodeAction | Command)[]
```

**Called** for ⌘. (*Quick Fix & Refactor…*) with the selection or the cursor's line, and after a
pause when the cursor is on a line with a problem (the lightbulb appears when there are actions).
`context.diagnostics` are the problems in the range; `context.only` is set when only one kind is
wanted (*Organize Imports* asks for `source.organizeImports`) — actions of other kinds are dropped.

A `CodeAction` has a `title`, a `kind` (`QuickFix`, `Refactor…`, `Source…`), an `edit`
(`WorkspaceEdit`, applied first), a `command` (run after), `diagnostics` (what it fixes),
`isPreferred` (listed first) and `disabled: { reason }` (listed, not runnable). A bare `Command`
works as an action too.

```ts
omc.languages.registerCodeActionsProvider("toy", {
  provideCodeActions(document, range, context) {
    return context.diagnostics
      .filter((d) => d.message.startsWith("Unknown keyword"))
      .map((d) => {
        const fix = new omc.CodeAction("Replace with 'end'", omc.CodeActionKind.QuickFix);
        fix.edit = new omc.WorkspaceEdit();
        fix.edit.replace(document.uri, d.range, "end");
        fix.diagnostics = [d];
        fix.isPreferred = true;
        return fix;
      });
  },
}, { providedCodeActionKinds: [omc.CodeActionKind.QuickFix] });
```

## Code lenses

```ts
registerCodeLensProvider(selector, { provideCodeLenses(document, token): CodeLens[]; resolveCodeLens?(lens, token): CodeLens })
```

**Called** when a file opens and after edits (with *Settings ▸ Editor ▸ code lens* on). A lens is
clickable text after its line; clicking runs its command. Return lenses without a `command` and
fill it in `resolveCodeLens` when computing the title is expensive.

```ts
omc.languages.registerCodeLensProvider("toy", {
  provideCodeLenses(document) {
    const lenses: omc.CodeLens[] = [];
    for (let line = 0; line < document.lineCount; line++) {
      if (document.lineAt(line).text.startsWith("test ")) lenses.push(new omc.CodeLens(new omc.Range(line, 0, line, 4)));
    }
    return lenses;
  },
  resolveCodeLens(lens) {
    lens.command = { title: "▶ Run test", command: "toy.runTest", arguments: [lens.range.start.line] };
    return lens;
  },
});
```

## Rename

```ts
registerRenameProvider(selector, {
  prepareRename?(document, position, token): Range | { range, placeholder },
  provideRenameEdits(document, position, newName, token): WorkspaceEdit,
})
```

**Called** for Rename Symbol (F2): `prepareRename` first (throw to say nothing can be renamed
there; the editor beeps), then the name is asked for, starting from the `placeholder` (or the text
of the range), then `provideRenameEdits`. The edit is shown for review before it's made.

```ts
omc.languages.registerRenameProvider("toy", {
  prepareRename(document, position) {
    const range = document.getWordRangeAtPosition(position);
    if (!range || KEYWORDS.has(document.getText(range))) throw new Error("This can't be renamed.");
    return range;
  },
  provideRenameEdits(document, position, newName) {
    const name = document.getText(document.getWordRangeAtPosition(position)!);
    const edit = new omc.WorkspaceEdit();
    for (let line = 0; line < document.lineCount; line++) {
      for (const match of document.lineAt(line).text.matchAll(new RegExp(`\\b${name}\\b`, "g"))) {
        edit.replace(document.uri, new omc.Range(line, match.index!, line, match.index! + name.length), newName);
      }
    }
    return edit;
  },
});
```

## Document highlights

```ts
registerDocumentHighlightProvider(selector, { provideDocumentHighlights(document, position, token): DocumentHighlight[] })
```

**Called** when the cursor rests on a word (with symbol highlights on). Each range is highlighted, with
its `DocumentHighlightKind` (`Text`, `Read`, `Write`). Without a provider or
server, the editor highlights the same word.

## Document links

```ts
registerDocumentLinkProvider(selector, { provideDocumentLinks(document, token): DocumentLink[]; resolveDocumentLink?(link, token): DocumentLink })
```

**Called** when a file opens and after edits. Links open on ⌘-click:
a URL in the browser, a file path or `file://` URI in the editor. Leave `target` out and fill it in
`resolveDocumentLink` when finding it is expensive (it's asked for on the click).

```ts
omc.languages.registerDocumentLinkProvider("toy", {
  provideDocumentLinks(document) {
    const links: omc.DocumentLink[] = [];
    for (let line = 0; line < document.lineCount; line++) {
      const match = /import "([^"]+)"/.exec(document.lineAt(line).text);
      if (match) {
        const start = match.index + 8;
        links.push(new omc.DocumentLink(new omc.Range(line, start, line, start + match[1].length), match[1] + ".toy"));
      }
    }
    return links;
  },
});
```

## Folding ranges

```ts
registerFoldingRangeProvider(selector, { provideFoldingRanges(document, context, token): FoldingRange[] })
```

**Called** when a file opens and after edits, when the language server doesn't provide folding.
`new FoldingRange(start, end, kind?)`: zero-based lines; `start` stays visible and the lines after
it through `end` fold. `kind` is `Comment`, `Imports` or `Region`. For simple `# region` markers, `folding.markers` in the
[language configuration](language-support.md#folding) needs no code.

## Inlay hints

```ts
registerInlayHintsProvider(selector, { provideInlayHints(document, range, token): InlayHint[] })
```

**Called** when a file opens and after edits (with inlay hints on, in files up to 5,000 lines), for
the whole file. A hint is drawn at its `position`: a string or parts (`{ value, tooltip }`),
`kind` (`Type`, `Parameter`), and `paddingLeft`/`paddingRight`.

```ts
omc.languages.registerInlayHintsProvider("toy", {
  provideInlayHints(document, range) {
    const hints: omc.InlayHint[] = [];
    for (let line = range.start.line; line <= range.end.line && line < document.lineCount; line++) {
      const match = /^let (\w+) = \d+$/.exec(document.lineAt(line).text);
      if (match) {
        const hint = new omc.InlayHint(new omc.Position(line, 4 + match[1].length), ": number", omc.InlayHintKind.Type);
        hints.push(hint);
      }
    }
    return hints;
  },
});
```

## Semantic tokens

```ts
registerDocumentSemanticTokensProvider(selector, { provideDocumentSemanticTokens(document, token): SemanticTokens }, legend)
```

**Called** when a file opens and after edits (with semantic highlighting on, files up to 20,000
lines). The `legend` names your token types; tokens are drawn in the theme's color for the type:
`namespace`, `type`, `class`, `enum`, `interface`, `struct` and `typeParameter` as types;
`function`, `method` and `macro` as functions; `property`, `enumMember` and `event` as properties;
`decorator` as an attribute; `variable` and `parameter` as plain text. Other types keep the syntax
colors. Build the data with `SemanticTokensBuilder`:

```ts
const legend = new omc.SemanticTokensLegend(["function", "variable"], []);
omc.languages.registerDocumentSemanticTokensProvider("toy", {
  provideDocumentSemanticTokens(document) {
    const builder = new omc.SemanticTokensBuilder(legend);
    for (let line = 0; line < document.lineCount; line++) {
      for (const match of document.lineAt(line).text.matchAll(/\b(\w+)\(/g)) {
        builder.push(new omc.Range(line, match.index!, line, match.index! + match[1].length), "function");
      }
    }
    return builder.build();
  },
}, legend);
```

With no grammar, this is how a language gets colors; with one, the tokens are drawn over the grammar's.

## Formatting

```ts
registerDocumentFormattingEditProvider(selector, { provideDocumentFormattingEdits(document, options, token): TextEdit[] })
registerDocumentRangeFormattingEditProvider(selector, { provideDocumentRangeFormattingEdits(document, range, options, token): TextEdit[] })
registerOnTypeFormattingEditProvider(selector, { provideOnTypeFormattingEdits(document, position, ch, options, token): TextEdit[] }, ";", "}")
```

`options` is `{ tabSize, insertSpaces }`, from `.editorconfig` or the file's indentation.

- **Document formatting**: *Format Document* (⇧⌥F) and format on save. One undo step; edits that
  arrive after the user typed are dropped.
- **Range formatting**: *Format Selection*, and format on save with *Format: modifications* (the
  changed lines), called once per range of lines.
- **On-type formatting**: after one of the trigger characters is typed, at the position just after
  it. The edits are applied as one undo step unless more was typed meanwhile.

```ts
omc.languages.registerDocumentRangeFormattingEditProvider("toy", {
  provideDocumentRangeFormattingEdits(document, range, options) {
    const unit = options.insertSpaces ? " ".repeat(options.tabSize) : "\t";
    const edits: omc.TextEdit[] = [];
    let depth = 0;
    for (let line = 0; line < document.lineCount; line++) {
      const text = document.lineAt(line).text.trim();
      if (/^end\b/.test(text)) depth = Math.max(0, depth - 1);
      if (line >= range.start.line && line <= range.end.line) {
        edits.push(omc.TextEdit.replace(new omc.Range(line, 0, line, document.lineAt(line).text.length), unit.repeat(depth) + text));
      }
      if (/\bdo$/.test(text)) depth++;
    }
    return edits;
  },
});
```

## See also

- [Language support](language-support.md): the languages these providers are for.
- [Language servers](language-servers.md): the server whose answers providers join.
- [Snippets](snippets.md): completions without code.
- [Syntax highlighting](syntax-highlighting.md): grammars, under the semantic tokens providers add.
- [API reference](api-reference.md) and [Cookbook](cookbook.md): the rest of the API, and providers in recipes.
