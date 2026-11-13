import AppKit

/// Find All References results, grouped by file like Find in Files.
struct ReferenceList {
    let symbol: String
    let results: [SearchFileResult]
    var count: Int { results.reduce(0) { $0 + $1.matches.count } }
}

/// Language server actions that span files: references, rename, formatting.
extension Workspace {
    private func languageTarget(_ target: EditorDocument?, _ feature: LanguageClient.Feature)
        -> (EditorDocument, LanguageClient, Int)? {
        guard let document = target ?? activeDocument, let client = document.languageClient,
              client.state == .ready, client.supports(feature),
              let selection = document.editor?.textView.selectedRange() ?? document.viewState?.selection else {
            NSSound.beep()
            return nil
        }
        return (document, client, selection.location)
    }

    /// Shows hover info for the symbol at the cursor (from the keyboard or palette).
    func showHover() {
        guard let editor = activeDocument?.editor else { return }
        let location = editor.textView.selectedRange().location
        Task { await editor.hover.show(at: location) }
    }

    // MARK: References

    /// ⇧F12: lists every use of the symbol at the cursor in the sidebar.
    @discardableResult
    func findReferences(in target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let (document, client, location) = languageTarget(target, .references) else { return nil }
        let symbol = document.wordRange(at: location).map { document.textStorage.mutableString.substring(with: $0) } ?? ""
        return Task {
            do {
                let locations = try await client.references(url: document.url, position: document.lspPosition(at: location))
                guard !locations.isEmpty else { NSSound.beep(); return }
                references = ReferenceList(symbol: symbol, results: referenceResults(locations))
                sidebarMode = .references
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func referenceResults(_ locations: [LSPLocation]) -> [SearchFileResult] {
        var byURL: [URL: [LSPRange]] = [:]
        for location in locations { byURL[workspaceURL(for: location.url), default: []].append(location.range) }
        return byURL.compactMap { url, ranges -> SearchFileResult? in
            let text: NSString
            let index: LineIndex
            if let document = document(matching: url) {
                text = document.textStorage.mutableString
                index = document.lineIndex
            } else if let contents = try? String(contentsOf: url, encoding: .utf8) {
                text = contents as NSString
                index = LineIndex(string: text)
            } else {
                return nil
            }
            var seen = Set<LSPPosition.Key>()
            let matches = ranges.sorted { ($0.start.line, $0.start.character) < ($1.start.line, $1.start.character) }
                .filter { seen.insert($0.start.key).inserted }
                .map { range -> SearchMatch in
                    let line = index.lineText(range.start.line, in: text)
                    let lineLength = (line as NSString).length
                    let column = min(range.start.character, lineLength)
                    let end = range.end.line == range.start.line ? min(range.end.character, lineLength) : lineLength
                    return TextSearch.makeMatch(line: range.start.line, column: column, length: max(0, end - column),
                                                lineText: line)
                }
            return SearchFileResult(path: relativePath(of: url) ?? url.path, url: url, matches: matches)
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Opens a search or reference result and selects it.
    func open(_ result: SearchFileResult, _ match: SearchMatch) {
        open(fileAt: result.url)
        guard let document = activeDocument else { return }
        let start = document.offset(for: LSPPosition(line: match.line, character: match.column))
        document.reveal(NSRange(location: start, length: match.length))
    }

    // MARK: Rename

    /// F2: renames the symbol at the cursor across the workspace.
    @discardableResult
    func renameSymbol(in target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let (document, client, location) = languageTarget(target, .rename) else { return nil }
        let position = document.lspPosition(at: location)
        let version = document.editVersion
        return Task {
            do {
                let current: String
                switch try await client.prepareRename(url: document.url, position: position) {
                case .invalid:
                    NSSound.beep()
                    return
                case .defaultBehavior:
                    guard let range = document.wordRange(at: location) else { NSSound.beep(); return }
                    current = document.textStorage.mutableString.substring(with: range)
                case .range(let range, let placeholder):
                    current = placeholder ?? document.textStorage.mutableString.substring(with: document.range(for: range))
                }
                guard document.editVersion == version,
                      let newName = promptForNewName(current), !newName.isEmpty, newName != current else { return }
                guard let edit = try await client.rename(url: document.url, position: position, newName: newName),
                      edit.editCount > 0 else { NSSound.beep(); return }
                guard document.editVersion == version else {
                    errorMessage = "\(document.fileName) changed while renaming. Try again."
                    return
                }
                try apply(edit, actionName: "Rename")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func promptForNewName(_ current: String) -> String? {
        if let renamePrompt { return renamePrompt(current) }
        let alert = NSAlert()
        alert.messageText = "Rename Symbol"
        alert.informativeText = "Rename “\(current)” to:"
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies a workspace edit: open documents are edited in memory (one undo step each,
    /// left unsaved); other files are rewritten on disk. Everything is validated first, so a
    /// bad edit changes nothing. Returns the number of files changed.
    @discardableResult
    func apply(_ edit: WorkspaceEdit, actionName: String) throws -> Int {
        var openEdits: [(EditorDocument, [TextReplacement])] = []
        var diskEdits: [(URL, String)] = []
        for (serverURL, edits) in edit.changes where !edits.isEmpty {
            let url = workspaceURL(for: serverURL)
            if let document = document(matching: url) {
                let replacements = edits.map { TextReplacement(range: document.range(for: $0.range), text: $0.newText) }
                _ = try TextReplacement.validated(replacements, length: document.textStorage.length)
                openEdits.append((document, replacements))
            } else {
                let text = try String(contentsOf: url, encoding: .utf8)
                let index = LineIndex(string: text as NSString)
                let length = (text as NSString).length
                let replacements = edits.map { TextReplacement(range: index.range(for: $0.range, length: length), text: $0.newText) }
                let updated = try TextReplacement.apply(replacements, to: text)
                if updated != text { diskEdits.append((url, updated)) }
            }
        }
        var changed = 0
        for (document, replacements) in openEdits where try document.apply(replacements, actionName: actionName) {
            changed += 1
        }
        for (url, text) in diskEdits {
            try Self.write(text, to: url)
            changed += 1
        }
        return changed
    }

    /// Atomic write that keeps the file's permissions (e.g. executable scripts).
    nonisolated static func write(_ text: String, to url: URL) throws {
        let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    // MARK: Formatting

    /// ⇧⌥F: formats the document with the language server, as one undoable step.
    @discardableResult
    func formatDocument(_ target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let document = target ?? activeDocument, let client = document.languageClient,
              client.state == .ready, client.supports(.formatting) else {
            NSSound.beep()
            return nil
        }
        let version = document.editVersion
        let (tabSize, insertSpaces) = document.indentation
        return Task {
            do {
                let edits = try await client.formatting(url: document.url, tabSize: tabSize, insertSpaces: insertSpaces)
                guard document.editVersion == version else { return } // typed meanwhile: stale edits
                try document.apply(edits.map { TextReplacement(range: document.range(for: $0.range), text: $0.newText) },
                                   actionName: "Format Document")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension LSPPosition {
    struct Key: Hashable { let line: Int, character: Int }
    var key: Key { Key(line: line, character: character) }
}
