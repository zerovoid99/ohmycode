import AppKit

/// Find All References results, grouped by file like Find in Files.
struct ReferenceList {
    let symbol: String
    let results: [SearchFileResult]
    /// What the list holds: "reference", "implementation", "type definition".
    var noun = "reference"
    var count: Int { results.reduce(0) { $0 + $1.matches.count } }
}

/// Language server actions that span files: references, rename, formatting.
extension Workspace {
    /// The document and cursor for `feature`, when its server or an extension has it.
    private func languageTarget(_ target: EditorDocument?, _ feature: LanguageClient.Feature, _ kind: ExtensionHost.ProviderKind)
        -> (EditorDocument, Int)? {
        guard let document = target ?? activeDocument, document.canUse(feature, kind),
              let selection = document.editor?.textView.selectedRange() ?? document.viewState?.selection else {
            NSSound.beep()
            return nil
        }
        return (document, selection.location)
    }

    /// Shows hover info for the symbol at the cursor (from the keyboard or palette).
    func showHover() {
        guard let editor = activeDocument?.editor else { return }
        let location = editor.textView.selectedRange().location
        Task { await editor.hover.show(at: location) }
    }

    // MARK: Implementations, type definitions

    /// ⌘F12: where the symbol at the cursor is implemented (a protocol's conformances, an
    /// interface's classes, an overridden method's overrides). One opens; several are listed.
    @discardableResult
    func goToImplementation(in target: EditorDocument? = nil) -> Task<Void, Never>? {
        goToLocations("textDocument/implementation", .implementation, .implementation, noun: "implementation", in: target)
    }

    /// The type of the symbol at the cursor (a variable's struct, a parameter's class).
    @discardableResult
    func goToTypeDefinition(in target: EditorDocument? = nil) -> Task<Void, Never>? {
        goToLocations("textDocument/typeDefinition", .typeDefinition, .typeDefinition, noun: "type definition", in: target)
    }

    private func goToLocations(_ method: String, _ feature: LanguageClient.Feature, _ kind: ExtensionHost.ProviderKind, noun: String,
                               in target: EditorDocument?) -> Task<Void, Never>? {
        guard let (document, location) = languageTarget(target, feature, kind) else { return nil }
        let symbol = document.wordRange(at: location).map { document.textStorage.mutableString.substring(with: $0) } ?? ""
        return Task {
            let locations = await locations(method, kind, in: document, at: location)
            if locations.isEmpty { NSSound.beep(); return }
            if locations.count == 1 {
                open(fileAt: workspaceURL(for: locations[0].url))
                if let target = activeDocument { target.reveal(target.range(for: locations[0].range)) }
                return
            }
            references = ReferenceList(symbol: symbol, results: referenceResults(locations), noun: noun)
            sidebarMode = .references
        }
    }

    // MARK: References

    /// ⇧F12: lists every use of the symbol at the cursor in the sidebar.
    @discardableResult
    func findReferences(in target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let (document, location) = languageTarget(target, .references, .references) else { return nil }
        let symbol = document.wordRange(at: location).map { document.textStorage.mutableString.substring(with: $0) } ?? ""
        return Task {
            do {
                let locations = try await references(in: document, at: location)
                guard !locations.isEmpty else { NSSound.beep(); return }
                references = ReferenceList(symbol: symbol, results: referenceResults(locations))
                sidebarMode = .references
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func referenceResults(_ locations: [LSPLocation]) -> [SearchFileResult] {
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
        guard let (document, location) = languageTarget(target, .rename, .rename) else { return nil }
        // An extension's rename for the language comes first (installing one is a choice), else the server's.
        let fromExtension = extensions.hasProviders(.rename, for: document)
        let client = document.readyLanguageClient
        let position = document.lspPosition(at: location)
        let version = document.editVersion
        return Task {
            do {
                let current: String
                let prepared: LanguageClient.PrepareRename
                if fromExtension {
                    prepared = await extensions.prepareRename(for: document, at: location) ?? .invalid
                } else if let client {
                    prepared = try await client.prepareRename(url: document.url, position: position)
                } else {
                    return
                }
                switch prepared {
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
                let edit = fromExtension ? await extensions.rename(in: document, at: location, to: newName)
                    : try await client?.rename(url: document.url, position: position, newName: newName)
                guard let edit, edit.editCount > 0 else { NSSound.beep(); return }
                guard document.editVersion == version else {
                    errorMessage = "\(document.fileName) changed while renaming. Try again."
                    return
                }
                review(try preview(edit, title: "Rename “\(current)” to “\(newName)”", actionName: "Rename"))
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

    /// A reviewable preview of a language server's workspace edit. Edits that don't fit their
    /// file (out of range, overlapping) fail here, before anything is changed.
    func preview(_ edit: WorkspaceEdit, title: String, actionName: String) throws -> EditPreview {
        // Servers may name one file by several URIs (e.g. through /var and /private/var):
        // merge by the symlink-resolved path, dropping edits sent twice.
        var byPath: [String: (url: URL, edits: [LSPTextEdit])] = [:]
        for (serverURL, edits) in edit.changes where !edits.isEmpty {
            let url = workspaceURL(for: serverURL)
            let key = FileWatcher.canonicalPath(url)
            var entry = byPath[key] ?? (url, [])
            for edit in edits where !entry.edits.contains(edit) { entry.edits.append(edit) }
            byPath[key] = entry
        }
        var files: [EditPreview.FileEdit] = []
        for (url, edits) in byPath.values {
            guard let text = currentText(of: url) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
            let index = document(matching: url)?.lineIndex ?? LineIndex(string: text as NSString)
            let length = (text as NSString).length
            let replacements = edits.map { TextReplacement(range: index.range(for: $0.range, length: length), text: $0.newText) }
            files.append(EditPreview.FileEdit(url: url, path: relativePath(of: url) ?? url.path,
                                              edits: try TextReplacement.validated(replacements, length: length),
                                              baseText: text))
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return EditPreview(title: title, actionName: actionName, files: files)
    }

    // MARK: Formatting

    /// ⇧⌥F: formats the document with the language server, as one undoable step.
    @discardableResult
    func formatDocument(_ target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let document = target ?? activeDocument, canFormat(document) else {
            NSSound.beep()
            return nil
        }
        return Task {
            do {
                try await format(document)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func canFormat(_ document: EditorDocument) -> Bool {
        if extensions.hasProviders(.formatting, for: document) { return true }
        guard let client = document.languageClient else { return false }
        return client.state == .ready && client.supports(.formatting)
    }

    /// Asks the server for formatting edits and applies them (one undo step). Edits that arrive
    /// after the user typed are stale and dropped. Returns whether the text changed.
    @discardableResult
    func format(_ document: EditorDocument) async throws -> Bool {
        let version = document.editVersion
        let edits: [TextReplacement]
        // An extension's formatter for the language comes first: installing one is a choice.
        if extensions.hasProviders(.formatting, for: document), let fromExtension = await extensions.formattingEdits(for: document) {
            edits = fromExtension
        } else if let client = document.languageClient, client.state == .ready, client.supports(.formatting) {
            let (tabSize, insertSpaces) = document.indentation
            let config = document.editorConfig
            edits = try await client.formatting(url: document.url, tabSize: tabSize, insertSpaces: insertSpaces,
                                                trimTrailingWhitespace: config.trimTrailingWhitespace ?? true,
                                                insertFinalNewline: config.insertFinalNewline ?? true)
                .map { TextReplacement(range: document.range(for: $0.range), text: $0.newText) }
        } else {
            return false
        }
        // Stale (typed meanwhile) or given up on (format on save timed out and saved already).
        guard document.editVersion == version, !Task.isCancelled else { return false }
        return try document.apply(edits, actionName: "Format Document")
    }

    /// ⌘S with format on save: formats (if the setting is on and a server can), then saves. A slow
    /// or failing formatter never blocks the save: after the timeout the text is saved as is.
    @discardableResult
    func formatAndSave(_ document: EditorDocument) -> Task<Bool, Never> {
        Task {
            if formatsOnSave, canFormat(document) {
                // Whichever comes first: the formatted text, or the timeout. (Cancelling doesn't
                // interrupt the wait for the server's reply, so race them explicitly.)
                let formatting = Task { try? await formatForSave(document) }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let once = ResumeOnce(continuation)
                    Task { await formatting.value; once.resume() }
                    Task {
                        try? await Task.sleep(for: formatOnSaveTimeout)
                        formatting.cancel() // late edits are then dropped (see `format`)
                        once.resume()
                    }
                }
            }
            return save(document)
        }
    }
}

/// Resumes a continuation once, whichever caller comes first.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

extension LSPPosition {
    struct Key: Hashable { let line: Int, character: Int }
    var key: Key { Key(line: line, character: character) }
}
