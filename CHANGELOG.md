# Changelog

All notable changes to Oh My Code. Versions follow [Semantic Versioning](https://semver.org);
downloads are on the [releases page](https://github.com/zerovoid99/ohmycode/releases).

## [Unreleased]

### Added
- Peek Definition (⌥F12), Peek References (⌥⇧F12), Peek Implementations (⇧⌘F12) and Peek Type
  Definition: an editor opens under the line, pushing the lines below down, with the results
  listed beside it by file. Edits there are edits to the file (its open tab too, with undo);
  Enter opens the result in a tab, Esc closes. In the Go menu, the palette and the editor's
  context menu.
- Color decorators: a swatch before each color in CSS, SCSS, Less, HTML styles, JS/TS strings
  (hex, `rgb()`, `hsl()`, named colors) and Swift (`Color(red:…)`, `NSColor`, `UIColor`), and
  wherever a language server reports colors. Click it for the color panel: the literal is
  rewritten in its own format as you pick, one undo step per drag. Settings ▸ Editor, the
  folder setting `showsColorDecorators` and *View: Toggle Color Decorators* turn them off.
- Emmet in HTML-like files, JSX/TSX and CSS/SCSS/Less: Tab expands an abbreviation
  (`ul>li.item$*3>a{Link $}`, `!`, `m10-20`, `df+jcsb`) with tab stops, and the completion list
  offers it. *Emmet: Wrap with Abbreviation…*, *Balance Outward/Inward* and *Remove Tag* are
  in the palette. Settings ▸ Editor turns it, or its Tab, off.
- Compare: *Select for Compare* and *Compare with Selected* in the Explorer (files or folders),
  *Compare with…*, *with Clipboard* and *with Saved* on a tab and in the palette, and *File:
  Compare Folder with…*. A folder comparison lists what's only on one side and what differs
  (ignoring `.git`, `node_modules`, build folders and the folder's `.gitignore`), with a filter;
  click a file for its diff. Binary files say whether they differ.
- A spell checker for code: words in comments, strings, Markdown and names (split by case:
  `parseHTTPResponse` is parse, HTTP, Response) get a dotted underline, with a few hundred
  programming terms, URLs, hex and such left alone. Its fixes (right-click, ⌘. or 💡) offer
  suggestions in the word's case, Rename Symbol, *Add to Folder Dictionary*
  (`.omc/dictionary.txt`), *Add to User Dictionary* and *Ignore in This File*;
  `spell-checker: ignore …` comments work. Settings ▸ Editor ▸ Spell Check (language, names,
  listing in Problems) and the folder setting `spellCheck`.

## [0.2.4] - 2026-11-19

### Added
- Run and Debug finds an Xcode project's (or workspace's) Mac apps and command-line tools by
  itself, built with `xcodebuild` first, and offers Python: Current File in a folder with
  Python. Look Again for Programs (in its ⋯ menu) finds them after a change.
- Breakpoints can all be turned off or on at once, and each removed with its × on hover.

### Changed
- Run and Debug, reworked: a compact start bar (run, configuration, menu), a toolbar with
  hover states and a status dot while debugging, collapsible sections with counts, breakpoint
  rows that show their folder, condition or log message and mark as the gutter does, watch
  rows with edit and remove on hover (and "—" until the program pauses), and the exception
  breakpoints in one row with a menu instead of six checkboxes.
- The Agent panel, reworked: a header like the other panels (agent menu, status dot, New
  Thread, a ⋯ menu with Show Log), the thread's title, a rounded prompt box with attachment
  chips and a toolbar (attach, settings, send or stop), tool calls that expand only when there's
  more to see, a Copy button on code blocks, a plan that shows how much is done (and scrolls
  when long), permission requests as a card, and one layout for the empty, starting, failed
  and sign-in screens. Command output and code backgrounds follow the theme.
- The activity bar: the active panel's mark sits against the window edge, the icons are
  centered in the bar, and badges (changed files, an agent waiting or at work, a debug
  session) cut a ring out of the icon behind them and no longer run into the sidebar's edge.

### Fixed
- The Agent panel: a prompt sent while a new thread was opening went to the old one and was
  lost; a failed sign-in said nothing; ⌘↩ sent the prompt even while typing elsewhere; the
  conversation jumped to the bottom on every chunk while you read further up, and didn't follow
  command output or a permission request; attaching the same lines twice added them twice.
- Claude Code no longer lists Oh My Code windows that are gone: the lock files of windows
  whose app crashed or was killed are removed. A run started with `OMC_SUPPORT_DIR` keeps
  its lock files in that folder, and the tests keep the chosen agent out of your settings.
- The editor no longer seems to scroll by itself: scrolling up after jumping somewhere (a
  search result, Go to Line, the minimap) or after a pause, the lines on screen jumped by up to
  a few lines as the ones coming into view were laid out, most with word wrap (Markdown).

## [0.2.3] - 2026-11-18

### Added
- A database explorer for SQLite, PostgreSQL and MySQL / MariaDB: the new Database panel lists
  your connections (saved in the folder or for every window, passwords in the Keychain), and
  their schemas, tables, views, columns, keys and indexes. Add one with its details or a
  connection URL, and try it with Test Connection.
- Right-click a table for Select Top 100, Show DDL, Copy Name, Refresh, Truncate or Drop (both
  ask first). Opening a SQLite file from the Explorer shows its tables (Open as Hex is still there).
- `.sql` files get syntax colors, a connection in the status bar, completion of tables, columns
  and keywords, and ⌘↩ to run the statement at the cursor (⇧⌘↩ for the selection or the whole
  file, or click Run above a statement). New Query opens a scratch SQL file on a connection.
- Results open in a tab beside the file: a fast grid you can sort, resize and copy from (cells,
  rows as text, JSON, CSV or INSERT), each result set in its own segment, messages and rows
  affected, the time taken, Cancel while it runs, and export to CSV, JSON or Markdown. Errors are
  underlined where the database says they are.
- Query history per connection (the last 100), and with AI set up, Explain Query, Fix Query with
  AI, and the connection's schema included when you use ⌘I in a SQL file.
- Extensions can add whole languages: new file types (by extension, file name, pattern or first
  line), their comments, brackets, auto-closing and surrounding pairs, folding markers, word
  definition and Enter indentation rules (VS Code's `language-configuration.json`), and snippets.
  They can also add more file types or a configuration to a language the editor already knows.
- *Change Language Mode*: click the language in the status bar (or use the palette) to open a file
  as another language. `files.associations` in Settings ▸ Languages or a folder's
  `.omc/settings.json` (`{ "*.tpl": "html" }`) does it for every matching file.
- Extensions can bring language servers, started for their languages before the built-in ones,
  with their own settings. *Settings ▸ Languages* lists every language server with whether it's
  running, a switch to turn it off (`languageServers.<id>.enabled`), Restart, and its log. Work a
  server reports (indexing, building) shows in the status bar, and its messages as notifications.
- Language servers can now register features after they start, watch files (they hear when
  matching files are created, changed or deleted), ask for their settings, and show messages
  with choices.
- Extensions can provide Go to Definition, Type Definition and Implementation, Find References,
  the Outline and breadcrumbs, Go to Symbol in Workspace, quick fixes and refactorings (⌘. and
  the lightbulb), code lenses, signature help, rename, symbol highlights, links, folding, inlay
  hints, semantic colors, selection and on-type formatting, and richer completions (snippets,
  documentation, extra edits such as imports, commit characters), together with the language
  server's. Slow answers are cancelled when they're no longer needed.
- *Extensions: New Language Support Extension…* starts a new extension from a working toy
  language, and `ExtensionAPI/examples/toy-language` shows every part of language support.
- Extensions can color languages with TextMate grammars, the same `.tmLanguage.json` files VS
  Code extensions use: multi-line strings and comments, embedded languages (JavaScript inside
  HTML), injections, and grammars that include each other all work. Imported VS Code themes color
  them by their own token colors, the way VS Code does; the built-in themes color the common scopes.
- Extensions can also bring tree-sitter parsers, built into a library with the new
  `ExtensionAPI/tools/build-tree-sitter-grammar.sh`, with their highlight and folding queries.
  Because a parser is native code, the extension has to ask for the new `nativeCode` permission,
  and the install dialog says so.
- *Settings ▸ Languages ▸ Highlighting* picks what colors a language when there's a choice. The
  editor's own highlighting stays for the languages it knows unless you pick a grammar there (or
  the grammar asks to replace it).
- *Extensions: Import VS Code Language Extension…* installs the languages, grammars and snippets of
  an unpacked VS Code extension, so its colors and snippets work here too.
- *Developer: Inspect Editor Tokens and Scopes* shows what colors the text under the caret: its
  scopes or syntax nodes, the semantic token over it, and the theme rule that decides its color.
- The toy language example is now colored by its own grammar, and the guide
  `docs/extensions/syntax-highlighting.md` explains both kinds of grammars from start to finish.
- A developer guide for extensions in `docs/extensions/`: a tutorial from an empty folder to an
  installed extension, a reference for `extension.json` and for the whole API, how extensions run
  and what their permissions allow, debugging and testing, publishing, the examples explained, and
  a cookbook of recipes.

### Fixed
- Signature help now shows the documentation of signatures and parameters that language servers
  send as Markdown.

## [0.2.2] - 2026-11-18

### Added
- HTTP requests in `.http` and `.rest` files, in the format of VS Code's REST Client and JetBrains'
  HTTP Client: click *Send Request* after a request line (or press ⌥⌘R) and the response opens in
  a tab beside the file, with its status, time, size, a pretty-printed and colored body (or an
  HTML preview, an image, a hex dump), headers, cookies, a timeline and the request as sent.
- File, environment, system (`$guid`, `$randomInt`, `$timestamp`, `$datetime`, `$processEnv`,
  `$dotenv`…) and request variables, so one request can use another's response. Environments come
  from `.vscode/settings.json` or `.omc/settings.json` and from `http-client.env.json` (with a
  private file for secrets); pick one in the status bar.
- Prompts, notes, `@no-redirect`, `@no-cookie-jar`, file bodies, forms, multipart uploads, GraphQL
  and Basic authentication; a cookie jar and the last 50 requests' history per window (secrets
  taken out); Copy as cURL, Paste cURL as Request and code snippets for Swift, JavaScript and
  Python.
- Syntax colors, completion, problems (unknown variables, malformed lines, missing files),
  folding and an outline for `.http` files, and Explain Response with AI.

## [0.2.1] - 2026-11-18

### Added
- Explain with AI: right-click in the editor (or use the command palette) to have the selection,
  or the line at the cursor, explained in a popover. The explanation streams in and can be
  stopped, copied, or continued in the Agent sidebar with *Ask Agent*.
- Fix with AI: problems from language servers, extensions and tasks can be fixed with AI from the
  Problems panel, the hover, the editor's context menu and the ⌘. menu. The lines around the
  problem are rewritten and shown as a diff to accept (one undo step) or reject; if they changed
  meanwhile, the fix is refused.
- Explain with AI for terminal output: select an error or a stack trace in the terminal and
  right-click ▸ Explain with AI. The Tasks panel has a button that explains a run's output.
- Source Control can write the commit message with AI: the ✨ button beside the message writes a
  Conventional Commits message from the staged changes (or all changes when nothing is staged),
  in the repository picked in Source Control.
- These AI actions use the provider set up in Settings ▸ AI, are disabled (saying where to set it
  up) until there is one, and send nothing until you choose them. The README lists what each one
  sends.
- Extensions can see every folder in the window: `omc.workspace.folders`,
  `omc.workspace.getWorkspaceFolder(path)` and the `onDidChangeWorkspaceFolders` event.
  `rootPath` stays the first folder, and relative paths still start there.

### Changed
- With several folders in a window, the Testing sidebar lists every folder's tests, each under its
  folder's name. Each folder's tests are found and run in that folder with its own toolchain, Run
  All runs them all, and failures point at the right folder's files.
- Breakpoints are saved per folder: every folder in a workspace keeps its breakpoints across
  restarts, also when it's opened by itself, and the debugger gets the breakpoints of files in any
  folder. Breakpoints saved before move to their folder by themselves.

## [0.2.0] - 2026-11-18

### Added
- Images, PDFs and binary files open in a viewer tab instead of an error. Images fit the window
  and zoom with ⌘+, ⌘-, ⌘0, pinching or the footer's buttons, over a checkerboard where they're
  transparent, and update when the file changes; the footer shows the size in pixels, the file
  size and the format. SVG files show as a picture with *Open as Text* one click away. PDFs
  scroll and zoom, with the page count in the footer. Other binary files show as a read-only hex
  dump, read as you scroll so big files open at once, with *Open as Text Anyway*. Viewer tabs
  split, move, close and come back with the session like other tabs.
- UTF-16 text files (with a byte order mark) open in the editor and are saved as UTF-16.
- Vim mode, off until turned on in Settings → Editor or with Toggle Vim Mode in the palette:
  Normal, Insert, Visual, Visual Line and Replace modes, motions, operators with counts and text
  objects, registers (with the system clipboard as `"+`), `.` to repeat, `u` and ⌃R, search with
  `/` and `*`, and `:w`, `:q`, `:s` and other commands. The status bar shows the mode and the
  command line, and Normal mode has a block cursor. ⌘ shortcuts keep working in every mode.
- Several folders in one window: File ▸ Add Folder to Workspace… adds one (right-click a folder
  in the Explorer to remove it), and each shows as its own top-level folder with its git badges.
  Files can be dragged between folders.
- Workspace files: File ▸ Save Workspace As… keeps the folders (and settings for all of them) in
  a `.omc-workspace` file, and File ▸ Open Workspace… opens one. VS Code's `.code-workspace` files
  open too, also from Finder, `omc` and Open Recent, where workspaces have their own icon. A
  window with several folders that wasn't saved comes back at the next launch.
- With several folders, Quick Open and Find in Files search all of them and show each file's
  folder; `name/**` (or the folder menu) searches just one. Source Control lists each repository
  with its branch, and the status bar shows the branch of the active file's repository.
- Language servers, tasks, launch configurations, agents and the Claude Code integration work
  with every folder of the window; `${workspaceFolder}` is the task's own folder.

## [0.1.9] - 2026-11-18

### Added
- AI inline suggestions: after a pause in typing, a suggestion shows in grey at the cursor. Tab
  inserts it, ⌘→ its next word, Esc dismisses it, ⌥\ asks for one right away. Off until turned
  on; the status bar shows when one is being asked for, or why the last one failed.
- ⌘I edits the selection with AI: describe the change and the reply streams in as a diff to
  accept (⌘↩), reject (Esc) or open as a diff tab. Without a selection it writes code on a blank
  line.
- Settings ▸ AI: the Claude API or any OpenAI-compatible server (Ollama, LM Studio, OpenRouter,
  OpenAI), the models for suggestions and edits, and a Test button. API keys are kept in the
  Keychain.

## [0.1.8] - 2026-11-18

### Added
- An app icon: a lime orbit around </> in a hexagon, after the ZeroVoid Lab mark. On macOS 26
  and later it's drawn by the system in its own shape; the welcome window and the start page
  show it too.

### Fixed
- The commit popover shown when hovering the blame annotation stays open while the mouse moves
  up into it, and closes once the mouse leaves it.

## [0.1.7] - 2026-11-18

### Changed
- Saving (⌘S) a file that changed on disk since it was opened asks first: overwrite it, revert
  to what's on disk, or cancel.
- Files dropped on the Explorer from outside the folder (from Finder, say) are copied in, not
  moved.
- Closing a window with no folder asks about its unsaved files.
- A language server that crashes is started again (up to three times in three minutes), with
  the open files.

### Fixed
- Crashes: writing to an agent or language server that had just exited; out-of-range line
  numbers or sizes from a language server, extension or agent; editing inside a merge conflict
  right before its markers were rescanned.
- Files with Windows (CRLF) line endings: change markers, Revert and Stage Change, blame,
  Enter, snippets and multi-cursor movement now treat them line by line.
- Unsaved changes to a file deleted on disk (by a branch switch, say) are no longer dropped at
  the next launch; picking a profile sync folder no longer overwrites the profile already there;
  an unreadable keybindings.json is backed up before it's replaced; saving keeps a UTF-8 byte
  order mark and writes through symlinks.
- Tasks, terminals, the debugger, language servers and agent commands stop when their window
  closes or the app quits; closed terminals no longer leave processes behind.
- Agents and extensions can't reach files outside the folder through a symlink to a new file;
  extensions without the file-system permission can't write into .git; the Markdown preview
  stays on its own page; task variables such as ${file} are quoted for the shell.
- Completions replace the whole range the language server names and add the imports it asks
  for; breakpoints follow renamed files; a failed debug launch shows its error; whole-word
  search and replace match the same text; file names with [ ] or * stage and discard only
  themselves; files added with `git add -N` show in Source Control.
- Explorer rows no longer show the previous row's name and icon faded over them.

## [0.1.6] - 2026-11-17

### Added
- Earlier agent threads can be reopened (Agent sidebar ▸ ⋯ ▸ Open Earlier Thread), with the
  conversation shown again, for agents that can reopen sessions (Claude Code's adapter can).

### Changed
- A new look for finding your way around:
  - The sidebar's panels are an activity bar down its left edge, each icon with its name and
    shortcut, the active one marked, with counts where they help (changed files) and a dot when
    the agent is working or waiting for you. Settings is at its foot.
  - Each panel has a header naming it, with its actions (New File and New Folder in the
    Explorer, Refresh in Source Control).
  - An editor with no file open shows a start page: the folder and its branch, ways to get going
    with their shortcuts, and the files opened lately.
  - Files have icons by kind (Swift, Markdown, JSON, …) in the Explorer and on tabs; the active
    tab is marked with a line in the accent color.
  - The welcome window lists recent folders with their locations, and shows the version.
  - In the status bar, the branch opens Source Control, the cursor's position opens Go to Line,
    and the agent's work (or its question) shows, opening the Agent sidebar.
- Tool calls and permission requests in the Agent sidebar name files inside the folder by their
  path in it, not their full path.

## [0.1.5] - 2026-11-17

### Added
- Coding agents in the editor: the Agent sidebar talks to any agent that speaks the Agent Client
  Protocol (Claude Code and Codex through their adapters, Gemini CLI). It shows the reply, the
  plan, the files the agent reads and the commands it runs, asks before edits and commands, and
  shows proposed edits as diffs. Its model and other settings it offers are picked above the
  prompt. Agents are set up in Settings ▸ Agents.
- Claude Code in the terminal connects to the window, as it does to VS Code: it sees the open
  files, the selection and the problems, and its proposed edits open as diff tabs to accept or
  reject. ⌥⌘K sends the selected lines to it, and the status bar shows when it's connected.

## [0.1.4] - 2026-11-17

### Fixed
- Typing in one half of a split no longer moves the other half. With the other half further
  down a long file, each keystroke above it showed it other lines (thousands away in a 3 MB
  file); it now keeps its top line. Edits above the view from anywhere else (Replace All, a
  rename) keep it too.
- Typing above where another view of the same file has scrolled through stays fast. The lines
  laid out along the way are now dropped above and between views too, not only below them; a
  keystroke took 307 ms in a 3 MB file, now about 5.
- A file's history no longer reads a rename line with too few fields (the check applied only to
  copies).

## [0.1.3] - 2026-11-17

### Fixed
- Scrolling with the minimap shown no longer keeps the syntax highlighter busy. The minimap
  asked for the colors of the few hundred lines it shows at every line scrolled, about twice
  per scroll event (some 9 ms of background work each, delaying the editor's own colors); it
  now asks for half a minimap more each way, so once every half a minimap of scrolling.

## [0.1.2] - 2026-11-17

### Added
- Updates from the GitHub releases. Oh My Code checks at launch and once a day, shows what's
  new, and downloads and installs the update when you choose to, then relaunches. Turn the
  checks off in Settings ▸ Updates, or check now with Oh My Code ▸ Check for Updates…. Each
  update is signed, and one whose signature doesn't match isn't installed. Copies older than
  this version don't have it: install this one by hand once.

### Fixed
- Syntax colors that arrive after the text is drawn now show. A file just opened (or a window
  opened in the background) stayed uncolored until its lines were edited or scrolled, because
  TextKit doesn't redraw text whose rendering attributes change.
- Run and Debug no longer pushes the sidebar up under the title bar. With nothing to run, its
  text asked for a window 1,746 pt tall; in a shorter window the whole sidebar, its picker too,
  was cut off at the top.

## [0.1.1] - 2026-11-16

### Performance
- The minimap keeps its picture between frames. A keystroke repaints only its own line, and
  scrolling copies the rows already painted and paints only the lines that come into view.
  A new syntax highlight result repaints only the lines whose colors changed.
- Moving the minimap's slider paints nothing: the slider is a layer of its own.
- Drawing per keystroke went from 2.1 to 1.3 ms, and a full minimap repaint from 1.2 to 0.5 ms
  (Release, 1–20 MB files).

## [0.1.0] - 2026-11-16

First public build: a native macOS code editor for Apple silicon, with TextKit 2 editing,
tree-sitter highlighting, language servers, git, an integrated terminal and extensions.

### Performance
- Typing stays under a millisecond of editor work in files of any size; the first screen of a
  20 MB file shows in about 80 ms.
- Files over 1 MB are parsed a window at a time (a 5 MB file adds about 15 MB of memory).
- The gutter and overlays redraw only the rows and marks that change, and line numbers are drawn
  from cached glyphs.

[Unreleased]: https://github.com/zerovoid99/ohmycode/compare/v0.2.4...HEAD
[0.2.4]: https://github.com/zerovoid99/ohmycode/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/zerovoid99/ohmycode/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/zerovoid99/ohmycode/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/zerovoid99/ohmycode/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/zerovoid99/ohmycode/compare/v0.1.9...v0.2.0
[0.1.9]: https://github.com/zerovoid99/ohmycode/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/zerovoid99/ohmycode/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/zerovoid99/ohmycode/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/zerovoid99/ohmycode/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/zerovoid99/ohmycode/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/zerovoid99/ohmycode/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/zerovoid99/ohmycode/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/zerovoid99/ohmycode/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/zerovoid99/ohmycode/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zerovoid99/ohmycode/releases/tag/v0.1.0
