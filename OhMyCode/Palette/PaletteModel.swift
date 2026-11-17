import Foundation
import Observation

struct PaletteItem: Identifiable {
    enum Action {
        case openFile(URL)
        case command(PaletteCommand)
        case goToLine(Int)
        /// A symbol in the active file (its name's range).
        case goToSymbol(NSRange)
        /// A symbol anywhere: its file, zero-based line, UTF-16 column and name length.
        case openSymbol(URL, line: Int, column: Int, length: Int)
        /// A command an extension adds.
        case extensionCommand(String)
        /// A quick pick's item, by index.
        case choose(Int)
        /// An input box's text.
        case submitText
    }

    let id: String
    let action: Action?
    let icon: String
    let title: String
    var titleMatches: [Int] = []
    var detail: String?
    var detailMatches: [Int] = []
    var shortcut: String?
}

/// Quick open (⌘P), command palette (`>`, ⇧⌘P) and go to line (`:`, ⌃G), switched by prefix
/// like VS Code.
@MainActor
@Observable
final class PaletteModel {
    enum Mode {
        case files, commands, goToLine, symbols, workspaceSymbols
        /// A quick pick or input box (an extension asking).
        case prompt

        var prefix: String {
            switch self {
            case .files, .prompt: ""
            case .commands: ">"
            case .goToLine: ":"
            case .symbols: "@"
            case .workspaceSymbols: "#"
            }
        }
    }

    /// A question an extension asks through the palette: pick an item, or type text.
    struct Prompt {
        enum Kind {
            case pick([QuickPickItem])
            /// The prompt shown under the text.
            case input(String?)
        }
        enum Reply { case index(Int), text(String) }

        let kind: Kind
        let placeholder: String?
        let reply: (Reply?) -> Void
    }

    /// The question being asked, if the palette is a prompt.
    @ObservationIgnored private(set) var prompt: Prompt?

    nonisolated static let resultLimit = 60

    var query: String {
        didSet { if query != oldValue { refresh() } }
    }
    private(set) var items: [PaletteItem] = []
    private(set) var emptyMessage: String?
    var selection = 0

    /// Weak: work still in flight when the window closes goes to a closed workspace (does nothing).
    @ObservationIgnored private weak var owner: Workspace?
    private var workspace: Workspace { owner ?? Workspace.closed }
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0

    var mode: Mode {
        if prompt != nil { return .prompt }
        if query.hasPrefix(">") { return .commands }
        if query.hasPrefix(":") { return .goToLine }
        if query.hasPrefix("@") { return .symbols }
        if query.hasPrefix("#") { return .workspaceSymbols }
        return .files
    }

    var placeholder: String {
        switch mode {
        case .files: "Search files by name (> commands, : line, @ symbol in file, # symbol anywhere)"
        case .symbols: "Type a symbol's name"
        case .workspaceSymbols: "Type a symbol's name to search the whole folder"
        case .commands: "Type a command"
        case .goToLine: "Type a line number"
        case .prompt:
            if let placeholder = prompt?.placeholder { placeholder }
            else if case .pick = prompt?.kind { "Select an item" } else { "Type, then press Enter" }
        }
    }

    init(workspace: Workspace, mode: Mode) {
        self.owner = workspace
        self.query = mode.prefix
        refresh()
    }

    init(workspace: Workspace, prompt: Prompt, text: String) {
        self.owner = workspace
        self.prompt = prompt
        self.query = text
        refresh()
    }

    /// Answers the prompt with nothing (the palette closed without a choice).
    func cancelPrompt() {
        guard let prompt else { return }
        self.prompt = nil
        prompt.reply(nil)
    }

    private func finishPrompt(_ reply: Prompt.Reply) {
        guard let prompt else { return }
        self.prompt = nil
        workspace.closePalette()
        prompt.reply(reply)
    }

    func moveSelection(_ offset: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + offset + items.count) % items.count
    }

    func acceptSelection() {
        guard items.indices.contains(selection) else { return }
        accept(items[selection])
    }

    func accept(_ item: PaletteItem) {
        guard let action = item.action else { return }
        switch action {
        case .openFile(let url):
            workspace.closePalette()
            workspace.open(fileAt: url)
        case .command(let command):
            workspace.closePalette()
            command.perform(workspace)
        case .goToLine(let line):
            workspace.closePalette()
            workspace.activeDocument?.revealLine(line)
        case .goToSymbol(let range):
            workspace.closePalette()
            workspace.activeDocument?.reveal(range)
        case .openSymbol(let url, let line, let column, let length):
            workspace.closePalette()
            workspace.open(fileAt: url)
            // Not if the file didn't open: the position is the symbol's file's, not the tab's.
            if let document = workspace.activeDocument, workspace.document(matching: url) === document {
                let start = document.offset(for: LSPPosition(line: line, character: column))
                document.reveal(NSRange(location: start, length: min(length, document.textStorage.length - start)))
            }
        case .extensionCommand(let id):
            workspace.closePalette()
            workspace.extensions.run(id)
        case .choose(let index):
            finishPrompt(.index(index))
        case .submitText:
            finishPrompt(.text(query))
        }
    }

    /// Re-run the query, e.g. after the file index finished building.
    func refresh() {
        searchTask?.cancel()
        searchGeneration += 1
        switch mode {
        case .files: refreshFiles()
        case .commands: refreshCommands()
        case .goToLine: refreshGoToLine()
        case .symbols: refreshSymbols()
        case .workspaceSymbols: refreshWorkspaceSymbols()
        case .prompt: refreshPrompt()
        }
    }

    private func setItems(_ newItems: [PaletteItem], emptyMessage: String? = nil) {
        items = newItems
        self.emptyMessage = newItems.isEmpty ? (emptyMessage ?? "No matching results") : nil
        selection = 0
    }

    // MARK: Symbols

    /// `@name`: the active file's symbols, matching ones first; in file order when empty.
    private func refreshSymbols() {
        guard let document = workspace.activeDocument else {
            return setItems([], emptyMessage: "Open a file to go to its symbols")
        }
        let text = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        let flat = DocumentSymbol.flattened(document.symbols)
        let query = FuzzyMatcher.prepareQuery(text)
        var scored: [(item: PaletteItem, score: Int)] = []
        for (index, entry) in flat.enumerated() {
            let detail = entry.container.joined(separator: " › ")
            let item = { (positions: [Int]) in
                PaletteItem(id: entry.symbol.id, action: .goToSymbol(entry.symbol.selectionRange), icon: entry.symbol.kind.icon,
                            title: entry.symbol.name, titleMatches: positions,
                            detail: detail.isEmpty ? entry.symbol.kind.name : detail)
            }
            if text.isEmpty {
                scored.append((item([]), -index))
            } else if let match = FuzzyMatcher.match(query, FuzzyCandidate(entry.symbol.name)) {
                scored.append((item(match.positions), match.score))
            }
        }
        scored.sort { $0.score > $1.score }
        setItems(scored.prefix(Self.resultLimit * 4).map(\.item),
                 emptyMessage: document.symbols.isEmpty ? "No symbols in \(document.fileName)" : nil)
    }

    // MARK: Workspace symbols

    /// `#name`: symbols anywhere in the folder (searched shortly after typing pauses).
    private func refreshWorkspaceSymbols() {
        let text = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard workspace.rootURL != nil else { return setItems([], emptyMessage: "Open a folder to search its symbols") }
        guard !text.isEmpty else { return setItems([], emptyMessage: "Type a symbol's name") }
        if items.isEmpty { emptyMessage = "Searching…" }
        let generation = searchGeneration
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            let results = await self.workspace.workspaceSymbols(matching: text)
            guard !Task.isCancelled, self.searchGeneration == generation else { return }
            let prepared = FuzzyMatcher.prepareQuery(text)
            self.setItems(results.map { result in
                let place = (self.workspace.relativePath(of: result.url) ?? result.url.lastPathComponent) + ":\(result.line + 1)"
                return PaletteItem(id: result.id, action: .openSymbol(result.url, line: result.line, column: result.column, length: result.length),
                                   icon: result.kind.icon, title: result.name,
                                   titleMatches: FuzzyMatcher.match(prepared, FuzzyCandidate(result.name))?.positions ?? [],
                                   detail: (result.container.map { $0 + " · " } ?? "") + place)
            }, emptyMessage: "No symbols named like “\(text)”")
        }
    }

    // MARK: Files

    private func refreshFiles() {
        guard workspace.rootNode != nil else {
            return setItems([], emptyMessage: "Open a folder to search its files")
        }
        guard let index = workspace.fileIndex else {
            return setItems([], emptyMessage: "Indexing files…")
        }
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            return setItems(recentAndFirstFiles(in: index), emptyMessage: "No files")
        }

        let generation = searchGeneration
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let results = FuzzyMatcher.search(text, in: index.files, limit: Self.resultLimit)
            guard !Task.isCancelled else { return }
            let items = results.map { Self.fileItem(index.files[$0.index], index: index, positions: $0.match.positions) }
            await MainActor.run {
                guard let self, self.searchGeneration == generation else { return }
                self.setItems(items)
            }
        }
    }

    private func recentAndFirstFiles(in index: FileIndex) -> [PaletteItem] {
        let rootPath = index.root.standardizedFileURL.path + "/"
        let recent = workspace.recentFiles.compactMap { url -> PaletteItem? in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { return nil }
            return Self.fileItem(FuzzyCandidate(String(path.dropFirst(rootPath.count))), index: index, positions: [])
        }
        let recentIDs = Set(recent.map(\.id))
        let rest = index.files.lazy
            .map { Self.fileItem($0, index: index, positions: []) }
            .filter { !recentIDs.contains($0.id) }
            .prefix(Self.resultLimit - recent.count)
        return recent + rest
    }

    nonisolated private static func fileItem(_ candidate: FuzzyCandidate, index: FileIndex, positions: [Int]) -> PaletteItem {
        let nameStart = candidate.nameStart
        let directory = nameStart > 0 ? String(decoding: candidate.bytes[..<(nameStart - 1)], as: UTF8.self) : nil
        return PaletteItem(
            id: candidate.text,
            action: .openFile(index.url(for: candidate)),
            icon: "doc.text",
            title: String(decoding: candidate.bytes[nameStart...], as: UTF8.self),
            titleMatches: positions.filter { $0 >= nameStart }.map { $0 - nameStart },
            detail: directory,
            detailMatches: positions.filter { $0 < nameStart - 1 }
        )
    }

    // MARK: Commands

    private func refreshCommands() {
        let text = String(query.dropFirst())
        let prepared = FuzzyMatcher.prepareQuery(text)
        let scored = PaletteCommand.all
            .filter { $0.isAvailable(workspace) }
            .compactMap { command -> (PaletteCommand, FuzzyMatch)? in
                guard let match = FuzzyMatcher.match(prepared, FuzzyCandidate(command.title)) else { return nil }
                return (command, match)
            }
        let builtIn = scored.map { command, match in
            (PaletteItem(id: command.id, action: .command(command), icon: command.icon, title: command.title,
                         titleMatches: match.positions, shortcut: Keybindings.shared.display(for: command.id)), match.score)
        }
        let contributed = workspace.extensions.paletteCommands.compactMap { command, instance -> (PaletteItem, Int)? in
            let title = command.paletteTitle
            guard let match = FuzzyMatcher.match(prepared, FuzzyCandidate(title)) else { return nil }
            return (PaletteItem(id: "extension:" + command.command, action: .extensionCommand(command.command),
                                icon: command.icon ?? "puzzlepiece.extension", title: title, titleMatches: match.positions,
                                // The extension, unless the category already names it.
                                detail: command.category == instance.manifest.name ? nil : instance.manifest.name,
                                shortcut: workspace.extensions.shortcut(for: command.command)), match.score)
        }
        let all = builtIn + contributed
        let sorted = prepared.isEmpty ? all : all.sorted { $0.1 > $1.1 }
        setItems(sorted.map(\.0), emptyMessage: "No matching commands")
    }

    // MARK: Prompts

    private func refreshPrompt() {
        guard let prompt else { return }
        switch prompt.kind {
        case .pick(let choices):
            let prepared = FuzzyMatcher.prepareQuery(query)
            let scored = choices.enumerated().compactMap { index, item -> (PaletteItem, Int)? in
                guard let match = FuzzyMatcher.match(prepared, FuzzyCandidate(item.label)) else { return nil }
                return (PaletteItem(id: "pick:\(index)", action: .choose(index), icon: "circle.fill", title: item.label,
                                    titleMatches: match.positions, detail: item.description ?? item.detail), match.score)
            }
            let sorted = prepared.isEmpty ? scored : scored.sorted { $0.1 > $1.1 }
            setItems(sorted.map(\.0), emptyMessage: "No matching items")
        case .input(let message):
            setItems([PaletteItem(id: "input", action: .submitText, icon: "return",
                                  title: message ?? "Press Enter to confirm", detail: message == nil ? nil : "Press Enter to confirm")])
        }
    }

    // MARK: Go to line

    private func refreshGoToLine() {
        guard let document = workspace.activeDocument else {
            return setItems([], emptyMessage: "Open a file to go to a line")
        }
        let lineCount = document.lineCount
        let text = query.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let line = Int(text) else {
            return setItems([], emptyMessage: "Type a line number between 1 and \(lineCount)")
        }
        guard (1...lineCount).contains(line) else {
            return setItems([], emptyMessage: "Line \(line) is out of range (1–\(lineCount))")
        }
        setItems([PaletteItem(id: "line", action: .goToLine(line), icon: "arrow.right.to.line",
                              title: "Go to line \(line)", detail: document.fileName)])
    }
}

/// An item an extension offers in a quick pick.
struct QuickPickItem: Equatable, Sendable {
    let label: String
    var description: String?
    var detail: String?
}
