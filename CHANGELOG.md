# Changelog

All notable changes to Oh My Code. Versions follow [Semantic Versioning](https://semver.org);
downloads are on the [releases page](https://github.com/zerovoid99/ohmycode/releases).

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

[0.1.1]: https://github.com/zerovoid99/ohmycode/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/zerovoid99/ohmycode/releases/tag/v0.1.0
