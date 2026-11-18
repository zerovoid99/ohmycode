# Oh My Code

A fast, native code editor for macOS, written in Swift with AppKit and SwiftUI. Language servers,
debugging, git, a terminal, coding agents and AI are built in; extensions add languages and
commands. It opens a 20 MB file in under a tenth of a second and keeps typing under a
millisecond, whatever the file's size.

[Download the latest release](https://github.com/zerovoid99/ohmycode/releases/latest) ·
[Changelog](CHANGELOG.md) · [Extension guide](docs/extensions/README.md)

## Install

Requires macOS 15 or later on an Apple silicon Mac.

1. Download `OhMyCode-<version>.dmg` from the [latest release](https://github.com/zerovoid99/ohmycode/releases/latest).
2. Open it and drag **Oh My Code** to Applications.
3. The app is ad-hoc signed and not notarized: the first time, right-click it and choose **Open**,
   or run `xattr -dr com.apple.quarantine "/Applications/Oh My Code.app"`.

It updates itself from then on (*Oh My Code ▸ Check for Updates…*). To open folders from a
terminal, *Oh My Code ▸ Install “omc” Command…* (see [Opening folders and files](#opening-folders-and-files)).

## Highlights

- **Editor**: TextKit 2, tree-sitter syntax colors, multiple cursors, snippets, folding, Vim mode,
  a minimap, sticky scroll, Emmet, a spell checker for code, color swatches with a picker, file
  and folder compare, and hot exit that never loses unsaved work.
- **Language servers**: completion, hover, go to definition, references, rename, quick fixes,
  formatting, inlay hints, code lens, semantic colors, peek definition and references, and the
  call hierarchy.
- **Run, test and debug**: tasks with problem matchers, a Testing sidebar for Swift, Xcode, Go,
  Python, Jest, Vitest and Rust, and LLDB or debugpy debugging.
- **Git**: staging, commits, branches, stashes, worktrees, blame, a commit graph, a merge editor
  and GitHub pull requests.
- **Agents and AI**: Claude Code, Gemini CLI or Codex in the sidebar (ACP), Claude Code in the
  terminal connected to the editor, and inline suggestions and edits with Claude or any
  OpenAI-compatible server.
- **Built-in tools**: an integrated terminal (libghostty), a REST client for `.http` files, and a
  database explorer for SQLite, PostgreSQL and MySQL.
- **Several folders in one window**, profiles, folder settings and `.editorconfig`.
- **Extensions** in TypeScript: commands, settings, and whole languages (TextMate or tree-sitter
  grammars, language servers, providers, snippets).

## Contents

- **Opening and finding things**: [Opening folders and files](#opening-folders-and-files) · [Several folders in one window](#several-folders-in-one-window) · [Files in the Explorer](#files-in-the-explorer) · [Outline and breadcrumbs](#outline-and-breadcrumbs) · [Links](#links) · [Images, PDFs and binary files](#images-pdfs-and-binary-files) · [Markdown preview](#markdown-preview) · [Compare files and folders](#compare-files-and-folders)
- **Editing**: [Line editing](#line-editing) · [Snippets](#snippets) · [Emmet](#emmet) · [Spell checking](#spell-checking) · [Folding](#folding) · [Brackets and indent guides](#brackets-and-indent-guides) · [Linked tag editing](#linked-tag-editing) · [Word wrap](#word-wrap) · [Tabs and whitespace](#tabs-and-whitespace) · [Vim mode](#vim-mode) · [Zen mode](#zen-mode)
- **Language features**: [Quick fixes and parameter hints](#quick-fixes-and-parameter-hints) · [Formatting](#formatting) · [Code lens](#code-lens) · [Semantic highlighting](#semantic-highlighting) · [Symbol highlights](#symbol-highlights) · [Peek](#peek) · [Color decorators](#color-decorators)
- **Running, testing and debugging**: [Terminal](#terminal) · [Tasks and Problems](#tasks-and-problems) · [Testing](#testing) · [Debugging](#debugging) · [HTTP requests (.http files)](#http-requests-http-files) · [Databases (SQLite, PostgreSQL, MySQL)](#databases-sqlite-postgresql-mysql)
- **Git and GitHub**: [Merge conflicts](#merge-conflicts) · [GitHub pull requests](#github-pull-requests) · [Local history](#local-history)
- **Agents and AI**: [Coding agents](#coding-agents) · [AI suggestions and edits](#ai-suggestions-and-edits) · [Explain and fix with AI](#explain-and-fix-with-ai)
- **Settings and your work**: [Unsaved changes, auto save and hot exit](#unsaved-changes-auto-save-and-hot-exit) · [Folder settings](#folder-settings) · [EditorConfig](#editorconfig) · [Keyboard shortcuts](#keyboard-shortcuts) · [Profiles and sync](#profiles-and-sync)
- **Extensions**: [Extensions](#extensions)
- **[Development](#development)**: [Requirements](#requirements) · [Setup](#setup) · [Build & test from CLI](#build--test-from-cli) · [Performance](#performance) · [Updates and releases](#updates-and-releases) · [Third-party libraries](#third-party-libraries)

## Opening and finding things

### Opening folders and files

Open a folder with ⌘O, File → Open Recent (⌃R), the welcome screen's recent list, by dropping it on a
window, or from Finder (Open With → Oh My Code, or onto the Dock icon). A folder that's already open
comes to the front; a file opens in the window whose folder holds it.

From a terminal: *Oh My Code → Install “omc” Command…* links `omc` into `/opt/homebrew/bin`,
`/usr/local/bin` or `~/.local/bin`, whichever can be written to.

```sh
omc .                     # this folder
omc src/app.swift:12:5    # a file at line 12, column 5 (a new file is created empty)
omc -n ~/code/other       # in a new window
omc -r notes.md           # in the frontmost window
```

### Several folders in one window

*File → Add Folder to Workspace…* (or right-click in the Explorer) adds another folder to the
window: a frontend and a backend, or a few repositories side by side. Each folder is a top-level
row in the Explorer with its own git badges; files can be dragged from one folder to another.
Right-click a folder's row to remove it.

*File → Save Workspace As…* keeps the folders in a `.omc-workspace` file, which then names the
window. Open it again with *File → Open Workspace…*, ⌘O, Open Recent, Finder or `omc`. VS Code's
`.code-workspace` files open the same way.

```json
{
  "folders": [{ "path": "web" }, { "path": "../api", "name": "API" }],
  "settings": { "formatOnSave": true }
}
```

Paths are relative to the workspace file. Its `settings` (the same names as a folder's
`.omc/settings.json`) apply to every folder; a folder's own settings win for its files. A window
with several folders that was never saved still comes back at the next launch.

With several folders:
- Quick Open and Find in Files cover all of them; paths start with the folder's name. To search
  one folder, put `name/**` in *Files to include*, or pick it from the folder menu next to it.
- Source Control lists every repository with its branch; pick one to commit, stage, switch
  branches or see its history. Two folders in the same repository share it. The status bar
  shows the branch of the active file's repository.
- A language server that supports several folders gets all of them; one that doesn't runs once
  per folder.
- Tasks and launch configurations are read from every folder, with the folder's name after
  theirs; `${workspaceFolder}` is that folder. New terminals start in the active file's folder.
- The Testing sidebar lists each folder's tests under the folder's name, found with that
  folder's own toolchain (a Swift package in one, npm or Go in another); ⌘U runs every folder's
  tests, each in its own folder.
- Breakpoints are kept per folder, so a folder keeps its breakpoints whether it's opened alone
  or with others, and the debugger gets the breakpoints of every folder's files.
- Agents and extensions may read and write in any of the folders, and nowhere else (unless an
  extension has the file system permission).

### Files in the Explorer

Right-click in the Explorer for *New File…*, *New Folder…*, *Rename…*, *Move to Trash*,
*Reveal in Finder*, *Copy Path* and *Copy Relative Path*. Clicking empty space puts new items at
the top of the folder. A new file's name can include folders (`src/util.ts`), which are created
too. Drag an item onto a folder to move it.

Renaming or moving first asks the language servers that want to know (TypeScript does) for the
edits that keep references working, such as imports that name the file. Those edits are applied
unsaved, so you can review and save or undo them, before the file moves. Open tabs follow the file
to its new name, with their unsaved changes.

### Outline and breadcrumbs

The Outline sidebar lists the active file's declarations (classes, functions, properties, Markdown
headings), with the one the cursor is in highlighted; click one to go there. Breadcrumbs above the
editor show the file's folders and the symbols the cursor is in; each part opens a menu of its
neighbours. ⇧⌘O (or `@` in quick open) goes to a symbol by name. Symbols come from the language
server when there is one, otherwise from the syntax tree (Swift, Python, JavaScript, TypeScript,
Rust, Go). Breadcrumbs can be turned off in Settings → Editor.

⌘T (or `#` in quick open) finds a symbol anywhere in the folder: the language servers' results with
every file's syntax tree, so it works without a server too. With a language server: ⌘F12 goes to
the implementations of a protocol, interface or method (several are listed in the sidebar), Go to
Type Definition to a value's type, and ⌥⇧H shows the call hierarchy — who calls a function, or
what it calls — opened level by level.

### Links

URLs written in any file (`https://`, `http://`, `ftp://`, `file://`) and links the language server
finds (such as an import's path) are underlined while ⌘ is held over them. ⌘-click opens them:
web links in the browser, and files in the editor (`#L12` goes to line 12). Elsewhere, ⌘-click is
still Go to Definition. Right-clicking a link offers *Open Link* and *Copy Link Address*.

### Images, PDFs and binary files

Files that aren't text open in a viewer tab instead of the editor, from the Explorer, Quick Open or
`omc`. Like other tabs they can be split, moved and closed, and they come back with the session.

- **Images** (PNG, JPEG, GIF, WebP, HEIC, TIFF, BMP, ICO, ICNS and other formats macOS reads) fit
  the window until you zoom: ⌘+, ⌘- and ⌘0 (fit), pinching, or the buttons in the footer, which
  also shows the size in pixels, the file size and the format. Animated GIFs play, transparent
  parts show a checkerboard, and the picture updates when the file changes on disk.
- **SVG** shows as a picture. *Open as Text* in the footer edits its source in the editor, and the
  editor's picture button brings the preview back beside it.
- **PDF** scrolls page by page, zooms the same way, and shows the current page and page count.
- **Other binary files** (NUL bytes near the start, or not valid UTF-8) show as a read-only hex
  dump: offset, bytes and ASCII. Only the part on screen is read, so a large file opens at once.
  *Open as Text Anyway* opens it in the editor; saving it from there can damage the file.

UTF-16 text files with a byte order mark open in the editor and are saved as UTF-16 again.

### Markdown preview

⇧⌘V shows a Markdown file rendered beside it (GitHub-style tables, task lists, highlighted code,
local images). It updates as you type and scrolls with the editor both ways; double-click a part
of the preview to go to its source. Scripts in the Markdown don't run.

### Compare files and folders
Right-click a file in the Explorer for *Select for Compare*, then *Compare with Selected* on
another; the same works for two folders. A tab's context menu (and the palette) has *Compare
with…* (any file in the folder), *Compare with Clipboard* and *Compare with Saved* (your unsaved
edits against the file on disk). The file you're comparing stays live: edit it in its tab and the
diff follows. *Swap Sides* in the diff's header swaps them; binary files only say whether they
differ.

*File: Compare Folder with…* compares folders anywhere. The comparison tab lists the files only on
the left, only on the right, and different, with counts, a filter and *Show Same*. `.git`,
`node_modules`, `.build`, `DerivedData` and other build folders, and what the folder's
`.gitignore` names, are left out. Click a file for its diff; double-click one that's on one side
only to open it. Files are compared by size, then content, in the background.

## Editing

### Line editing

Commands on the selection's lines, each one undoable step:

| Command | Shortcut |
| --- | --- |
| Toggle line comment (a block comment in CSS, HTML, Markdown) | ⌘/ |
| Move lines up / down | ⌥↑ / ⌥↓ |
| Copy lines up / down | ⇧⌥↑ / ⇧⌥↓ |
| Delete lines | ⇧⌘K |
| Indent / outdent | ⌘] / ⌘[ |
| Insert a line below / above | ⌘↩ / ⇧⌘↩ |
| Join lines | ⌃J |

*Sort Lines Ascending/Descending* (natural order: `item2` before `item10`), *Delete Duplicate
Lines*, *Transform to Uppercase/Lowercase/Title Case* and *Trim Trailing Whitespace* are in
Edit → Lines and the palette. Sorting works on the selected lines, or the whole file when one line
is selected. The editor handles these keys itself, so they work as usual in other text fields
(⌥↑ in the commit message box). They can be changed in Settings → Keyboard Shortcuts.

### Snippets

Snippets come up in completion and expand with Tab after their prefix (`guard⇥`); Tab and ⇧Tab
then move between their placeholders, typing in a repeated one changes every copy, Esc finishes.
Built-in ones cover Swift, Python, Rust, Go, C/C++, JavaScript/TypeScript, shell, Markdown and HTML.
Your own, in VS Code's format, go in `~/Library/Application Support/OhMyCode/Snippets/<language>.json`
(*Snippets: Configure User Snippets*) or the folder's `.omc/snippets/` and `.vscode/*.code-snippets`.

### Emmet
In HTML-like files (HTML, Vue, Svelte, PHP, ERB…), JSX/TSX and CSS, SCSS and Less, Tab after an
abbreviation expands it, and the completion list offers it as *Emmet Abbreviation*:

```text
ul>li.item$*3>a{Link $}     nav, children, siblings (+), climbing (^), groups (), *N, $ numbering
!                           an HTML5 document
input:email, a, img, btn:s  Emmet's snippets
m10-20  w100p  df+jcsb  bd! CSS: margin: 10px 20px; width: 100%; display: flex; justify-content: …
```

The result has tab stops (attribute values, empty elements). JSX gets `className` and `htmlFor`.
Tab goes first to an open completion list, an AI suggestion or a snippet being filled in, and a
plain word that isn't a tag doesn't expand. The palette has *Emmet: Expand Abbreviation*, *Wrap
with Abbreviation…* (`li*` wraps each selected line), *Balance Outward*, *Balance Inward* and
*Remove Tag*. Settings ▸ Editor turns Emmet, or expanding with Tab, off.

### Spell checking
Misspelled words in comments, strings and Markdown, and in names (split by case: `loadSettigns`
is load + Settigns), get a dotted underline, using macOS's dictionaries offline. Words under four
letters, URLs, paths, hex, UUIDs, keywords and a few hundred programming terms are left alone.
Right-click a word (or ⌘., or the 💡) for suggestions in the word's own case, *Rename Symbol…*,
*Add to Folder Dictionary* (`.omc/dictionary.txt`, to share with the project), *Add to User
Dictionary* and *Ignore in This File*. `// spell-checker: ignore word…`, `disable` and `enable`
comments work too. Settings ▸ Editor ▸ Spell Check sets the language, whether names are checked
and whether misspellings are listed in Problems; the folder setting is `spellCheck`.

### Folding

The ⌄ in the gutter, ⌥⌘[ and ⌥⌘] fold and unfold code. Regions follow the code's structure:

- the language server's folding ranges, or the syntax tree's;
- a block folds from its first line (a function, even with its parameters on several lines) to
  the line before its closing bracket;
- multi-line comments and runs of `//` lines fold;
- a run of imports folds;
- `// MARK:` sections fold to the next MARK, and `#region` to its `#endregion`.

Languages without brackets (Python, YAML) fold by indentation. *Fold All*, *Fold All Comments*
and *Fold Level 1/2/3* are in the palette.

### Brackets and indent guides

With the cursor beside a bracket (`(`, `[`, `{`), it and its match are outlined. Brackets inside
strings and comments don't count. ⇧⌘\ goes to the matching bracket, or from inside a pair to its
closing bracket. Thin indent guides mark each indentation level. The guide of the block the cursor
is in (or the block its line opens) is drawn brighter. Both can be turned off in Settings → Editor;
*View: Toggle Indent Guides* is in the palette.

### Linked tag editing

In HTML, XML, Markdown and JSX/TSX, typing or deleting in a tag's name changes its closing tag
(or opening tag) the same way, as one undo step. Nested tags with the same name are matched
correctly, and self-closing tags and tags still being typed are left alone. Turn it off in
Settings → Editor.

### Word wrap

Long lines wrap at the editor's edge in Markdown and plain text, and scroll sideways in code.
Settings → Editor → Word wrap changes that to always or never. ⌥Z (*View: Toggle Word Wrap*)
switches it for the active file until it's closed. Line numbers, breakpoints and other gutter marks
stay on a wrapped line's first row.

### Tabs and whitespace

A tab is drawn as wide as the file's tab width in spaces: `.editorconfig`'s `tab_width`, otherwise
the indentation's width. Tab-indented code lines up with space-indented code and with the indent
guides. Spaces show as · and tabs as → in the selection. Settings → Editor → Show whitespace
changes that to never, leading/trailing/repeated, or all. *View: Toggle Render Whitespace* switches
between all and the selection.

### Vim mode

Turn it on in Settings → Editor → *Vim mode*, or with *Toggle Vim Mode* in the palette. It's off
by default, and only the code editor uses it: the find bar, the terminal and other text fields
keep their usual keys, and ⌘ shortcuts (⌘S, ⌘P, ⌘C, ⌘V…) work in every mode. The status bar
shows the mode (`-- INSERT --`, `-- VISUAL --`…), keys typed so far (`2d`) and the command line.
Normal and Visual mode show a block cursor.

- Modes: Normal, Insert, Visual, Visual Line, Replace (`R`). Esc or ⌃[ goes back to Normal; an
  open completion list, AI suggestion or find bar closes first.
- Motions: `h j k l`, `w W b B e E ge gE`, `0 ^ $ g_`, `gg G` (`5G`), `f F t T ; ,`, `%`, `{ }`,
  `H M L`, `+ - _`, ⌃D ⌃U ⌃F ⌃B ⌃E ⌃Y, `zz zt zb`, `* #`, `/` and `?` with `n N`.
- Operators `d c y > < gu gU g~` with any motion or text object (`iw aw iW aW`, brackets
  `i( a( ib i{ iB i[ i<`, quotes `i"`, `i'`, `` i` ``, tags `it at`, paragraphs `ip ap`), doubled for lines
  (`dd`, `>>`, `gUU`), and `D C Y x X s S r ~ J gJ p P`. Counts work almost everywhere (`3dw`,
  `2d3w`, `5x`, `3ix<Esc>`).
- Registers: the unnamed one, `"a`–`"z` (`"A` appends), `"0` (the last yank), `"1`–`"9`, `"-`,
  `"_`, and `"+` / `"*` for the system clipboard. Lines are put as lines.
- `u` and ⌃R undo and redo (the editor's own undo: each Vim change, typing included, is one
  step), `.` repeats the last change with what was typed in it.
- Visual mode: motions extend the selection, `o` swaps its ends, `gv` selects it again; `d c y
  > < ~ u U r J p` act on it, `:` starts a command for its lines.
- Commands: `:w`, `:q` (closes the tab; `:q!` drops changes), `:wq`, `:x`, `:wa`, `:{line}`,
  `:s/pattern/replacement/g` on the line, `:%s` on the file, `:'<,'>s` on the selection (Vim's
  regular expressions: `\(\)`, `\<\>`, `\{n}`, `&` and `\1` in the replacement), `:d`, `:y`,
  `:>`, `:j`, `:noh`, `:set ic` / `:set scs`.
- Several cursors (⌥-click, ⌘D) switch to Insert mode, so typing goes to each of them; Esc
  removes them, and a second Esc returns to Normal mode, where commands use one cursor.
- In read-only views, Normal mode moves, selects and yanks but doesn't edit. Input methods work
  in Insert mode as usual.

### Zen mode

⌥⌘Z (View → Zen Mode) leaves only the text: the sidebar, tabs, breadcrumbs, bottom panel and status
bar hide, the editor is centered at about 100 columns and the window goes full screen (unless
turned off in Settings → Editor). ⌥⌘Z again, or Esc twice in the editor, puts everything back as
it was.

## Language features

### Quick fixes and parameter hints

With a language server, a 💡 appears beside the cursor's line when there are fixes for a problem on
it; ⌘. lists them with the server's refactorings and source actions (the preferred fix in bold).
⌥⇧O organizes imports. Typing a call's `(` shows its signature above the cursor, the current
argument in bold, following you through the arguments (⇧⌘Space shows it by hand, Esc hides it).
Inlay hints show what the server infers inside the code — a variable's type (`let total: Int`),
an argument's parameter name — without changing the text; they're turned off in Settings → Editor
or with *View: Toggle Inlay Hints*.

### Formatting

⇧⌥F formats the file with the language server (or an extension's formatter). *Format Selection*
(palette, or the editor's right-click menu) formats only the selected lines. Format on save
(Settings → Editor) can format the whole file or only the lines changed since the last commit. The
second keeps your edits tidy in a repository that isn't formatted yet; files not in git are
formatted whole. A slow formatter never holds up saving: after two seconds the file is saved as it
is.

### Code lens

Language servers that offer code lenses (TypeScript, Rust, Go and others) show them dimmed after
the line they're about, for example "3 references" after a function. Click one to run it:
references open in the sidebar, other commands run on the server. They update a moment after you
stop typing, and move with their lines meanwhile. Turn them off in Settings → Editor or with
*View: Toggle Code Lens*.

### Semantic highlighting

With a language server that classifies names (sourcekit-lsp does), types, functions and properties
get the theme's colors for what they really are, over the syntax tree's guess. Variables and
parameters get the plain text color. Colors stay in place while you type and are updated a moment
after you pause. Files over 20,000 lines keep the syntax colors only. Turn it off in
Settings → Editor.

### Symbol highlights

Putting the cursor on a symbol highlights where else it appears in the file. With a language server
these are its own places (the same name in another scope isn't), and places where it's assigned are
outlined. Without one, the same whole word is highlighted. Selecting text on one line highlights the
same text elsewhere. F7 and ⇧F7 go to the next and previous place. Highlights are turned off in
Settings → Editor or with *View: Toggle Symbol Highlights*.

### Peek
⌥F12 peeks at a definition, ⌥⇧F12 at references, ⇧⌘F12 at implementations (and *Peek Type
Definition* in the palette): an editor opens under the line, pushing the lines below down, with
several results listed beside it by file (↑ and ↓ go through them). It's the real file: edits
there are edits in its tab too, with undo. Enter or double-click opens a result in a tab; Esc, a
click elsewhere or typing above it closes it. Also in the Go menu and the editor's context menu
(Peek).

### Color decorators
Colors get a swatch before them: hex, `rgb()`, `hsl()` and named colors in CSS, SCSS, Less and
HTML styles, the same in strings in JavaScript and TypeScript (except names), and
`Color(red:green:blue:)`, `Color(hue:…)`, `NSColor` and `UIColor` in Swift, plus what a language
server reports. Click a swatch for the color panel: the literal is rewritten in its own format
as you pick (hex stays hex, `rgb()` stays `rgb()`), and a whole drag is one undo step. Turn them
off in Settings → Editor, with the folder setting `showsColorDecorators`, or with *View: Toggle
Color Decorators*.

## Running, testing and debugging

### Terminal

⌃` shows the integrated terminal and ⌃⇧` opens another one in a new tab. The ⊟ button (or
*Terminal: Split Terminal*) opens a shell beside the active one in the same tab. Click a pane to
type in it; a thin accent line marks the active pane. Closing a pane gives its place to its
neighbour. Double-click a tab, or right-click it, to rename it: the name stays until you clear it,
even when the shell sets its own title. Right-click also has *Split Terminal* and *Kill Terminal*.

⌘-click a file path in the terminal's output to open it in the editor at its line and column, as
compilers and test runners print them (`Sources/App/main.swift:12:5`, Python's
`File "x.py", line 3`). Relative paths are resolved from where the shell started. ⌘-click a URL to
open it in the browser. The pointer turns into a hand over links while ⌘ is held.

### Tasks and Problems

Terminal → Run Task… runs a folder's commands; ⇧⌘B runs the default build task. Tasks are found in
Package.swift, package.json (npm, yarn, pnpm or bun scripts), Makefile, Cargo.toml and go.mod, and
can be added in `.omc/tasks.json` (Configure Tasks… writes one listing the found tasks):

```json
{
  "tasks": [{
    "label": "Build",
    "command": "swift build",
    "group": "build",
    "isDefault": true,
    "cwd": "${workspaceFolder}",
    "env": {}
  }]
}
```

The output shows in the Tasks panel; errors in it (swiftc, clang, gcc, TypeScript, Rust, Go and
ESLint's unix format) are links, appear in the editor and in Problems (⇧⌘M), which lists every
error and warning in the folder (language servers, extensions and tasks), open files or not.
`"problemMatcher": "none"` leaves a task's output alone.

### Testing

The Testing sidebar lists the folder's tests (every folder's, with several), found by reading test files: Swift packages and Xcode
projects (XCTest and Swift Testing), Go, Python (pytest if it's installed, else unittest), Jest, Vitest and Rust.
⌘U runs them all, ⌃⌥⌘U the test at the cursor; the ▶ in the gutter runs one test or suite and
then shows ✓ or ✗. Failures appear under the test, in the editor and in Problems; the run's output
is in the Tasks panel. Xcode projects and workspaces (without a Package.swift) run with
`xcodebuild test`: the project's own scheme, on the Mac or, for an iOS project, the first iPhone
simulator; their test files are the Swift files in the test targets' folders.

### Debugging

Run and Debug (⇧⌘D, F5) debugs with LLDB through the Debug Adapter Protocol (`lldb-dap`, part of
Xcode): Swift, C, C++ and Objective-C. What to run is found by itself:

- a Swift package's executables, built with `swift build` first;
- an Xcode project's or workspace's schemes that build a Mac app or command-line tool, built with
  `xcodebuild` first and run from where Xcode puts them;
- *Python: Current File* in a folder with Python (with debugpy).

*Look Again for Programs* in the panel's ⋯ menu finds them after a change. Anything else goes in
`.omc/launch.json`:

```json
{
  "configurations": [{
    "name": "Debug tool",
    "program": "${workspaceFolder}/build/tool",
    "args": [],
    "cwd": "${workspaceFolder}",
    "env": {},
    "preLaunch": "make"
  }]
}
```

Click a line number (or F9) for a breakpoint. In the Breakpoints list, its context menu adds a
condition or turns it into a logpoint (prints `x is {x}` instead of stopping), × removes it, and
the section's buttons turn every breakpoint off or on, or remove them all. *Stop on exceptions*
picks thrown or caught Swift, C++ or Objective-C exceptions to stop on. F10/F11/⇧F11 step
over/into/out. Watch expressions are evaluated at every stop (double-click one to edit it); a
variable's context menu sets its value. The Debug Console shows the program's output and
evaluates expressions in the selected frame (start with a backtick for an LLDB command).

- **Attach:** *Debug: Attach to Process…* picks one of your running processes, or put
  `"request": "attach"` with a `"pid"` (or a `"program"` to wait for) in launch.json. Stopping lets
  the process go on.
- **Other debuggers:** `"type": "python"` uses debugpy (`pip install debugpy`); any debug adapter
  speaking DAP over stdio works with `"adapter": ["command", "args"…]`, and `"adapterArguments"`
  adds to its launch request.

### HTTP requests (.http files)

`.http` and `.rest` files are REST clients, in the format of VS Code's REST Client and JetBrains'
HTTP Client. Requests are separated by `###`, and each is a request line, headers, a blank line and
an optional body:

```http
@host = https://api.example.com

# @name login
POST {{host}}/login
Content-Type: application/json

{ "user": "{{user}}", "password": "{{$dotenv PASSWORD}}" }

### Current user
GET {{host}}/me
Authorization: Bearer {{login.response.body.$.token}}
```

Click *Send Request* after a request line, or press ⌥⌘R with the cursor in it. The response opens
in a tab beside the file: status, time (and time to first byte), size, then the body (pretty JSON
or XML with syntax colors, raw, a rendered HTML preview, images, or a hex dump), the response and
request headers, cookies, a timeline (DNS, connect, TLS, waiting, download) and the request exactly
as sent. Sending the same request again reuses its tab unless you pin it. Bodies over 10 MB are
written to a temporary file: *Save Body…* or *Open Body in Editor* gets all of it. With AI set up,
✨ explains the response (its status, headers and the start of the body are sent).

- **Variables**: `@name = value` lines (they can use other variables), the environment's,
  `{{$guid}}`, `{{$randomInt 1 100}}`, `{{$timestamp -1 d}}`, `{{$datetime iso8601}}`,
  `{{$datetime "YYYY-MM-DD" 1 w}}`, `{{$localDatetime rfc1123}}`, `{{$processEnv NAME}}`,
  `{{$dotenv NAME}}` (a `.env` next to the file or in the folder), and earlier responses:
  `{{login.response.body.$.items[0].id}}`, `{{login.response.headers.X-Token}}`,
  `{{login.request.body.*}}`. A variable that isn't defined is underlined, listed in Problems, and
  stops the request with a message before anything is sent.
- **Comments and options**: `#` and `//` lines (inside a body they're body text), `# @name`,
  `# @no-redirect`, `# @no-cookie-jar`, `# @prompt name description` (asked before sending) and
  `# @note` (confirmed before sending).
- **Bodies**: text, JSON and XML; `< ./file` sends a file and `<@ ./file` sends it with variables
  filled in (`<@latin1 ./file` for another encoding); form bodies may continue on lines starting
  with `&`; `multipart/form-data` parts can be files; with `X-Request-Type: GraphQL` the body is a
  query and, after a blank line, its variables. `Authorization: Basic user:password` (or
  `Basic user password`) is encoded for you. Digest authentication isn't supported.
- **Environments**: `rest-client.environmentVariables` in `.vscode/settings.json` or
  `.omc/settings.json`, with `$shared` variables in every environment, and JetBrains'
  `http-client.env.json` with `http-client.private.env.json` for secrets (the nearest ones from
  the file up to the folder). Pick one in the status bar or with *REST: Switch Environment*; the
  choice is kept per folder.
- **Commands**: *REST: Send Request* (⌥⌘R), *Rerun Last Request*, *Cancel Request*, *Copy Request
  as cURL* (also a lens), *Paste cURL as Request* (turns a cURL command on the clipboard into a
  request at the cursor), *Generate Code Snippet* (Swift URLSession, JavaScript fetch, Python
  requests), *Show History*, *Clear History*, *Clear Cookies* and *Explain Response*.
- **Sending**: each window keeps its own cookies (between launches) and the last 50 requests'
  history; history keeps the request as written, with credentials, cookies and token-like header
  values taken out. Settings ▸ HTTP sets the timeout (30 s), whether redirects are followed, and
  whether self-signed certificates are accepted from localhost (never from other hosts).
- **Editing**: syntax colors (JSON and XML bodies too), completion of methods, headers, content
  types and `{{` variables, problems for malformed request lines and missing files, a fold and an
  Outline entry per request.

### Databases (SQLite, PostgreSQL, MySQL)

The Database panel (the cylinder in the activity bar) lists your connections: SQLite files,
PostgreSQL, and MySQL or MariaDB servers. *Add Connection…* (＋) asks for the type, host, port,
user, password, database and SSL mode (or a SQLite file), or takes a connection URL such as
`postgres://user:pass@host:5432/db?sslmode=require`, `mysql://user@host/db` or
`sqlite:///path/to/app.db`; *Test Connection* tries it. A connection is saved either in the folder's
`.omc/databases.json` (to share it with the project) or for every window; passwords are never
written to either: they go in the Keychain, or are kept only until you quit.

- **Tree**: expand a connection to connect; then its schemas (or databases), tables and views,
  their columns (type, nullability, 🔑 primary and 🔗 foreign keys) and indexes. Double-click a
  table, or right-click it, for *Select Top 100*; *Show DDL* opens its CREATE statement;
  *Copy Name*, *Refresh*, and *Truncate…* / *Drop…* (only after a confirmation naming the table).
- **SQLite files**: opening a `.sqlite`, `.sqlite3` or `.db` file (or any file with a SQLite
  header) from the Explorer shows its tables and adds it to the panel; *Open as Hex* still shows
  the bytes.
- **SQL files**: `.sql` files get syntax colors and a connection in the status bar (chosen per
  file and remembered). ⌘↩ runs the statement at the cursor, ⇧⌘↩ the selection or the whole file,
  and *Run* above each statement runs that one. Statements are split the way the database does:
  quotes, comments, `$$` and `$tag$` bodies, backticks and MySQL's `DELIMITER`. *New Query* in the
  panel opens a scratch SQL file on a connection. Completion offers the connection's tables,
  columns (of the tables the statement uses, or after `alias.`), schemas and keywords.
- **Results** open in a tab beside the file: a grid you can sort by any column, resize and copy
  from (cells, or rows as text, JSON, CSV or INSERT statements), with NULL shown apart from text.
  Each result set of a run has its own segment, and *Messages* shows each statement's outcome,
  rows affected, server notices and time. Up to 10,000 rows are kept (*Fetch More* runs it again
  keeping more); *Export* saves CSV, JSON, Markdown, TSV or INSERT statements. *Cancel* stops a
  running query on the server. An error with a position is underlined in the file and listed in
  Problems.
- **History**: each connection keeps its last 100 statements (🕘 in the results tab, or *Query
  History…* on the connection) to run again or open.
- **AI**: with AI set up, *Explain Query* explains the statement (and its error), *Fix Query with
  AI* proposes a fix for the failed statement as a diff, and ⌘I in a SQL file sends the
  connection's schema (capped) along with your instruction.
- **Drivers**: written for the app, with no extra libraries: SQLite through the system library;
  PostgreSQL's wire protocol (password, MD5 and SCRAM-SHA-256 sign-in; TLS with *Prefer*,
  *Require* or *Verify Full*, with an optional root certificate); MySQL's and MariaDB's protocol
  (`caching_sha2_password`, sending the password encrypted with the server's RSA key when there's
  no TLS, and `mysql_native_password`). SCRAM channel binding (`-PLUS`) isn't used.

To run the integration tests against real servers, `eval "$(scripts/dbtest/start.sh)"` starts
throwaway PostgreSQL and MySQL servers (Homebrew's) in a temporary folder on free ports and prints
the `OMC_TEST_*` URLs; pass them to the tests with a `TEST_RUNNER_` prefix (for example
`TEST_RUNNER_OMC_TEST_POSTGRES_URL="$OMC_TEST_POSTGRES_URL" xcodebuild … test`), then
`scripts/dbtest/stop.sh "$OMC_DBTEST_DIR"`. Without them those tests are skipped.

## Git and GitHub

### Merge conflicts

Conflicted files show each conflict tinted (current green, incoming blue, base gray), with
*Accept Current*, *Accept Incoming*, *Accept Both*, *Compare* and *Merge Editor* above it.

The merge editor (*Merge Editor*, or *Git: Open Merge Editor*) goes through the file's conflicts
one by one:

- current, base (when git kept it: `merge.conflictStyle diff3`) and incoming side by side;
- take one side, both, or both with the incoming first (or *Accept All*);
- a live preview of the resulting file.

*Apply* makes all the choices one undo step. Conflicts left unresolved keep their markers. Saving a
file with no markers left stages it.

### GitHub pull requests

The Pull Requests sidebar lists the repository's open pull requests through the GitHub CLI
(`brew install gh`, then `gh auth login`). Each one shows its author, branch, draft state and
review decision. Click one to read its description, changed files (click to open), reviews and
comments. *Check Out* switches to its branch, and the compass button opens it on GitHub. The +
button (or *GitHub: Create Pull Request…*) creates one from the current branch. The form starts
with the last commit's subject and body, and the branch is pushed first if it has no upstream.

### Local history

Every save keeps a version of the file (and the version on disk before it, or before another
program replaced it), whether or not the file is in git. They're listed in the Timeline above the
commits: click one to compare it with the current text, or restore it (one undoable change).
*Local History: Restore a Saved Version…* does it from the command palette. Up to 50 versions per
file are kept for 30 days, in `~/Library/Application Support/OhMyCode/History`.

## Agents and AI

### Coding agents

The **Agent** sidebar (the sparkles icon, ⌃⌘A) talks to a coding agent over the [Agent Client
Protocol](https://agentclientprotocol.com) (ACP). Pick an agent, start it, and ask it to do
something in the window's folder. Its reply streams in, with its plan, the files it reads and
the commands it runs (with their output). Before it edits a file or runs a command it asks:
*Allow* or *Reject* on the card above the prompt, and *View Diff* shows a proposed edit side by
side. ⌘↩ sends (while the prompt box has focus), ⌘. stops the turn; the paperclip attaches the
selection (or the current file), and `/` lists the agent's commands. The agent's model and other
settings it offers are in the prompt box's toolbar. While it replies the conversation follows
along, unless you've scrolled up to read. *New Thread* starts over; *⋯ ▸ Open Earlier Thread*
reopens an earlier conversation in the folder (for agents that can reopen sessions; Claude
Code's adapter can), and *⋯ ▸ Show Log* shows what the agent printed. The agent reads files as the editor has them, unsaved
changes included, and only inside the folder; what it writes to an open file is one undo step.

Agents are set up in *Settings ▸ Agents*: a name and a command line, run with your login
shell's PATH. The defaults are Claude Code (`npx -y @agentclientprotocol/claude-agent-acp`),
Gemini CLI (`gemini --experimental-acp`) and Codex (`npx -y @agentclientprotocol/codex-acp`);
the npx ones need Node.js.

**Claude Code in the terminal.** `claude` started in this window's terminal connects to the
window, as it does to VS Code: it sees the open files, the selection and the problems, and the
edits it proposes open as diff tabs with *Accept* and *Reject* (closing the tab rejects). From a
terminal elsewhere, in the window's folder, type `/ide`. ⌥⌘K sends the selected lines to it as an
`@file#L…` mention. The window listens on 127.0.0.1 only, and Claude Code finds it through a lock
file in `~/.claude/ide` that holds a token it must send. Turn it off in *Settings ▸ Agents*.

### AI suggestions and edits

Set up in *Settings ▸ AI*, with one of two providers:

- **Claude API**: paste an API key. Suggestions use `claude-haiku-5-5` and edits
  `claude-opus-5-5` unless you name other models.
- **OpenAI-compatible**: any server with the Chat Completions API. The base URL has presets for
  Ollama, LM Studio, OpenRouter and OpenAI; the key is optional (local servers need none), and
  you name the models.

Keys are kept in the macOS Keychain (service `dev.zerovoid99.ohmycode.ai`), never in the
settings file, and the field never shows a saved key. *Test* sends a tiny request to check the
setup.

**Inline suggestions** (off until you turn them on): after a pause in typing, at the end of a
line (or before closing brackets and quotes), a suggestion appears in grey at the cursor. Tab
inserts it as one undo step, ⌘→ inserts its next word, Esc dismisses it; typing what it starts
with keeps the rest. Tab still moves through a snippet's stops and picks from the completion
list when those are showing. ⌥\ asks for a suggestion right away (also with suggestions off).
The *AI* item in the status bar shows when a request runs or the last one failed; clicking it
turns suggestions on or off (also *AI: Toggle Inline Suggestions* in the command palette).

**⌘I edits the selection** (*AI: Edit Selection…*): describe the change, press Enter, and the
reply streams in as a diff against the selection. ⌘↩ accepts it (one undo step), Esc rejects it,
*Open as Diff* opens it as a proposed change in a diff tab. Without a selection, ⌘I on a blank
line writes code there; on another line it edits that line.

### Explain and fix with AI

These use the edit model of the provider set up in *Settings ▸ AI*. Until one is set up their
menu items are disabled and say where to set it up. Replies stream in and can be stopped.

- **Explain with AI** (editor context menu, *Edit ▸ Explain with AI*, or *AI: Explain Selection*
  in the command palette): explains the selection, or the line at the cursor, in a popover. *Copy*
  copies the explanation; *Ask Agent* opens the Agent sidebar with the code attached and a
  question in the prompt, for you to send.
- **Fix with AI**: on a problem from a language server, an extension or a task, choose *Fix with
  AI* in the Problems panel's context menu, in the hover over the problem, in the editor's
  context menu, or in the ⌘. menu (and the 💡 beside the line). The lines around the problem are
  rewritten and shown as a diff: ⌘↩ accepts it as one undo step, replacing only those lines. If
  they changed in the meantime, it's refused and you can try again.
- **Terminal and task output**: select text in a terminal and right-click ▸ *Explain with AI*
  for an error or a stack trace. In the Tasks panel, the ✨ button explains the selected run's
  output.
- **Commit messages**: the ✨ button beside the message in Source Control writes a Conventional
  Commits message (a subject of at most 72 characters, a body when it helps) from the staged
  changes, or from all changes when nothing is staged (its tooltip says which). With several
  repositories, it's the one picked in Source Control.

**Privacy**: nothing is sent until a provider is set up, and then only when you ask:

- Inline suggestions: the code around the cursor (up to 6,000 characters before it and 2,000
  after), only while suggestions are on or when you press ⌥\.
- ⌘I edits: the instruction, the selection and up to 40 lines on each side.
- Explain with AI: the file's path and language, the selection (or line), and up to 40 lines on
  each side.
- Fix with AI: the file's path and language, the problem's message, source and position, the
  lines around it and 30 lines on each side.
- Terminal and task output: the selected text (or the run's last 200 lines), at most its last
  12,000 characters, the terminal's title or the task's command, and the path of the file open
  in the editor (not its contents).
- Commit messages: the repository's staged diff (or all changes, with untracked files by name
  only), up to 30,000 characters; past that, the other files are listed with their added and
  removed line counts. The current branch's name.

## Settings and your work

### Unsaved changes, auto save and hot exit

Quitting never loses unsaved work, and doesn't ask about it. Each window keeps its open tabs and
the text of its unsaved files in `~/Library/Application Support/OhMyCode/Sessions`, updated a
moment after every change, so a crash loses nothing either. At the next launch the windows come
back as they were, unsaved changes included; the file on disk isn't touched until you save. A
window closed with unsaved changes keeps them, and they come back when its folder is opened
again. If a file changed on disk meanwhile, you're told to compare before saving. With hot exit
off (Settings → Editor), quitting asks about each unsaved file instead.

Auto save (Settings → Editor) saves files a moment after you stop typing (the delay is
adjustable), or when you switch tabs, windows or apps. The second one formats first if format on
save is on.

### Folder settings

A folder's `.omc/settings.json` overrides the app's settings for files in it.
*Preferences: Open Folder Settings* writes one with every option commented out. It understands:

- `formatOnSave`, `formatOnSaveScope` (`file`, `modifications`);
- `autoSave` (`off`, `afterDelay`, `onFocusChange`), `autoSaveDelay`;
- `wordWrap` (`off`, `on`, `prose`), `renderWhitespace` (`none`, `selection`, `boundary`, `all`);
- `showsInlayHints`, `semanticHighlighting`, `showsCodeLens`, `showsColorDecorators`, `spellCheck`.

Comments and trailing commas are allowed. Changes apply when the file is saved, even from another
editor. Names it doesn't know, and a file that isn't valid JSON, are reported. Indentation and line
endings come from `.editorconfig`.

### EditorConfig

`.editorconfig` files in a file's folder and the folders above it (up to one with `root = true`)
set its indentation and what saving fixes, as in other editors. Supported: `indent_style`,
`indent_size`, `tab_width`, `end_of_line`, `trim_trailing_whitespace` and `insert_final_newline`.
Indentation applies to Enter, snippets and formatting; without a setting it's judged from the file.
The fixes made when saving are one undoable step. The status bar shows the indentation and line
endings; hover them to see which `.editorconfig` set them. Editing an `.editorconfig` applies it to
open files at once.

### Keyboard shortcuts

Settings → Keyboard Shortcuts lists every command (extensions' too): double-click one and press new
keys. Changes are saved in `~/Library/Application Support/OhMyCode/keybindings.json`, which can
also be edited by hand:

```json
[
  { "key": "cmd+shift+r", "command": "tasks.run" },
  { "key": "shift+cmd+b", "command": "-tasks.build" }
]
```

A rule gives a command a shortcut; `-command` removes its default one. Commands without a menu item
(any in the command palette) can have shortcuts too.

### Profiles and sync

Settings → Profiles keeps named profiles ("Work", "Presenting"), each with its own settings,
keyboard shortcuts, snippets and which extensions are off; *Profiles: Switch Profile…* changes
between them (the current one is saved first). Export… and Import… move a profile as one
`.omcprofile` file. Choose a sync folder (iCloud Drive, Dropbox, a git repository) to keep profiles
there: your other Macs pick up changes when you come back to them.

## Extensions

Extensions are written in TypeScript or JavaScript against the `omc` API (`ExtensionAPI/omc.d.ts`)
and run in JavaScriptCore: each one in its own context, off the main thread, so a slow extension
can't freeze the editor. They can add commands with shortcuts, settings, notifications and status
bar items; work with documents, files, programs and the network (with the permissions they ask
for, shown before installing); and add whole languages: file types, TextMate grammars and
tree-sitter parsers, snippets, language servers and every language feature in code.

- *Extensions: New Extension…* (palette, or **+** in the Extensions sidebar) writes a Hello World
  in TypeScript, installs it for development and opens it; *Extensions: New Language Support
  Extension…* starts from a working toy language. Rebuild and run *Extensions: Reload* to try
  changes; each extension's log is in its details in the sidebar.
- **+** ▸ *Install from Folder…* installs an extension; *Import VS Code Language Extension…* brings
  over a VS Code extension's languages, grammars and snippets.

The developer guide, [`docs/extensions/`](docs/extensions/README.md), covers it all: a tutorial,
the `extension.json` and API references, the runtime and its permissions, debugging and testing,
publishing, the examples in `ExtensionAPI/examples`, a cookbook, and a guide for each part of
language support.

## Development

The bundle ID is `dev.zerovoid99.ohmycode`.

### Requirements

- Xcode 27+
- macOS 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Setup

```sh
xcodegen          # generates OhMyCode.xcodeproj from project.yml
open OhMyCode.xcodeproj
```

### Build & test from CLI

```sh
xcodebuild -scheme OhMyCode -destination 'platform=macOS' build
xcodebuild -scheme OhMyCode -destination 'platform=macOS' test
xcodebuild test -scheme OhMyCode -destination 'platform=macOS' -only-testing:OhMyCodeTests/SessionTests
```

Rules for contributors and agents are in [CLAUDE.md](CLAUDE.md).

### Performance

Typing stays under a millisecond, and opening shows the first screen in about 10 ms, whatever the
file's size: only what's on screen is laid out. Without word wrap, the text view is made as wide
as the file's widest line instead of giving TextKit a container wider than its view. That setup
made every keystroke update every paragraph after the cursor. Line positions after an edit are
shifted lazily, so typing in one place costs the same in a 20 MB file as in a small one. The
hot-exit backup writes only files that changed, at most every two seconds.

Opening a 20 MB file takes about 85 ms: the whole-file passes (line starts, the widest line,
tabs, merge conflict markers) read the text in chunks. Edits rescan for conflicts only in a
file that has a `<<<<<<<`, or when they type one. Highlight queries are compiled in the
background at launch (Swift's takes about 100 ms).

A syntax tree takes about 50 times the text's size in memory, so files over about 1 MB are parsed
a window at a time: what's on screen and 128 KB either side, starting and ending at top-level
lines. Scrolling out of it parses a new window in the background, and edits inside it reparse
incrementally. Such files are colored at any size, but their outline and folding come from the
language server (folding also from indentation), not from a part of the file. A 5 MB file adds
about 15 MB of memory instead of 270 MB.

Each editor group keeps the editors of its 8 most recently shown tabs (the hidden ones within
64 MB), so switching back to a tab shows its editor as it was left instead of building a new one.
`TabSwitchBenchmarks` times that the same way as `PerformanceBenchmarks`.

`PerformanceGuardTests` (in the normal test run) fail if typing in a big file gets slow again.
The full benchmarks (opening, typing, scrolling and memory for 1, 5 and 20 MB files) print their
timings:

```sh
TEST_RUNNER_OMC_BENCH=1 xcodebuild -scheme OhMyCode test -only-testing:OhMyCodeTests/PerformanceBenchmarks
```

That's a debug build, several times slower in places. For release numbers, add
`-configuration Release ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO` (the hardened runtime
won't load the test bundle).

Typing, scrolling and cursor moves are timed with their drawing: each step ends with layout and a
Core Animation commit, where the text, gutter and overlay draw what the step left dirty. The
minimap keeps its picture between frames and paints only the lines that changed (a keystroke's
line, lines scrolled into it, lines a new highlight result recolored); its slider is a layer of
its own. The
`.nodraw` numbers leave drawing out, like the benchmarks before November 2026 (whose
`displayIfNeeded` drew nothing). The window is never shown.

Launch times (from the process's start to the first window, the first editor drawn and its
first highlight, with nothing to restore and with a hot-exit session of 5 files, one of 5 MB):

```sh
TEST_RUNNER_OMC_BENCH=1 xcodebuild -scheme OhMyCode test -only-testing:OhMyCodeTests/LaunchBenchmarks
```

It launches a copy of the built app under its own bundle ID, in the background, with
`OMC_LAUNCH_TRACE=1` (windows transparent and click-through; milestones printed, then it quits
by itself) and `OMC_SUPPORT_DIR` (a scratch Application Support folder, so your sessions are
never read or written; the app's defaults — recent folders, settings, agents — are kept in it
too, and API keys in memory rather than the Keychain). The same variables work on any build.

Instruments' Points of Interest show intervals for opening a document, `textDidEdit`,
`applyHighlights`, parsing, and gutter and overlay drawing, and the launch milestones.

### Updates and releases

Installed copies update themselves from the GitHub releases (Sparkle, `AppUpdater`). They check
at launch and once a day (Settings ▸ Updates turns that off; Oh My Code ▸ Check for Updates…
checks now), show the new version's changelog, and download and install it only when asked. A
release's DMG is signed with an EdDSA key whose public half is `SUPublicEDKey` in
`project.yml`; an update whose signature doesn't match isn't installed. Debug builds don't
update themselves.

To release, with what's new under `## [Unreleased]` in `CHANGELOG.md`:

```sh
scripts/release.sh 0.1.2
```

It sets the version and the next build number, turns [Unreleased] into [0.1.2], commits and
pushes that, builds the app (Release, ad-hoc signed), makes the DMG, signs it, and creates the
GitHub release v0.1.2 with the DMG and an `appcast.xml` (the version, its notes from the
changelog, the DMG's signature). Installed copies read the latest release's `appcast.xml`.

The private key is in the login keychain of the Mac that makes releases (account `ohmycode`,
made once with Sparkle's `generate_keys --account ohmycode`). Without it no update can be
published that installed copies accept, so back it up: `generate_keys --account ohmycode -x
<file>` exports it, `-f <file>` imports it on another Mac. The script downloads Sparkle's tools
to `~/Library/Caches/ohmycode-release` on first use.

Trying an update without publishing anything: `scripts/release.sh --local 9.9.9 <folder>` builds
version 9.9.9 with its DMG and appcast in `<folder>`. Serve the folder over HTTP (Sparkle doesn't
read `file:` feeds), point the appcast's URL at it, and run a Release build with
`OMC_UPDATE_FEED=http://127.0.0.1:<port>/appcast.xml`.

The app is ad-hoc signed, so it carries the `com.apple.security.cs.disable-library-validation`
entitlement: without a Team ID, the hardened runtime won't load the embedded Sparkle framework.

### Third-party libraries

- [libghostty-vt](https://github.com/ghostty-org/ghostty) 1.0.1 (MIT): terminal emulation for
  the integrated terminal. Prebuilt XCFramework from `release.files.ghostty.org`, pinned by
  checksum in `Packages/GhosttyVt/Package.swift`.
- [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) and tree-sitter grammars
  (MIT): syntax highlighting.
- [Sparkle](https://sparkle-project.org) 2.10.1 (MIT): updates from the GitHub releases.
