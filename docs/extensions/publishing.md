# Publishing

There's no extension marketplace: an extension is shared as its folder — in a zip file, a git
repository, a release on GitHub — and installed from that folder. This page covers what goes in
the folder, versions, how people install and update, and staying compatible with the API.

## The id

The `id` (`publisher.name`) is the extension's identity: its folder in the extensions folder is
named after it, its settings and stored values are kept under it, and installing a folder with an
id that's already installed replaces that extension. Choose it before you share the extension and
don't change it: a new id is a new extension, installed beside the old one, without its settings.

*New Extension…* uses `local.<name>`: change `local` to your name, your GitHub user or your
organization (`acme.date-tools`).

## What to ship

Installing copies the **whole folder**. Make a folder that has only what the extension needs at
run time:

| Include | Why |
| --- | --- |
| `extension.json` | Required. |
| The main file (`dist/extension.js`), built | Required; the install checks it's there. |
| Everything `extension.json` names: language configurations, grammars, snippets, parser libraries and queries, a bundled language server | Contributions are read from these. |
| Files the code reads at run time | Anything it doesn't bundle. |
| `README.md`, `LICENSE` | For people reading the folder. |

| Leave out | Why |
| --- | --- |
| `node_modules/` | Build-time only: esbuild has put what the code uses into `dist/extension.js`. (Unless a contributed language server runs from it: then keep just that package.) |
| `src/`, `tsconfig.json`, `package.json`, `omc.d.ts`, tests | Not used at run time. Keeping `src/` does no harm if you want the source next to the code. |
| `.git/`, editor settings, build caches | Not the extension's. |

There's no ignore file: build the clean folder yourself. A script in `package.json` does it:

```json
"scripts": {
  "build": "esbuild src/extension.ts --bundle --format=cjs --platform=neutral --main-fields=module,main --target=es2020 --external:omc --outfile=dist/extension.js --minify",
  "package": "npm run build && rm -rf package && mkdir -p package/date-tools && cp -R extension.json dist README.md LICENSE package/date-tools/ && cd package && ditto -c -k --keepParent date-tools date-tools-$npm_package_version.zip"
}
```

`ditto` keeps permissions (a bundled server's executable bit) and extended attributes. Keep the
`version` in `package.json` and `extension.json` the same, or read it from one place.

**Native code.** A tree-sitter parser library or a server binary must be built for both Apple
silicon and Intel (`lipo -create`, or `build-tree-sitter-grammar.sh`, which does it). macOS
quarantines files downloaded in a browser; a library from a downloaded zip may be refused (“not
verified”) unless it's signed with a Developer ID and notarized. Without that, tell users to run
`xattr -dr com.apple.quarantine <folder>` after unzipping, or to build it themselves.

## Versions

`version` is shown in the Extensions sidebar and in the install dialog (“Replace Date Tools
1.1.0 with 1.2.0?”). The editor doesn't compare versions — installing an older one replaces a newer
one, after the same question — so it's for people: use [Semantic Versioning](https://semver.org).
Bump the major version when you rename or remove commands or settings users rely on.

Keep a changelog in the README or a `CHANGELOG.md`: the install dialog shows only the
description.

## Distributing

- **A zip** (the `package` script above): people unzip it and install the folder.
- **A git repository**: commit the built `dist/extension.js` (or attach the zip to releases), so
  people can install without building. Say in the README which folder to install, if it isn't the
  repository's top.
- **From source**: people clone it, run `npm install && npm run build`, and install the folder.

## Installing

Users install from the Extensions sidebar (the puzzle piece in the activity bar) → **+**:

| Choice | What it does |
| --- | --- |
| *Install from Folder…* | Asks for a folder with an `extension.json`, shows the extension's name, version, description and the permissions it asks for, and on **Install** copies the folder to `~/Library/Application Support/OhMyCode/Extensions/<id>`. |
| *Install for Development…* | The same, but links the folder instead of copying it (marked **DEV**): for working on an extension, not for using one. |
| *Import VS Code Language Extension…* | Converts an unpacked VS Code extension's languages, grammars and snippets into an Oh My Code extension and installs it ([details](syntax-highlighting.md#importing-a-vs-code-language-extension)). |
| *Open Extensions Folder* | Shows the extensions folder in Finder. |

The extension is enabled at once, in every open window. Each extension can be disabled with its
switch (the disabled list is part of the user's profile), and uninstalled with right-click ▸
*Uninstall…*, which also removes its settings and stored values.

Copying a folder into the extensions folder by hand works too: it's picked up the next time
extensions load (*Extensions: Reload*, or a new window), but no dialog shows its permissions.

## Updating

Users update by installing the new version's folder the same way: the dialog asks to replace the
installed one. Its settings and stored values are kept. Open windows stop the old version
(`deactivate`) and start the new one.

There's no automatic update check. If you want one, an extension with the `network` permission
can compare `omc.net.fetch` of your releases with its own version and show a notification — ask
for `network` only if the extension needs it for something else too.

## Compatibility

The API version is `omc.version` (`"0.3.0"` now). `extension.json` has no field for the API
version it needs (an `engines` field is ignored), so check at run time, when the extension starts:

```ts
import * as omc from "omc";

/** "0.3.0" → [0, 3, 0]. */
function parts(version: string): number[] {
  return version.split(".").map((part) => parseInt(part, 10) || 0);
}

function atLeast(version: string, minimum: string): boolean {
  const a = parts(version), b = parts(minimum);
  for (let i = 0; i < 3; i++) if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  return true;
}

export async function activate(context: omc.ExtensionContext) {
  if (!atLeast(omc.version, "0.3.0")) {
    await omc.window.showErrorMessage(`Date Tools needs a newer Oh My Code (API ${omc.version} < 0.3.0).`);
    return;
  }
  // Or check for one feature:
  if (typeof omc.languages.registerInlayHintsProvider === "function") {
    // …
  }
}
```

- Build against the `omc.d.ts` of the oldest app version you support.
- Unknown fields in `extension.json` are ignored, so a manifest written for a newer app installs on
  an older one; the newer contributions just don't do anything there.
- The API keeps VS Code's names and shapes; code written for it should keep working as the API
  grows.

## Before you publish

- [ ] `id` is yours, `version` is bumped, `description` says what it does.
- [ ] `permissions` lists only what the code uses.
- [ ] The packaged folder installs with *Install from Folder…* in a clean setup, and its commands
      work in a fresh window.
- [ ] Nothing it starts with is slow: `onStartup` only if it needs it ([performance](debugging-and-testing.md#performance)).
- [ ] The README says what it does, its commands, shortcuts and settings, and why it needs each
      permission.

## See also

- [The manifest](manifest.md): `id`, `version`, `permissions`.
- [Runtime and security](runtime-and-security.md): what users agree to when they install.
- [Getting started](getting-started.md#building-with-esbuild): the build.
