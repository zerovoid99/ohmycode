import Foundation

/// A file or directory in the workspace tree. Children load lazily on first access,
/// so opening huge folders only reads directories the user actually expands.
final class FileNode: Identifiable, Hashable {
    static let ignoredNames: Set<String> = [".git", ".DS_Store", ".build", "DerivedData"]

    let url: URL
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// `nil` for files (so `List`/`OutlineGroup` shows no disclosure triangle).
    lazy var children: [FileNode]? = isDirectory ? Self.loadChildren(of: url) : nil

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
