import AppKit

/// A token the language server classified: where it is and what it is (`type`, `function`, …).
struct SemanticToken: Equatable {
    var range: NSRange
    var type: String
}

enum SemanticTokens {
    /// The standard token types we ask for.
    static let knownTypes = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable",
        "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment",
        "string", "number", "regexp", "operator", "decorator",
    ]

    /// The capture (for the theme's colors) a token type is drawn as; nil leaves the syntax
    /// tree's color (keywords, strings and comments it already gets right). Variables and
    /// parameters get the plain text color, undoing a guess that took them for something else.
    static func capture(for type: String) -> String? {
        switch type {
        case "namespace", "type", "class", "enum", "interface", "struct", "typeParameter": "type"
        case "function", "method", "macro": "function"
        case "property", "enumMember", "event": "property"
        case "decorator": "attribute"
        case "parameter", "variable": ""
        default: nil
        }
    }

    /// The numbers in a `semanticTokens` answer's `data`. Read from the `NSArray` as it is:
    /// casting it to `[Any]` first boxes every number (half a million in a long file).
    static func numbers(_ data: Any?) -> [Int] {
        guard let array = data as? NSArray else { return [] }
        var numbers: [Int] = []
        numbers.reserveCapacity(array.count)
        for element in array {
            if let number = element as? NSNumber { numbers.append(number.intValue) }
        }
        return numbers
    }

    /// The server's numbers (line delta, start delta, length, type, modifiers) as tokens.
    @MainActor
    static func decode(_ data: [Int], legend: [String], in document: EditorDocument) -> [SemanticToken] {
        var tokens: [SemanticToken] = []
        tokens.reserveCapacity(data.count / 5)
        var line = 0, character = 0
        var index = 0
        while index + 4 < data.count {
            let deltaLine = data[index], deltaStart = data[index + 1], length = data[index + 2], type = data[index + 3]
            index += 5
            line += deltaLine
            character = deltaLine == 0 ? character + deltaStart : deltaStart
            guard type >= 0, type < legend.count, length > 0, line < document.lineIndex.lineCount else { continue }
            let start = document.offset(for: LSPPosition(line: line, character: character))
            let range = NSRange(location: start, length: min(length, document.textStorage.length - start))
            if range.length > 0 { tokens.append(SemanticToken(range: range, type: legend[type])) }
        }
        return tokens
    }
}

extension EditorDocument {
    /// Asks the language server for the file's tokens again (after `delay`, restarted by every call).
    func refreshSemanticTokens(after delay: Duration = .zero) {
        semanticTokensTask?.cancel()
        semanticTokensTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            guard self.projectSettings.semanticHighlighting ?? AppSettings.shared.semanticHighlighting, let client = self.languageClient, client.state == .ready,
                  client.supports(.semanticTokens), self.lineIndex.lineCount <= Self.semanticTokenLineLimit else {
                self.setSemanticTokens([])
                return
            }
            let version = self.editVersion
            guard let data = try? await client.semanticTokens(url: self.url) else { return }
            // An edit since: the tokens it shifted stay until its own refresh.
            guard !Task.isCancelled, version == self.editVersion else { return }
            self.setSemanticTokens(SemanticTokens.decode(data, legend: client.semanticTokenTypes, in: self))
        }
    }

    /// Big files: the syntax tree's colors only.
    static let semanticTokenLineLimit = 20_000

    func waitForSemanticTokens() async { await semanticTokensTask?.value }

    func setSemanticTokens(_ tokens: [SemanticToken]) {
        guard tokens != semanticTokens else { return }
        semanticTokens = tokens
        editors.forEach { $0.refreshHighlights(force: true) }
    }

    /// An edit replaced `oldRange` with `newLength` characters: tokens after it move, tokens it
    /// touched go (until the server's next answer).
    func shiftSemanticTokens(oldRange: NSRange, newLength: Int) {
        guard !semanticTokens.isEmpty else { return }
        let delta = newLength - oldRange.length
        let end = NSMaxRange(oldRange)
        // In place, from the first token the edit reaches (they're sorted by position, as
        // `semanticTokens(in:)` relies on): this runs on every keystroke, and making the array
        // again took 6 ms with 150,000 tokens.
        var first = 0, high = semanticTokens.count
        while first < high {
            let middle = (first + high) / 2
            if NSMaxRange(semanticTokens[middle].range) <= oldRange.location { first = middle + 1 } else { high = middle }
        }
        // Typing inside a token or right before it: it's no longer known. The ones after move.
        var firstMoved = first
        while firstMoved < semanticTokens.count {
            let location = semanticTokens[firstMoved].range.location
            if location >= end, oldRange.length > 0 || location > oldRange.location { break }
            firstMoved += 1
        }
        if firstMoved > first { semanticTokens.removeSubrange(first..<firstMoved) }
        guard delta != 0, first < semanticTokens.count else { return }
        semanticTokens.withUnsafeMutableBufferPointer { tokens in
            for index in first..<tokens.count { tokens[index].range.location += delta }
        }
    }

    /// The tokens overlapping `range` (sorted by position: binary search for the first).
    func semanticTokens(in range: NSRange) -> [SemanticToken] {
        var low = 0, high = semanticTokens.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(semanticTokens[middle].range) <= range.location { low = middle + 1 } else { high = middle }
        }
        var result: [SemanticToken] = []
        var index = low
        while index < semanticTokens.count, semanticTokens[index].range.location < NSMaxRange(range) {
            result.append(semanticTokens[index])
            index += 1
        }
        return result
    }
}

extension EditorController {
    /// The server's classification over the syntax tree's colors, in the highlighted range:
    /// `paint(range, color)` sets the color of the characters `range` (inside `range`).
    func semanticColors(in range: NSRange, paint: (NSRange, NSColor) -> Void) {
        guard document.projectSettings.semanticHighlighting ?? AppSettings.shared.semanticHighlighting,
              !document.semanticTokens.isEmpty else { return }
        let foreground = EditorTheme.current.foreground
        for token in document.semanticTokens(in: range) {
            guard let capture = SemanticTokens.capture(for: token.type) else { continue }
            let color = capture.isEmpty ? foreground : EditorTheme.color(forCapture: capture)
            let clipped = NSIntersectionRange(token.range, range)
            guard let color, clipped.length > 0 else { continue }
            paint(clipped, color)
        }
    }

    /// The color drawn at a character (tests).
    func renderedColor(at index: Int) -> NSColor? {
        guard let layoutManager = textView.textLayoutManager, let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(contentManager.documentRange.location, offsetBy: index) else { return nil }
        var color: NSColor?
        layoutManager.enumerateRenderingAttributes(from: location, reverse: false) { _, attributes, _ in
            color = attributes[.foregroundColor] as? NSColor
            return false
        }
        return color
    }
}
