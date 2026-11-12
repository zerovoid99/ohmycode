// swift-tools-version: 5.9
import PackageDescription

// libghostty-vt: Ghostty's terminal emulation core (VT parsing, screen state, key/paste
// encoding). Prebuilt XCFramework published by the Ghostty project; the checksum pins the
// exact file (it matches the signed SHA256SUMS of the vt-1.0.1 release).
let package = Package(
    name: "GhosttyVt",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GhosttyVt", targets: ["GhosttyVt"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1.xcframework.zip",
            checksum: "c0f9631277f726154c8f521954d17cdc41aac4626fc0df8cf925a19ee58e829b"
        ),
    ]
)
