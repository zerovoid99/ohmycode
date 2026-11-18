import Foundation

/// Emmet's CSS abbreviations: `m10` → `margin: 10px;`, `m10-20` → `margin: 10px 20px;`,
/// `w100p` → `width: 100%;`, `dn` → `display: none;`, `p10!` adds `!important`, `+` joins
/// several. A property with no value gets a stop for it.
extension Emmet {
    /// The snippet body for a CSS abbreviation, nil when it isn't one.
    static func expandCSS(_ abbreviation: String) -> String? {
        guard !abbreviation.isEmpty, abbreviation.count <= 200 else { return nil }
        let parts = splitCSS(abbreviation)
        guard !parts.isEmpty else { return nil }
        var stop = 0
        var lines: [String] = []
        for part in parts {
            guard let line = expandCSSProperty(part, stop: &stop) else { return nil }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The abbreviation that ends at the end of `line` (the text before the cursor), and where
    /// it starts (UTF-16).
    static func extractCSS(beforeCursor line: String) -> (abbreviation: String, start: Int)? {
        let units = Array(line.utf16)
        var index = units.count
        while index > 0, let scalar = Unicode.Scalar(units[index - 1]),
              CharacterSet.alphanumerics.contains(scalar) || "-.!#%+@$".unicodeScalars.contains(scalar) {
            index -= 1
        }
        guard index < units.count, let first = Unicode.Scalar(units[index]),
              CharacterSet.letters.contains(first) || first == "-" else { return nil }
        return (String(decoding: units[index...], as: UTF16.self), index)
    }

    /// `m10+p5` → ["m10", "p5"]; a "+" that ends one (`bd+`) stays with it.
    private static func splitCSS(_ abbreviation: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in abbreviation {
            if character == "+", !current.isEmpty, cssKeywords[current + "+"] == nil {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func expandCSSProperty(_ part: String, stop: inout Int) -> String? {
        var abbreviation = part
        var important = false
        if abbreviation.hasSuffix("!") {
            important = true
            abbreviation.removeLast()
        }
        guard !abbreviation.isEmpty else { return nil }
        func finish(_ property: String, _ value: String) -> String {
            "\(property): \(value)\(important ? " !important" : "");"
        }
        func nextStop(_ placeholder: String = "") -> String {
            stop += 1
            return placeholder.isEmpty ? "${\(stop)}" : "${\(stop):\(placeholder)}"
        }
        // A whole declaration (`dn`, `posa`, `bd+`).
        if let keyword = cssKeywords[abbreviation] {
            return finish(keyword.property, keyword.value)
        }
        if let template = cssTemplates[abbreviation] {
            var text = template.value
            // Numbered in the order they're used, after the parts before this one.
            for index in (1...9).reversed() where text.contains("${\(index)") {
                text = text.replacingOccurrences(of: "${\(index)", with: "${\(index + stop)")
            }
            stop += template.stops
            return finish(template.property, text)
        }
        // A property alias or name, then a value (numbers, a color, keyword aliases).
        let characters = Array(abbreviation)
        var split = 0
        while split < characters.count, characters[split].isLetter || (characters[split] == "-" && split + 1 < characters.count
                                                                        && characters[split + 1].isLetter && split > 0) {
            split += 1
        }
        var name = String(characters[..<split])
        var valueText = String(characters[split...])
        // `dib` is a declaration, `pos` a property: letters that don't name one may be a
        // property's alias followed by a keyword's (`fl` + `l` … only for ones listed).
        if valueText.isEmpty, cssProperties[name] == nil, !cssPropertyNames.contains(name) {
            guard let (property, keyword) = splitKeyword(name) else { return nil }
            name = property
            valueText = ":" + keyword
        }
        guard let property = cssProperties[name] ?? (cssPropertyNames.contains(name) ? name : nil) else { return nil }
        if valueText.isEmpty { return finish(property, nextStop()) }
        if valueText.hasPrefix(":") {
            let keyword = String(valueText.dropFirst())
            return finish(property, cssValueKeywords[keyword] ?? keyword)
        }
        guard let values = cssValues(valueText, property: property) else { return nil }
        return finish(property, values.joined(separator: " "))
    }

    /// `posa` → ("pos", "a")? Only when the property's alias is followed by a keyword alias.
    private static func splitKeyword(_ name: String) -> (String, String)? {
        for length in stride(from: name.count - 1, to: 0, by: -1) {
            let property = String(name.prefix(length)), keyword = String(name.dropFirst(length))
            if cssProperties[property] != nil, cssValueKeywords[keyword] != nil { return (property, keyword) }
        }
        return nil
    }

    /// `10-20`, `-10`, `10--20`, `100p`, `1.5`, `#fc0`, `10-a` → CSS values.
    private static func cssValues(_ text: String, property: String) -> [String]? {
        var tokens: [String] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            var token = ""
            if characters[index] == "#" {
                token.append("#")
                index += 1
                while index < characters.count, characters[index].isHexDigit { token.append(characters[index]); index += 1 }
                guard token.count > 1 else { return nil }
                tokens.append(color(String(token.dropFirst())))
            } else {
                if characters[index] == "-", index + 1 < characters.count, characters[index + 1].isNumber || characters[index + 1] == "." {
                    token.append("-")
                    index += 1
                }
                var number = ""
                while index < characters.count, characters[index].isASCII, characters[index].isNumber || characters[index] == "." {
                    number.append(characters[index])
                    index += 1
                }
                var unit = ""
                while index < characters.count, characters[index].isLetter || characters[index] == "%" {
                    unit.append(characters[index])
                    index += 1
                }
                if number.isEmpty {
                    guard !unit.isEmpty, token.isEmpty else { return nil }
                    tokens.append(cssValueKeywords[unit] ?? unit)
                } else {
                    guard Double(number) != nil else { return nil }
                    tokens.append(token + number + cssUnit(unit, for: property, number: number))
                }
            }
            // A "-" between values separates them (a second one starts a negative number).
            if index < characters.count {
                guard characters[index] == "-", index + 1 < characters.count else { return nil }
                index += 1
            }
        }
        return tokens.isEmpty ? nil : tokens
    }

    private static func cssUnit(_ unit: String, for property: String, number: String) -> String {
        switch unit {
        case "p": return "%"
        case "e": return "em"
        case "r": return "rem"
        case "x": return "ex"
        case "w": return "vw"
        case "h": return "vh"
        case "": break
        default: return unit
        }
        if Double(number) == 0 || cssUnitless.contains(property) { return "" }
        return number.contains(".") ? "em" : "px"
    }

    /// `#f` → `#fff`, `#e0` → `#e0e0e0`, `#ffcc00` → `#fc0`.
    private static func color(_ digits: String) -> String {
        let lower = digits.lowercased()
        var full: String
        switch lower.count {
        case 1: full = String(repeating: lower, count: 6)
        case 2: full = lower + lower + lower
        case 3: return "#" + lower
        case 6: full = lower
        default: return "#" + lower
        }
        let characters = Array(full)
        if characters[0] == characters[1], characters[2] == characters[3], characters[4] == characters[5] {
            full = String([characters[0], characters[2], characters[4]])
        }
        return "#" + full
    }

    // MARK: Tables

    static let cssUnitless: Set<String> = [
        "z-index", "line-height", "opacity", "font-weight", "zoom", "flex", "flex-grow", "flex-shrink", "order",
    ]

    /// Property aliases.
    static let cssProperties: [String: String] = [
        "m": "margin", "mt": "margin-top", "mr": "margin-right", "mb": "margin-bottom", "ml": "margin-left",
        "p": "padding", "pt": "padding-top", "pr": "padding-right", "pb": "padding-bottom", "pl": "padding-left",
        "w": "width", "h": "height", "maw": "max-width", "mah": "max-height", "miw": "min-width", "mih": "min-height",
        "d": "display", "pos": "position", "t": "top", "r": "right", "b": "bottom", "l": "left", "z": "z-index",
        "fz": "font-size", "ff": "font-family", "fw": "font-weight", "fs": "font-style", "fv": "font-variant", "lh": "line-height",
        "c": "color", "bg": "background", "bgc": "background-color", "bgi": "background-image", "bgr": "background-repeat",
        "bgp": "background-position", "bgsz": "background-size", "bga": "background-attachment",
        "bd": "border", "bdt": "border-top", "bdr": "border-right", "bdb": "border-bottom", "bdl": "border-left",
        "bdc": "border-color", "bdw": "border-width", "bds": "border-style", "bdrs": "border-radius", "bdcl": "border-collapse",
        "ol": "outline", "olo": "outline-offset", "ta": "text-align", "td": "text-decoration", "tt": "text-transform",
        "ti": "text-indent", "tov": "text-overflow", "tsh": "text-shadow", "ls": "letter-spacing", "wos": "word-spacing",
        "ws": "white-space", "wob": "word-break", "wow": "word-wrap", "va": "vertical-align",
        "jc": "justify-content", "ji": "justify-items", "js": "justify-self", "ai": "align-items", "ac": "align-content",
        "as": "align-self", "fx": "flex", "fxd": "flex-direction", "fxw": "flex-wrap", "fxf": "flex-flow", "fxg": "flex-grow",
        "fxsh": "flex-shrink", "fxb": "flex-basis", "ord": "order", "gap": "gap", "rg": "row-gap", "cg": "column-gap",
        "g": "grid", "gtc": "grid-template-columns", "gtr": "grid-template-rows", "gta": "grid-template-areas",
        "gc": "grid-column", "gr": "grid-row", "ga": "grid-area", "gaf": "grid-auto-flow",
        "ov": "overflow", "ovx": "overflow-x", "ovy": "overflow-y", "op": "opacity", "cur": "cursor", "trs": "transition",
        "trsde": "transition-delay", "trsdu": "transition-duration", "trsp": "transition-property",
        "trstf": "transition-timing-function", "trf": "transform", "trfo": "transform-origin", "anim": "animation",
        "bxsh": "box-shadow", "bxz": "box-sizing", "v": "visibility", "cnt": "content", "lis": "list-style",
        "list": "list-style-type", "fl": "float", "cl": "clear", "ins": "inset", "ar": "aspect-ratio", "us": "user-select",
        "pe": "pointer-events", "obf": "object-fit", "obp": "object-position", "zm": "zoom", "rsz": "resize",
        "fil": "filter", "bdf": "backdrop-filter", "colm": "columns", "q": "quotes", "tbl": "table-layout",
    ]

    /// Full property names written out (`color` → `color: ;`).
    static let cssPropertyNames: Set<String> = Set(cssProperties.values)

    /// Value aliases (`posa` is `pos` + `a`).
    static let cssValueKeywords: [String: String] = [
        "a": "auto", "n": "none", "i": "inherit", "s": "solid", "d": "dashed", "dt": "dotted", "h": "hidden",
        "t": "transparent", "c": "center", "b": "block", "ib": "inline-block", "f": "flex", "g": "grid",
        "r": "relative", "st": "static", "x": "fixed", "sk": "sticky",
    ]

    /// Whole declarations.
    static let cssKeywords: [String: (property: String, value: String)] = [
        "dn": ("display", "none"), "db": ("display", "block"), "di": ("display", "inline"), "dib": ("display", "inline-block"),
        "df": ("display", "flex"), "dif": ("display", "inline-flex"), "dg": ("display", "grid"), "dig": ("display", "inline-grid"),
        "dt": ("display", "table"), "dtc": ("display", "table-cell"), "dtr": ("display", "table-row"), "dli": ("display", "list-item"),
        "dc": ("display", "contents"),
        "posa": ("position", "absolute"), "posr": ("position", "relative"), "posf": ("position", "fixed"),
        "poss": ("position", "static"), "pos:s": ("position", "static"), "posst": ("position", "sticky"),
        "fwb": ("font-weight", "bold"), "fwn": ("font-weight", "normal"), "fwbr": ("font-weight", "bolder"),
        "fwlr": ("font-weight", "lighter"), "fsi": ("font-style", "italic"), "fsn": ("font-style", "normal"),
        "tac": ("text-align", "center"), "tal": ("text-align", "left"), "tar": ("text-align", "right"), "taj": ("text-align", "justify"),
        "tdn": ("text-decoration", "none"), "tdu": ("text-decoration", "underline"), "tdl": ("text-decoration", "line-through"),
        "ttu": ("text-transform", "uppercase"), "ttl": ("text-transform", "lowercase"), "ttc": ("text-transform", "capitalize"),
        "ttn": ("text-transform", "none"), "tove": ("text-overflow", "ellipsis"),
        "ovh": ("overflow", "hidden"), "ova": ("overflow", "auto"), "ovs": ("overflow", "scroll"), "ovv": ("overflow", "visible"),
        "ovxh": ("overflow-x", "hidden"), "ovyh": ("overflow-y", "hidden"), "ovxa": ("overflow-x", "auto"), "ovya": ("overflow-y", "auto"),
        "cup": ("cursor", "pointer"), "cud": ("cursor", "default"), "cuh": ("cursor", "help"), "cum": ("cursor", "move"),
        "cut": ("cursor", "text"), "cuw": ("cursor", "wait"),
        "vh": ("visibility", "hidden"), "vv": ("visibility", "visible"),
        "fll": ("float", "left"), "flr": ("float", "right"), "fln": ("float", "none"),
        "cb": ("clear", "both"), "cll": ("clear", "left"), "clr": ("clear", "right"), "cln": ("clear", "none"),
        "jcc": ("justify-content", "center"), "jcsb": ("justify-content", "space-between"),
        "jcsa": ("justify-content", "space-around"), "jcse": ("justify-content", "space-evenly"),
        "jcfs": ("justify-content", "flex-start"), "jcfe": ("justify-content", "flex-end"),
        "jcs": ("justify-content", "start"), "jce": ("justify-content", "end"),
        "aic": ("align-items", "center"), "aifs": ("align-items", "flex-start"), "aife": ("align-items", "flex-end"),
        "ais": ("align-items", "stretch"), "aib": ("align-items", "baseline"),
        "acc": ("align-content", "center"), "acsb": ("align-content", "space-between"),
        "asc": ("align-self", "center"), "asfs": ("align-self", "flex-start"), "asfe": ("align-self", "flex-end"),
        "ass": ("align-self", "stretch"),
        "fxdc": ("flex-direction", "column"), "fxdr": ("flex-direction", "row"), "fxdcr": ("flex-direction", "column-reverse"),
        "fxdrr": ("flex-direction", "row-reverse"), "fxww": ("flex-wrap", "wrap"), "fxwn": ("flex-wrap", "nowrap"),
        "fxwwr": ("flex-wrap", "wrap-reverse"), "fx1": ("flex", "1"),
        "bxzbb": ("box-sizing", "border-box"), "bxzcb": ("box-sizing", "content-box"),
        "wsnw": ("white-space", "nowrap"), "wsn": ("white-space", "normal"), "wsp": ("white-space", "pre"),
        "wspw": ("white-space", "pre-wrap"), "wobba": ("word-break", "break-all"),
        "bdn": ("border", "none"), "bd+": ("border", "1px solid #000"), "bdcc": ("border-collapse", "collapse"),
        "bgn": ("background", "none"), "bgrn": ("background-repeat", "no-repeat"), "bgszcv": ("background-size", "cover"),
        "bgszct": ("background-size", "contain"), "usn": ("user-select", "none"), "pen": ("pointer-events", "none"),
        "pea": ("pointer-events", "auto"), "lisn": ("list-style", "none"), "oln": ("outline", "none"),
        "obfc": ("object-fit", "cover"), "obfct": ("object-fit", "contain"), "vat": ("vertical-align", "top"),
        "vam": ("vertical-align", "middle"), "vab": ("vertical-align", "bottom"), "trfn": ("transform", "none"),
        "op0": ("opacity", "0"), "op1": ("opacity", "1"),
    ]

    /// Declarations with several stops.
    static let cssTemplates: [String: (property: String, value: String, stops: Int)] = [
        "bgi": ("background-image", "url(${1})", 1),
        "trs": ("transition", "${1:prop} ${2:time}", 2),
        "bxsh": ("box-shadow", "${1:inset }${2:hoff} ${3:voff} ${4:blur} ${5:color}", 5),
        "tsh": ("text-shadow", "${1:hoff} ${2:voff} ${3:blur} ${4:#000}", 4),
        "trf": ("transform", "${1}", 1),
        "trfr": ("transform", "rotate(${1:angle})", 1),
        "trfs": ("transform", "scale(${1:x}, ${2:y})", 2),
        "trft": ("transform", "translate(${1:x}, ${2:y})", 2),
        "cnt": ("content", "'${1}'", 1),
        "gtc": ("grid-template-columns", "repeat(${1:2}, ${2:1fr})", 2),
        "ff": ("font-family", "${1:sans-serif}", 1),
        "bd": ("border", "${1:1px} ${2:solid} ${3:#000}", 3),
        "anim": ("animation", "${1:name} ${2:duration} ${3:timing-function} ${4:delay} ${5:iteration-count}", 5),
    ]
}
