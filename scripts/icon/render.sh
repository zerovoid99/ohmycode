#!/bin/zsh
# Turns scripts/icon/Logo.svg into PNGs, with AppKit's SVG renderer (svg2png.swift):
# the app icon for macOS before 26 (Assets.xcassets/AppIcon.appiconset; 26 and later show
# OhMyCode/AppIcon.icon) and the logo the app shows (AppLogo.imageset).
# scripts/icon/generate.py writes the SVGs.
set -euo pipefail
cd "${0:A:h}/../.."
svg=scripts/icon/Logo.svg
assets=OhMyCode/Resources/Assets.xcassets
render() { # pixels, destination
    swift scripts/icon/svg2png.swift "$svg" "$2" $1
}
for px in 16 32 64 128 256 512 1024; do
    render $px "$assets/AppIcon.appiconset/icon_$px.png"
done
python3 - "$assets/AppIcon.appiconset/Contents.json" <<'PY'
import json, sys
path = sys.argv[1]
contents = json.load(open(path))
for image in contents["images"]:
    points = int(image["size"].split("x")[0])
    image["filename"] = "icon_%d.png" % (points * int(image["scale"][0]))
json.dump(contents, open(path, "w"), indent=2)
PY
mkdir -p "$assets/AppLogo.imageset"
render 512 "$assets/AppLogo.imageset/AppLogo.png"
cat > "$assets/AppLogo.imageset/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppLogo.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
