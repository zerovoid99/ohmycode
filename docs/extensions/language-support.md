# Language support

An extension can teach Oh My Code a new language — or add to one it already knows — without
writing any code: a `contributes.languages` entry in `extension.json` says which files are in the
language, and a `language-configuration.json` says how the editor treats their text (comments,
brackets, what closes itself, folding, words, indentation). Language servers, providers and
snippets build on top of that and are described in their own guides.

This guide covers:

- [Declaring a language](#declaring-a-language) (`contributes.languages`)
- [How a file's language is chosen](#how-a-files-language-is-chosen), `files.associations` and
  *Change Language Mode*
- [`language-configuration.json`](#language-configurationjson), field by field
- [Extending a built-in language](#extending-a-built-in-language)
- [Activation](#activation) and [built-in language ids](#built-in-language-ids)

Colors are in their own guide, [Syntax highlighting](syntax-highlighting.md).
`ExtensionAPI/examples/toy-language` is a complete, working example of everything here, and
*Extensions: New Language Support Extension…* creates a new extension from it.

## Declaring a language

```json
{
  "id": "acme.toy",
  "name": "Toy Language",
  "version": "1.0.0",
  "main": "dist/extension.js",
  "contributes": {
    "languages": [
      {
        "id": "toy",
        "aliases": ["Toy", "toy"],
        "extensions": [".toy", ".d.toy"],
        "filenames": ["Toyfile"],
        "filenamePatterns": ["*.toy.txt", "**/toys/*.cfg"],
        "firstLine": "^#!.*\\btoy\\b",
        "configuration": "./language-configuration.json"
      }
    ]
  }
}
```

| Field | Meaning |
| --- | --- |
| `id` | The language id: what `TextDocument.languageId`, `DocumentSelector`s, `onLanguage:<id>` and language servers use. Required. Use VS Code's id when there is one (`rust`, `ruby`, `elixir`). |
| `aliases` | Names for people. The first is what the status bar and the language picker show; the others are accepted by `files.associations`. |
| `extensions` | File extensions, with the dot (`.toy`). Several dots work (`.d.toy`): the longest match wins. Matching ignores case. |
| `filenames` | Whole file names (`Toyfile`, `.toyrc`), case-sensitive. |
| `filenamePatterns` | Globs. Without a `/` a glob matches the file name (`*.toy.txt`); with one it matches the path (`**/toys/*.cfg`). `*`, `**`, `?`, `[abc]` and `{a,b}` work. |
| `firstLine` | A regular expression the file's first line is tested against: a shebang (`^#!.*\\bnode\\b`) or a modeline. Used only when nothing else matched. |
| `configuration` | A `language-configuration.json`, relative to the extension's folder (it must be inside it). |

`extension.json` is checked when the extension is installed: a language without an `id`, or a
configuration path outside the extension's folder, is an error. A configuration file that's
missing or isn't valid JSON doesn't stop the extension: the language works without it, and why
is in the extension's log (Extensions sidebar → the extension → Log).

## How a file's language is chosen

When a file opens (and again when extensions or settings change), the first of these that
matches decides:

1. **Change Language Mode** for that file (see below), for as long as the window is open.
2. **`files.associations`**: the folder's `.omc/settings.json` over the app's (*Settings ▸
   Languages ▸ File Associations*). A pattern without a `/` matches the file name; one with a
   `/` matches the path. Whole names win over globs, longer globs over shorter ones. The value
   is a language id or alias.
3. The extensions' **`filenames`**, then **`filenamePatterns`**, then **`extensions`**, then
   **`firstLine`**. When two extensions claim the same file, the one later in the Extensions list
   wins (one installed while the app is running counts as last until the app restarts).
4. The **built-in** table (`.swift`, `.ts`, `.py`, … — see below); anything else is Plain Text.

```jsonc
// .omc/settings.json
{
  "files.associations": {
    "*.tpl": "html",
    "Justfile": "shellscript",
    "**/config/*.conf": "toy"
  }
}
```

**Change Language Mode** — click the language's name in the status bar, or run *Change Language
Mode* from the palette — lists every language, built in and contributed, by name. Picking one
reopens the file in it: syntax colors, the Outline, folding and the language server follow, and
extensions hear `onDidCloseTextDocument` then `onDidOpenTextDocument` with the new
`languageId`. *Auto Detect* goes back to what the rules above say.

Extensions can do the same with `omc.languages.setTextDocumentLanguage(document, "toy")`, and list
the known ids with `omc.languages.getLanguages()`.

## language-configuration.json

The file is VS Code's format, so configurations from VS Code extensions work as they are.
Comments and trailing commas are allowed. Every field is optional; what's missing keeps the
editor's built-in behavior. Regular expressions are strings (or `{ "pattern": "…", "flags": "i" }`)
in JavaScript syntax, which macOS's regular expressions share for everything these files use
(classes, anchors, lookahead, `\b`).

A complete example:

```jsonc
{
  "comments": {
    "lineComment": "#",
    "blockComment": ["#[", "]#"]
  },
  "brackets": [["(", ")"], ["[", "]"], ["{", "}"]],
  "autoClosingPairs": [
    { "open": "(", "close": ")" },
    { "open": "[", "close": "]" },
    { "open": "\"", "close": "\"", "notIn": ["string", "comment"] },
    { "open": "/**", "close": " */", "notIn": ["string"] }
  ],
  "surroundingPairs": [["(", ")"], ["[", "]"], ["\"", "\""], ["*", "*"]],
  "autoCloseBefore": ";:.,=}])> \n\t",
  "folding": {
    "markers": { "start": "^\\s*#\\s*region\\b", "end": "^\\s*#\\s*endregion\\b" },
    "offSide": true
  },
  "wordPattern": "[A-Za-z_][A-Za-z0-9_-]*",
  "indentationRules": {
    "increaseIndentPattern": "\\bdo\\s*$",
    "decreaseIndentPattern": "^\\s*end\\b",
    "indentNextLinePattern": "^\\s*if\\b[^{]*$",
    "unIndentedLinePattern": "^\\s*#"
  },
  "onEnterRules": [
    { "beforeText": "^\\s*#(?!\\[).*$", "action": { "indent": "none", "appendText": "# " } },
    { "beforeText": "^\\s*/\\*\\*(?!/).*$", "afterText": "^\\s*\\*/$",
      "action": { "indent": "indentOutdent", "appendText": " * " } }
  ]
}
```

### comments

| Field | Used by |
| --- | --- |
| `lineComment` | *Toggle Line Comment* (⌘/): added at the least-indented line's column, removed with the space after it. Snippets' `$LINE_COMMENT` variable. |
| `blockComment` | `[open, close]`. *Toggle Line Comment* in a language without a line comment wraps the lines in it; snippets' `$BLOCK_COMMENT_START` / `$BLOCK_COMMENT_END`. |

Setting `comments` replaces the built-in comments for the language entirely: `{ "blockComment":
["<!--", "-->"] }` alone means the language has no line comment.

### brackets

`[open, close]` pairs of single characters. They're what bracket matching outlines (the
bracket beside the cursor and its match), what *Go to Bracket* jumps between, what Enter
indents after, and — when `autoClosingPairs` isn't given — the pairs that close themselves.
Without `brackets`, the editor uses `()`, `[]` and `{}`.

### autoClosingPairs

What closes itself as you type (with *Settings ▸ Editor ▸ Close brackets and quotes automatically* on).
Each entry is `[open, close]` or `{ "open", "close", "notIn" }`:

- `open` may be longer than one character (`/**`): the pair closes when what you just typed makes
  the text before the cursor end with it.
- `notIn` lists where it doesn't close: `"string"`, `"comment"`. The editor works out where the
  cursor is from the line: quotes from the single-character pairs whose open and close are the
  same (`"`, `'`, `` ` ``, with `\` escapes) and the line comment.
- A quote doesn't close right after a letter, digit or `_` (`don't`).

With the configuration's pairs, a closer that's already next is stepped over, and Backspace
between an empty pair deletes both — for the single-character pairs.

### autoCloseBefore

The characters a pair may close in front of. When the character after the cursor isn't one of
them (a letter, say), typing an opener just inserts it, so `(word` doesn't become `()word`.
Default: `;:.,=}])> ` plus newline and tab.

### surroundingPairs

With text selected, typing a pair's opener wraps the selection in the pair instead of replacing
it. Without `surroundingPairs`, the auto-closing pairs wrap.

### folding

| Field | Meaning |
| --- | --- |
| `markers.start`, `markers.end` | Lines matching them begin and end a fold region (`# region` … `# endregion`), nested. Used when neither the language server nor an extension's `FoldingRangeProvider` (nor a syntax tree) gives regions. |
| `offSide` | The language is indentation-based (Python-like). Accepted for compatibility: the editor already folds by indentation wherever no other region applies. |

### wordPattern

What a word is: double-clicking selects it, completion uses it as the prefix it replaces and
filters by, and symbol highlights and *Rename* start from it. Without it, a word is letters,
digits and `_`.

### indentationRules

| Field | Effect |
| --- | --- |
| `increaseIndentPattern` | Enter after a line (the part before the cursor) matching it indents the new line one level. |
| `decreaseIndentPattern` | Typing that makes a line match it moves the line one level shallower than the line above (or level with it, when the line above increased the indent). Enter between an increasing line and text matching it (`do|end`) puts that text on its own line, outdented. |
| `indentNextLinePattern` | Like `increaseIndentPattern`, for the next line only: the line after it goes back. |
| `unIndentedLinePattern` | Lines that don't affect indentation (comments): Enter keeps their indentation. |

### onEnterRules

Rules tried in order when Enter is pressed; the first whose patterns match decides, before
`indentationRules`.

| Field | Meaning |
| --- | --- |
| `beforeText` | Must match the line's text before the cursor. |
| `afterText` | If given, must match the line's text after the cursor. |
| `previousLineText` | If given, must match the line above. |
| `action.indent` | `"none"` (keep the indentation), `"indent"` (one level deeper), `"outdent"` (one shallower), `"indentOutdent"` (the cursor goes on a deeper line, and the text after it on its own line at the old indentation — for `{|}`). VS Code's numeric `indentAction` (0–3) works too. |
| `action.appendText` | Typed after the indentation on the new line (`"# "` to continue a comment). |
| `action.removeText` | Characters to take off the indentation first. |

## Extending a built-in language

A contribution whose `id` is a language the editor knows adds to it rather than defining a new
one. Built-in languages are known by both their VS Code ids and the editor's own (`typescriptreact`
or `tsx`, `shellscript` or `shell`, `objective-c` or `objc`).

```json
"languages": [
  { "id": "javascript", "extensions": [".mjsx", ".es6"] },
  { "id": "plaintext", "configuration": "./plaintext-configuration.json" }
]
```

- New `extensions`, `filenames`, `filenamePatterns` and `firstLine` send more files to the language.
- A `configuration` replaces the built-in behavior for the parts it sets (a `brackets` list for
  Plain Text, a different `lineComment`); everything else stays.
- An `aliases` entry renames it in the status bar and the picker.

The language keeps its syntax colors, Outline and language server.

## Activation

A file of a language an extension **adds** activates that extension, as VS Code does — no
`activationEvents` entry is needed. For built-in languages, list `onLanguage:<id>`
(`"onLanguage:javascript"`). Both happen again when *Change Language Mode* puts a file in the
language.

## Built-in language ids

| Language | id (VS Code's) | Files |
| --- | --- | --- |
| C | `c` | `.c`, `.h` |
| C++ | `cpp` | `.cc`, `.cpp`, `.cxx`, `.hpp`, `.hh` |
| CSS | `css` | `.css`, `.scss` |
| Go | `go` | `.go` |
| HTML | `html` | `.html`, `.htm` |
| HTTP | `http` | `.http`, `.rest` |
| JavaScript | `javascript` | `.js`, `.mjs`, `.cjs`, `.jsx` |
| JSON | `json` | `.json` |
| Markdown | `markdown` | `.md`, `.markdown` |
| Objective-C | `objective-c` | `.m`, `.mm` |
| Plain Text | `plaintext` | everything else |
| Python | `python` | `.py` |
| Rust | `rust` | `.rs` |
| Shell Script | `shellscript` | `.sh`, `.bash`, `.zsh` |
| SQL | `sql` | `.sql` |
| Swift | `swift` | `.swift` |
| TOML | `toml` | `.toml` |
| TypeScript | `typescript` | `.ts`, `.mts`, `.cts` |
| TypeScript JSX | `typescriptreact` | `.tsx` |
| YAML | `yaml` | `.yml`, `.yaml` |

A new language opens with plain text colors until something colors it: a TextMate grammar or a
tree-sitter parser (`contributes.grammars`, `contributes.treeSitterGrammars`; see
[Syntax highlighting](syntax-highlighting.md)), or a language server's or an extension's
semantic tokens.

## See also

- [Syntax highlighting](syntax-highlighting.md): TextMate grammars and tree-sitter parsers.
- [Language servers](language-servers.md): starting a server for your language.
- [Language feature providers](providers.md): completion, definitions, symbols and the rest, in code.
- [Snippets](snippets.md): `contributes.snippets`.
- [The manifest](manifest.md) and the [developer guide](README.md): everything else an extension can declare.
