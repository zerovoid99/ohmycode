import AppKit

/// The `omc` command: a script inside the app, linked from a folder on the PATH.
enum CommandLineTool {
    static let name = "omc"

    /// The script in the app bundle.
    static var script: URL? { Bundle.main.url(forResource: name, withExtension: nil) }

    /// Where it's linked from, in order of preference: Homebrew's and the standard local bin
    /// (writable without a password on most Macs), then the user's own.
    static var directories: [URL] {
        [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin"),
         FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")]
    }

    enum InstallError: LocalizedError {
        case missingScript
        case occupied(URL)
        case noWritableFolder

        var errorDescription: String? {
            switch self {
            case .missingScript: "The omc script is missing from the app."
            case .occupied(let url): "\(url.path) is already there and isn't Oh My Code's: remove it first."
            case .noWritableFolder: "None of /opt/homebrew/bin, /usr/local/bin or ~/.local/bin can be written to."
            }
        }
    }

    /// The link already installed, if any (in `directories`).
    static func installedLink(in directories: [URL] = directories) -> URL? {
        directories.map { $0.appending(path: name) }.first { link in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))?.hasSuffix("/Contents/Resources/\(name)") == true
        }
    }

    /// Links `script` from the first writable folder (the last one is created if needed);
    /// replaces an older link to an Oh My Code. Returns the link.
    @discardableResult
    static func install(script: URL? = script, in directories: [URL] = directories) throws -> URL {
        guard let script else { throw InstallError.missingScript }
        let files = FileManager.default
        for (index, directory) in directories.enumerated() {
            let isLast = index == directories.count - 1
            if isLast, !files.fileExists(atPath: directory.path) {
                try? files.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            guard files.isWritableFile(atPath: directory.path) else { continue }
            let link = directory.appending(path: name)
            if let destination = try? files.destinationOfSymbolicLink(atPath: link.path) {
                guard destination.hasSuffix("/Contents/Resources/\(name)") || destination == script.path else { throw InstallError.occupied(link) }
                try files.removeItem(at: link)
            } else if files.fileExists(atPath: link.path) {
                throw InstallError.occupied(link)
            }
            try files.createSymbolicLink(at: link, withDestinationURL: script)
            return link
        }
        throw InstallError.noWritableFolder
    }

    /// Removes the link (only ours). Returns it, or nil if there was none.
    @discardableResult
    static func uninstall(in directories: [URL] = directories) throws -> URL? {
        guard let link = installedLink(in: directories) else { return nil }
        try FileManager.default.removeItem(at: link)
        return link
    }

    /// Whether a folder is on the login shell's PATH.
    static func isOnPath(_ directory: URL, path: String) -> Bool {
        path.split(separator: ":").contains { URL(filePath: String($0)).standardizedFileURL.path == directory.standardizedFileURL.path }
    }
}

extension Workspace {
    /// Shell Command: Install 'omc' Command.
    func installCommandLineTool() {
        Task {
            let alert = NSAlert()
            do {
                let link = try CommandLineTool.install()
                let path = await ShellEnvironment.shared.environment()["PATH"] ?? ""
                alert.messageText = "The omc command is installed"
                var text = "Linked from \(link.path). Open a folder with “omc .”, a file at a line with “omc file.swift:12”."
                if !CommandLineTool.isOnPath(link.deletingLastPathComponent(), path: path) {
                    text += "\n\n\(link.deletingLastPathComponent().path) isn't on your PATH yet: add it in your shell's profile."
                }
                alert.informativeText = text
            } catch {
                alert.alertStyle = .warning
                alert.messageText = "The omc command couldn't be installed"
                alert.informativeText = error.localizedDescription
            }
            if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    func uninstallCommandLineTool() {
        do {
            if let link = try CommandLineTool.uninstall() {
                notifyPlainly("Removed \(link.path).")
            } else {
                notifyPlainly("The omc command isn't installed.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// File: Open Recent…: picks a recent folder (opened in its window, or this one if empty).
    func pickRecentFolder() async {
        let folders = RecentFolders.shared.existing
        let items = folders.map { QuickPickItem(label: $0.lastPathComponent,
                                                description: ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) }
        guard let index = await showQuickPick(items, placeholder: "Folder to open"), folders.indices.contains(index) else { return }
        OpenRouter.shared.open(OpenRequest(url: folders[index]))
    }

    private func notifyPlainly(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
