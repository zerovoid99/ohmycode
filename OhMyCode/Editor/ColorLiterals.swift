import AppKit

/// A color as code writes it: sRGB channels and alpha, each 0...1.
struct RGBAColor: Equatable, Hashable, Sendable {
    var red, green, blue, alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func clamp(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
        (self.red, self.green, self.blue, self.alpha) = (clamp(red), clamp(green), clamp(blue), clamp(alpha))
    }

    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    /// Equal once written as 8-bit channels (what a hex color or a color panel can tell apart).
    func isClose(to other: RGBAColor) -> Bool {
        func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
        return byte(red) == byte(other.red) && byte(green) == byte(other.green) && byte(blue) == byte(other.blue)
            && byte(alpha) == byte(other.alpha)
    }

    var isOpaque: Bool { alpha >= 0.9995 }

    /// Hue, saturation and lightness (hue in degrees, the others 0...1).
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 1e-9 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        return (hue(maximum: maximum, delta: delta), min(saturation, 1), lightness)
    }

    /// Hue, saturation and brightness, each 0...1 (as Swift's `Color(hue:…)` takes them).
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 1e-9 else { return (0, 0, maximum) }
        return (hue(maximum: maximum, delta: delta) / 360, delta / maximum, maximum)
    }

    private func hue(maximum: Double, delta: Double) -> Double {
        var hue: Double
        if maximum == red { hue = (green - blue) / delta } else if maximum == green { hue = (blue - red) / delta + 2 } else { hue = (red - green) / delta + 4 }
        hue *= 60
        return hue < 0 ? hue + 360 : hue
    }

    init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let s = min(max(saturation, 0), 1), l = min(max(lightness, 0), 1)
        let chroma = (1 - abs(2 * l - 1)) * s
        self.init(hueSector: hue, chroma: chroma, offset: l - chroma / 2, alpha: alpha)
    }

    init(hue: Double, saturation: Double, brightness: Double, alpha: Double = 1) {
        let s = min(max(saturation, 0), 1), v = min(max(brightness, 0), 1)
        let chroma = v * s
        self.init(hueSector: hue * 360, chroma: chroma, offset: v - chroma, alpha: alpha)
    }

    private init(hueSector degrees: Double, chroma: Double, offset: Double, alpha: Double) {
        let h = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch h {
        case ..<1: (chroma, x, 0)
        case ..<2: (x, chroma, 0)
        case ..<3: (0, chroma, x)
        case ..<4: (0, x, chroma)
        case ..<5: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        self.init(red: r + offset, green: g + offset, blue: b + offset, alpha: alpha)
    }
}

/// A color written in the text: where, which color, and the text (to rewrite it in its format).
struct ColorLiteral: Equatable, Sendable {
    var range: NSRange
    var text: String
    var color: RGBAColor
}

/// How a file's colors are found.
enum ColorSyntax: Sendable {
    /// Stylesheets: colors where a CSS value can be.
    case css
    /// HTML-like files: CSS colors in `style` attributes and `<style>` blocks only.
    case markup
    /// JavaScript and TypeScript: CSS colors inside strings.
    case script
    /// `Color(red:green:blue:)`, `NSColor(…)`, `UIColor(…)` with number literals.
    case swift

    static func of(_ language: SourceLanguage) -> ColorSyntax? {
        switch language.rawValue {
        case "css", "scss", "less", "sass", "stylus", "postcss": .css
        case "html", "svelte", "vue": .markup
        case "javascript", "typescript", "tsx", "javascriptreact", "typescriptreact", "jsx": .script
        case "swift": .swift
        default: nil
        }
    }
}

/// Finding colors in code, and writing a changed color back in the same format.
enum ColorLiterals {
    // MARK: Parsing one literal

    /// The color `text` (one whole literal) is, in any format this knows.
    static func color(of text: String) -> RGBAColor? {
        if text.hasPrefix("#") { return hexColor(text) }
        if let parsed = cssFunction(text) { return parsed.color }
        if let parsed = swiftColor(text) { return parsed.color }
        return namedColors[text.lowercased()]
    }

    static func hexColor(_ text: String) -> RGBAColor? {
        let digits = Array(text.utf8.dropFirst())
        guard text.hasPrefix("#"), [3, 4, 6, 8].contains(digits.count) else { return nil }
        var values: [Double] = []
        func nibble(_ byte: UInt8) -> Int? {
            switch byte {
            case 0x30...0x39: Int(byte - 0x30)
            case 0x41...0x46: Int(byte - 0x41 + 10)
            case 0x61...0x66: Int(byte - 0x61 + 10)
            default: nil
            }
        }
        if digits.count <= 4 {
            for byte in digits {
                guard let n = nibble(byte) else { return nil }
                values.append(Double(n * 17) / 255)
            }
        } else {
            for index in stride(from: 0, to: digits.count, by: 2) {
                guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
                values.append(Double(high * 16 + low) / 255)
            }
        }
        return RGBAColor(red: values[0], green: values[1], blue: values[2], alpha: values.count > 3 ? values[3] : 1)
    }

    /// A number in a literal: where it is (in the literal's UTF-16) and its unit.
    struct Component {
        var range: NSRange
        var value: Double
        var unit: String
    }

    struct CSSFunction {
        var name: String
        var isHSL: Bool
        var usesCommas: Bool
        /// Channels (3), then alpha if written.
        var components: [Component]
        var color: RGBAColor
    }

    private static let numberPattern = try! NSRegularExpression(pattern: #"^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?(%|deg)?$"#, options: .caseInsensitive)

    /// `rgb()`, `rgba()`, `hsl()` or `hsla()`, with commas or spaces (and `/ alpha`).
    static func cssFunction(_ text: String) -> CSSFunction? {
        let ns = text as NSString
        let open = ns.range(of: "(")
        guard open.location != NSNotFound, text.hasSuffix(")") else { return nil }
        let name = ns.substring(to: open.location)
        let lower = name.lowercased()
        guard ["rgb", "rgba", "hsl", "hsla"].contains(lower) else { return nil }
        let innerStart = open.location + 1, innerEnd = ns.length - 1
        // Each piece: its range and text, split at commas, or at spaces and "/".
        var pieces: [NSRange] = []
        var slashes = 0, commas = 0
        var pieceStart: Int?
        for index in innerStart..<innerEnd {
            let unit = ns.character(at: index)
            let isSpace = unit == 0x20 || unit == 0x09
            if unit == 0x2C || unit == 0x2F || isSpace {
                if let start = pieceStart { pieces.append(NSRange(location: start, length: index - start)); pieceStart = nil }
                if unit == 0x2C { commas += 1 } else if unit == 0x2F {
                    slashes += 1
                    if pieces.count != 3 { return nil } // "/" only before the alpha
                }
            } else if pieceStart == nil {
                pieceStart = index
            }
        }
        if let start = pieceStart { pieces.append(NSRange(location: start, length: innerEnd - start)) }
        let usesCommas = commas > 0
        guard pieces.count == 3 || pieces.count == 4, slashes <= 1 else { return nil }
        if usesCommas { guard commas == pieces.count - 1, slashes == 0 else { return nil } } else if pieces.count == 4 { guard slashes == 1 else { return nil } } else { guard slashes == 0 else { return nil } }
        var components: [Component] = []
        for piece in pieces {
            let token = ns.substring(with: piece)
            guard let match = numberPattern.firstMatch(in: token, range: NSRange(location: 0, length: (token as NSString).length)) else { return nil }
            let unitRange = match.range(at: 1)
            let unit = unitRange.location == NSNotFound ? "" : (token as NSString).substring(with: unitRange).lowercased()
            let number = unit.isEmpty ? token : (token as NSString).substring(to: unitRange.location)
            guard let value = Double(number) else { return nil }
            components.append(Component(range: piece, value: value, unit: unit))
        }
        let isHSL = lower.hasPrefix("hsl")
        // Units: a hue in degrees (or none); "deg" nowhere else.
        for (index, component) in components.enumerated() where component.unit == "deg" && !(isHSL && index == 0) { return nil }
        func alpha() -> Double {
            guard components.count == 4 else { return 1 }
            let a = components[3]
            return a.unit == "%" ? a.value / 100 : a.value
        }
        let color: RGBAColor
        if isHSL {
            guard components[0].unit != "%" else { return nil }
            func fraction(_ c: Component) -> Double { c.value / 100 } // with or without "%"
            color = RGBAColor(hue: components[0].value, saturation: fraction(components[1]), lightness: fraction(components[2]), alpha: alpha())
        } else {
            func channel(_ c: Component) -> Double { c.unit == "%" ? c.value / 100 : c.value / 255 }
            color = RGBAColor(red: channel(components[0]), green: channel(components[1]), blue: channel(components[2]), alpha: alpha())
        }
        return CSSFunction(name: name, isHSL: isHSL, usesCommas: usesCommas, components: components, color: color)
    }

    struct SwiftColor {
        var isHSB: Bool
        var alphaLabel: String
        /// The numbers: three channels, then alpha if written.
        var components: [Component]
        var color: RGBAColor
    }

    private static let swiftArgument = try! NSRegularExpression(pattern: #"^\s*([A-Za-z]+)\s*:\s*(\d+(?:\.\d+)?)\s*$"#)

    /// `Color(red:green:blue:opacity:)`, `Color(.sRGB, red:…)`, `Color(hue:saturation:brightness:)`,
    /// `NSColor`/`UIColor(red:green:blue:alpha:)` and NSColor's `calibratedRed:`, `srgbRed:`,
    /// `deviceRed:` (and hue) forms. Number literals only.
    static func swiftColor(_ text: String) -> SwiftColor? {
        let ns = text as NSString
        let open = ns.range(of: "(")
        guard open.location != NSNotFound, text.hasSuffix(")") else { return nil }
        var type = ns.substring(to: open.location)
        for module in ["SwiftUI.", "AppKit.", "UIKit."] where type.hasPrefix(module) { type.removeFirst(module.count) }
        guard ["Color", "NSColor", "UIColor"].contains(type) else { return nil }
        var arguments: [NSRange] = []
        var start = open.location + 1
        for index in start..<(ns.length - 1) where ns.character(at: index) == 0x2C {
            arguments.append(NSRange(location: start, length: index - start))
            start = index + 1
        }
        arguments.append(NSRange(location: start, length: ns.length - 1 - start))
        if type == "Color", let first = arguments.first,
           ns.substring(with: first).trimmingCharacters(in: .whitespaces) == ".sRGB" {
            arguments.removeFirst()
        }
        var labels: [String] = []
        var components: [Component] = []
        for argument in arguments {
            let piece = ns.substring(with: argument)
            guard let match = swiftArgument.firstMatch(in: piece, range: NSRange(location: 0, length: (piece as NSString).length)) else { return nil }
            let number = match.range(at: 2)
            labels.append((piece as NSString).substring(with: match.range(at: 1)))
            components.append(Component(range: NSRange(location: argument.location + number.location, length: number.length),
                                        value: Double((piece as NSString).substring(with: number)) ?? 0, unit: ""))
        }
        guard labels.count == 3 || labels.count == 4 else { return nil }
        let alphaLabel = type == "Color" ? "opacity" : "alpha"
        if labels.count == 4 { guard labels[3] == alphaLabel else { return nil } }
        let firsts = type == "NSColor" ? ["red", "calibratedRed", "srgbRed", "deviceRed"] : ["red"]
        let hues = type == "NSColor" ? ["hue", "calibratedHue", "deviceHue"] : ["hue"]
        let alpha = components.count == 4 ? components[3].value : 1
        let values = components.map(\.value)
        if firsts.contains(labels[0]), labels[1] == "green", labels[2] == "blue" {
            return SwiftColor(isHSB: false, alphaLabel: alphaLabel, components: components,
                              color: RGBAColor(red: values[0], green: values[1], blue: values[2], alpha: alpha))
        }
        if hues.contains(labels[0]), labels[1] == "saturation", labels[2] == "brightness" {
            return SwiftColor(isHSB: true, alphaLabel: alphaLabel, components: components,
                              color: RGBAColor(hue: values[0], saturation: values[1], brightness: values[2], alpha: alpha))
        }
        return nil
    }

    // MARK: Writing a color back

    /// `original` (a whole literal) rewritten for `color`, in the same format: hex stays hex
    /// (same case, short when it can be), functions keep their syntax and units, Swift keeps its
    /// labels. Alpha is added when the color needs it. A color name becomes hex.
    static func rewrite(_ original: String, to color: RGBAColor) -> String? {
        if original.hasPrefix("#") { return hexColor(original) == nil ? nil : hex(color, like: original) }
        if let function = cssFunction(original) { return rewrite(original, function, to: color) }
        if let swift = swiftColor(original) { return rewrite(original, swift, to: color) }
        guard let named = namedColors[original.lowercased()] else { return nil }
        if color.isOpaque, named.isClose(to: color) { return original }
        if color.isOpaque, let name = colorNames[hexKey(color)] {
            return original == original.uppercased() ? name.uppercased() : name
        }
        return hex(color, like: "#000000")
    }

    private static func hexKey(_ color: RGBAColor) -> Int {
        func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }
        return byte(color.red) << 16 | byte(color.green) << 8 | byte(color.blue)
    }

    /// Hex like `original`: its case, its length (3/4 or 6/8 digits, short only when the color
    /// fits), and alpha digits if it had them or the color isn't opaque.
    static func hex(_ color: RGBAColor, like original: String) -> String {
        let digits = original.dropFirst()
        let uppercase = digits.contains { $0.isLetter && $0.isUppercase }
        let hadAlpha = digits.count == 4 || digits.count == 8
        var bytes = [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
        if hadAlpha || !color.isOpaque { bytes.append(Int((color.alpha * 255).rounded())) }
        let short = (digits.count == 3 || digits.count == 4) && bytes.allSatisfy { $0 % 17 == 0 }
        let text = bytes.map { short ? String($0 / 17, radix: 16) : String(format: "%02x", $0) }.joined()
        return "#" + (uppercase ? text.uppercased() : text)
    }

    /// A number with at most `decimals` decimals, without trailing zeros.
    static func number(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    private static func rewrite(_ original: String, _ function: CSSFunction, to color: RGBAColor) -> String {
        let ns = NSMutableString(string: original)
        var values: [String] = []
        let c = function.components
        if function.isHSL {
            let hsl = color.hsl
            values = [number(hsl.hue, decimals: 0) + c[0].unit, number(hsl.saturation * 100, decimals: 0) + c[1].unit,
                      number(hsl.lightness * 100, decimals: 0) + c[2].unit]
        } else {
            for (index, channel) in [color.red, color.green, color.blue].enumerated() {
                values.append(c[index].unit == "%" ? number(channel * 100, decimals: 1) + "%" : number(channel * 255, decimals: 0))
            }
        }
        if c.count == 4 {
            values.append(c[3].unit == "%" ? number(color.alpha * 100, decimals: 0) + "%" : number(color.alpha, decimals: 3))
        }
        // Back to front: the ranges before stay put.
        if c.count == 3, !color.isOpaque {
            let alpha = number(color.alpha, decimals: 3)
            if function.usesCommas {
                // The separator the text uses (", " or ","), and rgb → rgba for older browsers.
                let afterFirst = NSMaxRange(c[0].range)
                let separator = (original as NSString).substring(with: NSRange(location: afterFirst, length: c[1].range.location - afterFirst))
                ns.insert(separator + alpha, at: NSMaxRange(c[2].range))
            } else {
                ns.insert(" / " + alpha, at: NSMaxRange(c[2].range))
            }
        }
        for (index, component) in c.enumerated().reversed() {
            ns.replaceCharacters(in: component.range, with: values[index])
        }
        if c.count == 3, !color.isOpaque, function.usesCommas, function.name.count == 3 {
            let suffix = function.name == function.name.uppercased() ? "A" : "a"
            ns.insert(suffix, at: 3)
        }
        return ns as String
    }

    private static func rewrite(_ original: String, _ swift: SwiftColor, to color: RGBAColor) -> String {
        let ns = NSMutableString(string: original)
        func fixed(_ value: Double) -> String { String(format: "%.3f", value) }
        var values: [String]
        if swift.isHSB {
            let hsb = color.hsb
            values = [fixed(hsb.hue), fixed(hsb.saturation), fixed(hsb.brightness)]
        } else {
            values = [fixed(color.red), fixed(color.green), fixed(color.blue)]
        }
        let c = swift.components
        if c.count == 4 {
            values.append(fixed(color.alpha))
        } else if !color.isOpaque {
            ns.insert(", \(swift.alphaLabel): \(fixed(color.alpha))", at: NSMaxRange(c[2].range))
        }
        for (index, component) in c.enumerated().reversed() {
            ns.replaceCharacters(in: component.range, with: values[index])
        }
        return ns as String
    }

    // MARK: Finding literals

    /// At most this much text is looked through at once (the viewport, usually far less).
    static let scanLimit = 60_000

    private static let hexPattern = try! NSRegularExpression(pattern: #"(?<![\w&#$-])#(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3,4})(?![\w-])"#)
    private static let functionPattern = try! NSRegularExpression(pattern: #"(?<![\w-])(?:rgba?|hsla?)\([^()\n]{1,80}\)"#, options: .caseInsensitive)
    private static let namePattern = try! NSRegularExpression(pattern: #"(?<![\w$@#.\-])[A-Za-z]{3,20}(?![\w\-(])"#)
    private static let swiftPattern = try! NSRegularExpression(pattern: #"(?<![\w.])(?:(?:SwiftUI|AppKit|UIKit)\.)?(?:Color|NSColor|UIColor)\([^()\n]{1,160}\)"#)

    /// The colors in `range` of `text` (whole lines), in order. Literals at a line's start
    /// aren't included: the swatch goes in a gap after the character before.
    static func find(in text: NSString, range: NSRange, syntax: ColorSyntax) -> [ColorLiteral] {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard range.length > 0, range.length <= scanLimit else { return [] }
        var found: [ColorLiteral] = []
        func add(_ match: NSRange) {
            guard match.location > 0, text.character(at: match.location - 1) != 0x0A else { return }
            let literal = text.substring(with: match)
            guard let color = color(of: literal) else { return }
            found.append(ColorLiteral(range: match, text: literal, color: color))
        }
        switch syntax {
        case .swift:
            for match in swiftPattern.matches(in: text as String, range: range) { add(match.range) }
        case .css, .script, .markup:
            let styleBlocks = syntax == .markup ? styleBlockRanges(in: text, range: range) : []
            func allowed(_ match: NSRange, isName: Bool, isFunction: Bool) -> Bool {
                switch syntax {
                case .css: return isFunction || isValuePosition(match, in: text, allowParentheses: !isName)
                case .script: return !isName && isInString(match, in: text)
                case .markup:
                    if styleBlocks.contains(where: { NSLocationInRange(match.location, $0) }) {
                        return isFunction || isValuePosition(match, in: text, allowParentheses: !isName)
                    }
                    return isInStyleAttribute(match, in: text) && (isFunction || isValuePosition(match, in: text, allowParentheses: !isName))
                case .swift: return false
                }
            }
            var matches: [(NSRange, Bool, Bool)] = []
            for match in hexPattern.matches(in: text as String, range: range) { matches.append((match.range, false, false)) }
            for match in functionPattern.matches(in: text as String, range: range) { matches.append((match.range, false, true)) }
            if syntax != .script {
                for match in namePattern.matches(in: text as String, range: range)
                where namedColors[text.substring(with: match.range).lowercased()] != nil {
                    matches.append((match.range, true, false))
                }
            }
            matches.sort { $0.0.location < $1.0.location }
            for (match, isName, isFunction) in matches where allowed(match, isName: isName, isFunction: isFunction) { add(match) }
        }
        // One per place (overlaps can't both be rewritten).
        var result: [ColorLiteral] = []
        for literal in found where result.last.map({ NSMaxRange($0.range) <= literal.range.location }) ?? true {
            result.append(literal)
        }
        return result
    }

    /// The start of `range`'s line (looking back at most `limit` characters).
    private static func lineStart(of location: Int, in text: NSString, limit: Int = 400) -> Int {
        var index = location
        while index > 0, location - index < limit, text.character(at: index - 1) != 0x0A { index -= 1 }
        return index
    }

    /// Where a CSS value can be: after a `:` in a declaration (the last of `:;{}` before it on its
    /// line is a `:`), but not in a selector (`a:hover #abc {`). With `allowParentheses`, also
    /// inside a function's parentheses (`mix(#fff, #000)`).
    static func isValuePosition(_ match: NSRange, in text: NSString, allowParentheses: Bool) -> Bool {
        let start = lineStart(of: match.location, in: text)
        var depth = 0
        var index = match.location - 1
        var sawColon = false
        while index >= start {
            let unit = text.character(at: index)
            if unit == 0x29 { depth += 1 } // )
            else if unit == 0x28 { // (
                if depth == 0 && allowParentheses { sawColon = true; break }
                depth = max(0, depth - 1)
            } else if unit == 0x3A { sawColon = true; break } // :
            else if unit == 0x3B || unit == 0x7B || unit == 0x7D || unit == 0x22 || unit == 0x27 { break } // ; { } " '
            index -= 1
        }
        guard sawColon else { return false }
        // A selector goes on to "{" before any ";" or "}".
        var end = NSMaxRange(match)
        while end < text.length, end - match.location < 400 {
            let unit = text.character(at: end)
            if unit == 0x0A || unit == 0x3B || unit == 0x7D || unit == 0x22 || unit == 0x27 { return true }
            if unit == 0x7B { return false }
            end += 1
        }
        return true
    }

    /// Inside a quoted string on its line (', ", `), escapes skipped.
    static func isInString(_ match: NSRange, in text: NSString) -> Bool {
        let start = lineStart(of: match.location, in: text, limit: 2_000)
        guard match.location - start < 2_000 else { return false }
        var quote: unichar = 0
        var index = start
        while index < match.location {
            let unit = text.character(at: index)
            if quote != 0 {
                if unit == 0x5C { index += 2; continue }
                if unit == quote { quote = 0 }
            } else if unit == 0x22 || unit == 0x27 || unit == 0x60 {
                quote = unit
            } else if unit == 0x2F, index + 1 < match.location, text.character(at: index + 1) == 0x2F {
                return false // a // comment
            }
            index += 1
        }
        return quote != 0
    }

    /// Inside a `style="…"` (or '…') attribute's value on the same line.
    static func isInStyleAttribute(_ match: NSRange, in text: NSString) -> Bool {
        let start = lineStart(of: match.location, in: text, limit: 2_000)
        let line = NSRange(location: start, length: match.location - start)
        let found = text.range(of: "style=", options: [.backwards, .caseInsensitive], range: line)
        guard found.location != NSNotFound, NSMaxRange(found) < match.location else { return false }
        let quote = text.character(at: NSMaxRange(found))
        guard quote == 0x22 || quote == 0x27 else { return false }
        let valueStart = NSMaxRange(found) + 1
        for index in valueStart..<match.location where text.character(at: index) == quote { return false }
        return true
    }

    /// The parts of `range` inside `<style>` blocks (from `<style` to `</style`).
    static func styleBlockRanges(in text: NSString, range: NSRange) -> [NSRange] {
        // Whether `range` starts inside one: the nearest opening or closing tag before it.
        let lookBack = max(0, range.location - 200_000)
        let before = NSRange(location: lookBack, length: range.location - lookBack)
        let lastOpen = text.range(of: "<style", options: [.backwards, .caseInsensitive], range: before)
        let lastClose = text.range(of: "</style", options: [.backwards, .caseInsensitive], range: before)
        var blockStart: Int? = nil
        if lastOpen.location != NSNotFound, lastClose.location == NSNotFound || lastOpen.location > lastClose.location {
            blockStart = range.location
        }
        var result: [NSRange] = []
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let rest = NSRange(location: index, length: end - index)
            if let start = blockStart {
                let close = text.range(of: "</style", options: .caseInsensitive, range: rest)
                let stop = close.location == NSNotFound ? end : close.location
                result.append(NSRange(location: start, length: stop - start))
                blockStart = nil
                index = close.location == NSNotFound ? end : NSMaxRange(close)
            } else {
                let open = text.range(of: "<style", options: .caseInsensitive, range: rest)
                guard open.location != NSNotFound else { break }
                blockStart = NSMaxRange(open)
                index = NSMaxRange(open)
            }
        }
        if let start = blockStart, start < end { result.append(NSRange(location: start, length: end - start)) }
        return result
    }

    // MARK: Named colors

    /// CSS's named colors (lowercase) and their values.
    static let namedColors: [String: RGBAColor] = {
        var colors: [String: RGBAColor] = [:]
        for (name, value) in namedColorValues {
            colors[name] = RGBAColor(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                                     blue: Double(value & 0xFF) / 255)
        }
        return colors
    }()

    /// A name for each value (the first in the list where two share one: "aqua" over "cyan").
    private static let colorNames: [Int: String] = {
        var names: [Int: String] = [:]
        for (name, value) in namedColorValues where names[value] == nil { names[value] = name }
        return names
    }()

    private static let namedColorValues: [(String, Int)] = [
        ("black", 0x000000), ("silver", 0xC0C0C0), ("gray", 0x808080), ("white", 0xFFFFFF), ("maroon", 0x800000),
        ("red", 0xFF0000), ("purple", 0x800080), ("fuchsia", 0xFF00FF), ("green", 0x008000), ("lime", 0x00FF00),
        ("olive", 0x808000), ("yellow", 0xFFFF00), ("navy", 0x000080), ("blue", 0x0000FF), ("teal", 0x008080),
        ("aqua", 0x00FFFF), ("orange", 0xFFA500), ("aliceblue", 0xF0F8FF), ("antiquewhite", 0xFAEBD7),
        ("aquamarine", 0x7FFFD4), ("azure", 0xF0FFFF), ("beige", 0xF5F5DC), ("bisque", 0xFFE4C4),
        ("blanchedalmond", 0xFFEBCD), ("blueviolet", 0x8A2BE2), ("brown", 0xA52A2A), ("burlywood", 0xDEB887),
        ("cadetblue", 0x5F9EA0), ("chartreuse", 0x7FFF00), ("chocolate", 0xD2691E), ("coral", 0xFF7F50),
        ("cornflowerblue", 0x6495ED), ("cornsilk", 0xFFF8DC), ("crimson", 0xDC143C), ("cyan", 0x00FFFF),
        ("darkblue", 0x00008B), ("darkcyan", 0x008B8B), ("darkgoldenrod", 0xB8860B), ("darkgray", 0xA9A9A9),
        ("darkgreen", 0x006400), ("darkgrey", 0xA9A9A9), ("darkkhaki", 0xBDB76B), ("darkmagenta", 0x8B008B),
        ("darkolivegreen", 0x556B2F), ("darkorange", 0xFF8C00), ("darkorchid", 0x9932CC), ("darkred", 0x8B0000),
        ("darksalmon", 0xE9967A), ("darkseagreen", 0x8FBC8F), ("darkslateblue", 0x483D8B), ("darkslategray", 0x2F4F4F),
        ("darkslategrey", 0x2F4F4F), ("darkturquoise", 0x00CED1), ("darkviolet", 0x9400D3), ("deeppink", 0xFF1493),
        ("deepskyblue", 0x00BFFF), ("dimgray", 0x696969), ("dimgrey", 0x696969), ("dodgerblue", 0x1E90FF),
        ("firebrick", 0xB22222), ("floralwhite", 0xFFFAF0), ("forestgreen", 0x228B22), ("gainsboro", 0xDCDCDC),
        ("ghostwhite", 0xF8F8FF), ("gold", 0xFFD700), ("goldenrod", 0xDAA520), ("greenyellow", 0xADFF2F),
        ("grey", 0x808080), ("honeydew", 0xF0FFF0), ("hotpink", 0xFF69B4), ("indianred", 0xCD5C5C), ("indigo", 0x4B0082),
        ("ivory", 0xFFFFF0), ("khaki", 0xF0E68C), ("lavender", 0xE6E6FA), ("lavenderblush", 0xFFF0F5),
        ("lawngreen", 0x7CFC00), ("lemonchiffon", 0xFFFACD), ("lightblue", 0xADD8E6), ("lightcoral", 0xF08080),
        ("lightcyan", 0xE0FFFF), ("lightgoldenrodyellow", 0xFAFAD2), ("lightgray", 0xD3D3D3), ("lightgreen", 0x90EE90),
        ("lightgrey", 0xD3D3D3), ("lightpink", 0xFFB6C1), ("lightsalmon", 0xFFA07A), ("lightseagreen", 0x20B2AA),
        ("lightskyblue", 0x87CEFA), ("lightslategray", 0x778899), ("lightslategrey", 0x778899),
        ("lightsteelblue", 0xB0C4DE), ("lightyellow", 0xFFFFE0), ("limegreen", 0x32CD32), ("linen", 0xFAF0E6),
        ("magenta", 0xFF00FF), ("mediumaquamarine", 0x66CDAA), ("mediumblue", 0x0000CD), ("mediumorchid", 0xBA55D3),
        ("mediumpurple", 0x9370DB), ("mediumseagreen", 0x3CB371), ("mediumslateblue", 0x7B68EE),
        ("mediumspringgreen", 0x00FA9A), ("mediumturquoise", 0x48D1CC), ("mediumvioletred", 0xC71585),
        ("midnightblue", 0x191970), ("mintcream", 0xF5FFFA), ("mistyrose", 0xFFE4E1), ("moccasin", 0xFFE4B5),
        ("navajowhite", 0xFFDEAD), ("oldlace", 0xFDF5E6), ("olivedrab", 0x6B8E23), ("orangered", 0xFF4500),
        ("orchid", 0xDA70D6), ("palegoldenrod", 0xEEE8AA), ("palegreen", 0x98FB98), ("paleturquoise", 0xAFEEEE),
        ("palevioletred", 0xDB7093), ("papayawhip", 0xFFEFD5), ("peachpuff", 0xFFDAB9), ("peru", 0xCD853F),
        ("pink", 0xFFC0CB), ("plum", 0xDDA0DD), ("powderblue", 0xB0E0E6), ("rosybrown", 0xBC8F8F),
        ("royalblue", 0x4169E1), ("saddlebrown", 0x8B4513), ("salmon", 0xFA8072), ("sandybrown", 0xF4A460),
        ("seagreen", 0x2E8B57), ("seashell", 0xFFF5EE), ("sienna", 0xA0522D), ("skyblue", 0x87CEEB),
        ("slateblue", 0x6A5ACD), ("slategray", 0x708090), ("slategrey", 0x708090), ("snow", 0xFFFAFA),
        ("springgreen", 0x00FF7F), ("steelblue", 0x4682B4), ("tan", 0xD2B48C), ("thistle", 0xD8BFD8),
        ("tomato", 0xFF6347), ("turquoise", 0x40E0D0), ("violet", 0xEE82EE), ("wheat", 0xF5DEB3),
        ("whitesmoke", 0xF5F5F5), ("yellowgreen", 0x9ACD32), ("rebeccapurple", 0x663399),
    ]
}
