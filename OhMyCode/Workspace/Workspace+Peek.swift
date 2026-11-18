import AppKit

/// What a peek shows: the places a language request (definition, references…) found for the
/// symbol at the cursor, in a panel inside the editor (see PeekView.swift).
enum PeekKind: String, CaseIterable {
    case definition, references, implementation, typeDefinition

    var title: String {
        switch self {
        case .definition: "Peek Definition"
        case .references: "Peek References"
        case .implementation: "Peek Implementations"
        case .typeDefinition: "Peek Type Definition"
        }
    }

    /// The command's id (palette, keybindings).
    var commandID: String {
        switch self {
        case .definition: "go.peekDefinition"
        case .references: "go.peekReferences"
        case .implementation: "go.peekImplementation"
        case .typeDefinition: "go.peekTypeDefinition"
        }
    }

    /// What one result is called ("No reference found for…", "3 references").
    var noun: String {
        switch self {
        case .definition: "definition"
        case .references: "reference"
        case .implementation: "implementation"
        case .typeDefinition: "type definition"
        }
    }

    /// The request (references have their own, with a context).
    var method: String {
        switch self {
        case .definition: "textDocument/definition"
        case .references: "textDocument/references"
        case .implementation: "textDocument/implementation"
        case .typeDefinition: "textDocument/typeDefinition"
        }
    }

    var providerKind: ExtensionHost.ProviderKind {
        switch self {
        case .definition: .definition
        case .references: .references
        case .implementation: .implementation
        case .typeDefinition: .typeDefinition
        }
    }

    /// The server capability it needs (definitions every server has).
    var feature: LanguageClient.Feature? {
        switch self {
        case .definition: nil
        case .references: .references
        case .implementation: .implementation
        case .typeDefinition: .typeDefinition
        }
    }

    var editorCommand: EditorCommand {
        switch self {
        case .definition: .peekDefinition
        case .references: .peekReferences
        case .implementation: .peekImplementation
        case .typeDefinition: .peekTypeDefinition
        }
    }
}

/// One place in a peek's list.
struct PeekEntry: Equatable {
    /// Its file, as the workspace names it, and its path relative to the folder.
    let url: URL
    let path: String
    let match: SearchMatch

    var position: LSPPosition { LSPPosition(line: match.line, character: match.column) }
    var range: LSPRange { LSPRange(start: position, end: LSPPosition(line: match.line, character: match.column + match.length)) }
}

/// What a peek shows and which place is selected. The places come grouped by file (files by
/// path, each one's places by position, as Find All References lists them).
struct PeekModel {
    let kind: PeekKind
    let symbol: String
    let files: [SearchFileResult]
    /// Every place, in list order.
    let entries: [PeekEntry]
    private(set) var selection: Int

    /// `origin`: the file and position the peek was asked from.
    init(kind: PeekKind, symbol: String, files: [SearchFileResult], origin: (url: URL, position: LSPPosition)? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.files = files
        entries = files.flatMap { file in file.matches.map { PeekEntry(url: file.url, path: file.path, match: $0) } }
        selection = Self.initialSelection(entries, kind: kind, origin: origin)
    }

    var selected: PeekEntry? { entries.indices.contains(selection) ? entries[selection] : nil }

    /// More than one place: the list is shown beside the editor.
    var showsList: Bool { entries.count > 1 }

    /// "3 references", "1 definition".
    var countText: String {
        "\(entries.count) \(kind.noun)\(entries.count == 1 ? "" : "s")"
    }

    mutating func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selection = index
    }

    /// The next (or previous) place, wrapping around.
    mutating func move(by offset: Int) {
        guard !entries.isEmpty else { return }
        selection = ((selection + offset) % entries.count + entries.count) % entries.count
    }

    /// The place shown first. References: the one at the cursor (or the next one after it in
    /// that file), so the list starts where the user is; the others: the first.
    static func initialSelection(_ entries: [PeekEntry], kind: PeekKind, origin: (url: URL, position: LSPPosition)?) -> Int {
        guard kind == .references, let origin else { return 0 }
        let path = FileWatcher.canonicalPath(origin.url)
        let inFile = entries.indices.filter { FileWatcher.canonicalPath(entries[$0].url) == path }
        guard let last = inFile.last else { return 0 }
        let key = { (position: LSPPosition) in (position.line, position.character) }
        if let containing = inFile.first(where: { entries[$0].match.line == origin.position.line
            && entries[$0].match.column <= origin.position.character
            && origin.position.character <= entries[$0].match.column + entries[$0].match.length }) {
            return containing
        }
        return inFile.first { key(entries[$0].position) >= key(origin.position) } ?? last
    }

    // MARK: Closing rules

    /// Whether an edit of the editor the peek is in closes it: one made in that editor (typing,
    /// undo there) at or above the end of the line the peek hangs from. Edits from elsewhere
    /// (the peek's own editor on the same file, another split) only move it with its line.
    static func editCloses(editLocation: Int, anchorLineEnd: Int, fromHostEditor: Bool) -> Bool {
        fromHostEditor && editLocation <= anchorLineEnd
    }

    /// Where `offset` is after `oldLength` characters at `editLocation` became `newLength`.
    /// Inside the replaced text it goes to the edit's start.
    static func shifted(_ offset: Int, editLocation: Int, oldLength: Int, newLength: Int) -> Int {
        if offset < editLocation { return offset }
        if offset >= editLocation + oldLength { return offset + newLength - oldLength }
        return editLocation
    }
}

extension Workspace {
    /// ⌥F12, ⌥⇧F12…: shows the places `kind` finds for the symbol at the cursor in a panel
    /// below its line. Nothing found: a short note there instead.
    @discardableResult
    func peek(_ kind: PeekKind, in target: EditorDocument? = nil) -> Task<Void, Never>? {
        guard let document = target ?? activeDocument, let editor = document.editor, editor.textView != nil else { return nil }
        let available = kind == .definition
            ? document.languageClient != nil || extensions.hasProviders(.definition, for: document)
            : document.canUse(kind.feature ?? .references, kind.providerKind)
        guard available else { NSSound.beep(); return nil }
        let location = editor.textView.selectedRange().location
        let symbol = document.wordRange(at: location).map { document.textStorage.mutableString.substring(with: $0) } ?? ""
        let origin = (url: workspaceURL(for: document.url), position: document.lspPosition(at: location))
        return Task {
            let found: [LSPLocation]
            if kind == .references {
                found = (try? await references(in: document, at: location)) ?? []
            } else {
                found = await locations(kind.method, kind.providerKind, in: document, at: location)
            }
            let model = PeekModel(kind: kind, symbol: symbol, files: referenceResults(found), origin: origin)
            showPeek(model, from: editor, at: location)
        }
    }

    /// Shows `model` in `editor` below the line of `location` (inside a peek: in that peek).
    func showPeek(_ model: PeekModel, from editor: EditorController, at location: Int) {
        guard editor.textView != nil else { return }
        if model.entries.isEmpty {
            let what = model.symbol.isEmpty ? "" : " for ‘\(model.symbol)’"
            editor.showInlineMessage("No \(model.kind.noun) found\(what)", at: location)
            NSSound.beep()
            return
        }
        if let peek = editor.peekHost {
            peek.show(model)
        } else {
            editor.peek?.close(refocus: false)
            let peek = PeekController(host: editor, model: model, anchor: location, workspace: self)
            editor.peek = peek
            peek.open()
        }
    }

    /// The document a peek shows for `url`: the open one (edits in the peek are its edits), or
    /// one read for the peek alone (`owned`; see `releasePeekDocument`).
    func peekDocument(for url: URL) -> (document: EditorDocument, owned: Bool)? {
        if let open = document(matching: url) { return (open, false) }
        return openWithoutTab(url).map { ($0, true) }
    }

    /// A document read for a peek, which closed: changed, it gets a tab (in the background) so
    /// the change can be saved; else it goes, unless it got a tab or a diff meanwhile.
    func releasePeekDocument(_ document: EditorDocument, group: EditorGroup?) {
        guard documents.contains(where: { $0 === document }),
              !groups.contains(where: { $0.contains(document.id) }),
              !diffSessions.contains(where: { $0.document === document }) else { return }
        if document.isDirty {
            let group = group ?? activeGroup
            group.insert(document.id, at: group.documentIDs.count)
        } else {
            closeUntabbedDocument(document)
        }
    }

    /// Opens a peek's place in a tab (in the active group) and selects `range` there.
    func openPeekLocation(_ url: URL, range: NSRange) {
        open(fileAt: url)
        guard let document = activeDocument, FileWatcher.canonicalPath(document.url) == FileWatcher.canonicalPath(url) else { return }
        document.reveal(range)
    }
}
