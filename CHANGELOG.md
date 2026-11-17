# Changelog

All notable changes to Oh My Code. Versions follow [Semantic Versioning](https://semver.org);
downloads are on the [releases page](https://github.com/zerovoid99/ohmycode/releases).

## [Unreleased]

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

[Unreleased]: https://github.com/zerovoid99/ohmycode/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/zerovoid99/ohmycode/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/zerovoid99/ohmycode/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/zerovoid99/ohmycode/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/zerovoid99/ohmycode/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/zerovoid99/ohmycode/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/zerovoid99/ohmycode/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/zerovoid99/ohmycode/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/zerovoid99/ohmycode/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zerovoid99/ohmycode/releases/tag/v0.1.0
