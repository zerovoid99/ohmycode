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

## Third-party libraries
- [libghostty-vt](https://github.com/ghostty-org/ghostty) 1.0.1 (MIT): terminal emulation for
  the integrated terminal. Prebuilt XCFramework from `release.files.ghostty.org`, pinned by
  checksum in `Packages/GhosttyVt/Package.swift`.
- [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) and tree-sitter grammars
  (MIT): syntax highlighting.

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
