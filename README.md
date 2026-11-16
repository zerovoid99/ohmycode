# Oh My Code (OMC)

macOS desktop app — bundle ID `dev.zerovoid99.ohmycode`.

## Requirements
- Xcode 27+
- macOS 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Setup
```sh
xcodegen          # generates OhMyCode.xcodeproj from project.yml
open OhMyCode.xcodeproj
```

## Build & test from CLI
```sh
xcodebuild -scheme OhMyCode -destination 'platform=macOS' build
xcodebuild -scheme OhMyCode -destination 'platform=macOS' test
```

## Performance
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

`PerformanceGuardTests` (in the normal test run) fail if typing in a big file gets slow again.
The full benchmarks (opening, typing, scrolling and memory for 1, 5 and 20 MB files) print their
timings:

```sh
TEST_RUNNER_OMC_BENCH=1 xcodebuild -scheme OhMyCode test -only-testing:OhMyCodeTests/PerformanceBenchmarks
```

That's a debug build, several times slower in places. For release numbers, add
`-configuration Release ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO` (the hardened runtime
won't load the test bundle).

## Third-party libraries
- [libghostty-vt](https://github.com/ghostty-org/ghostty) 1.0.1 (MIT): terminal emulation for
  the integrated terminal. Prebuilt XCFramework from `release.files.ghostty.org`, pinned by
  checksum in `Packages/GhosttyVt/Package.swift`.
- [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) and tree-sitter grammars
  (MIT): syntax highlighting.

## Opening folders and files
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

## Quick fixes and parameter hints
With a language server, a 💡 appears beside the cursor's line when there are fixes for a problem on
it; ⌘. lists them with the server's refactorings and source actions (the preferred fix in bold).
⌥⇧O organizes imports. Typing a call's `(` shows its signature above the cursor, the current
argument in bold, following you through the arguments (⇧⌘Space shows it by hand, Esc hides it).
Inlay hints show what the server infers inside the code — a variable's type (`let total: Int`),
an argument's parameter name — without changing the text; they're turned off in Settings → Editor
or with *View: Toggle Inlay Hints*.

## Formatting
⇧⌥F formats the file with the language server (or an extension's formatter). *Format Selection*
(palette, or the editor's right-click menu) formats only the selected lines. Format on save
(Settings → Editor) can format the whole file or only the lines changed since the last commit. The
second keeps your edits tidy in a repository that isn't formatted yet; files not in git are
formatted whole. A slow formatter never holds up saving: after two seconds the file is saved as it
is.

## Code lens
Language servers that offer code lenses (TypeScript, Rust, Go and others) show them dimmed after
the line they're about, for example "3 references" after a function. Click one to run it:
references open in the sidebar, other commands run on the server. They update a moment after you
stop typing, and move with their lines meanwhile. Turn them off in Settings → Editor or with
*View: Toggle Code Lens*.

## Semantic highlighting
With a language server that classifies names (sourcekit-lsp does), types, functions and properties
get the theme's colors for what they really are, over the syntax tree's guess. Variables and
parameters get the plain text color. Colors stay in place while you type and are updated a moment
after you pause. Files over 20,000 lines keep the syntax colors only. Turn it off in
Settings → Editor.

## Symbol highlights
Putting the cursor on a symbol highlights where else it appears in the file. With a language server
these are its own places (the same name in another scope isn't), and places where it's assigned are
outlined. Without one, the same whole word is highlighted. Selecting text on one line highlights the
same text elsewhere. F7 and ⇧F7 go to the next and previous place. Highlights are turned off in
Settings → Editor or with *View: Toggle Symbol Highlights*.

## Terminal
⌃` shows the integrated terminal and ⌃⇧` opens another one in a new tab. The ⊟ button (or
*Terminal: Split Terminal*) opens a shell beside the active one in the same tab. Click a pane to
type in it; a thin accent line marks the active pane. Closing a pane gives its place to its
neighbour. Double-click a tab, or right-click it, to rename it: the name stays until you clear it,
even when the shell sets its own title. Right-click also has *Split Terminal* and *Kill Terminal*.

⌘-click a file path in the terminal's output to open it in the editor at its line and column, as
compilers and test runners print them (`Sources/App/main.swift:12:5`, Python's
`File "x.py", line 3`). Relative paths are resolved from where the shell started. ⌘-click a URL to
open it in the browser. The pointer turns into a hand over links while ⌘ is held.

## GitHub pull requests
The Pull Requests sidebar lists the repository's open pull requests through the GitHub CLI
(`brew install gh`, then `gh auth login`). Each one shows its author, branch, draft state and
review decision. Click one to read its description, changed files (click to open), reviews and
comments. *Check Out* switches to its branch, and the compass button opens it on GitHub. The +
button (or *GitHub: Create Pull Request…*) creates one from the current branch. The form starts
with the last commit's subject and body, and the branch is pushed first if it has no upstream.

## Merge conflicts
Conflicted files show each conflict tinted (current green, incoming blue, base gray), with
*Accept Current*, *Accept Incoming*, *Accept Both*, *Compare* and *Merge Editor* above it.

The merge editor (*Merge Editor*, or *Git: Open Merge Editor*) goes through the file's conflicts
one by one:

- current, base (when git kept it: `merge.conflictStyle diff3`) and incoming side by side;
- take one side, both, or both with the incoming first (or *Accept All*);
- a live preview of the resulting file.

*Apply* makes all the choices one undo step. Conflicts left unresolved keep their markers. Saving a
file with no markers left stages it.

## Files in the Explorer
Right-click in the Explorer for *New File…*, *New Folder…*, *Rename…*, *Move to Trash*,
*Reveal in Finder*, *Copy Path* and *Copy Relative Path*. Clicking empty space puts new items at
the top of the folder. A new file's name can include folders (`src/util.ts`), which are created
too. Drag an item onto a folder to move it.

Renaming or moving first asks the language servers that want to know (TypeScript does) for the
edits that keep references working, such as imports that name the file. Those edits are applied
unsaved, so you can review and save or undo them, before the file moves. Open tabs follow the file
to its new name, with their unsaved changes.

## Folding
The ⌄ in the gutter, ⌥⌘[ and ⌥⌘] fold and unfold code. Regions follow the code's structure:

- the language server's folding ranges, or the syntax tree's;
- a block folds from its first line (a function, even with its parameters on several lines) to
  the line before its closing bracket;
- multi-line comments and runs of `//` lines fold;
- a run of imports folds;
- `// MARK:` sections fold to the next MARK, and `#region` to its `#endregion`.

Languages without brackets (Python, YAML) fold by indentation. *Fold All*, *Fold All Comments*
and *Fold Level 1/2/3* are in the palette.

## Zen mode
⌥⌘Z (View → Zen Mode) leaves only the text: the sidebar, tabs, breadcrumbs, bottom panel and status
bar hide, the editor is centered at about 100 columns and the window goes full screen (unless
turned off in Settings → Editor). ⌥⌘Z again, or Esc twice in the editor, puts everything back as
it was.

## Word wrap
Long lines wrap at the editor's edge in Markdown and plain text, and scroll sideways in code.
Settings → Editor → Word wrap changes that to always or never. ⌥Z (*View: Toggle Word Wrap*)
switches it for the active file until it's closed. Line numbers, breakpoints and other gutter marks
stay on a wrapped line's first row.

## Tabs and whitespace
A tab is drawn as wide as the file's tab width in spaces: `.editorconfig`'s `tab_width`, otherwise
the indentation's width. Tab-indented code lines up with space-indented code and with the indent
guides. Spaces show as · and tabs as → in the selection. Settings → Editor → Show whitespace
changes that to never, leading/trailing/repeated, or all. *View: Toggle Render Whitespace* switches
between all and the selection.

## Brackets and indent guides
With the cursor beside a bracket (`(`, `[`, `{`), it and its match are outlined. Brackets inside
strings and comments don't count. ⇧⌘\ goes to the matching bracket, or from inside a pair to its
closing bracket. Thin indent guides mark each indentation level. The guide of the block the cursor
is in (or the block its line opens) is drawn brighter. Both can be turned off in Settings → Editor;
*View: Toggle Indent Guides* is in the palette.

## Linked tag editing
In HTML, XML, Markdown and JSX/TSX, typing or deleting in a tag's name changes its closing tag
(or opening tag) the same way, as one undo step. Nested tags with the same name are matched
correctly, and self-closing tags and tags still being typed are left alone. Turn it off in
Settings → Editor.

## Line editing
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

## Links
URLs written in any file (`https://`, `http://`, `ftp://`, `file://`) and links the language server
finds (such as an import's path) are underlined while ⌘ is held over them. ⌘-click opens them:
web links in the browser, and files in the editor (`#L12` goes to line 12). Elsewhere, ⌘-click is
still Go to Definition. Right-clicking a link offers *Open Link* and *Copy Link Address*.

## Outline and breadcrumbs
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

## EditorConfig
`.editorconfig` files in a file's folder and the folders above it (up to one with `root = true`)
set its indentation and what saving fixes, as in other editors. Supported: `indent_style`,
`indent_size`, `tab_width`, `end_of_line`, `trim_trailing_whitespace` and `insert_final_newline`.
Indentation applies to Enter, snippets and formatting; without a setting it's judged from the file.
The fixes made when saving are one undoable step. The status bar shows the indentation and line
endings; hover them to see which `.editorconfig` set them. Editing an `.editorconfig` applies it to
open files at once.

## Folder settings
A folder's `.omc/settings.json` overrides the app's settings for files in it.
*Preferences: Open Folder Settings* writes one with every option commented out. It understands:

- `formatOnSave`, `formatOnSaveScope` (`file`, `modifications`);
- `autoSave` (`off`, `afterDelay`, `onFocusChange`), `autoSaveDelay`;
- `wordWrap` (`off`, `on`, `prose`), `renderWhitespace` (`none`, `selection`, `boundary`, `all`);
- `showsInlayHints`, `semanticHighlighting`, `showsCodeLens`.

Comments and trailing commas are allowed. Changes apply when the file is saved, even from another
editor. Names it doesn't know, and a file that isn't valid JSON, are reported. Indentation and line
endings come from `.editorconfig`.

## Unsaved changes, auto save and hot exit
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

## Local history
Every save keeps a version of the file (and the version on disk before it, or before another
program replaced it), whether or not the file is in git. They're listed in the Timeline above the
commits: click one to compare it with the current text, or restore it (one undoable change).
*Local History: Restore a Saved Version…* does it from the command palette. Up to 50 versions per
file are kept for 30 days, in `~/Library/Application Support/OhMyCode/History`.

## Tasks and Problems
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

## Snippets
Snippets come up in completion and expand with Tab after their prefix (`guard⇥`); Tab and ⇧Tab
then move between their placeholders, typing in a repeated one changes every copy, Esc finishes.
Built-in ones cover Swift, Python, Rust, Go, C/C++, JavaScript/TypeScript, shell, Markdown and HTML.
Your own, in VS Code's format, go in `~/Library/Application Support/OhMyCode/Snippets/<language>.json`
(*Snippets: Configure User Snippets*) or the folder's `.omc/snippets/` and `.vscode/*.code-snippets`.

## Markdown preview
⇧⌘V shows a Markdown file rendered beside it (GitHub-style tables, task lists, highlighted code,
local images). It updates as you type and scrolls with the editor both ways; double-click a part
of the preview to go to its source. Scripts in the Markdown don't run.

## Testing
The Testing sidebar lists the folder's tests, found by reading test files: Swift packages and Xcode
projects (XCTest and Swift Testing), Go, Python (pytest if it's installed, else unittest), Jest, Vitest and Rust.
⌘U runs them all, ⌃⌥⌘U the test at the cursor; the ▶ in the gutter runs one test or suite and
then shows ✓ or ✗. Failures appear under the test, in the editor and in Problems; the run's output
is in the Tasks panel. Xcode projects and workspaces (without a Package.swift) run with
`xcodebuild test`: the project's own scheme, on the Mac or, for an iOS project, the first iPhone
simulator; their test files are the Swift files in the test targets' folders.

## Profiles and sync
Settings → Profiles keeps named profiles ("Work", "Presenting"), each with its own settings,
keyboard shortcuts, snippets and which extensions are off; *Profiles: Switch Profile…* changes
between them (the current one is saved first). Export… and Import… move a profile as one
`.omcprofile` file. Choose a sync folder (iCloud Drive, Dropbox, a git repository) to keep profiles
there: your other Macs pick up changes when you come back to them.

## Keyboard shortcuts
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

## Debugging
Run and Debug (⇧⌘D, F5) debugs with LLDB through the Debug Adapter Protocol (`lldb-dap`, part of
Xcode): Swift, C, C++ and Objective-C. A Swift package's executables are found by themselves
(built with `swift build` first); anything else goes in `.omc/launch.json`:

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

Click a line number (or F9) for a breakpoint; its context menu in the Breakpoints list adds a
condition or turns it into a logpoint (prints `x is {x}` instead of stopping). The Breakpoints list
also stops on thrown Swift, C++ or Objective-C exceptions. F10/F11/⇧F11 step over/into/out.
Watch expressions are evaluated at every stop; a variable's context menu sets its value. The Debug
Console shows the program's output and evaluates expressions in the selected frame (start with a
backtick for an LLDB command).

- **Attach:** *Debug: Attach to Process…* picks one of your running processes, or put
  `"request": "attach"` with a `"pid"` (or a `"program"` to wait for) in launch.json. Stopping lets
  the process go on.
- **Other debuggers:** `"type": "python"` uses debugpy (`pip install debugpy`); any debug adapter
  speaking DAP over stdio works with `"adapter": ["command", "args"…]`, and `"adapterArguments"`
  adds to its launch request.

## Extensions
Extensions are written in TypeScript or JavaScript and run in JavaScriptCore: each one in its
own context, off the main thread, so a slow extension can't freeze the editor. They can only
reach the app through the `omc` API (`ExtensionAPI/omc.d.ts`).

An extension is a folder with an `extension.json` and its compiled main file:

```json
{
  "id": "publisher.name",
  "name": "My Extension",
  "version": "1.0.0",
  "main": "dist/extension.js",
  "activationEvents": ["onStartup"],
  "contributes": {
    "commands": [{ "command": "my.hello", "title": "Say Hello", "category": "My" }],
    "configuration": { "my.greeting": { "type": "string", "default": "Hello" } },
    "keybindings": [{ "command": "my.hello", "key": "cmd+shift+h", "when": "editorTextFocus" }]
  },
  "permissions": []
}
```

- **Main file:** CommonJS that exports `activate(context)` and optionally `deactivate()`. Compile
  TypeScript with `tsc` (`"module": "commonjs"`) or `esbuild --format=cjs --bundle`. Only `omc` can
  be `require`d, so bundle other dependencies.
- **Activation:** `onStartup` (or `*`) when the window opens, `onLanguage:<id>` when such a file
  opens, and on first use of any command listed under `contributes.commands` (those also show in
  the command palette).
- **Keybindings:** `key` is like `cmd+shift+h`, `ctrl+alt+f5` (cmd, ctrl or alt needed, except
  for function keys); `when` can use `editorTextFocus` and `editorLangId == swift`, joined with
  `&&` and negated with `!`. A shortcut a menu item already has stays the menu's.
- **Language features:** `omc.languages` adds completion, hover and formatting providers and
  diagnostics for any language, shown together with the language server's.
- **Limits:** JavaScript that runs 5 seconds without returning is stopped (the extension keeps
  running); `activate()` gets 10 seconds, providers 1.5 seconds.
- **Permissions:** the extension can always use the editor and files in the open folder. It needs
  `process` to run programs, `network` to make requests, and `fileSystem` for files elsewhere. The
  permissions are shown before installing.
- **New extension:** *Extensions: New Extension…* (palette, or **+** in the Extensions sidebar)
  writes a Hello World in TypeScript, already compiled, installs it for development and opens it
  in a new window. `npm install && npm run build` compiles changes.
- **Installing:** Extensions sidebar → **+** → *Install from Folder…* copies the folder into
  `~/Library/Application Support/OhMyCode/Extensions`. *Install for Development…* links it
  instead: rebuild, then use *Reload Extensions* to try changes. Each extension's log
  (`console.log`, errors) is in its details.

See `ExtensionAPI/examples/word-count` for a complete extension.
