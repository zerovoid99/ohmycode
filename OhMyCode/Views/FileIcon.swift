import SwiftUI

/// A file's icon by its kind, in the Explorer, on tabs and in lists: a symbol and a color, so
/// kinds are told apart at a glance.
struct FileIcon: View {
    let name: String
    var isDirectory = false
    var isOpen = false

    var body: some View {
        let style = Self.style(for: name, isDirectory: isDirectory, isOpen: isOpen)
        Image(systemName: style.symbol)
            .foregroundStyle(style.color)
            .symbolRenderingMode(.hierarchical)
    }

    static func style(for name: String, isDirectory: Bool = false, isOpen: Bool = false) -> (symbol: String, color: Color) {
        if isDirectory {
            switch name.lowercased() {
            case ".git", ".github": return ("folder.badge.gearshape", .secondary)
            case "tests", "test", "spec", "__tests__": return ("folder", .green.opacity(0.8))
            default: return ("folder", Color(nsColor: .systemBlue).opacity(0.8))
            }
        }
        let lower = name.lowercased()
        switch lower {
        case "package.swift": return ("shippingbox", .orange)
        case "dockerfile": return ("shippingbox.fill", .blue)
        case "makefile", "justfile": return ("hammer", .secondary)
        case "license", "license.md", "license.txt": return ("checkmark.seal", .secondary)
        case ".gitignore", ".gitattributes", ".gitmodules": return ("arrow.triangle.branch", .orange)
        case ".editorconfig", ".env": return ("gearshape", .secondary)
        default: break
        }
        switch (lower as NSString).pathExtension {
        case "swift": return ("swift", .orange)
        case "m", "mm", "h", "c", "cpp", "cc", "hpp": return ("c.square", .blue)
        case "js", "mjs", "cjs", "jsx": return ("j.square", .yellow)
        case "ts", "tsx", "mts", "cts": return ("t.square", .blue)
        case "py": return ("p.square", .cyan)
        case "rs": return ("r.square", .orange)
        case "go": return ("g.square", .cyan)
        case "rb": return ("r.square", .red)
        case "java", "kt", "kts": return ("cup.and.saucer", .orange)
        case "json", "jsonc": return ("curlybraces", .yellow)
        case "yml", "yaml", "toml", "plist", "xcconfig", "ini", "conf": return ("gearshape", .secondary)
        case "md", "markdown", "mdx": return ("text.document", .blue)
        case "txt", "log": return ("doc.plaintext", .secondary)
        case "html", "htm", "xml", "svg": return ("chevron.left.forwardslash.chevron.right", .orange)
        case "css", "scss", "sass", "less": return ("paintbrush", .purple)
        case "sh", "bash", "zsh", "fish": return ("terminal", .green)
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "icns": return ("photo", .purple)
        case "pdf": return ("doc.richtext", .red)
        case "zip", "tar", "gz", "xz", "dmg": return ("archivebox", .secondary)
        case "lock", "resolved": return ("lock", .secondary)
        case "py.typed", "d.ts": return ("t.square", .blue)
        case "xcodeproj", "xcworkspace", "pbxproj": return ("hammer", .blue)
        case "sql": return ("cylinder", .teal)
        case "http", "rest": return ("network", .green)
        default: return ("doc", .secondary)
        }
    }
}
