import Foundation
import Observation

/// A file or directory in the workspace tree. Children load lazily on first access,
/// so opening huge folders only reads directories the user actually expands.
@Observable
final class FileNode: Identifiable, Hashable {
    static let ignoredNames: Set<String> = [".git", ".DS_Store", ".build", "DerivedData"]

    let url: URL
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// Bumped on reload; reading `children` registers a dependency on it.
    private var version = 0
    @ObservationIgnored private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// `nil` for files (so `List`/`OutlineGroup` shows no disclosure triangle).
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        _ = version
        if let loadedChildren { return loadedChildren }
        let loaded = Self.loadChildren(of: url)
        loadedChildren = loaded
        return loaded
    }

    var isLoaded: Bool { loadedChildren != nil }

    /// Re-reads this directory if it was loaded, keeping existing child nodes (and with them
    /// their loaded subtrees and expansion state) for entries that still exist.
    func reloadChildren() {
        guard isDirectory, let existing = loadedChildren else { return }
        let byURL = Dictionary(existing.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        loadedChildren = Self.loadChildren(of: url).map { fresh in
            if let old = byURL[fresh.url], old.isDirectory == fresh.isDirectory { return old }
            return fresh
        }
        version += 1
    }

    /// Reloads every loaded directory in this subtree.
    func reloadLoadedSubtree() {
        guard let existing = loadedChildren else { return }
        reloadChildren()
        for child in existing where child.isDirectory { child.reloadLoadedSubtree() }
    }

    /// Finds an already-loaded descendant without triggering any directory reads.
    func loadedNode(atRelativePath components: [String]) -> FileNode? {
        var node = self
        for component in components {
            guard let next = node.loadedChildren?.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    private static func loadChildren(of url: URL) -> [FileNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        return urls
            .filter { !ignoredNames.contains($0.lastPathComponent) }
            .map { childURL in
                let isDir = (try? childURL.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
                return FileNode(url: URL(filePath: childURL.path, directoryHint: isDir ? .isDirectory : .notDirectory),
                                isDirectory: isDir)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
