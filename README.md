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
