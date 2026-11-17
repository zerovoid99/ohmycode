import SwiftUI

/// The blocks of an agent's Markdown reply: what `Text` can't lay out by itself (it does the
/// inline part: emphasis, code, links). A block still streaming in (an unclosed code fence)
/// is shown as it is so far.
enum AgentMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// One list item: its marker ("•" or "3."), how deep it's nested, its text.
        case listItem(marker: String, depth: Int, text: String)
        case quote(String)
        case code(language: String?, text: String)
        /// Table rows, as written (shown in monospace).
        case table(String)
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [Substring] = [], quote: [Substring] = [], table: [Substring] = []
        var code: (language: String?, lines: [Substring])?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table.joined(separator: "\n"))); table = [] }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    open.lines.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("|") {
                if table.isEmpty { flush() }
                table.append(line)
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(Substring(trimmed.dropFirst().drop { $0 == " " }))
                continue
            }
            if let heading = Self.heading(trimmed) { flush(); blocks.append(heading); continue }
            if trimmed.count >= 3, Set(trimmed.filter { $0 != " " }).count == 1, let first = trimmed.first, "-*_".contains(first) {
                flush(); blocks.append(.rule); continue
            }
            if let item = Self.listItem(line) { flush(); blocks.append(item); continue }
            if !quote.isEmpty || !table.isEmpty { flush() }
            paragraph.append(Substring(trimmed))
        }
        if let open = code { blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: Substring) -> Block? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        let depth = indent / 2
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            var text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            var marker = "•"
            // Task lists: "- [ ] x", "- [x] x".
            if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) } else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text.removeFirst(4) }
            return .listItem(marker: marker, depth: depth, text: text)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " {
                return .listItem(marker: "\(digits).", depth: depth, text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Inline Markdown (emphasis, code, links), line breaks kept.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A reply, block by block.
struct AgentMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(AgentMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: AgentMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let text):
            Text(AgentMarkdown.inline(text))
        case .heading(let level, let text):
            Text(AgentMarkdown.inline(text))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 2)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(AgentMarkdown.inline(text))
            }
            .padding(.leading, CGFloat(depth) * 12)
        case .quote(let text):
            Text(AgentMarkdown.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
        case .code(_, let text), .table(let text):
            if !text.isEmpty {
                ScrollView(.horizontal) {
                    Text(text).font(.system(size: 11, design: .monospaced)).padding(6)
                }
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
        case .rule:
            Divider()
        }
    }
}
