# Syntax highlighting

An extension can color a language's files in two ways: with a **TextMate grammar** — the
`.tmLanguage.json` files VS Code, Sublime Text and TextMate use, so the grammars of thousands of
existing extensions work as they are — or with a **tree-sitter parser** built as a native library,
the way the editor's own Swift, TypeScript, Python, Rust, Go and JSON highlighting works. Either
way the colors come from the active theme, and a language server's (or an extension's) semantic
tokens are still drawn on top.

This guide covers:

- [Which one to choose](#which-one-to-choose)
- [TextMate grammars](#textmate-grammars): `contributes.grammars`, the grammar format, embedded
  languages and injections, and [what the regex engine supports](#regular-expressions)
- [Scopes and theme colors](#scopes-and-theme-colors)
- [Tree-sitter parsers](#tree-sitter-parsers): `contributes.treeSitterGrammars`, building the
  library, queries, ABI versions and the [`nativeCode` permission](#the-nativecode-permission)
- [Which highlighting a language gets](#which-highlighting-a-language-gets) when there are several
- [Importing a VS Code language extension](#importing-a-vs-code-language-extension)
- [Debugging](#debugging) with *Developer: Inspect Editor Tokens and Scopes*
- [Performance](#performance) and [limitations](#limitations)

`ExtensionAPI/examples/toy-language` colors `.toy` files with a TextMate grammar
(`syntaxes/toy.tmLanguage.json`); *Extensions: New Language Support Extension…* starts a new
extension from it.

## Which one to choose

| | TextMate grammar | Tree-sitter parser |
| --- | --- | --- |
| What you write | JSON (or a property list) of regular expressions | A `grammar.js`, generated to C by the tree-sitter CLI, built into a `.dylib` |
| Already exists for | Nearly every language (any VS Code language extension) | Many languages (`tree-sitter-<language>` repositories) |
| Accuracy | Line by line, by patterns: good for most code, wrong on constructs patterns can't see | A real parse of the file: precise, and it knows the structure |
| Also gives | Colors | Colors, folding (`folds.scm`), and the generic structure features (sticky scroll headers, bracket-based folding) |
| Installing | Nothing to build; no permission | A native library per extension, built for Apple silicon and Intel; needs the `nativeCode` permission |
| Safety | Data only | Native code running inside the editor |

Start with a TextMate grammar: it's data, it's portable, and there's probably one already. Choose
tree-sitter when you need its precision or its structure, and are happy to ship (and sign) a
binary.

## TextMate grammars

### Contributing a grammar

```json
{
  "id": "acme.toy",
  "name": "Toy Language",
  "version": "1.0.0",
  "main": "dist/extension.js",
  "contributes": {
    "languages": [{ "id": "toy", "extensions": [".toy"], "configuration": "./language-configuration.json" }],
    "grammars": [
      {
        "language": "toy",
        "scopeName": "source.toy",
        "path": "./syntaxes/toy.tmLanguage.json",
        "embeddedLanguages": { "meta.embedded.block.sql": "sql" },
        "tokenTypes": { "string.template": "other" }
      },
      {
        "scopeName": "toy.todo.injection",
        "path": "./syntaxes/todo.tmLanguage.json",
        "injectTo": ["source.toy"]
      }
    ]
  }
}
```

| Field | Meaning |
| --- | --- |
| `language` | The language id it colors. Omit it for a grammar that's only included by others (`source.sql` for an embedded block) or only injected. |
| `scopeName` | The grammar's root scope: `source.<lang>` for code, `text.<lang>` for markup. Must match the file's `scopeName`. Required. |
| `path` | The grammar file, relative to the extension's folder (it must be inside it). `.tmLanguage.json`, or `.tmLanguage` / `.plist` (a property list). |
| `embeddedLanguages` | Scopes of embedded code → the language id it's in. Shown by *Inspect Editor Tokens and Scopes*. |
| `tokenTypes` | Accepted for compatibility with VS Code (it tunes bracket matching there); not used. |
| `injectTo` | Root scopes of the grammars this one is injected into; its own `injectionSelector` says where (see [Injections](#injections)). |
| `override` | `true`: used instead of the editor's built-in highlighting for `language` (see [precedence](#which-highlighting-a-language-gets)). Default `false`. |

Installing checks that every `path` is inside the extension's folder. A grammar that's missing or
doesn't parse doesn't stop the extension: the language stays uncolored, and why is in the
extension's log (Extensions sidebar → the extension → Log).

### The grammar file

The format is TextMate's, as VS Code reads it. A grammar has a `scopeName`, top-level `patterns`
and a `repository` of named rules:

```json
{
  "scopeName": "source.toy",
  "patterns": [{ "include": "#comments" }, { "include": "#strings" }, { "include": "#keywords" }],
  "repository": {
    "keywords": { "match": "\\b(?:if|else|do|end)\\b", "name": "keyword.control.toy" },
    "comments": {
      "begin": "#", "end": "$", "name": "comment.line.number-sign.toy",
      "beginCaptures": { "0": { "name": "punctuation.definition.comment.toy" } }
    },
    "strings": {
      "begin": "\"", "end": "\"", "name": "string.quoted.double.toy",
      "patterns": [{ "match": "\\\\.", "name": "constant.character.escape.toy" }]
    }
  }
}
```

Every rule construct works:

- **`match`** with `name`, and `captures` for its groups (`"1": { "name": "…" }`; `"0"` is the
  whole match).
- **`begin` / `end`** rules, which can span lines, with `beginCaptures`, `endCaptures` (or
  `captures` for both), `name` (the whole region, delimiters included), `contentName` (only
  what's between them), nested `patterns`, and `applyEndPatternLast`.
- **`begin` / `while`** rules (Markdown's block quotes and lists): the region continues while
  each following line matches `while`; `whileCaptures` colors that part.
- **Captures with `patterns`**: a capture's text is tokenized again with its own patterns (an
  escape inside a captured string).
- **`include`**: `#name` (a repository rule; repositories nest), `$self` (this grammar),
  `$base` (the grammar of the document, from inside an embedded one), `source.other` (another
  grammar) and `source.other#name` (a rule of another grammar).
- **Back-references** in `end` and `while`: `"begin": "<<(\\w+)", "end": "^\\1$"` ends a heredoc
  on its own marker.
- **Anchors**: `\G` matches where the previous match ended (the end of `begin` for the first
  pattern inside a region), `\A` only at the start of the file.
- **Names from the text**: `"name": "entity.name.tag.$1"` or `"${1:/downcase}"` / `"${1:/upcase}"`.
- A `name` with spaces adds several scopes.

### Embedded languages

Code of another language inside yours — SQL in a string, JavaScript in an HTML `<script>`
element — is a `begin`/`end` rule that includes that language's grammar:

```json
{
  "begin": "(sql)(\")", "end": "\"",
  "contentName": "meta.embedded.block.sql",
  "patterns": [{ "include": "source.sql" }]
}
```

The included grammar must be installed too (by your extension, or another one): a grammar that
isn't there is left out and the text stays the host's color. Inside the embedded grammar, `$self`
is that grammar and `$base` is still yours. Map the scope to its language in `embeddedLanguages`
so tools can tell which language the caret is in.

### Injections

An injection adds patterns to other rules' regions, chosen by a scope selector — highlighting
`TODO` in every comment, or URLs in strings. A grammar can inject into its own documents:

```json
"injections": {
  "L:source.toy comment -comment.block.documentation": {
    "patterns": [{ "match": "\\b(?:TODO|FIXME)\\b", "name": "keyword.other.todo.toy" }]
  }
}
```

or a separate grammar can inject into others, listed with `injectTo` in `extension.json` and
saying where with `injectionSelector`:

```json
{
  "scopeName": "toy.todo.injection",
  "injectionSelector": "L:comment",
  "patterns": [{ "match": "\\bTODO\\b", "name": "keyword.other.todo" }]
}
```

Selectors: scopes separated by spaces must appear in that order (each is a prefix: `comment`
matches `comment.line.toy`); `-scope` excludes; `a | b` and `(…)` group; commas separate
alternatives. `L:` makes the injection win over the region's own patterns when both match at
the same place, `R:` (the default) makes it lose. Injections only apply where the tokenizer looks
for patterns: inside a `begin`/`end` region, not inside a single `match`.

### Regular expressions

TextMate grammars are written for the Oniguruma regex engine; the editor matches with ICU (the
engine behind `NSRegularExpression`). Most patterns mean the same in both. These differences are
translated for you:

| Oniguruma | Becomes | Why |
| --- | --- | --- |
| `\h`, `\H` | `[0-9a-fA-F]`, `[^0-9a-fA-F]` | A hex digit in Oniguruma; horizontal space in ICU |
| `(?m)`, `(?m:…)` | `(?s)`, `(?s:…)` | "Dot matches newline" in Oniguruma's Ruby syntax |
| `(?x)` with spaces and `# comments` | the pattern without them | ICU would also drop spaces inside `[…]`; Oniguruma keeps them |
| `a{,3}` | `a{0,3}` | ICU needs the lower bound |
| a `{` or `}` that isn't a quantifier | `\{`, `\}` | ICU rejects a bare brace |
| `\p{^Alpha}` | `\P{Alpha}` | ICU's negation |
| `(?<my_name>…)`, `\k<my_name>`, a name used twice | `(?<myname>…)`, … | ICU names are letters and digits, each used once |
| `[` inside a class (`[a[]`) | `\[` | ICU would start a nested class |

`^` and `$` match at line starts and ends, `.` doesn't match a line break, and the possessive
(`a++`), atomic (`(?>…)`), look-ahead and bounded look-behind constructs, `\b`, `\z`, `\Z`,
`\x{…}`, `\p{…}`, POSIX classes (`[[:alpha:]]`) and class intersection (`[a-z&&[^aeiou]]`) work
as they are. `\G` and `\A` are handled by the tokenizer.

**Not supported** — a pattern with one of these fails to compile, its rule is skipped (the rest
of the grammar works) and the pattern is logged once:

- `\K` (keep), subexpression calls (`\g<name>`, `\g<1>`), conditionals (`(?(1)…|…)`) and the
  absent operator (`(?~…)`).
- Look-behind of unbounded length (`(?<=a+)`).
- A nested class other than after `&&` (`[a-z[0-9]]`: write `[a-z0-9]`).
- `(?x)` turned on inside a group is applied to the rest of the pattern, not only to the group.

### YAML and other formats

Grammars written in YAML (`.tmLanguage.yaml`, `.YAML-tmLanguage`) aren't read: convert them to
JSON (`npx js-yaml grammar.tmLanguage.yaml > grammar.tmLanguage.json`). VS Code extensions ship
the JSON already.

## Scopes and theme colors

Tokens get **scopes**, outermost first: in `"hi\n"`, the `\n` is
`source.toy string.quoted.double.toy constant.character.escape.toy`. Use the standard names (the
same ones VS Code and Sublime Text themes color), ending with your language:

| Scope | For |
| --- | --- |
| `comment.line`, `comment.block`, `comment.block.documentation` | Comments |
| `string.quoted.single`, `.double`, `.triple`, `string.unquoted`, `string.regexp` | Strings |
| `constant.character.escape` | Escapes in strings |
| `constant.numeric` | Numbers |
| `constant.language` | `true`, `false`, `null` |
| `keyword.control` | `if`, `return`, `import` |
| `keyword.operator` | Operators |
| `storage.type`, `storage.modifier` | `fn`, `class`, `let`; `static`, `public` |
| `entity.name.function`, `entity.name.type`, `entity.name.class` | Names being declared |
| `support.function`, `support.type`, `support.class` | Built-in or library functions and types |
| `variable.parameter`, `variable.language`, `variable.other.property` | Parameters, `self`/`this`, properties |
| `entity.name.tag`, `entity.other.attribute-name` | Markup tags and attributes |
| `punctuation.definition.string.begin`, `punctuation.definition.comment` | Delimiters (colored with what they delimit) |
| `meta.*` | Regions (`meta.function`, `meta.embedded.block.sql`): structure, rarely colored |
| `invalid.illegal` | Errors |

How scopes become colors depends on the theme:

- **Imported VS Code themes** (Settings ▸ Appearance ▸ Import VS Code Theme) color them with
  their `tokenColors`, the way VS Code does: the innermost scope that any rule matches decides;
  among rules for it, the one naming more of the scope wins (`string.quoted` over `string`), then
  the one with more ancestors (`meta.tag string` over `string`), then the later one. Selectors
  with ancestors (`meta.embedded string`) and exclusions (`source -comment keyword`) work.
- **Built-in themes** map common scopes to their syntax roles (the colors tree-sitter captures
  get): `comment` → comment; `string`, `punctuation.definition.string` → string;
  `constant.numeric` → number; `constant.character.escape` → number; `constant.language`,
  `keyword`, `storage`, `variable.language`, `entity.name.tag`, `markup.heading` → keyword;
  `entity.name.function`, `support.function` → function; `entity.name.type`,
  `entity.name.class`, `support.type`, `support.class`, `entity.other.inherited-class` → type;
  `variable.other.property`, `support.type.property-name`, `meta.object-literal.key` → property;
  `entity.other.attribute-name`, `storage.type.annotation` → attribute. Other scopes take the
  color of the nearest enclosing scope that has one; `keyword.operator`, `variable.parameter`
  and `meta.*` alone stay the text color.

Strings and comments found by a grammar also keep brackets inside them out of bracket matching
and bracket pair colors.

## Tree-sitter parsers

### Contributing a parser

```json
{
  "id": "acme.foo",
  "name": "Foo",
  "version": "1.0.0",
  "main": "dist/extension.js",
  "permissions": ["nativeCode"],
  "contributes": {
    "languages": [{ "id": "foo", "extensions": [".foo"] }],
    "treeSitterGrammars": [
      {
        "language": "foo",
        "library": "./parser/libtree-sitter-foo.dylib",
        "symbol": "tree_sitter_foo",
        "queries": {
          "highlights": "./queries/highlights.scm",
          "folds": "./queries/folds.scm",
          "injections": "./queries/injections.scm",
          "locals": "./queries/locals.scm",
          "indents": "./queries/indents.scm"
        }
      }
    ]
  }
}
```

| Field | Meaning |
| --- | --- |
| `language` | The language id it parses. Required. |
| `library` | The parser, a dynamic library inside the extension's folder (a link pointing outside it is refused). Required. |
| `symbol` | The parser's language function: `tree_sitter_<name>` (the build script prints it). Required. |
| `queries.highlights` | Captures to color (`@keyword`, `@string`, `@function.method`, …). Without it the file isn't colored, but still gets the parser's structure. |
| `queries.folds` | `@fold` captures: the folding ranges (see [Folding](#folding)). |
| `queries.injections`, `locals`, `indents` | Accepted, not used yet (see [Limitations](#limitations)). |
| `override` | `true`: used instead of the editor's built-in highlighting for `language`. Default `false`. |

### Building the library

`ExtensionAPI/tools/build-tree-sitter-grammar.sh` compiles a grammar's generated `src/parser.c`
(and `src/scanner.c` or `scanner.cc` if it has one) into a universal (Apple silicon and Intel)
library and signs it ad hoc:

```sh
git clone https://github.com/tree-sitter-grammars/tree-sitter-foo
cd tree-sitter-foo
tree-sitter generate          # only if the repository doesn't commit src/parser.c
/path/to/ExtensionAPI/tools/build-tree-sitter-grammar.sh . ../my-extension/parser/libtree-sitter-foo.dylib
# Built ../my-extension/parser/libtree-sitter-foo.dylib
#   architectures: x86_64 arm64
#   symbol: tree_sitter_foo
cp queries/highlights.scm ../my-extension/queries/
```

It needs the Xcode command line tools (`clang`, `codesign`). `ARCHS="arm64"` builds for one
architecture, `CFLAGS` adds compiler flags, and `SIGN_IDENTITY="Developer ID Application: …"`
signs it with your identity for distribution.

### Queries

Highlight queries are tree-sitter's usual `highlights.scm`; the capture names color by the same
roles as the built-in grammars: `@keyword` (and `@keyword.function`, `@conditional`, `@repeat`,
`@include`, `@exception`, `@boolean`, `@constant.builtin`, `@variable.builtin`, `@tag`), `@string`
(`@character`, `@string.special`), `@escape`, `@comment`, `@number` (`@float`, `@constant`),
`@type` (`@constructor`, `@module`, `@namespace`), `@function` (`@method`), `@property`
(`@field`, `@variable.member`), `@attribute` (`@label`). A dotted capture falls back to its
first part (`@function.method.call` → `@function`); later matches win over earlier ones.
Predicates (`#match?`, `#eq?`, `#any-of?`) work. Queries from nvim-treesitter or Helix mostly
work as they are; a query that doesn't compile against your parser (a node type it doesn't
have) is reported in the extension's log.

### Folding

With `folds.scm`, every `@fold` capture folds from its first line to its last (to the line before,
when that line is its closing bracket):

```scheme
[(block) (object) (array) (comment)] @fold
```

Without it, a tree-sitter language folds by its brackets, like the built-in ones, and a
TextMate-colored language folds by its language configuration's `folding.markers` and by
indentation. A language server's or extension's folding ranges come first in both cases.

### ABI versions

A generated `parser.c` targets an ABI version (its `LANGUAGE_VERSION`). The editor's tree-sitter
runtime (0.25) reads ABI **13 through 15**, what recent tree-sitter CLIs generate (ABI 14 since
0.20.7, ABI 15 since 0.25). A parser outside that range isn't loaded, and the log
says which version it has: regenerate it with a matching CLI.

### The nativeCode permission

A parser library is native code: once loaded it runs inside the editor with the editor's access
to your files, and it can't be unloaded until the app quits. So an extension with
`treeSitterGrammars` must list `"nativeCode"` in `permissions` (installing refuses it otherwise),
and the install dialog says it will *load native code into Oh My Code*. Only install such
extensions from people you trust, as you would an app.

The editor also refuses a `library` outside the extension's folder (links are followed first),
and a `symbol` that isn't a `tree_sitter_<name>` function.

The editor's signature allows loading libraries signed by other developers (or ad hoc): that's
what lets an extension's parser load. If macOS refuses a library you downloaded ("not verified"),
remove the quarantine flag (`xattr -d com.apple.quarantine parser/*.dylib`) or rebuild it
locally with the script.

## Which highlighting a language gets

A language can have several: the editor's own (tree-sitter for Swift, JavaScript, TypeScript,
Python, Rust, Go and JSON; hand-written for HTTP and SQL), a contributed tree-sitter parser, and
a contributed TextMate grammar. The editor picks:

1. The one chosen for the language in *Settings ▸ Languages ▸ Highlighting*, if it's there.
2. For a language the editor highlights itself: a contribution with `"override": true`
   (tree-sitter before TextMate), else the built-in highlighting.
3. Otherwise: a contributed tree-sitter parser, then a contributed TextMate grammar.

If the one picked can't be loaded (a parser with the wrong ABI), the next one is used. When
several extensions contribute the same kind for a language, the last one in the Extensions list
wins. Open
files switch when extensions are enabled, disabled or installed, and when you pick another in
Settings. The choice is saved as `languages.highlighting` (language id → `builtin`,
`tree-sitter` or `textmate`) and travels with profiles.

Semantic tokens from a language server or an extension's provider are drawn over whichever
highlighting is used.

## Importing a VS Code language extension

*Extensions: Import VS Code Language Extension…* (palette, or **+** in the Extensions sidebar)
takes an unpacked VS Code extension — a folder with its `package.json`, or a `.vsix` unzipped
(`unzip foo.vsix -d foo`; the files are under `extension/`) — and installs it as an Oh My Code
extension:

- `contributes.languages` (with their `language-configuration.json`), `contributes.grammars`
  and `contributes.snippets` are translated into `extension.json`, and the files they name are
  copied, with the license and readme.
- The id is `<publisher>.<name>` from `package.json`, and the install dialog shows it as usual.
- Its code (`main`: completion, commands, debuggers) isn't brought over — VS Code's API isn't
  this one — nor are YAML grammars or files outside the extension; a notification lists what
  was left out.

To keep an imported extension up to date, import the new version again: it replaces the
installed one.

## Debugging

**Developer: Inspect Editor Tokens and Scopes** (palette) shows, for the text under the caret:

```
“greet”
language: Toy (toy)
highlighting: TextMate grammar source.toy
textmate scopes:
  entity.name.function.toy
  source.toy
semantic token: none
foreground: #326D74 (scope → function)
```

— the language, which highlighting colors it, the TextMate scopes (innermost first) or the
tree-sitter captures and syntax nodes, the embedded language, the semantic token over it, and
the color that wins with what decided it (the theme rule's selector for an imported theme).
**Copy** puts it on the clipboard for a bug report.

If nothing is colored:

- Check the file's language in the status bar, and *Settings ▸ Languages ▸ Highlighting* for
  what the language uses.
- Read the extension's log: a grammar file that doesn't parse, a `scopeName` that doesn't match
  `extension.json`, a parser that doesn't load or a query that doesn't compile are reported
  there. A regex the engine can't compile is reported in the system log (`OMC: TextMate pattern
  not supported…`; Console.app, process *Oh My Code*).
- During development, install the extension for development and use *Extensions: Reload* after
  editing the grammar or the queries: open files pick up the change. A rebuilt parser library is
  only loaded again after restarting the app (a loaded library can't be replaced).

## Performance

- Highlighting runs in the background; typing never waits for it.
- TextMate grammars tokenize line by line, and only as far as the screen (and the minimap)
  shows. Each line's end state is kept: an edit re-tokenizes from its line until a line ends in
  the same state as before — typing inside a function re-tokenizes one line, opening a block
  comment re-tokenizes until it closes.
- Compiled patterns are shared by every file and window. A grammar file is read once, and its
  rules are compiled as a file of the language is first highlighted.
- A line longer than 20,000 characters, or one that takes more than 80 ms, is left uncolored (a
  minified file, a pattern that backtracks without end); the next line starts as if it weren't
  there.
- Tree-sitter parsers parse incrementally, a window at a time in files over a million
  characters, like the built-in ones. TextMate grammars always tokenize from the top: in a huge
  file, colors further down arrive later.

## Limitations

- **Tree-sitter injections** (`injections.scm`): the highlighting pipeline doesn't run injected
  parsers yet, so code embedded in a tree-sitter-parsed file isn't colored as its language; use
  a TextMate grammar if that matters. `locals.scm` and `indents.scm` aren't used either.
- **Outline**: the Outline comes from a language server or an extension's document symbol
  provider; neither kind of grammar fills it.
- **TextMate**: only the foreground color of theme rules is used (no bold or italic);
  `tokenTypes` is ignored; the regex differences above.
- **Built-in grammars aren't TextMate grammars**: an injection with `injectTo: ["source.js"]`
  applies only where a TextMate grammar for `source.js` is installed.

## See also

- [Language support](language-support.md): declaring the language a grammar colors.
- [Language feature providers](providers.md): semantic tokens and folding ranges in code.
- [Language servers](language-servers.md): semantic tokens and folding from a server.
- [Snippets](snippets.md).
- [Cookbook](cookbook.md#a-language-with-a-textmate-grammar): a small grammar from scratch; the [developer guide](README.md).
