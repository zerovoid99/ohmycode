# Changelog

All notable changes to Oh My Code. Versions follow [Semantic Versioning](https://semver.org);
downloads are on the [releases page](https://github.com/zerovoid99/ohmycode/releases).

## [Unreleased]

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

[Unreleased]: https://github.com/zerovoid99/ohmycode/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/zerovoid99/ohmycode/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/zerovoid99/ohmycode/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/zerovoid99/ohmycode/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zerovoid99/ohmycode/releases/tag/v0.1.0
