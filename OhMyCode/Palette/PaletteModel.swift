import Foundation
import Observation

struct PaletteItem: Identifiable {
    enum Action {
        case openFile(URL)
        case command(PaletteCommand)
        case goToLine(Int)
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
        case files, commands, goToLine

        var prefix: String {
            switch self {
            case .files: ""
            case .commands: ">"
            case .goToLine: ":"
            }
        }
    }

    nonisolated static let resultLimit = 60

    var query: String {
        didSet { if query != oldValue { refresh() } }
    }
    private(set) var items: [PaletteItem] = []
    private(set) var emptyMessage: String?
    var selection = 0

    @ObservationIgnored private unowned let workspace: Workspace
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0

    var mode: Mode {
        if query.hasPrefix(">") { return .commands }
        if query.hasPrefix(":") { return .goToLine }
        return .files
    }

    var placeholder: String {
        switch mode {
        case .files: "Search files by name (type > for commands, : to go to a line)"
        case .commands: "Type a command"
        case .goToLine: "Type a line number"
        }
    }

    init(workspace: Workspace, mode: Mode) {
        self.workspace = workspace
        self.query = mode.prefix
        refresh()
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
        }
    }

    private func setItems(_ newItems: [PaletteItem], emptyMessage: String? = nil) {
        items = newItems
        self.emptyMessage = newItems.isEmpty ? (emptyMessage ?? "No matching results") : nil
        selection = 0
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
        let sorted = prepared.isEmpty ? scored : scored.sorted { $0.1.score > $1.1.score }
        setItems(sorted.map { command, match in
            PaletteItem(id: command.id, action: .command(command), icon: command.icon, title: command.title,
                        titleMatches: match.positions, shortcut: command.shortcut)
        }, emptyMessage: "No matching commands")
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
