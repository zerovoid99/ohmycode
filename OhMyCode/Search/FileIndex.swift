import Foundation

/// Flat list of a workspace's files, prepared for fuzzy matching.
struct FileIndex: Sendable {
    /// The folders; with several, each path starts with its folder's label (see `WorkspaceRoots`).
    let roots: WorkspaceRoots
    let files: [FuzzyCandidate]

    init(root: URL, files: [FuzzyCandidate]) {
        roots = WorkspaceRoots(single: root)
        self.files = files
    }

    init(roots: WorkspaceRoots, files: [FuzzyCandidate]) {
        self.roots = roots
        self.files = files
    }

    /// The primary folder.
    var root: URL { roots.folders.first?.url ?? URL(filePath: "/") }

    func url(for candidate: FuzzyCandidate) -> URL {
        roots.url(for: candidate.text) ?? root.appending(path: candidate.text, directoryHint: .notDirectory)
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

    /// Every folder's files, each folder's prefixed with its label when there are several.
    static func build(roots: WorkspaceRoots) -> FileIndex {
        guard roots.isMultiRoot, !roots.folders.isEmpty else {
            return FileIndex(roots: roots, files: build(root: roots.folders.first?.url ?? URL(filePath: "/")).files)
        }
        var paths: [String] = []
        for folder in roots.folders {
            let own = gitFiles(root: folder.url) ?? walk(root: folder.url)
            paths += roots.paths(own.prefix(maxFiles / roots.folders.count).sorted(), in: folder)
        }
        return FileIndex(roots: roots, files: paths.map(FuzzyCandidate.init))
    }

    private static func gitFiles(root: URL) -> [String]? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        // No fsmonitor hook from the folder's config runs just because the folder was opened.
        process.arguments = ["-c", "core.fsmonitor=false", "-C", root.path,
                             "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard let result = try? ProcessIO.run(process, output: output, error: nil), result.status == 0 else { return nil }
        var data = result.output
        if data.last != 0 { data.append(0) } // every path a C string, in place

        // --cached also lists tracked files deleted from disk: each is checked, relative to the
        // folder's descriptor (no URL or absolute path per file: there may be 200,000).
        let folder = open(root.path, O_RDONLY | O_DIRECTORY)
        guard folder >= 0 else { return nil }
        defer { close(folder) }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [String] in
            guard let base = bytes.baseAddress else { return [] }
            var paths: [String] = []
            var start = 0
            while start < bytes.count {
                let name = (base + start).assumingMemoryBound(to: CChar.self)
                let length = strlen(name)
                defer { start += length + 1 }
                guard length > 0, faccessat(folder, name, F_OK, 0) == 0 else { continue }
                let path = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<(start + length)]), as: UTF8.self)
                // A file in a merge conflict is listed once per stage, one after the other.
                if paths.last != path { paths.append(path) }
            }
            return paths
        }
    }

    /// Walks the tree with readdir (which says what is a folder): no URL or resource lookup
    /// per file. Symbolic links aren't followed (a linked folder is listed like a file).
    private static func walk(root: URL) -> [String] {
        var result: [String] = []
        // Folders still to read: their path, and the same from the root ("" or "sub/dir/").
        var pending = [(path: root.standardizedFileURL.path, prefix: "")]
        while let (path, prefix) = pending.popLast() {
            guard let directory = opendir(path) else { continue }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let name = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if name == "." || name == ".." { continue }
                var type = entry.pointee.d_type
                if type == DT_UNKNOWN { // a file system that doesn't say
                    var info = stat()
                    if lstat(path + "/" + name, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { type = UInt8(DT_DIR) }
                }
                if type == DT_DIR {
                    if !ignoredDirectories.contains(name) { pending.append((path + "/" + name, prefix + name + "/")) }
                    continue
                }
                if name == ".DS_Store" { continue }
                result.append(prefix + name)
                if result.count >= maxFiles { return result }
            }
        }
        return result
    }

    /// Whether none of `paths` (from the folder) can be in the index or in git's status: git
    /// ignores them all (tracked files are never ignored), or, without a repository, each is
    /// inside a folder the walk skips.
    static func areIgnored(_ paths: [String], in repository: Git.Repository?) -> Bool {
        guard !paths.isEmpty else { return false }
        guard let repository else {
            return paths.allSatisfy { path in
                path.split(separator: "/").dropLast().contains { ignoredDirectories.contains(String($0)) }
            }
        }
        let input = Data(paths.joined(separator: "\0").utf8)
        // Prints the ignored ones (exit status 1: none); anything odd counts as not ignored.
        guard let output = Git.run(["check-ignore", "-z", "--stdin"], in: repository.root, input: input) else { return false }
        return output.split(separator: 0).count == paths.count
    }
}
