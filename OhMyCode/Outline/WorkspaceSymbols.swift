import Foundation
import SwiftTreeSitter

/// A declaration somewhere in the folder (⌘T).
struct WorkspaceSymbolResult: Identifiable, Equatable, Sendable {
    var name: String
    var kind: DocumentSymbol.Kind
    /// The symbols it's in ("Store", "Store.Item").
    var container: String?
    var url: URL
    /// Zero-based line and UTF-16 column of its name.
    var line: Int
    var column: Int
    var length: Int
    var id: String { "\(url.path):\(line):\(column):\(name)" }
}

/// The folder's declarations from the syntax trees of its files, read in the background and
/// kept per file until it changes (for languages a server doesn't search, or with none).
actor WorkspaceSymbolIndex {
    static let maxFiles = 20_000
    static let maxFileSize = 1_000_000

    private var files: [String: (date: Date, symbols: [WorkspaceSymbolResult])] = [:]
    private var parsers: [SourceLanguage: Parser] = [:]
    private(set) var isComplete = false

    /// Reads files that are new or changed since last time (`paths` relative to `root`);
    /// forgets those no longer listed.
    func update(root: URL, paths: [String]) {
        let listed = Set(paths.prefix(Self.maxFiles))
        for path in files.keys where !listed.contains(path) { files[path] = nil }
        for path in paths.prefix(Self.maxFiles) {
            let language = SourceLanguage(fileExtension: (path as NSString).pathExtension)
            guard language == .markdown || GrammarRegistry.treeSitterLanguage(for: language) != nil else { continue }
            let url = root.appending(path: path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let date = attributes[.modificationDate] as? Date,
                  (attributes[.size] as? Int ?? 0) <= Self.maxFileSize else { continue }
            if files[path]?.date == date { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files[path] = (date, symbols(in: text as NSString, language: language, url: url))
        }
        isComplete = true
    }

    /// Files changed on disk: read again at the next update.
    func invalidate(_ paths: [String]) {
        for path in paths { files[path] = nil }
    }

    func clear() {
        files = [:]
        isComplete = false
    }

    var fileCount: Int { files.count }

    /// Every symbol, except in `excluded` files (relative paths: open documents have their own).
    func all(excluding excluded: Set<String>) -> [WorkspaceSymbolResult] {
        files.filter { !excluded.contains($0.key) }.values.flatMap(\.symbols)
    }

    private func symbols(in text: NSString, language: SourceLanguage, url: URL) -> [WorkspaceSymbolResult] {
        let tree: [DocumentSymbol]
        if language == .markdown {
            tree = DocumentSymbol.markdown(text)
        } else {
            guard let parser = parser(for: language), let parsed = parser.parse(text as String), let root = parsed.rootNode else { return [] }
            var found: [DocumentSymbol] = []
            Outline.walk(root, language: language, text: text, into: &found)
            tree = found
        }
        return Self.results(tree, text: text, url: url)
    }

    private func parser(for language: SourceLanguage) -> Parser? {
        if let parser = parsers[language] { return parser }
        guard let treeSitterLanguage = GrammarRegistry.treeSitterLanguage(for: language) else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(treeSitterLanguage)) != nil else { return nil }
        parsers[language] = parser
        return parser
    }

    /// A file's symbol tree as results (with their containers' names).
    static func results(_ symbols: [DocumentSymbol], text: NSString, url: URL) -> [WorkspaceSymbolResult] {
        let index = LineIndex(string: text)
        return DocumentSymbol.flattened(symbols).map { entry in
            let start = min(entry.symbol.selectionRange.location, text.length)
            let line = index.line(containing: start)
            return WorkspaceSymbolResult(name: entry.symbol.name, kind: entry.symbol.kind,
                                         container: entry.container.isEmpty ? nil : entry.container.joined(separator: "."),
                                         url: url, line: line, column: start - index.lineStarts[line],
                                         length: entry.symbol.selectionRange.length)
        }
    }
}

extension Workspace {
    /// ⌘T: symbols named like `query` in the whole folder: the language servers' and the
    /// syntax trees' (open files as they are now), best matches first.
    func workspaceSymbols(matching query: String, limit: Int = 200) async -> [WorkspaceSymbolResult] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard let root = rootURL, !text.isEmpty else { return [] }

        // The servers, each given a moment: a slow one doesn't hold the rest up.
        let clients = languageClientsForSymbols
        async let fromServers = Self.serverSymbols(clients, query: text)

        // The index, brought up to date with the file list first.
        let paths = await searchableFiles()
        await symbolIndex.update(root: root, paths: paths)
        // The servers' first: they know containers and kinds best (duplicates are dropped below).
        var results: [WorkspaceSymbolResult] = await fromServers.map { symbol in
            WorkspaceSymbolResult(name: symbol.name, kind: DocumentSymbol.Kind(rawValue: symbol.kind) ?? .variable,
                                  container: symbol.containerName.flatMap { $0.isEmpty ? nil : $0 },
                                  url: workspaceURL(for: symbol.url), line: symbol.range.start.line,
                                  column: symbol.range.start.character,
                                  length: max(0, symbol.range.end.character - symbol.range.start.character))
        }
        var openPaths = Set<String>()
        for document in documents {
            guard let path = relativePath(of: document.url) else { continue }
            openPaths.insert(path)
            results += WorkspaceSymbolIndex.results(document.symbols, text: document.textStorage.mutableString, url: document.url)
        }
        results += await symbolIndex.all(excluding: openPaths)

        let prepared = FuzzyMatcher.prepareQuery(text)
        var seen = Set<String>()
        var scored: [(result: WorkspaceSymbolResult, score: Int)] = []
        for result in results {
            guard let match = FuzzyMatcher.match(prepared, FuzzyCandidate(result.name)) else { continue }
            // The same symbol from a server and a syntax tree: once.
            guard seen.insert("\(FileWatcher.canonicalPath(result.url)):\(result.line):\(result.name)").inserted else { continue }
            scored.append((result, match.score))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.result.name.count < $1.result.name.count }
        return scored.prefix(limit).map(\.result)
    }

    /// Ready servers that search the workspace.
    private var languageClientsForSymbols: [LanguageClient] {
        languageClients.values.filter { $0.state == .ready && $0.supports(.workspaceSymbol) }
    }

    private static func serverSymbols(_ clients: [LanguageClient], query: String) async -> [WorkspaceSymbol] {
        // All asked at once; each given a moment, so a slow one doesn't hold the rest up.
        let tasks = clients.map { client in
            Task { @MainActor in
                (try? await ExtensionHost.within(.milliseconds(1500)) { @MainActor in try await client.workspaceSymbols(query: query) }) ?? nil
            }
        }
        var results: [WorkspaceSymbol] = []
        for task in tasks { results += await task.value ?? [] }
        return results
    }
}
