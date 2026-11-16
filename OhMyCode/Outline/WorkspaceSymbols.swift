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
    private(set) var isComplete = false
    private var updating: Task<Void, Never>?

    /// Reads files that are new or changed since last time (`paths` relative to `root`);
    /// forgets those no longer listed. Changed files are parsed on all cores.
    func update(root: URL, paths: [String]) async {
        // One at a time: the actor is free while files are parsed, and a second search then
        // would parse the same files again.
        while let updating { await updating.value }
        let task = Task { await self.read(root: root, paths: paths) }
        updating = task
        await task.value
        updating = nil
    }

    private func read(root: URL, paths: [String]) async {
        let listed = Set(paths.prefix(Self.maxFiles))
        for path in files.keys where !listed.contains(path) { files[path] = nil }
        var stale: [(path: String, language: SourceLanguage, date: Date)] = []
        for path in paths.prefix(Self.maxFiles) {
            let language = SourceLanguage(fileExtension: (path as NSString).pathExtension)
            guard language == .markdown || GrammarRegistry.treeSitterLanguage(for: language) != nil else { continue }
            // stat, not `attributesOfItem`: this runs for every file at every search (88 µs
            // against 2 a file).
            var info = stat()
            guard stat(root.appending(path: path).path, &info) == 0, info.st_size <= Self.maxFileSize else { continue }
            let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
            if files[path]?.date == date { continue }
            stale.append((path, language, date))
        }
        if !stale.isEmpty {
            let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, stale.count / 8))
            let size = (stale.count + workers - 1) / workers
            let pending = stale
            await withTaskGroup(of: [(String, Date, [WorkspaceSymbolResult])].self) { group in
                for start in stride(from: 0, to: pending.count, by: size) {
                    let slice = Array(pending[start..<min(start + size, pending.count)])
                    group.addTask {
                        var parsers: [SourceLanguage: Parser] = [:]
                        return slice.compactMap { entry in
                            let url = root.appending(path: entry.path)
                            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                            return (entry.path, entry.date, Self.symbols(in: text as NSString, language: entry.language, url: url, parsers: &parsers))
                        }
                    }
                }
                for await parsed in group {
                    for (path, date, symbols) in parsed { files[path] = (date, symbols) }
                }
            }
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

    private static func symbols(in text: NSString, language: SourceLanguage, url: URL,
                                parsers: inout [SourceLanguage: Parser]) -> [WorkspaceSymbolResult] {
        let tree: [DocumentSymbol]
        if language == .markdown {
            tree = DocumentSymbol.markdown(text)
        } else {
            guard let parser = parser(for: language, in: &parsers), let parsed = parser.parse(text as String),
                  let root = parsed.rootNode else { return [] }
            var found: [DocumentSymbol] = []
            Outline.walk(root, language: language, text: text, into: &found)
            tree = found
        }
        return Self.results(tree, text: text, url: url)
    }

    private static func parser(for language: SourceLanguage, in parsers: inout [SourceLanguage: Parser]) -> Parser? {
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

        // Hundreds of thousands of names: matched and sorted off the main thread.
        let all = results
        return await Task.detached(priority: .userInitiated) { Self.best(all, matching: text, limit: limit) }.value
    }

    /// The symbols named like `query`, best first, each place once.
    nonisolated static func best(_ results: [WorkspaceSymbolResult], matching query: String, limit: Int) -> [WorkspaceSymbolResult] {
        let prepared = FuzzyMatcher.prepareQuery(query)
        var seen = Set<Place>()
        // A file's canonical path is a system call (realpath): once per file, not per symbol.
        var canonical: [URL: String] = [:]
        // Sorted by index: comparing names' lengths (counted a character at a time) for each
        // of a few hundred thousand matches took most of a search.
        var scored: [(index: Int, score: Int, length: Int)] = []
        for (index, result) in results.enumerated() {
            guard let match = FuzzyMatcher.match(prepared, FuzzyCandidate(result.name)) else { continue }
            let path: String
            if let known = canonical[result.url] {
                path = known
            } else {
                path = FileWatcher.canonicalPath(result.url)
                canonical[result.url] = path
            }
            // The same symbol from a server and a syntax tree: once.
            guard seen.insert(Place(path: path, line: result.line, name: result.name)).inserted else { continue }
            scored.append((index, match.score, result.name.count))
        }
        // Equal ones in the order they came (servers' first), whatever the sort does with them.
        scored.sort { ($1.score, $0.length, $0.index) < ($0.score, $1.length, $1.index) }
        return scored.prefix(limit).map { results[$0.index] }
    }

    private struct Place: Hashable {
        let path: String
        let line: Int
        let name: String
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
