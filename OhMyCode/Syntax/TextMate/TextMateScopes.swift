import AppKit

/// How TextMate scopes become colors. A TextMate token reaches the editor as a highlight
/// named by its scopes joined with spaces (`source.toy string.quoted.double.toy`); tree-sitter
/// capture names never have a space, so the two are told apart by that.
enum TextMateScopes {
    static func isScopeList(_ name: String) -> Bool { name.contains(" ") }

    static func scopes(of name: String) -> [String] { name.split(separator: " ").map(String.init) }

    /// In a string or a comment (brackets there don't pair up).
    static func isNonCode(_ name: String) -> Bool {
        name.contains(" string") || name.contains(" comment")
    }

    /// Common scopes → the capture names the built-in themes color (see
    /// `EditorTheme.color(forCapture:)`), longest prefix first within a scope.
    static let captureNames: [(scope: String, capture: String)] = [
        ("comment", "comment"),
        ("punctuation.definition.comment", "comment"),
        ("constant.character.escape", "escape"),
        ("string", "string"),
        ("punctuation.definition.string", "string"),
        ("markup.inline.raw", "string"),
        ("constant.numeric", "number"),
        ("constant.language", "constant.builtin"),
        ("constant.character", "character"),
        ("constant", "constant"),
        ("support.constant", "constant"),
        ("keyword.operator", "operator"),
        ("keyword", "keyword"),
        ("storage.type.annotation", "attribute"),
        ("storage.type", "keyword"),
        ("storage.modifier", "keyword"),
        ("storage", "keyword"),
        ("variable.language", "variable.builtin"),
        ("support.variable", "variable.builtin"),
        ("variable.parameter", "variable.parameter"),
        ("variable.other.property", "property"),
        ("variable.other.member", "property"),
        ("variable.other.object.property", "property"),
        ("support.type.property-name", "property"),
        ("meta.object-literal.key", "property"),
        ("entity.name.tag", "tag"),
        ("entity.other.attribute-name", "attribute"),
        ("meta.attribute", "attribute"),
        ("entity.name.function", "function"),
        ("support.function", "function"),
        ("entity.name.type", "type"),
        ("entity.name.class", "type"),
        ("entity.name.struct", "type"),
        ("entity.name.enum", "type"),
        ("entity.name.interface", "type"),
        ("entity.name.namespace", "namespace"),
        ("entity.other.inherited-class", "type"),
        ("support.type", "type"),
        ("support.class", "type"),
        ("entity.name.section", "keyword"),
        ("markup.heading", "keyword"),
        ("entity.name.label", "label"),
    ]

    /// The capture name for the innermost scope the table knows (nil: plain text).
    static func captureName(for scopes: [String]) -> String? {
        for scope in scopes.reversed() {
            var best: (length: Int, capture: String)?
            for entry in captureNames where ScopeSelector.scope(scope, matches: entry.scope) {
                if entry.scope.count > (best?.length ?? -1) { best = (entry.scope.count, entry.capture) }
            }
            if let best { return best.capture }
        }
        return nil
    }
}

/// A VS Code theme's `tokenColors`, matched the way VS Code does: the innermost scope that
/// any rule matches decides; among the rules for it, the one naming more of the scope
/// (`string.quoted` over `string`), then the one with more ancestor scopes (`meta.tag string`
/// over `string`), then the later one.
struct TextMateThemeRules: @unchecked Sendable {
    struct Rule {
        /// Ancestor scopes, then the scope itself: "meta.tag string" is ["meta.tag", "string"].
        let path: [String]
        /// "-comment": rules that don't apply inside these.
        let excluded: [String]
        let color: NSColor
        let order: Int
    }

    var rules: [Rule] = []

    var isEmpty: Bool { rules.isEmpty }

    /// From `tokenColors` entries' scope selectors ("a, b c, d -e").
    mutating func add(selector: String, color: NSColor) {
        let parts = selector.split(separator: " ").map(String.init)
        var path: [String] = [], excluded: [String] = []
        var excluding = false
        for part in parts {
            if part == "-" { excluding = true; continue }
            if part.hasPrefix("-") { excluded.append(String(part.dropFirst())); continue }
            if excluding { excluded.append(part) } else { path.append(part) }
        }
        guard !path.isEmpty else { return }
        rules.append(Rule(path: path, excluded: excluded, color: color, order: rules.count))
    }

    func match(_ scopes: [String]) -> Rule? {
        for depth in scopes.indices.reversed() {
            let scope = scopes[depth]
            var best: Rule?
            for rule in rules where ScopeSelector.scope(scope, matches: rule.path[rule.path.count - 1]) {
                guard Self.ancestorsMatch(rule.path.dropLast(), in: scopes[..<depth]),
                      !rule.excluded.contains(where: { excluded in scopes.contains { ScopeSelector.scope($0, matches: excluded) } })
                else { continue }
                if let current = best, Self.rank(current) > Self.rank(rule) { continue }
                best = rule
            }
            if let best { return best }
        }
        return nil
    }

    private static func rank(_ rule: Rule) -> (Int, Int, Int) {
        (rule.path[rule.path.count - 1].split(separator: ".").count, rule.path.count, rule.order)
    }

    private static func ancestorsMatch(_ ancestors: ArraySlice<String>, in scopes: ArraySlice<String>) -> Bool {
        var position = scopes.startIndex
        for ancestor in ancestors {
            guard let found = scopes[position...].firstIndex(where: { ScopeSelector.scope($0, matches: ancestor) }) else { return false }
            position = found + 1
        }
        return true
    }
}
