import Foundation

/// A file's settings from `.editorconfig` files (https://editorconfig.org): the ones in its
/// folder and every folder above, up to one marked `root = true`. Nearer files and later
/// sections win. Unset properties are nil (the editor's own behavior applies).
struct EditorConfig: Equatable, Sendable {
    enum IndentStyle: String, Sendable { case space, tab }
    enum LineEnding: String, Sendable {
        case lf, crlf, cr

        var characters: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }
    }

    var indentStyle: IndentStyle?
    /// Columns per indent level (`indent_size = tab` means the tab width).
    var indentSize: Int?
    var tabWidth: Int?
    var endOfLine: LineEnding?
    var trimTrailingWhitespace: Bool?
    var insertFinalNewline: Bool?
    /// The `.editorconfig` files that set something for the file, nearest first.
    var sources: [URL] = []

    var isEmpty: Bool {
        indentStyle == nil && indentSize == nil && tabWidth == nil && endOfLine == nil
            && trimTrailingWhitespace == nil && insertFinalNewline == nil
    }

    /// Applies one section's properties (later ones override).
    private mutating func set(_ properties: [String: String]) {
        for (key, value) in properties {
            let value = value.lowercased()
            // "unset" removes what an earlier section or file set.
            let isUnset = value == "unset"
            switch key {
            case "indent_style": indentStyle = isUnset ? nil : IndentStyle(rawValue: value) ?? indentStyle
            case "indent_size":
                if isUnset { indentSize = nil } else if value == "tab" { indentSize = -1 } else if let size = Int(value), size > 0 { indentSize = size }
            case "tab_width":
                if isUnset { tabWidth = nil } else if let width = Int(value), width > 0 { tabWidth = width }
            case "end_of_line": endOfLine = isUnset ? nil : LineEnding(rawValue: value) ?? endOfLine
            case "trim_trailing_whitespace": trimTrailingWhitespace = isUnset ? nil : Self.bool(value) ?? trimTrailingWhitespace
            case "insert_final_newline": insertFinalNewline = isUnset ? nil : Self.bool(value) ?? insertFinalNewline
            default: break
            }
        }
    }

    private static func bool(_ value: String) -> Bool? {
        switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }

    /// The width of a tab, and of one indent level, as the spec defines them from each other.
    private mutating func resolveWidths() {
        if indentSize == -1 { indentSize = tabWidth } // indent_size = tab
        if tabWidth == nil, let indentSize { tabWidth = indentSize }
        if indentSize == nil, indentStyle == .tab { indentSize = tabWidth }
    }

    // MARK: Files

    /// One `.editorconfig`: whether it's the root, and its sections (glob, properties) in order.
    struct File: Equatable, Sendable {
        var isRoot = false
        var sections: [(glob: String, properties: [String: String])] = []

        static func == (lhs: File, rhs: File) -> Bool {
            lhs.isRoot == rhs.isRoot && lhs.sections.map(\.glob) == rhs.sections.map(\.glob)
                && lhs.sections.map(\.properties) == rhs.sections.map(\.properties)
        }

        init(isRoot: Bool = false, sections: [(glob: String, properties: [String: String])] = []) {
            self.isRoot = isRoot
            self.sections = sections
        }

        /// INI-like: `[glob]` headers, `key = value` lines, `#` and `;` comments. Keys are
        /// case-insensitive; properties before any section are the preamble (only `root`).
        init(parsing text: String) {
            var current: (glob: String, properties: [String: String])?
            for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
                if line.hasPrefix("["), line.hasSuffix("]") {
                    if let current { sections.append(current) }
                    current = (String(line.dropFirst().dropLast()), [:])
                    continue
                }
                guard let equals = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if current == nil {
                    if key == "root" { isRoot = value.lowercased() == "true" }
                } else {
                    current?.properties[key] = value
                }
            }
            if let current { sections.append(current) }
        }
    }

    /// Parsed files by path, with the modification date they were read at.
    @MainActor private static var cache: [String: (date: Date?, file: File?)] = [:]

    @MainActor
    private static func file(at url: URL) -> File? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = cache[url.path], cached.date == date { return cached.file }
        let file = date == nil ? nil : (try? String(contentsOf: url, encoding: .utf8)).map(File.init(parsing:))
        cache[url.path] = (date, file)
        return file
    }

    /// The settings for `url`: from its folder's `.editorconfig` up to a root one.
    @MainActor
    static func resolve(for url: URL) -> EditorConfig {
        let path = url.standardizedFileURL.path
        var files: [(directory: String, url: URL, file: File)] = []
        // Paths, not URLs: "/" has no parent ("/.." would go on forever).
        var directory = (path as NSString).deletingLastPathComponent
        while !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appending(path: ".editorconfig")
            if let file = file(at: candidate) {
                files.append((directory, candidate, file))
                if file.isRoot { break }
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory { break }
            directory = parent
        }
        var config = EditorConfig()
        // Farthest first: nearer files override.
        for entry in files.reversed() {
            var matched = false
            let base = entry.directory.hasSuffix("/") ? entry.directory : entry.directory + "/"
            guard path.hasPrefix(base) else { continue }
            let relative = String(path.dropFirst(base.count))
            for section in entry.file.sections where matches(section.glob, relative: relative) {
                config.set(section.properties)
                matched = true
            }
            if matched { config.sources.insert(entry.url, at: 0) }
        }
        config.resolveWidths()
        return config
    }

    /// Whether `glob` matches a file at `relative` (to the `.editorconfig`'s folder). A glob
    /// without a `/` matches the file's name in any folder below.
    static func matches(_ glob: String, relative: String) -> Bool {
        var glob = glob
        if glob.hasPrefix("/") { glob.removeFirst() } else if !glob.contains("/") { glob = "**/" + glob }
        guard let regex = try? NSRegularExpression(pattern: "^" + regexPattern(for: glob) + "$") else { return false }
        return regex.firstMatch(in: relative, range: NSRange(location: 0, length: (relative as NSString).length)) != nil
    }

    /// `*` (not across `/`), `**` (across), `?`, `[abc]`, `[!abc]`, `{a,b}`, `{1..9}`.
    private static func regexPattern(for glob: String) -> String {
        let characters = Array(glob)
        var result = ""
        var index = 0
        var braceDepth = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\":
                index += 1
                if index < characters.count { result += NSRegularExpression.escapedPattern(for: String(characters[index])) }
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    index += 1
                    // "**/" also matches no folder at all.
                    if index + 1 < characters.count, characters[index + 1] == "/" {
                        index += 1
                        result += "(?:.*/)?"
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^/]*"
                }
            case "?": result += "[^/]"
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]") {
                    var set = String(characters[(index + 1)..<close])
                    if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                    result += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    index = close
                } else {
                    result += "\\["
                }
            case "{":
                if let close = characters[(index + 1)...].firstIndex(of: "}") {
                    let inner = String(characters[(index + 1)..<close])
                    // {1..10}: a number in the range.
                    let bounds = inner.components(separatedBy: "..")
                    if bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]), low <= high, high - low <= 10_000 {
                        result += "(?:" + (low...high).map(String.init).joined(separator: "|") + ")"
                        index = close
                    } else if inner.contains(",") {
                        braceDepth += 1
                        result += "(?:"
                    } else {
                        // {single}: literal braces.
                        result += NSRegularExpression.escapedPattern(for: "{" + inner + "}")
                        index = close
                    }
                } else {
                    result += "\\{"
                }
            case "}" where braceDepth > 0:
                braceDepth -= 1
                result += ")"
            case "," where braceDepth > 0:
                result += "|"
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return result
    }
}

extension EditorDocument {
    /// The edits `.editorconfig` asks for when saving: trailing whitespace trimmed, a final
    /// newline, and its line endings.
    func editorConfigEdits() -> [TextReplacement] {
        let config = editorConfig
        let text = textStorage.mutableString
        let length = text.length
        var edits: [TextReplacement] = []

        if let ending = config.endOfLine {
            var index = 0
            var lineEnds: [TextReplacement] = []
            while index < length {
                let unit = text.character(at: index)
                if unit == 0x0D || unit == 0x0A {
                    let isPair = unit == 0x0D && index + 1 < length && text.character(at: index + 1) == 0x0A
                    let range = NSRange(location: index, length: isPair ? 2 : 1)
                    if text.substring(with: range) != ending.characters {
                        lineEnds.append(TextReplacement(range: range, text: ending.characters))
                    }
                    index += range.length
                } else {
                    index += 1
                }
            }
            // A file that's all the other kind: one replacement, not one per line.
            if lineEnds.count > 2_000 {
                let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\n", with: ending.characters)
                var whole = normalized
                if config.trimTrailingWhitespace == true {
                    whole = whole.components(separatedBy: ending.characters)
                        .map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
                        .joined(separator: ending.characters)
                }
                if config.insertFinalNewline == true, !whole.isEmpty, !whole.hasSuffix(ending.characters) { whole += ending.characters }
                return [TextReplacement(range: NSRange(location: 0, length: length), text: whole)]
            }
            edits += lineEnds
        }

        if config.trimTrailingWhitespace == true {
            var index = 0
            while index <= length {
                // The end of this line (before its line break, or the text's end).
                var end = index
                while end < length, text.character(at: end) != 0x0A, text.character(at: end) != 0x0D { end += 1 }
                var start = end
                while start > index, text.character(at: start - 1) == 0x20 || text.character(at: start - 1) == 0x09 { start -= 1 }
                if start < end { edits.append(TextReplacement(range: NSRange(location: start, length: end - start), text: "")) }
                guard end < length else { break }
                index = end + (text.character(at: end) == 0x0D && end + 1 < length && text.character(at: end + 1) == 0x0A ? 2 : 1)
            }
        }

        if config.insertFinalNewline == true, length > 0 {
            let last = text.character(at: length - 1)
            if last != 0x0A && last != 0x0D {
                let ending = config.endOfLine?.characters ?? (text.range(of: "\r\n").location != NSNotFound ? "\r\n" : "\n")
                // After trimmed whitespace at the end, not inside it.
                edits.append(TextReplacement(range: NSRange(location: length, length: 0), text: ending))
            }
        }
        return edits.sorted { $0.range.location < $1.range.location }
    }

    /// The line endings the text uses (the first one found; LF for one line).
    var lineEnding: EditorConfig.LineEnding {
        let text = textStorage.mutableString
        let newline = text.rangeOfCharacter(from: .newlines)
        guard newline.location != NSNotFound else { return .lf }
        if text.character(at: newline.location) == 0x0D {
            return newline.location + 1 < text.length && text.character(at: newline.location + 1) == 0x0A ? .crlf : .cr
        }
        return .lf
    }
}
