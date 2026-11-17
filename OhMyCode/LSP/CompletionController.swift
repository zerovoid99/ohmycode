import AppKit
import SwiftUI

@MainActor
@Observable
final class CompletionModel {
    struct Row: Identifiable {
        let item: CompletionItem
        let matches: [Int]
        var id: Int { item.id }
    }

    var rows: [Row] = []
    var selection = 0
}

/// Code completion for one editor: asks the language server as you type, filters results
/// locally while you keep typing (fuzzy, like quick open), and inserts the chosen item.
@MainActor
final class CompletionController {
    private unowned let editor: EditorController
    private let model = CompletionModel()
    private var panel: NSPanel?
    private var items: [CompletionItem] = []
    /// The items' filter texts, prepared for matching once per answer (not once per keystroke).
    private var candidates: [FuzzyCandidate] = []
    private var isIncomplete = false
    /// Where the word being completed starts (UTF-16 offset).
    private var wordStart = 0
    /// Where the cursor was when the listed items were asked for: servers' edit ranges are in
    /// the text as it was then, and typing since moved their ends.
    private var itemsCursor = 0
    private var requestTask: Task<Void, Never>?
    private var isInserting = false
    private var windowObserver: NSObjectProtocol?

    static let maxVisibleRows = 10
    static let rowHeight: CGFloat = 22

    init(editor: EditorController) {
        self.editor = editor
    }

    var isVisible: Bool { panel?.isVisible == true }
    var visibleItems: [CompletionItem] { model.rows.map(\.item) }

    // MARK: Triggering

    /// Called after each text change with what was typed (nil for deletions/programmatic edits).
    /// The language server, when it's ready.
    private var client: LanguageClient? {
        editor.document.languageClient.flatMap { $0.state == .ready ? $0 : nil }
    }

    /// Whether anything can complete here: the language server or an extension.
    private var canComplete: Bool {
        client != nil || editor.document.extensionHost?.hasProviders(.completion, for: editor.document) == true
            || !snippets.isEmpty
    }

    /// The language's snippets (offered while typing a word).
    private var snippets: [SnippetDefinition] {
        SnippetLibrary.shared.snippets(for: editor.document.languageId, root: editor.document.workspaceRoot)
    }

    static let snippetKind = 15

    private func snippetItems(firstID: Int) -> [CompletionItem] {
        var items: [CompletionItem] = []
        for snippet in snippets {
            for prefix in snippet.prefixes {
                items.append(CompletionItem(id: firstID + items.count, label: prefix, detail: snippet.description ?? snippet.name,
                                            kind: Self.snippetKind, sortText: "~" + prefix, insertText: snippet.body, isSnippet: true))
            }
        }
        return items
    }

    private var triggerCharacters: Set<String> {
        Set(client?.triggerCharacters ?? []).union(editor.document.extensionHost?.completionTriggers(for: editor.document) ?? [])
    }

    func textDidChange(typed: String?) {
        guard !isInserting, canComplete else { return }
        let triggerCharacters = triggerCharacters
        let cursor = editor.textView.selectedRange().location
        if isVisible {
            if cursor < wordStart || (typed.map { !Self.isWordText($0) && !triggerCharacters.contains($0) } ?? false) {
                dismiss()
            } else if isIncomplete {
                request(trigger: nil)
            } else {
                filter()
            }
            if isVisible || typed == nil { return }
        }
        // A paste is "typed" too: counting a megabyte's characters took 0.8 ms per 100 kB.
        guard let typed, (typed as NSString).length <= 16, typed.count == 1 else { return }
        if triggerCharacters.contains(typed) {
            request(trigger: typed, delay: .zero)
        } else if Self.isWordText(typed) {
            request(trigger: nil, delay: .milliseconds(60))
        }
    }

    /// Manual trigger (Esc, as in other macOS text views).
    func triggerManually() {
        request(trigger: nil, delay: .zero)
    }

    private func request(trigger: String?, delay: Duration = .zero) {
        guard canComplete else { return }
        let client = self.client
        requestTask?.cancel()
        let document = editor.document
        // Weak: the editor (which owns this) may close while the request waits.
        requestTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            // Typed on already (each key asks again while the server's list is incomplete).
            guard !Task.isCancelled, let cursor = self?.beginRequest() else { return }
            let position = document.lspPosition(at: cursor)
            // The server's items and the extensions' together, asked at the same time.
            let server = Task { () -> (items: [CompletionItem], isIncomplete: Bool)? in
                guard let client else { return nil }
                return try? await client.completion(url: document.url, position: position, triggerCharacter: trigger)
            }
            // Typing on cancels this task: the server is told to stop too.
            let (fromExtensions, result) = await withTaskCancellationHandler {
                let fromExtensions = await document.extensionHost?.completions(for: document, at: cursor, trigger: trigger, firstID: 1_000_000)
                return (fromExtensions, await server.value)
            } onCancel: {
                server.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.finishRequest(server: result, extensions: fromExtensions, trigger: trigger, cursor: cursor)
        }
    }

    /// Where the word being completed starts; returns the cursor.
    private func beginRequest() -> Int {
        let cursor = editor.textView.selectedRange().location
        wordStart = Self.wordStart(in: editor.document.textStorage.mutableString, before: cursor)
        return cursor
    }

    private func finishRequest(server result: (items: [CompletionItem], isIncomplete: Bool)?,
                               extensions fromExtensions: (items: [CompletionItem], isIncomplete: Bool)?, trigger: String?,
                               cursor: Int) {
        // Snippets while typing a word (not after "." and other trigger characters).
        let snippets = trigger == nil ? snippetItems(firstID: 2_000_000) : []
        guard result != nil || fromExtensions?.items.isEmpty == false || !snippets.isEmpty else { return }
        items = (result?.items ?? []) + (fromExtensions?.items ?? []) + snippets
        itemsCursor = cursor
        candidates = items.map { FuzzyCandidate($0.filterText) }
        isIncomplete = result?.isIncomplete == true || fromExtensions?.isIncomplete == true
        filter()
    }

    // MARK: Filtering & display

    private func filter() {
        let text = editor.document.textStorage.mutableString
        let cursor = editor.textView.selectedRange().location
        guard cursor >= wordStart, cursor <= text.length else { return dismiss() }
        let prefix = text.substring(with: NSRange(location: wordStart, length: cursor - wordStart))
        model.rows = Self.rows(items: items, candidates: candidates, prefix: prefix)
        model.selection = 0
        // An exact match stays listed: its insert text may add more (e.g. call arguments).
        if model.rows.isEmpty { return dismiss() }
        show()
    }

    /// The best `limit` items for what's typed, best first (the server's order among equals).
    /// `candidates` are the items' filter texts. Sorts the matches' indices, not the items.
    static func rows(items: [CompletionItem], candidates: [FuzzyCandidate], prefix: String, limit: Int = 200) -> [CompletionModel.Row] {
        let query = FuzzyMatcher.prepareQuery(prefix)
        var matched: [(index: Int, match: FuzzyMatch)] = []
        if query.isEmpty {
            matched = items.indices.map { ($0, FuzzyMatch(score: 0, positions: [])) }
        } else {
            for index in items.indices {
                if let match = FuzzyMatcher.match(query, candidates[index]) { matched.append((index, match)) }
            }
        }
        matched.sort {
            if $0.match.score != $1.match.score { return $0.match.score > $1.match.score }
            let left = items[$0.index].sortText, right = items[$1.index].sortText
            return left != right ? left < right : $0.index < $1.index
        }
        return matched.prefix(limit).map { index, match in
            let item = items[index]
            // Highlight positions are for filterText; only show them when it is the label.
            return CompletionModel.Row(item: item, matches: item.filterText == item.label ? match.positions : [])
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let height = CGFloat(min(model.rows.count, Self.maxVisibleRows)) * Self.rowHeight + 8
        let width: CGFloat = 440
        // Under the start of the word, flipping above when there's no room below.
        var anchor = editor.textView.firstRect(forCharacterRange: NSRange(location: wordStart, length: 0), actualRange: nil)
        if anchor == .zero, let window = editor.textView.window {
            anchor = window.convertToScreen(editor.textView.convert(editor.textView.bounds, to: nil))
        }
        var origin = NSPoint(x: anchor.minX - 26, y: anchor.minY - height - 2)
        if let screen = editor.textView.window?.screen?.visibleFrame, origin.y < screen.minY {
            origin.y = anchor.maxY + 2
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if !panel.isVisible, let window = editor.textView.window {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            // Switching apps or windows closes the list.
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = NSHostingView(rootView: CompletionListView(model: model) { [weak self] index in
            self?.model.selection = index
            self?.accept()
        })
        return panel
    }

    func dismiss() {
        requestTask?.cancel()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    // MARK: Keyboard (while visible)

    /// Returns true if the completion list consumed the command.
    func handle(_ selector: Selector) -> Bool {
        guard isVisible else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(Self.maxVisibleRows)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-Self.maxVisibleRows)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): accept()
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)): dismiss()
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        guard !model.rows.isEmpty else { return }
        model.selection = min(max(model.selection + delta, 0), model.rows.count - 1)
    }

    // MARK: Insertion

    func accept() {
        guard model.rows.indices.contains(model.selection) else { return dismiss() }
        insert(model.rows[model.selection].item)
    }

    /// Replaces the word being completed (or the server's edit range) with the item, through
    /// the text view so it's a single undoable change; then makes its additional edits (asking
    /// the server for them first when it sends them only on request).
    func insert(_ item: CompletionItem) {
        let document = editor.document
        let textView = editor.textView!
        let text = document.textStorage.mutableString
        let cursor = textView.selectedRange().location
        var replacement = NSRange(location: wordStart, length: max(0, cursor - wordStart))
        if let editRange = item.editRange {
            replacement = Self.replacementRange(document.range(for: editRange), requestedAt: itemsCursor, cursor: cursor, length: text.length)
        }
        // In the text before the insertion, which moves those after it.
        let additional = item.additionalTextEdits.map { TextReplacement(range: document.range(for: $0.range), text: $0.newText) }
        let resolving = additional.isEmpty && item.raw != nil ? client : nil
        let lengthBefore = text.length
        dismiss()
        isInserting = true
        if item.isSnippet {
            // Tab then steps through its placeholders.
            editor.insertSnippet(item.insertText, replacing: replacement)
        } else {
            // Defensive: keep the insertion a separate undo step from coalesced typing.
            textView.breakUndoCoalescing()
            textView.insertText(item.insertText, replacementRange: replacement)
            textView.breakUndoCoalescing()
        }
        isInserting = false
        let inserted = NSRange(location: replacement.location, length: replacement.length + text.length - lengthBefore)
        if !additional.isEmpty {
            applyAdditionalEdits(additional, around: replacement, inserted: inserted)
        } else if let resolving, resolving.resolvesCompletionItems {
            // Only edits before the insertion apply then (imports, mostly): the text there is
            // checked unchanged when the answer comes, whatever was typed after it.
            let before = text.substring(to: min(replacement.location, text.length))
            Task { [weak self, weak document] in
                guard let resolved = try? await resolving.resolve(item), !resolved.additionalTextEdits.isEmpty,
                      let self, let document, document === self.editor.document else { return }
                let current = document.textStorage.mutableString
                guard current.length >= before.utf16.count, current.substring(to: before.utf16.count) == before else { return }
                let edits = resolved.additionalTextEdits.map { TextReplacement(range: document.range(for: $0.range), text: $0.newText) }
                    .filter { NSMaxRange($0.range) <= replacement.location }
                if !edits.isEmpty { _ = try? document.apply(edits, actionName: "Completion") }
            }
        }
    }

    /// `edits` (in the text before `replacement` became `inserted`) moved past the insertion;
    /// any overlapping it are left out.
    private func applyAdditionalEdits(_ edits: [TextReplacement], around replacement: NSRange, inserted: NSRange) {
        let shift = inserted.length - replacement.length
        let moved = edits.compactMap { edit -> TextReplacement? in
            if NSMaxRange(edit.range) <= replacement.location { return edit }
            guard edit.range.location >= NSMaxRange(replacement) else { return nil }
            return TextReplacement(range: NSRange(location: edit.range.location + shift, length: edit.range.length), text: edit.text)
        }
        _ = try? editor.document.apply(moved, actionName: "Completion")
    }

    /// Where an item with a server's edit range goes: the range (asked for at `requestedAt`,
    /// computed in the current text) from its start to its end moved by what was typed since,
    /// and at least to the cursor.
    static func replacementRange(_ edit: NSRange, requestedAt: Int, cursor: Int, length: Int) -> NSRange {
        let start = min(edit.location, cursor)
        var end = NSMaxRange(edit)
        if end >= requestedAt { end += cursor - requestedAt }
        end = min(max(end, cursor), length)
        return NSRange(location: start, length: end - start)
    }

    // MARK: Words

    static func isWordText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }
    }

    static func wordStart(in text: NSString, before offset: Int) -> Int {
        var start = min(offset, text.length)
        while start > 0 {
            let character = text.character(at: start - 1)
            guard let scalar = Unicode.Scalar(character),
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$" else { break }
            start -= 1
        }
        return start
    }
}

private struct CompletionListView: View {
    let model: CompletionModel
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        CompletionRowView(row: row, isSelected: index == model.selection)
                            .frame(height: CompletionController.rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(index) }
                    }
                }
                .padding(4)
            }
            .onChange(of: model.selection) { _, selection in
                if model.rows.indices.contains(selection) { proxy.scrollTo(model.rows[selection].id) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

private struct CompletionRowView: View {
    let row: CompletionModel.Row
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.item.icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            label
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let detail = row.item.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private var label: Text {
        let matched = Set(row.matches)
        var attributed = AttributedString(row.item.label)
        var byteOffset = 0
        var index = attributed.startIndex
        for scalar in row.item.label.unicodeScalars {
            let next = attributed.unicodeScalars.index(after: index)
            if matched.contains(byteOffset) {
                attributed[index..<next].foregroundColor = .accentColor
                attributed[index..<next].font = .system(size: 12, weight: .bold, design: .monospaced)
            }
            byteOffset += String(scalar).utf8.count
            index = next
        }
        return Text(attributed)
    }
}
