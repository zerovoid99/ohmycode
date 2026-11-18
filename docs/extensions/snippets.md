# Snippets

Snippets are templates inserted by typing a short prefix: `fn` then Tab writes a whole function
with the cursor on its name. An extension can ship snippets for any language — its own or a
built-in one — in VS Code's snippet format, so existing VS Code snippet files work unchanged.

## Contributing snippets

List the files under `contributes.snippets` in `extension.json`:

```json
{
  "contributes": {
    "languages": [{ "id": "toy", "extensions": [".toy"] }],
    "snippets": [
      { "language": "toy", "path": "./snippets/toy.json" },
      { "language": "markdown", "path": "./snippets/markdown.json" },
      { "path": "./snippets/everywhere.code-snippets" }
    ]
  }
}
```

| Field | Meaning |
| --- | --- |
| `language` | The language id the snippets are for (built-in ids work in either spelling: `shellscript` or `shell`). Leave it out, or use `"*"`, for every language — then each snippet's `scope` can narrow it. |
| `path` | The file, relative to the extension's folder (it must be inside it; installing checks). |

The snippets are there as soon as the extension is installed and enabled — the extension doesn't
have to activate, and it doesn't need code at all. Disabling or uninstalling it removes them.
Changes to the files are picked up the next time completion is asked for.

## The snippet file

A JSON object (comments and trailing commas allowed) with one entry per snippet, keyed by its name:

```jsonc
{
  "Function": {
    "prefix": ["fn", "function"],
    "body": [
      "fn ${1:name}(${2:params}) do",
      "\t$0",
      "end"
    ],
    "description": "A function"
  },
  "Print": {
    "prefix": "pr",
    "body": "print(\"${1:$TM_SELECTED_TEXT}\")$0",
    "description": "Print a value"
  },
  "Header": {
    "prefix": "header",
    "body": ["$LINE_COMMENT ${TM_FILENAME_BASE} — ${CURRENT_YEAR}", "$0"],
    "scope": "toy,python"
  }
}
```

| Field | Meaning |
| --- | --- |
| `prefix` | What's typed to offer it: a string, or several. Required. |
| `body` | The text: a string, or an array of lines (joined with line breaks). Required. |
| `description` | Shown beside the prefix in the completion list (the name is used without one). |
| `scope` | Comma-separated language ids it's for; only used in files listed without a `language`. |

### Body syntax

| Syntax | Meaning |
| --- | --- |
| `$1`, `$2`, … | Tab stops, visited in order with Tab. The same number in several places is edited together. |
| `${1:default}` | A tab stop with text already in it, selected when reached. Placeholders nest: `${1:a ${2:b}}`. |
| `${1\|one,two,three\|}` | A choice. |
| `$0` | Where the cursor ends. |
| `$NAME`, `${NAME:default}` | A variable: `TM_SELECTED_TEXT`, `TM_CURRENT_LINE`, `TM_CURRENT_WORD`, `TM_LINE_INDEX`, `TM_LINE_NUMBER`, `TM_FILENAME`, `TM_FILENAME_BASE`, `TM_DIRECTORY`, `TM_FILEPATH`, `CLIPBOARD`, `CURRENT_YEAR`, `CURRENT_YEAR_SHORT`, `CURRENT_MONTH`, `CURRENT_MONTH_NAME`, `CURRENT_MONTH_NAME_SHORT`, `CURRENT_DATE`, `CURRENT_DAY_NAME`, `CURRENT_DAY_NAME_SHORT`, `CURRENT_HOUR`, `CURRENT_MINUTE`, `CURRENT_SECOND`, `CURRENT_SECONDS_UNIX`, `RANDOM`, `RANDOM_HEX`, `UUID`, `LINE_COMMENT`, `BLOCK_COMMENT_START`, `BLOCK_COMMENT_END`. |
| `\$`, `\}`, `\\` | A literal `$`, `}` or `\`. |
| Tab characters | Become the file's indentation (tabs or spaces); every line keeps the indentation of the line the snippet is inserted on. |

`LINE_COMMENT` and the block comment variables come from the language's
[`comments` configuration](language-support.md#comments) for contributed languages.

## Where snippets show

- **Completion:** while typing a word, snippets whose prefix matches are listed (after the
  language server's and the providers' items; not after a trigger character such as `.`).
  Enter or Tab inserts one.
- **Insert Snippet…** (palette) lists every snippet for the file's language by name.

When the user, the folder (`.omc/snippets/<language>.json`, `.vscode/*.code-snippets`) and an
extension define the same prefix, the user's and the folder's come first in the list; any of
them replaces a built-in snippet with that prefix.

## Snippets from code

Snippets inserted by a completion item are written with `SnippetString`, which escapes text for
you:

```ts
const item = new omc.CompletionItem("loop", omc.CompletionItemKind.Snippet);
item.insertText = new omc.SnippetString("for ")
  .appendPlaceholder("item")
  .appendText(" in ")
  .appendChoice(["list", "range(10)"])
  .appendText(" do\n\t")
  .appendTabstop(0)
  .appendText("\nend");
```

See [completion](providers.md#completion).

## See also

- [Language support](language-support.md): declaring the language the snippets are for.
- [Language feature providers](providers.md): completion items with snippets.
- [Language servers](language-servers.md).
- [Cookbook](cookbook.md#snippets) and the [developer guide](README.md).
