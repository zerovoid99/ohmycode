import Foundation
import Synchronization

/// TextMate grammars are written for Oniguruma (Ruby syntax); the app matches with ICU
/// (`NSRegularExpression`). Most patterns mean the same in both; this rewrites the ones that
/// don't, before compiling:
///
/// - `\h` / `\H` are hex digits in Oniguruma (horizontal space in ICU): `[0-9a-fA-F]`.
/// - `(?m)` is "dot matches newline" in Ruby syntax: ICU's `(?s)`. (`^` and `$` always match
///   at line ends, as in Oniguruma.)
/// - `(?x)` free-spacing: whitespace and `#` comments are removed here, since ICU also
///   ignores whitespace inside `[...]` and Oniguruma doesn't.
/// - `{,n}` becomes `{0,n}`; a `{` or `}` that isn't a quantifier is escaped.
/// - `\p{^Alpha}` becomes `\P{Alpha}`.
/// - Group names with `_` or duplicates (ICU allows letters and digits only, once each) are
///   renamed, with their `\k<name>` back-references.
/// - A `[` inside a character class that doesn't start a POSIX class (`[:alpha:]`) or an
///   intersection (`&&[...]`) is a literal bracket.
///
/// Not supported (the pattern fails to compile and its rule is skipped, logged once):
/// `\K`, subexpression calls (`\g<name>`), conditionals `(?(1)…)`, the absent operator `(?~…)`,
/// and look-behind of unbounded length. `\G` and `\A` are handled by the tokenizer.
enum OnigurumaRegex {
    /// The ICU equivalent of an Oniguruma pattern, or nil for a construct ICU can't express.
    static func translate(_ source: String) -> String? {
        var scanner = Translator(Array(source.unicodeScalars))
        return scanner.run()
    }

    /// Compiled patterns, shared by every grammar and thread (`NSRegularExpression` is safe to
    /// match from several threads). A pattern that can't be compiled is remembered as nil.
    private static let cache = Mutex<[String: NSRegularExpression?]>([:])
    private static let failures = Mutex<Set<String>>([])

    static func compile(_ source: String) -> NSRegularExpression? {
        if let cached = cache.withLock({ $0[source] }) { return cached }
        var regex: NSRegularExpression?
        if let translated = translate(source) {
            regex = try? NSRegularExpression(pattern: translated, options: [.anchorsMatchLines])
        }
        if regex == nil, failures.withLock({ $0.insert(source).inserted }) {
            NSLog("OMC: TextMate pattern not supported by the regex engine: \(source.prefix(200))")
        }
        cache.withLock { cache in
            if cache.count > 20_000 { cache.removeAll() }
            cache[source] = regex
        }
        return regex
    }

    private struct Translator {
        let chars: [Unicode.Scalar]
        var index = 0
        var output = ""
        /// Free-spacing mode (`(?x)`), from where it's turned on.
        var extended = false
        var classDepth = 0
        var names: [String: String] = [:]
        var usedNames = Set<String>()

        init(_ chars: [Unicode.Scalar]) { self.chars = chars }

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            index + offset < chars.count ? chars[index + offset] : nil
        }

        func startsWith(_ text: String) -> Bool {
            let scalars = Array(text.unicodeScalars)
            guard index + scalars.count <= chars.count else { return false }
            return Array(chars[index..<index + scalars.count]) == scalars
        }

        mutating func run() -> String? {
            while index < chars.count {
                let c = chars[index]
                if classDepth > 0 {
                    guard translateInClass(c) else { return nil }
                    continue
                }
                if extended {
                    if c.properties.isWhitespace { index += 1; continue }
                    if c == "#" {
                        while index < chars.count, chars[index] != "\n" { index += 1 }
                        continue
                    }
                }
                switch c {
                case "\\":
                    guard translateEscape(inClass: false) else { return nil }
                case "[":
                    classDepth = 1
                    output.append("[")
                    index += 1
                    if peek() == "^" { output.append("^"); index += 1 }
                    // A "]" first in a class is a literal one.
                    if peek() == "]" { output.append("\\]"); index += 1 }
                case "(":
                    guard translateGroup() else { return nil }
                case "{":
                    translateBrace()
                case "}":
                    output.append("\\}")
                    index += 1
                default:
                    output.unicodeScalars.append(c)
                    index += 1
                }
            }
            return output
        }

        /// `(?…` groups: flags, names; the rest pass through.
        mutating func translateGroup() -> Bool {
            guard peek(1) == "?" else { output.append("("); index += 1; return true }
            let next = peek(2)
            if next == "~" || next == "(" { return false } // absent operator, conditionals
            if next == "<", let after = peek(3), after != "=", after != "!" {
                // (?<name>…)
                var name = ""
                var cursor = index + 3
                while cursor < chars.count, chars[cursor] != ">" { name.unicodeScalars.append(chars[cursor]); cursor += 1 }
                guard cursor < chars.count else { return false }
                output.append("(?<\(icuName(name))>")
                index = cursor + 1
                return true
            }
            if next == "P", peek(3) == "<" { return false } // (?P<…>) isn't Oniguruma either
            // Flags: (?imx-imx) or (?imx-imx:…)
            var cursor = index + 2
            var flags = ""
            while cursor < chars.count, "imx-".unicodeScalars.contains(chars[cursor]) {
                flags.unicodeScalars.append(chars[cursor])
                cursor += 1
            }
            if !flags.isEmpty, cursor < chars.count, chars[cursor] == ")" || chars[cursor] == ":" {
                let turnsOn = flags.split(separator: "-", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                if turnsOn.contains("x") { extended = true }
                if flags.contains("-x") || (flags.hasPrefix("-") && flags.contains("x")) { extended = false }
                // Ruby's m is ICU's s; x is applied here.
                let mapped = flags.replacingOccurrences(of: "m", with: "s").replacingOccurrences(of: "x", with: "")
                let isColon = chars[cursor] == ":"
                if mapped.isEmpty || mapped == "-" {
                    output.append(isColon ? "(?:" : "")
                } else {
                    output.append("(?\(mapped)\(isColon ? ":" : ")")")
                }
                index = cursor + 1
                return true
            }
            output.append("(?")
            index += 2
            return true
        }

        mutating func icuName(_ name: String) -> String {
            var base = String(name.unicodeScalars.filter { ($0.isASCII && $0.properties.isAlphabetic) || ("0"..."9").contains($0) })
            if base.isEmpty || !(base.unicodeScalars.first!.properties.isAlphabetic) { base = "g" + base }
            var unique = base
            var counter = 1
            while usedNames.contains(unique) { counter += 1; unique = "\(base)\(counter)" }
            usedNames.insert(unique)
            names[name] = unique // a back-reference to a duplicate name means the latest one
            return unique
        }

        /// `{n}`, `{n,}`, `{n,m}` and `{,m}` are quantifiers; any other brace is a literal.
        mutating func translateBrace() {
            var cursor = index + 1
            var first = "", second = ""
            var sawComma = false
            while cursor < chars.count, chars[cursor] != "}" {
                let c = chars[cursor]
                if c == "," && !sawComma { sawComma = true } else if ("0"..."9").contains(c) {
                    if sawComma { second.unicodeScalars.append(c) } else { first.unicodeScalars.append(c) }
                } else { break }
                cursor += 1
            }
            if cursor < chars.count, chars[cursor] == "}", !(first.isEmpty && second.isEmpty), output.last.map({ $0 != "(" && $0 != "|" }) ?? false {
                output.append("{\(first.isEmpty ? "0" : first)\(sawComma ? "," : "")\(second)}")
                index = cursor + 1
            } else {
                output.append("\\{")
                index += 1
            }
        }

        mutating func translateInClass(_ c: Unicode.Scalar) -> Bool {
            switch c {
            case "\\":
                return translateEscape(inClass: true)
            case "[":
                if peek(1) == ":" {
                    // A POSIX class: copy through its closing ":]".
                    var cursor = index + 2
                    while cursor + 1 < chars.count, !(chars[cursor] == ":" && chars[cursor + 1] == "]") { cursor += 1 }
                    guard cursor + 1 < chars.count else { output.append("\\["); index += 1; return true }
                    let name = String(String.UnicodeScalarView(chars[(index + 2)..<cursor]))
                    output.append("[:\(name):]")
                    index = cursor + 2
                } else if output.hasSuffix("&&") {
                    classDepth += 1
                    output.append("[")
                    index += 1
                    if peek() == "^" { output.append("^"); index += 1 }
                } else {
                    output.append("\\[")
                    index += 1
                }
            case "]":
                classDepth -= 1
                output.append("]")
                index += 1
            case " ", "\t", "#":
                // Literal in Oniguruma even in free-spacing mode; ICU would drop them.
                output.append(c == "\t" ? "\\t" : (c == "#" ? "\\#" : "\\x{20}"))
                index += 1
            default:
                output.unicodeScalars.append(c)
                index += 1
            }
            return true
        }

        mutating func translateEscape(inClass: Bool) -> Bool {
            guard let next = peek(1) else { output.append("\\\\"); index += 1; return true }
            index += 2
            switch next {
            case "h": output.append(inClass ? "0-9a-fA-F" : "[0-9a-fA-F]")
            case "H":
                guard !inClass else { return false }
                output.append("[^0-9a-fA-F]")
            case "K": return false
            case "g": return false // subexpression call
            case "k":
                // \k<name>
                if peek() == "<" {
                    var cursor = index + 1
                    var name = ""
                    while cursor < chars.count, chars[cursor] != ">" { name.unicodeScalars.append(chars[cursor]); cursor += 1 }
                    guard cursor < chars.count else { return false }
                    if let number = Int(name) {
                        output.append("\\\(number)")
                    } else {
                        guard let mapped = names[name] else { return false }
                        output.append("\\k<\(mapped)>")
                    }
                    index = cursor + 1
                } else {
                    output.append("\\k")
                }
            case "p", "P", "x", "o", "N":
                // Braces belong to the escape: \p{Alpha}, \x{41}. \p{^Alpha} → \P{Alpha}.
                var name = "\\"
                name.unicodeScalars.append(next)
                if peek() == "{" {
                    var cursor = index + 1
                    if next == "p" || next == "P", cursor < chars.count, chars[cursor] == "^" {
                        name = next == "p" ? "\\P" : "\\p"
                        cursor += 1
                    }
                    var body = ""
                    while cursor < chars.count, chars[cursor] != "}" { body.unicodeScalars.append(chars[cursor]); cursor += 1 }
                    guard cursor < chars.count else { return false }
                    output.append("\(name){\(body)}")
                    index = cursor + 1
                } else {
                    output.append(name)
                }
            default:
                output.append("\\")
                output.unicodeScalars.append(next)
            }
            return true
        }
    }
}
