import AppKit

@MainActor
enum EditorTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.textColor]
    }

    // Palette (light, dark), inspired by Xcode's default themes.
    static let keyword = color(light: 0xAD3DA4, dark: 0xFF7AB2)
    static let string = color(light: 0xC41A16, dark: 0xFF8170)
    static let comment = color(light: 0x5D6C79, dark: 0x7F8C98)
    static let number = color(light: 0x1C00CF, dark: 0xD9C97C)
    static let type = color(light: 0x0B4F79, dark: 0x5DD8FF)
    static let function = color(light: 0x326D74, dark: 0x67B7A4)
    static let property = color(light: 0x3E8087, dark: 0x4EB0CC)
    static let attribute = color(light: 0x947100, dark: 0xCC9768)

    private static let captureColors: [String: NSColor] = [
        "keyword": keyword, "include": keyword, "conditional": keyword, "repeat": keyword,
        "exception": keyword, "storageclass": keyword, "variable.builtin": keyword,
        "string": string, "character": string, "string.special": string, "escape": number,
        "comment": comment,
        "number": number, "float": number, "boolean": keyword, "constant": number,
        "constant.builtin": keyword,
        "type": type, "constructor": type, "module": type, "namespace": type,
        "function": function, "method": function,
        "property": property, "field": property, "variable.member": property,
        "attribute": attribute, "tag": keyword, "label": attribute,
    ]

    private static var resolvedColors: [String: NSColor?] = [:]

    /// Color for a capture like `keyword.function`, falling back to `keyword`.
    static func color(forCapture name: String) -> NSColor? {
        if let resolved = resolvedColors[name] { return resolved }
        var components = name.split(separator: ".")
        var result: NSColor?
        while !components.isEmpty {
            if let color = captureColors[components.joined(separator: ".")] {
                result = color
                break
            }
            components.removeLast()
        }
        resolvedColors[name] = result
        return result
    }

    private static func color(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }
}
