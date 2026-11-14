import Foundation

/// Flat list of a workspace's files, prepared for fuzzy matching.
struct FileIndex: Sendable {
    let root: URL
    let files: [FuzzyCandidate]

    func url(for candidate: FuzzyCandidate) -> URL {
        root.appending(path: candidate.text, directoryHint: .notDirectory)
    }
}

enum FileIndexer {
    static let maxFiles = 200_000
    static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "build", "DerivedData", "node_modules", "Pods", "xcuserdata",
    ]

    /// Uses `git ls-files` inside a repository (fast, respects .gitignore); otherwise walks the
    /// tree skipping common build/dependency folders. Call off the main thread.
    static func build(root: URL) -> FileIndex {
        let paths = gitFiles(root: root) ?? walk(root: root)
        let sorted = paths.prefix(maxFiles).sorted()
        return FileIndex(root: root, files: sorted.map(FuzzyCandidate.init))
    }

    private static func gitFiles(root: URL) -> [String]? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard let result = try? ProcessIO.run(process, output: output, error: nil), result.status == 0 else { return nil }
        let data = result.output

        let fileManager = FileManager.default
        var seen = Set<String>()
        return data.split(separator: 0).compactMap { bytes in
            let path = String(decoding: bytes, as: UTF8.self)
            // --cached also lists tracked files deleted from disk; dedupe merge-conflict entries.
            guard seen.insert(path).inserted,
                  fileManager.fileExists(atPath: root.appending(path: path).path) else { return nil }
            return path
        }
    }

    private static func walk(root: URL) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        let rootPath = root.standardizedFileURL.path
        let prefixLength = rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1
        var result: [String] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
            if isDirectory {
                if ignoredDirectories.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if name == ".DS_Store" { continue }
            result.append(String(url.standardizedFileURL.path.dropFirst(prefixLength)))
            if result.count >= maxFiles { break }
        }
        return result
    }
}
