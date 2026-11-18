import AppKit
import SwiftUI

/// What colors the text under the caret (Developer: Inspect Editor Tokens and Scopes): the
/// language and what highlights it, the TextMate scopes or tree-sitter captures there, the
/// semantic token over them, and the color that wins.
struct TokenInspection: Equatable {
    var text: String
    var language: String
    var engine: String
    /// TextMate scopes, innermost first.
    var scopes: [String] = []
    /// Tree-sitter captures there, in query order (the last one's color wins).
    var captures: [String] = []
    /// Syntax nodes enclosing it, innermost first.
    var nodes: [String] = []
    var embeddedLanguage: String?
    var semanticToken: String?
    /// What decides its color: a theme rule's selector, or a syntax role.
    var colorSource: String?
    /// "#RRGGBB", or nil for the plain text color.
    var foreground: String?

    /// As the popover shows it (and as tests read it).
    var summary: String {
        var lines = ["\(text.isEmpty ? "(empty)" : "“\(text)”")", "language: \(language)", "highlighting: \(engine)"]
        if let embeddedLanguage { lines.append("embedded language: \(embeddedLanguage)") }
        if !scopes.isEmpty { lines.append("textmate scopes:\n" + scopes.map { "  \($0)" }.joined(separator: "\n")) }
        if !captures.isEmpty { lines.append("tree-sitter captures: " + captures.joined(separator: ", ")) }
        if !nodes.isEmpty { lines.append("syntax nodes: " + nodes.joined(separator: " < ")) }
        lines.append("semantic token: \(semanticToken ?? "none")")
        lines.append("foreground: \(foreground ?? "default")" + (colorSource.map { " (\($0))" } ?? ""))
        return lines.joined(separator: "\n")
    }
}

extension EditorDocument {
    /// What highlighting sees at `offset` (see `TokenInspection`).
    func inspectTokens(at offset: Int) async -> TokenInspection {
        let length = textStorage.length
        let location = min(max(0, offset), length)
        let wordRange = self.wordRange(at: location) ?? NSRange(location: location, length: location < length ? 1 : 0)
        var inspection = TokenInspection(text: textStorage.mutableString.substring(with: wordRange).trimmingCharacters(in: .newlines),
                                         language: "\(language.displayName) (\(language.languageId))",
                                         engine: Self.engineTitle(highlighter?.engineKey))
        let found = await highlighter?.inspect(at: location) ?? (scopes: [], captures: [], nodes: [])
        inspection.scopes = found.scopes.reversed()
        inspection.captures = found.captures
        inspection.nodes = found.nodes
        if !found.scopes.isEmpty {
            inspection.embeddedLanguage = ContributedGrammars.shared.embeddedLanguage(forScopes: found.scopes)
        }
        if let token = semanticTokens(in: NSRange(location: location, length: 1)).last(where: { NSLocationInRange(location, $0.range) }) {
            inspection.semanticToken = token.type
        }
        let theme = EditorTheme.current
        var color: NSColor?
        if !found.scopes.isEmpty {
            if let rule = theme.textMateRules?.match(found.scopes) {
                color = rule.color
                inspection.colorSource = "theme rule “\((rule.path + rule.excluded.map { "-" + $0 }).joined(separator: " "))”"
            } else if theme.textMateRules == nil, let capture = TextMateScopes.captureName(for: found.scopes) {
                color = EditorTheme.color(forCapture: capture)
                inspection.colorSource = "scope → \(capture)"
            }
        } else if let capture = found.captures.last(where: { EditorTheme.color(forCapture: $0) != nil }) {
            color = EditorTheme.color(forCapture: capture)
            inspection.colorSource = "capture @\(capture)"
        }
        if let type = inspection.semanticToken, let capture = SemanticTokens.capture(for: type) {
            color = capture.isEmpty ? nil : EditorTheme.color(forCapture: capture)
            inspection.colorSource = "semantic token \(type)"
        }
        inspection.foreground = color.map { String(format: "#%06X", VSCodeTheme.rgb($0)) }
        return inspection
    }

    static func engineTitle(_ key: String?) -> String {
        guard let key else { return "none" }
        let parts = key.split(separator: ":").map(String.init)
        switch parts.first {
        case "builtin": return "built-in"
        case "tree-sitter": return "tree-sitter (extension)"
        case "textmate": return "TextMate grammar \(parts.count > 1 ? parts[1] : "")"
        default: return key
        }
    }
}

extension EditorController {
    /// Shows `TokenInspection` for the caret in a popover under it.
    func inspectTokensAtCaret() {
        let location = textView.selectedRange().location
        Task { @MainActor [weak self] in
            guard let self else { return }
            let inspection = await document.inspectTokens(at: location)
            let anchor = rect(for: NSRange(location: min(location, document.textStorage.length), length: 0))
                ?? NSRect(x: 0, y: 0, width: 1, height: 16)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: TokenInspectionView(inspection: inspection))
            popover.show(relativeTo: anchor.insetBy(dx: -1, dy: 0), of: textView, preferredEdge: .maxY)
        }
    }
}

private struct TokenInspectionView: View {
    let inspection: TokenInspection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(inspection.summary)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let hex = inspection.foreground, let color = VSCodeTheme.color(hex) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: color)).frame(width: 12, height: 12)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(inspection.summary, forType: .string)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 380, alignment: .leading)
    }
}
