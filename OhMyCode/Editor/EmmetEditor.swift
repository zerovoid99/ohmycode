import AppKit

/// Where Emmet applies in a document, and its editor commands: Tab after an abbreviation,
/// the completion list's "Emmet Abbreviation" item, and the palette's Expand, Wrap with
/// Abbreviation…, Balance and Remove Tag.
extension Emmet {
    /// An abbreviation found before the cursor, its expansion and the text it replaces.
    struct Expansion: Equatable {
        var range: NSRange
        var abbreviation: String
        var syntax: Syntax
        /// A snippet body (stops for empty attributes and elements).
        var body: String
    }

    /// The Emmet syntax of a file's language, nil for languages without abbreviations
    /// (Markdown, plain JavaScript, …). HTML-like templates (Vue, Svelte, PHP, ERB…) are HTML;
    /// `.jsx`, `.tsx` are JSX.
    static func syntax(languageId: String, fileExtension: String) -> Syntax? {
        let ext = fileExtension.lowercased()
        if ["javascriptreact", "typescriptreact"].contains(languageId) || ["jsx", "tsx"].contains(ext) { return .jsx }
        if ["css", "scss", "less"].contains(languageId) || ["css", "scss", "less"].contains(ext) { return .css }
        if ["xml", "xsl", "xslt", "svg"].contains(languageId) || ["xml", "xsl", "xslt", "svg", "xhtml"].contains(ext) {
            return ext == "xhtml" ? .html : .xml
        }
        let htmlLike: Set<String> = [
            "html", "xhtml", "vue", "vue-html", "svelte", "php", "erb", "html.erb", "handlebars", "hbs", "razor", "aspnetcorerazor",
            "astro", "jinja-html", "django-html", "twig", "blade", "liquid", "ejs", "nunjucks", "njk",
        ]
        let htmlExtensions: Set<String> = [
            "html", "htm", "vue", "svelte", "php", "erb", "hbs", "handlebars", "astro", "twig", "njk", "ejs", "liquid", "cshtml",
        ]
        if htmlLike.contains(languageId) || htmlExtensions.contains(ext) { return .html }
        return nil
    }

    /// The abbreviation ending at `cursor` and its expansion, when one expands there.
    /// `confident` (Tab, completion) also asks that it's where people write markup or a CSS
    /// property, and that a plain word is a tag; the palette's Expand doesn't.
    static func expansion(in text: NSString, at cursor: Int, languageSyntax: Syntax?, confident: Bool) -> Expansion? {
        guard cursor <= text.length else { return nil }
        let base = languageSyntax ?? (confident ? nil : .html)
        guard let base else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: cursor, length: 0)).location
        let prefixStart = max(lineStart, cursor - 1000)
        let prefix = text.substring(with: NSRange(location: prefixStart, length: cursor - prefixStart))
        guard let syntax = context(in: text, at: cursor, base: base) ?? (confident ? nil : base) else { return nil }
        if syntax == .css {
            guard let (abbreviation, start) = extractCSS(beforeCursor: prefix) else { return nil }
            let location = prefixStart + start
            if confident, !isPropertyStart(in: text, at: location) { return nil }
            guard let body = expandCSS(abbreviation) else { return nil }
            return Expansion(range: NSRange(location: location, length: cursor - location), abbreviation: abbreviation, syntax: syntax, body: body)
        }
        guard let (abbreviation, start) = extractMarkup(beforeCursor: prefix) else { return nil }
        let location = prefixStart + start
        if confident {
            guard isConfidentMarkup(abbreviation, syntax: syntax) else { return nil }
            if syntax == .jsx, !isJSXTagPosition(in: text, at: location) { return nil }
        }
        guard let body = expandMarkup(abbreviation, syntax: syntax) else { return nil }
        return Expansion(range: NSRange(location: location, length: cursor - location), abbreviation: abbreviation, syntax: syntax, body: body)
    }

    // MARK: Context

    /// The syntax that applies at `offset` in a file of `base` syntax: CSS in an HTML file's
    /// `<style>`, nothing in its comments, scripts, template code (`<?php`, `<%`, `{{`) or
    /// inside a tag (attributes), nothing in a CSS comment or outside a rule's braces.
    static func context(in text: NSString, at offset: Int, base: Syntax) -> Syntax? {
        let windowStart = max(0, offset - 100_000)
        let window = NSRange(location: windowStart, length: offset - windowStart)
        func last(_ string: String, caseInsensitive: Bool = false) -> Int {
            let found = text.range(of: string, options: caseInsensitive ? [.backwards, .caseInsensitive] : [.backwards, .literal], range: window)
            return found.location == NSNotFound ? -1 : found.location
        }
        switch base {
        case .css:
            return isInCSSRule(text, from: windowStart, to: offset) ? .css : nil
        case .jsx:
            if last("/*") > last("*/") { return nil }
            let line = text.lineRange(for: NSRange(location: offset, length: 0))
            let before = text.substring(with: NSRange(location: line.location, length: offset - line.location))
            if before.contains("//") { return nil }
            for quote in ["\"", "'", "`"] where before.components(separatedBy: quote).count % 2 == 0 { return nil }
            return isInsideTag(text, before: offset, lowerBound: windowStart) ? nil : .jsx
        case .html, .xml:
            if last("<!--") > last("-->") { return nil }
            if last("<?") > last("?>") || last("<%") > last("%>") || last("{{") > last("}}") { return nil }
            if base == .html {
                let style = last("<style", caseInsensitive: true)
                if style > last("</style", caseInsensitive: true) {
                    let tagEnd = text.range(of: ">", options: .literal, range: NSRange(location: style, length: offset - style))
                    guard tagEnd.location != NSNotFound else { return nil } // in the <style …> tag
                    return isInCSSRule(text, from: NSMaxRange(tagEnd), to: offset) ? .css : nil
                }
                if last("<script", caseInsensitive: true) > last("</script", caseInsensitive: true) { return nil }
            }
            return isInsideTag(text, before: offset, lowerBound: windowStart) ? nil : base
        }
    }

    /// Whether `offset` is between a tag's `<` and its `>` (where attributes go).
    private static func isInsideTag(_ text: NSString, before offset: Int, lowerBound: Int) -> Bool {
        var index = offset - 1
        while index >= lowerBound {
            switch text.character(at: index) {
            case 0x3E: // ">", but not JSX's "=>"
                if index > 0, text.character(at: index - 1) == 0x3D { break }
                return false
            case 0x3C:
                guard index + 1 < text.length, let next = Unicode.Scalar(text.character(at: index + 1)) else { return false }
                return CharacterSet.letters.contains(next) || next == "/"
            default:
                break
            }
            index -= 1
        }
        return false
    }

    /// Whether `offset` is inside a rule's braces and not in a comment.
    private static func isInCSSRule(_ text: NSString, from start: Int, to offset: Int) -> Bool {
        guard offset > start else { return false }
        let range = NSRange(location: start, length: offset - start)
        let commentOpen = text.range(of: "/*", options: [.backwards, .literal], range: range)
        let commentClose = text.range(of: "*/", options: [.backwards, .literal], range: range)
        if commentOpen.location != NSNotFound, commentClose.location == NSNotFound || commentClose.location < commentOpen.location { return false }
        var depth = 0
        var quote: unichar?
        for index in start..<offset {
            let unit = text.character(at: index)
            if let open = quote {
                if unit == open { quote = nil }
                continue
            }
            switch unit {
            case 0x22, 0x27: quote = unit
            case 0x7B: depth += 1
            case 0x7D: depth = max(0, depth - 1)
            default: break
            }
        }
        return depth > 0 && quote == nil
    }

    /// Whether a CSS abbreviation at `offset` is where a property goes: after `{`, `;` or `}`.
    static func isPropertyStart(in text: NSString, at offset: Int) -> Bool {
        guard let previous = previousCharacter(in: text, before: offset) else { return false }
        return previous == "{" || previous == ";" || previous == "}"
    }

    /// Whether a JSX abbreviation at `offset` is where an element goes: after another
    /// element's `>`, a `(` that ends its line (`return (`), or a `return`.
    static func isJSXTagPosition(in text: NSString, at offset: Int) -> Bool {
        var index = offset - 1
        while index >= 0, let scalar = Unicode.Scalar(text.character(at: index)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            index -= 1
        }
        guard index >= 0 else { return true }
        switch text.character(at: index) {
        case 0x3E: return index == 0 || text.character(at: index - 1) != 0x3D // ">" but not "=>"
        case 0x28: // "(" ending a line (`return (`), not a call's arguments
            return text.substring(with: NSRange(location: index, length: offset - index)).contains("\n")
        default:
            let start = max(0, index - 5)
            return text.substring(with: NSRange(location: start, length: index - start + 1)) == "return"
                && (start == 0 || !(Unicode.Scalar(text.character(at: start - 1)).map(CharacterSet.alphanumerics.contains) ?? false))
        }
    }

    private static func previousCharacter(in text: NSString, before offset: Int) -> Character? {
        var index = offset - 1
        while index >= 0, let scalar = Unicode.Scalar(text.character(at: index)) {
            if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return Character(scalar) }
            index -= 1
        }
        return nil
    }

    // MARK: Tags

    /// An element in a document: its opening tag, and its closing tag (nil: void or `<x/>`).
    struct TagPair: Equatable {
        var name: String
        var open: NSRange
        var close: NSRange?

        var outer: NSRange { NSRange(location: open.location, length: NSMaxRange(close ?? open) - open.location) }
        var inner: NSRange? { close.map { NSRange(location: NSMaxRange(open), length: $0.location - NSMaxRange(open)) } }
    }

    /// The document's elements, matched by name (comments, `<!…>`, `<?…?>` and script/style
    /// contents are skipped; unclosed ones are left out).
    static func tagPairs(in text: NSString) -> [TagPair] {
        var pairs: [TagPair] = []
        var stack: [(name: String, open: NSRange)] = []
        let length = min(text.length, 4_000_000)
        var index = 0
        func find(_ string: String, from start: Int) -> Int? {
            guard start <= length else { return nil }
            let found = text.range(of: string, options: .literal, range: NSRange(location: start, length: length - start))
            return found.location == NSNotFound ? nil : found.location
        }
        func isNameCharacter(_ unit: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || "-_:.".unicodeScalars.contains(scalar)
        }
        /// The end of the tag starting at `start` (after its `>`), quotes skipped.
        func tagEnd(from start: Int) -> Int? {
            var quote: unichar?
            var cursor = start
            while cursor < length {
                let unit = text.character(at: cursor)
                if let open = quote {
                    if unit == open { quote = nil }
                } else if unit == 0x22 || unit == 0x27 {
                    quote = unit
                } else if unit == 0x3E {
                    return cursor + 1
                } else if unit == 0x3C {
                    return nil
                }
                cursor += 1
            }
            return nil
        }
        while let next = find("<", from: index) {
            index = next + 1
            guard next + 1 < length else { break }
            let following = text.character(at: next + 1)
            if text.substring(with: NSRange(location: next, length: min(4, length - next))) == "<!--" {
                index = (find("-->", from: next + 4) ?? length - 3) + 3
                continue
            }
            if following == 0x21 || following == 0x3F { // <! <?
                index = (find(">", from: next) ?? length - 1) + 1
                continue
            }
            let closing = following == 0x2F
            var nameEnd = next + (closing ? 2 : 1)
            while nameEnd < length, isNameCharacter(text.character(at: nameEnd)) { nameEnd += 1 }
            let nameStart = next + (closing ? 2 : 1)
            guard nameEnd > nameStart, let scalar = Unicode.Scalar(text.character(at: nameStart)), CharacterSet.letters.contains(scalar),
                  let end = tagEnd(from: nameEnd) else { continue }
            let name = text.substring(with: NSRange(location: nameStart, length: nameEnd - nameStart))
            let range = NSRange(location: next, length: end - next)
            index = end
            if closing {
                guard let match = stack.lastIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
                pairs.append(TagPair(name: name, open: stack[match].open, close: range))
                stack.removeSubrange(match...)
                continue
            }
            if text.character(at: end - 2) == 0x2F || voidElements.contains(name.lowercased()) {
                pairs.append(TagPair(name: name, open: range, close: nil))
                continue
            }
            if ["script", "style"].contains(name.lowercased()), let close = find("</" + name, from: end) {
                stack.append((name, range))
                index = close
                continue
            }
            stack.append((name, range))
        }
        return pairs.sorted { $0.open.location < $1.open.location }
    }

    /// The range Balance Outward selects from `selection`: the content of the element around
    /// it, then the whole element, then its parent's content….
    static func balanceOutward(_ selection: NSRange, in pairs: [TagPair]) -> NSRange? {
        let candidates = pairs.flatMap { [$0.inner, $0.outer].compactMap { $0 } }
        return candidates.filter { contains($0, selection) && $0 != selection }
            .min { $0.length < $1.length }
    }

    /// The range Balance Inward selects: the element's content, then its first child….
    static func balanceInward(_ selection: NSRange, in pairs: [TagPair]) -> NSRange? {
        let candidates = pairs.flatMap { [$0.inner, $0.outer].compactMap { $0 } }
            .filter { contains(selection, $0) && $0 != selection && $0.length > 0 }
        let topLevel = candidates.filter { candidate in !candidates.contains { $0 != candidate && contains($0, candidate) } }
        return topLevel.min { $0.location < $1.location }
    }

    private static func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }

    /// The edits that remove the element around `offset`'s tags: a tag alone on its line takes
    /// the line with it, and then the content moves out one level.
    static func removeTagEdits(at offset: Int, in text: NSString, indentUnit: String) -> [TextReplacement]? {
        let pairs = tagPairs(in: text)
        guard let pair = pairs.filter({ $0.outer.location <= offset && offset <= NSMaxRange($0.outer) })
            .min(by: { $0.outer.length < $1.outer.length }) else { return nil }
        /// The tag's whole line (with its line break) when nothing else is on it.
        func removal(_ tag: NSRange) -> (range: NSRange, wholeLine: Bool) {
            let line = text.lineRange(for: tag)
            let before = text.substring(with: NSRange(location: line.location, length: tag.location - line.location))
            let after = text.substring(with: NSRange(location: NSMaxRange(tag), length: NSMaxRange(line) - NSMaxRange(tag)))
            if before.trimmingCharacters(in: .whitespaces).isEmpty, after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (line, true)
            }
            return (tag, false)
        }
        let open = removal(pair.open)
        guard let close = pair.close.map(removal) else { return [TextReplacement(range: open.range, text: "")] }
        var edits = [TextReplacement(range: open.range, text: ""), TextReplacement(range: close.range, text: "")]
        if open.wholeLine, close.wholeLine {
            var lineStart = NSMaxRange(open.range)
            while lineStart < close.range.location {
                let line = text.lineRange(for: NSRange(location: lineStart, length: 0))
                let content = text.substring(with: line)
                if content.hasPrefix(indentUnit) {
                    edits.append(TextReplacement(range: NSRange(location: line.location, length: (indentUnit as NSString).length), text: ""))
                } else if content.hasPrefix("\t") {
                    edits.append(TextReplacement(range: NSRange(location: line.location, length: 1), text: ""))
                }
                lineStart = NSMaxRange(line)
            }
        }
        return edits
    }
}

extension EditorController {
    /// The file's Emmet syntax (nil: none, or Emmet is off).
    var emmetSyntax: Emmet.Syntax? {
        guard AppSettings.shared.emmetEnabled else { return nil }
        return Emmet.syntax(languageId: document.languageId, fileExtension: document.url.pathExtension)
    }

    /// What Tab or the completion list would expand at the cursor.
    func emmetExpansion(confident: Bool = true) -> Emmet.Expansion? {
        guard let syntax = emmetSyntax ?? (confident ? nil : .html) else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        return Emmet.expansion(in: document.textStorage.mutableString, at: selection.location, languageSyntax: syntax, confident: confident)
    }

    /// Tab after an abbreviation (once nothing else took it: completion, a suggestion, a snippet).
    func expandEmmetOnTab() -> Bool {
        guard AppSettings.shared.emmetExpandOnTab, !hasExtraCursors, let expansion = emmetExpansion() else { return false }
        insertSnippet(expansion.body, replacing: expansion.range)
        return true
    }

    /// The completion list's "Emmet Abbreviation" item for the cursor, and what it replaces.
    func emmetCompletion(id: Int) -> (item: CompletionItem, range: NSRange)? {
        guard let expansion = emmetExpansion() else { return nil }
        var item = CompletionItem(id: id, label: expansion.abbreviation, detail: "Emmet Abbreviation", kind: CompletionController.snippetKind,
                                  insertText: expansion.body, isSnippet: true)
        item.documentation = ParsedSnippet(expansion.body).text
        return (item, expansion.range)
    }
}

extension Workspace {
    private var emmetEditor: EditorController? { activeDocument?.editor }

    /// Emmet: Expand Abbreviation — whatever is before the cursor, in any file (as HTML where
    /// the language has no Emmet syntax).
    func emmetExpandAbbreviation() {
        guard let editor = emmetEditor else { return }
        guard let expansion = editor.emmetExpansion(confident: false) else {
            errorMessage = "There's no Emmet abbreviation before the cursor."
            return
        }
        editor.insertSnippet(expansion.body, replacing: expansion.range)
        editor.focus()
    }

    /// Emmet: Wrap with Abbreviation… — the selection (or the element or line at the cursor)
    /// goes in the abbreviation's deepest element; `li*` makes one per line.
    func emmetWrapWithAbbreviation() async {
        guard let document = activeDocument, let editor = document.editor else { return }
        let text = document.textStorage.mutableString
        var range = editor.textView.selectedRange()
        if range.length == 0 {
            let pairs = Emmet.tagPairs(in: text)
            if let pair = pairs.filter({ $0.outer.location <= range.location && range.location <= NSMaxRange($0.outer) })
                .min(by: { $0.outer.length < $1.outer.length }) {
                range = pair.outer
            } else {
                range = text.lineRange(for: range)
            }
        }
        // Not the line breaks or indentation around it: the wrapper takes the first line's place.
        while range.length > 0, let scalar = Unicode.Scalar(text.character(at: NSMaxRange(range) - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            range.length -= 1
        }
        while range.length > 0, let scalar = Unicode.Scalar(text.character(at: range.location)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            range.location += 1
            range.length -= 1
        }
        guard range.length > 0 else { return }
        let lineStart = text.lineRange(for: NSRange(location: range.location, length: 0)).location
        let firstIndent = text.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        let lines = Emmet.dedent(text.substring(with: range), firstLineIndent: firstIndent)
        guard let abbreviation = await showInputBox(prompt: "Abbreviation to wrap with (li* wraps each line)", value: "",
                                                    placeholder: "div.wrapper"),
              !abbreviation.trimmingCharacters(in: .whitespaces).isEmpty,
              document.editor === editor, document.textStorage.length >= NSMaxRange(range) else { return }
        var syntax = editor.emmetSyntax ?? .html
        if syntax == .css { syntax = .html }
        guard let body = Emmet.expandMarkup(abbreviation.trimmingCharacters(in: .whitespaces), syntax: syntax, wrapping: lines) else {
            errorMessage = "“\(abbreviation)” isn't an Emmet abbreviation."
            return
        }
        editor.insertSnippet(body, replacing: range)
        editor.focus()
    }

    /// Emmet: Balance Outward / Inward — selects the element around the selection (its
    /// content first), or inside it.
    func emmetBalance(outward: Bool) {
        guard let editor = emmetEditor else { return }
        let pairs = Emmet.tagPairs(in: editor.document.textStorage.mutableString)
        let selection = editor.textView.selectedRange()
        let target = outward || selection.length == 0
            ? Emmet.balanceOutward(selection, in: pairs) : Emmet.balanceInward(selection, in: pairs)
        guard let target else { return }
        editor.textView.setSelectedRange(target)
        editor.textView.scrollRangeToVisible(target)
    }

    /// Emmet: Remove Tag — the element around the cursor goes, its content stays.
    func emmetRemoveTag() {
        guard let editor = emmetEditor, let document = activeDocument,
              let edits = Emmet.removeTagEdits(at: editor.textView.selectedRange().location, in: document.textStorage.mutableString,
                                               indentUnit: editor.indentUnit) else { return }
        _ = try? document.apply(edits, actionName: "Remove Tag")
    }
}

extension Emmet {
    /// Lines of wrapped text without their shared indentation (the first line's is
    /// `firstLineIndent`, from before the selection).
    static func dedent(_ text: String, firstLineIndent: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.count > 1 else { return lines }
        lines[0] = firstLineIndent + lines[0]
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let shared = indents.min() ?? 0
        return lines.map { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(line.dropFirst(min(shared, line.prefix { $0 == " " || $0 == "\t" }.count)))
        }
    }
}
