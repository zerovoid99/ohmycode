import AppKit

/// Explorer file operations: new files and folders, rename and move (asking the language
/// servers to update what refers to the files), the Trash, Finder, and paths.
extension Workspace {
    enum FileOperationError: LocalizedError {
        case invalidName(String)
        case exists(String)
        case outsideFolder

        var errorDescription: String? {
            switch self {
            case .invalidName(let name): "“\(name)” isn't a valid file name."
            case .exists(let name): "“\(name)” already exists there."
            case .outsideFolder: "Files can only be moved within the folder."
            }
        }
    }

    /// Asks for a name (title, suggested name); replaced in tests.
    @ObservationIgnored nonisolated(unsafe) static var promptForName: @MainActor (String, String) -> String? = { title, suggestion in
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: suggestion)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // The name without its extension selected, like Finder.
        if let dot = suggestion.lastIndex(of: "."), dot != suggestion.startIndex {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: suggestion.distance(from: suggestion.startIndex, to: dot))
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Confirms moving items to the Trash; replaced in tests.
    @ObservationIgnored nonisolated(unsafe) static var confirmTrash: @MainActor ([URL]) -> Bool = { urls in
        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to the Trash?" : "Move \(urls.count) items to the Trash?"
        alert.informativeText = "You can restore them from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains(":") else { throw FileOperationError.invalidName(name) }
        return trimmed
    }

    /// The folder new items go in, for an Explorer selection (a folder, or a file's folder).
    func folder(for selection: URL?) -> URL? {
        guard let selection else { return rootURL }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: selection.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? selection : selection.deletingLastPathComponent()
    }

    // MARK: New

    /// New File…: creates it (a name with `/` makes the folders too) and opens it.
    @discardableResult
    func newFile(in folder: URL, named name: String) -> URL? {
        do {
            let path = try Self.validName(name)
            let url = folder.appending(path: path)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw FileOperationError.exists(path) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
            reloadTree(around: url)
            open(fileAt: url)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func newFolder(in folder: URL, named name: String) -> URL? {
        do {
            let path = try Self.validName(name)
            let url = folder.appending(path: path, directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw FileOperationError.exists(path) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            reloadTree(around: url)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func promptNewFile(in selection: URL?) {
        guard let folder = folder(for: selection), let name = Self.promptForName("New File", "") else { return }
        newFile(in: folder, named: name)
    }

    func promptNewFolder(in selection: URL?) {
        guard let folder = folder(for: selection), let name = Self.promptForName("New Folder", "") else { return }
        newFolder(in: folder, named: name)
    }

    // MARK: Rename and move

    func promptRename(_ url: URL) {
        guard let name = Self.promptForName("Rename “\(url.lastPathComponent)”", url.lastPathComponent),
              name != url.lastPathComponent else { return }
        Task { await rename(url, to: name) }
    }

    @discardableResult
    func rename(_ url: URL, to name: String) async -> URL? {
        do {
            let valid = try Self.validName(name)
            return await move(url, to: url.deletingLastPathComponent().appending(path: valid))
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Dropped on a folder in the Explorer: moves there (keeping the name).
    @discardableResult
    func move(_ url: URL, into folder: URL) async -> URL? {
        guard folder.standardizedFileURL != url.deletingLastPathComponent().standardizedFileURL else { return nil }
        return await move(url, to: folder.appending(path: url.lastPathComponent))
    }

    /// Moves or renames a file or folder. Language servers that want to are asked first for the
    /// edits that keep references working (imports naming it); those are applied (unsaved,
    /// one undo step per file), the item moves, open tabs follow it, and the servers are told.
    @discardableResult
    func move(_ source: URL, to destination: URL) async -> URL? {
        do {
            guard let root = rootURL else { throw FileOperationError.outsideFolder }
            let rootPath = FileWatcher.canonicalPath(root) + "/"
            let destinationFolder = FileWatcher.canonicalPath(destination.deletingLastPathComponent()) + "/"
            guard destinationFolder.hasPrefix(rootPath) else { throw FileOperationError.outsideFolder }
            // Into itself (a folder dropped on its own child).
            guard !destinationFolder.hasPrefix(FileWatcher.canonicalPath(source) + "/") else { throw FileOperationError.outsideFolder }
            guard !FileManager.default.fileExists(atPath: destination.path)
                    || source.path.lowercased() == destination.path.lowercased() else { // case-only rename
                throw FileOperationError.exists(destination.lastPathComponent)
            }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            let renames = [(old: source, new: destination)]

            // 1. What the servers want changed first.
            for client in languageClients.values where client.state == .ready
                && client.wantsRename(of: source, isFolder: isDirectory.boolValue, notification: false) {
                if let edit = try? await client.willRenameFiles(renames), edit.editCount > 0 {
                    applyServerEdit(edit, actionName: "Update References to \(source.lastPathComponent)")
                }
            }
            // 2. The move. (The old path is resolved first: once it's gone, symlinks in it can't be.)
            // So are the open documents' paths (each resolves its own lazily).
            let oldPath = FileWatcher.canonicalPath(source)
            let affected = documents.compactMap { document -> (EditorDocument, String)? in
                let path = document.canonicalPath
                return path == oldPath || path.hasPrefix(oldPath + "/") ? (document, path) : nil
            }
            try FileManager.default.moveItem(at: source, to: destination)
            // 3. Open documents at (or under) the old path follow, unsaved text and all.
            for (document, path) in affected {
                let newURL = destination.appending(path: String(path.dropFirst(oldPath.count)))
                guard let moved = try? EditorDocument(url: path == oldPath ? destination : newURL) else { continue }
                if document.isDirty {
                    _ = try? moved.apply([TextReplacement(range: NSRange(location: 0, length: moved.textStorage.length),
                                                          text: document.textStorage.string)], actionName: "Unsaved Changes")
                }
                replaceDocument(document, with: moved)
            }
            // 4. Servers hear it happened.
            for client in languageClients.values where client.state == .ready
                && client.wantsRename(of: source, isFolder: isDirectory.boolValue, notification: true) {
                client.didRenameFiles(renames)
            }
            reloadTree(around: source)
            reloadTree(around: destination)
            refreshGit()
            return destination
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: Trash, Finder, paths

    /// Move to Trash: closes their tabs (unsaved changes are lost with the file; the Trash
    /// keeps what was saved).
    func trash(_ urls: [URL]) {
        guard !urls.isEmpty, Self.confirmTrash(urls) else { return }
        for url in urls {
            do {
                let path = FileWatcher.canonicalPath(url)
                for document in documents where document.canonicalPath == path || document.canonicalPath.hasPrefix(path + "/") {
                    discardDocument(document)
                }
                try Self.moveToTrash(url)
                reloadTree(around: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        refreshGit()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ url: URL, relative: Bool) {
        let text = relative ? (relativePath(of: url) ?? url.path) : url.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Shows a change in the tree at once (the file watcher catches up too).
    func reloadTree(around url: URL) {
        guard let rootNode, let root = rootURL else { return }
        let rootPath = FileWatcher.canonicalPath(root)
        let parent = FileWatcher.canonicalPath(url.deletingLastPathComponent())
        guard parent == rootPath || parent.hasPrefix(rootPath + "/") else { return }
        let relative = parent == rootPath ? "" : String(parent.dropFirst(rootPath.count + 1))
        let components = relative.isEmpty ? [] : relative.split(separator: "/").map(String.init)
        rootNode.loadedNode(atRelativePath: components)?.reloadChildren()
    }
}
