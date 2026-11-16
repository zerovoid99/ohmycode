import Foundation
import Observation

/// A file or directory in the workspace tree. Children load lazily on first access,
/// so opening huge folders only reads directories the user actually expands.
@Observable
final class FileNode: Identifiable, Hashable {
    static let ignoredNames: Set<String> = [".git", ".DS_Store", ".build", "DerivedData"]

    let url: URL
    let isDirectory: Bool
    /// The last path component. Kept: sorting a big folder asks for it hundreds of thousands
    /// of times, and taking it from the URL each time was most of the cost of listing one.
    let name: String
    var id: URL { url }

    /// Bumped on reload; reading `children` registers a dependency on it.
    private var version = 0
    @ObservationIgnored private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        name = url.lastPathComponent
    }

    private init(url: URL, isDirectory: Bool, name: String) {
        self.url = url
        self.isDirectory = isDirectory
        self.name = name
    }

    /// `nil` for files (so `List`/`OutlineGroup` shows no disclosure triangle).
    var children: [FileNode]? {
        guard isDirectory else { return nil }
        _ = version
        if let loadedChildren { return loadedChildren }
        let path = url.path
        let loaded = Self.entries(of: path).map { Self.node($0, in: path) }.sorted(by: Self.inOrder)
        loadedChildren = loaded
        return loaded
    }

    var isLoaded: Bool { loadedChildren != nil }

    /// Re-reads this directory if it was loaded, keeping existing child nodes (and with them
    /// their loaded subtrees and expansion state) for entries that still exist. Only what was
    /// added is sorted (into its place among the rest), and when nothing was added or removed
    /// nothing changes at all: a build can touch a folder of thousands of files many times a second.
    func reloadChildren() {
        guard isDirectory, let existing = loadedChildren else { return }
        let path = url.path
        var entries = Dictionary(Self.entries(of: path).map { ($0.name, $0.isDirectory) }, uniquingKeysWith: { first, _ in first })
        var kept: [FileNode] = []
        kept.reserveCapacity(existing.count)
        for node in existing where entries[node.name] == node.isDirectory {
            kept.append(node)
            entries[node.name] = nil
        }
        guard kept.count != existing.count || !entries.isEmpty else { return }
        let added = entries.map { Self.node((name: $0.key, isDirectory: $0.value), in: path) }.sorted(by: Self.inOrder)

        var merged: [FileNode] = []
        merged.reserveCapacity(kept.count + added.count)
        var next = 0
        for node in kept {
            while next < added.count, Self.inOrder(added[next], node) {
                merged.append(added[next])
                next += 1
            }
            merged.append(node)
        }
        merged.append(contentsOf: added[next...])
        loadedChildren = merged
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

    /// Folders first, then by name the way Finder orders them.
    private static func inOrder(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func node(_ entry: (name: String, isDirectory: Bool), in path: String) -> FileNode {
        let childPath = path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name
        return FileNode(url: URL(filePath: childPath, directoryHint: entry.isDirectory ? .isDirectory : .notDirectory),
                        isDirectory: entry.isDirectory, name: entry.name)
    }

    /// A directory's entries, unsorted, without the ignored ones. From readdir, which says what
    /// is a folder: no URL or resource lookup per entry. A symbolic link is listed as a file.
    private static func entries(of path: String) -> [(name: String, isDirectory: Bool)] {
        guard let directory = opendir(path) else { return [] }
        defer { closedir(directory) }
        var result: [(name: String, isDirectory: Bool)] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." || ignoredNames.contains(name) { continue }
            var isDirectory = entry.pointee.d_type == DT_DIR
            if entry.pointee.d_type == DT_UNKNOWN { // a file system that doesn't say
                var info = stat()
                isDirectory = lstat(path + "/" + name, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            }
            result.append((name, isDirectory))
        }
        return result
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
