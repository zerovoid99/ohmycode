#!/bin/zsh
# Makes a release that installed copies update to (Sparkle, see OhMyCode/App/AppUpdater.swift).
#
#   scripts/release.sh 0.1.2
#       The CHANGELOG's [Unreleased] section becomes [0.1.2] - today; project.yml gets the
#       version and the next build number; that's committed ("chore(release): 0.1.2") and
#       pushed. Then the app is built (Release, ad-hoc signed), put in a DMG, the DMG signed
#       with the EdDSA key in your keychain (account "ohmycode"), and a GitHub release v0.1.2
#       created with the DMG and an appcast.xml describing it. Installed copies read the latest
#       release's appcast.xml (SUFeedURL).
#
#   scripts/release.sh --local 9.9.9 <folder> [build number]
#       Only the build, DMG, signature and appcast, into <folder>, for that version (nothing is
#       changed, committed or published). The appcast points at the DMG in <folder>: run a
#       build with OMC_UPDATE_FEED=file://<folder>/appcast.xml to try an update.
#
# Needs: Xcode, xcodegen, gh (logged in), the signing key (scripts/release.sh makes no key:
# Sparkle's generate_keys does, once). Sparkle's tools are downloaded on first use.
set -euo pipefail

REPO=zerovoid99/ohmycode
SPARKLE_VERSION=2.10.1
KEY_ACCOUNT=ohmycode
MIN_SYSTEM=15.0
ROOT=${0:A:h:h}
cd "$ROOT"

die() { print -u2 "release: $*"; exit 1; }

local_mode=false
if [[ ${1:-} == --local ]]; then
    local_mode=true
    VERSION=${2:?version}
    OUT=${3:?folder}
    BUILD=${4:-$(( $(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?/\1/p' project.yml) + 1 ))}
    mkdir -p "$OUT"
    OUT=${OUT:A}
else
    VERSION=${1:?usage: scripts/release.sh <version> | --local <version> <folder> [build]}
fi
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "version must look like 1.2.3"
TAG=v$VERSION

# Sparkle's tools (sign_update), from its release, cached per version.
TOOLS=${SPARKLE_BIN:-$HOME/Library/Caches/ohmycode-release/Sparkle-$SPARKLE_VERSION/bin}
if [[ ! -x $TOOLS/sign_update ]]; then
    print "Downloading Sparkle $SPARKLE_VERSION's tools…"
    download=$(mktemp -d)
    gh release download $SPARKLE_VERSION -R sparkle-project/Sparkle -p "Sparkle-$SPARKLE_VERSION.tar.xz" -D "$download"
    mkdir -p "${TOOLS:h}"
    tar -xJf "$download/Sparkle-$SPARKLE_VERSION.tar.xz" -C "${TOOLS:h}"
    rm -rf "$download"
fi
"$TOOLS/generate_keys" --account $KEY_ACCOUNT -p >/dev/null 2>&1 \
    || die "no signing key in the keychain (account \"$KEY_ACCOUNT\"); updates signed with another key won't install"
public_key=$("$TOOLS/generate_keys" --account $KEY_ACCOUNT -p 2>/dev/null | tail -1)
[[ $public_key == $(sed -nE 's/^ *SUPublicEDKey: *//p' project.yml) ]] \
    || die "the keychain's key isn't the one in project.yml (SUPublicEDKey)"

if ! $local_mode; then
    [[ -z $(git status --porcelain) ]] || die "commit or stash your changes first"
    [[ $(git branch --show-current) == main ]] || die "release from main"
    git fetch -q origin main --tags
    [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || die "main isn't the same as origin/main"
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "$TAG exists already"
    grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md has no [Unreleased] section"

    # Version and build number.
    BUILD=$(( $(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "?([0-9]+)"?/\1/p' project.yml) + 1 ))
    sed -i '' -E "s/^( *MARKETING_VERSION: )\"[^\"]*\"/\1\"$VERSION\"/; s/^( *CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\1\"$BUILD\"/" project.yml
    xcodegen >/dev/null

    # [Unreleased] becomes this version; a new empty one goes above it.
    previous=$(git describe --tags --abbrev=0 --match 'v*')
    python3 - "$VERSION" "$(date +%F)" "$previous" <<'EOF'
import re, sys
version, date, previous = sys.argv[1:]
text = open("CHANGELOG.md").read()
text = text.replace("## [Unreleased]", "## [Unreleased]\n\n## [%s] - %s" % (version, date), 1)
text = re.sub(r"^\[Unreleased\]: .*$",
              "[Unreleased]: https://github.com/zerovoid99/ohmycode/compare/v%s...HEAD\n"
              "[%s]: https://github.com/zerovoid99/ohmycode/compare/%s...v%s" % (version, version, previous, version),
              text, count=1, flags=re.M)
open("CHANGELOG.md", "w").write(text)
EOF
    git add project.yml OhMyCode.xcodeproj CHANGELOG.md
    git commit -q -m "chore(release): $VERSION"
    git push -q origin main
    OUT=$(mktemp -d)
fi

# The changelog's section for this version (in local mode, [Unreleased]'s).
section=$( $local_mode && print Unreleased || print $VERSION )
notes=$(awk -v head="## [$section]" '
    index($0, head) == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on && /^\[[^]]+\]: / { exit }
    on { print }' CHANGELOG.md | sed -e '/./,$!d')
[[ -n ${notes//[[:space:]]/} ]] || die "the changelog's [$section] section is empty"

# Build, DMG, signature.
DERIVED=$OUT/build
print "Building $VERSION ($BUILD)…"
xcodebuild -project OhMyCode.xcodeproj -scheme OhMyCode -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD build -quiet
APP="$DERIVED/Build/Products/Release/Oh My Code.app"
codesign --verify --deep --strict "$APP"
DMG_NAME=OhMyCode-$VERSION.dmg
DMG=$OUT/$DMG_NAME
stage=$(mktemp -d)
ditto "$APP" "$stage/Oh My Code.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Oh My Code $VERSION" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"
# Launch Services registered the built copies: left registered, they show in Spotlight and
# Launchpad as more copies of the app (and stay listed once their folder is gone).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" 2>/dev/null || true
"$LSREGISTER" -u "$stage/Oh My Code.app" 2>/dev/null || true
rm -rf "$stage"
signature=$("$TOOLS/sign_update" --account $KEY_ACCOUNT "$DMG")  # sparkle:edSignature="…" length="…"
sha=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

if $local_mode; then
    url="file://$DMG"
else
    url="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
fi

# The appcast: this release, its notes as HTML.
NOTES=$notes python3 - "$OUT/appcast.xml" "$VERSION" "$BUILD" "$url" "$signature" "$MIN_SYSTEM" "$REPO" <<'EOF'
import html, os, re, sys
from email.utils import formatdate
path, version, build, url, signature, minimum, repo = sys.argv[1:]
notes = os.environ["NOTES"]

def inline(text):
    text = html.escape(text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)

out, items, para = [], [], []
def flush():
    global items, para
    if items: out.append("<ul>" + "".join("<li>%s</li>" % inline(i) for i in items) + "</ul>"); items = []
    if para: out.append("<p>%s</p>" % inline(" ".join(para))); para = []
for line in notes.splitlines():
    if line.startswith("#"):
        flush(); out.append("<h3>%s</h3>" % inline(line.lstrip("#").strip()))
    elif line.startswith("- "):
        if para: flush()
        items.append(line[2:].strip())
    elif line.startswith("  ") and items:
        items[-1] += " " + line.strip()
    elif not line.strip():
        flush()
    else:
        para.append(line.strip())
flush()

open(path, "w").write("""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Oh My Code</title>
    <link>https://github.com/%s/releases</link>
    <item>
      <title>Oh My Code %s</title>
      <pubDate>%s</pubDate>
      <sparkle:version>%s</sparkle:version>
      <sparkle:shortVersionString>%s</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>
      <description><![CDATA[%s]]></description>
      <enclosure url="%s" type="application/octet-stream" %s/>
    </item>
  </channel>
</rss>
""" % (repo, version, formatdate(usegmt=True), build, version, minimum, "\n".join(out), html.escape(url, quote=True), signature))
EOF

if $local_mode; then
    rm -rf "$DERIVED"
    print "Built $DMG_NAME and appcast.xml in $OUT"
    exit 0
fi

# The GitHub release: the notes, how to install, the checksum.
cat > "$OUT/notes.md" <<EOF
## Changelog

$notes

Full history: [CHANGELOG.md](https://github.com/$REPO/blob/main/CHANGELOG.md) · Changes: [$previous...$TAG](https://github.com/$REPO/compare/$previous...$TAG)

## Download
\`$DMG_NAME\`: open it and drag **Oh My Code** to Applications. Requires macOS $MIN_SYSTEM or later on an Apple silicon Mac. Copies from 0.1.2 on update themselves (Oh My Code ▸ Check for Updates…).

This build is ad-hoc signed and not notarized. The first time you open it, right-click the app and choose **Open**, or run:

\`\`\`sh
xattr -dr com.apple.quarantine "/Applications/Oh My Code.app"
\`\`\`

SHA-256: \`$sha\`
EOF
gh release create "$TAG" "$DMG" "$OUT/appcast.xml" -R $REPO --target main --title "Oh My Code $VERSION" --notes-file "$OUT/notes.md"
rm -rf "$OUT"
