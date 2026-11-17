import AppKit
import Testing
@testable import Oh_My_Code

private func makeFolder(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "omc-open-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, text) in files {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

@MainActor
struct OpenRequestTests {
    @Test func readsFileAndCommandURLs() throws {
        let file = try #require(OpenRequest(external: URL(filePath: "/tmp/a/../b.txt")))
        #expect(file == OpenRequest(url: URL(filePath: "/tmp/b.txt")))

        let url = try #require(URL(string: "ohmycode://open?path=%2Fwork%2Fmy%20app%2Fmain.swift&line=12&column=5&new=1"))
        let request = try #require(OpenRequest(external: url))
        #expect(request.url.path == "/work/my app/main.swift" && request.line == 12 && request.column == 5)
        #expect(request.newWindow && !request.reuseWindow)
        // What the omc command sends reads back the same.
        #expect(OpenRequest(external: request.commandURL) == request)

        #expect(OpenRequest(external: URL(string: "ohmycode://open?path=relative")!) == nil)
        #expect(OpenRequest(external: URL(string: "https://example.com")!) == nil)
        #expect(OpenRequest(external: URL(string: "ohmycode://open?path=/a&line=0")!)?.line == nil)
    }

    @Test func routesToTheRightWindow() throws {
        let root = try makeFolder(["src/a.swift": "a\n", "README.md": "#\n"])
        let other = try makeFolder(["b.txt": "b\n"])
        let withFolder = Workspace()
        withFolder.openFolder(root)
        let empty = Workspace()
        let windows = [withFolder, empty]
        let id = { (workspace: Workspace) in ObjectIdentifier(workspace) }

        // The folder: its window. Another folder: the empty window, else a new one.
        #expect(OpenRouter.route(OpenRequest(url: root), isDirectory: true, workspaces: windows) == .focus(id(withFolder)))
        #expect(OpenRouter.route(OpenRequest(url: other), isDirectory: true, workspaces: windows) == .openIn(id(empty)))
        #expect(OpenRouter.route(OpenRequest(url: other), isDirectory: true, workspaces: [withFolder]) == .newWindow)
        #expect(OpenRouter.route(OpenRequest(url: other, reuseWindow: true), isDirectory: true, workspaces: [withFolder]) == .openIn(id(withFolder)))
        #expect(OpenRouter.route(OpenRequest(url: root, newWindow: true), isDirectory: true, workspaces: windows) == .newWindow)

        // A file: the window whose folder has it (even under /private), else the empty one.
        let file = URL(filePath: FileWatcher.canonicalPath(root.appending(path: "src/a.swift")))
        #expect(OpenRouter.route(OpenRequest(url: file), isDirectory: false, workspaces: [empty, withFolder]) == .focus(id(withFolder)))
        let loose = other.appending(path: "b.txt")
        #expect(OpenRouter.route(OpenRequest(url: loose), isDirectory: false, workspaces: windows) == .openIn(id(empty)))
        #expect(OpenRouter.route(OpenRequest(url: loose), isDirectory: false, workspaces: [withFolder]) == .newWindow)
        #expect(OpenRouter.route(OpenRequest(url: loose, reuseWindow: true), isDirectory: false, workspaces: [withFolder]) == .openIn(id(withFolder)))
    }

    @Test func opensFilesAtTheirPosition() throws {
        let root = try makeFolder(["a.txt": "first\nsecond line\nthird\n"])
        let workspace = Workspace()
        workspace.openFolder(root)
        OpenRouter.shared.apply(OpenRequest(url: root.appending(path: "a.txt"), line: 2, column: 4), in: workspace)
        let document = try #require(workspace.activeDocument)
        #expect(document.pendingReveal == NSRange(location: 9, length: 0))
        // Past the end of the line or file: clamped.
        OpenRouter.shared.apply(OpenRequest(url: root.appending(path: "a.txt"), line: 99, column: 99), in: workspace)
        #expect(document.pendingReveal?.location == document.textStorage.length)

        // A folder in a window that has another: that window switches to it.
        let other = try makeFolder(["b.txt": ""])
        workspace.close(document)
        OpenRouter.shared.apply(OpenRequest(url: other), in: workspace)
        #expect(workspace.rootURL == other)
        #expect(RecentFolders.shared.urls.first?.path == other.path)
    }

    @Test func remembersRecentFolders() throws {
        let suite = "omc-recent-test-\(UUID().uuidString)"
        let recent = RecentFolders(defaults: ScratchDefaults.named(suite))
        let a = try makeFolder([:]), b = try makeFolder([:])
        recent.add(a)
        recent.add(b)
        recent.add(a)
        #expect(recent.urls.map(\.path) == [a.path, b.path])
        for index in 0..<20 { recent.add(URL(filePath: "/nonexistent/\(index)")) }
        #expect(recent.urls.count == RecentFolders.limit && recent.urls.first?.path == "/nonexistent/19")
        #expect(recent.existing.isEmpty) // a and b fell off the end
        recent.add(b)
        #expect(RecentFolders(defaults: ScratchDefaults.named(suite)).urls.first?.path == b.path)
        recent.remove(b)
        recent.clear()
        #expect(recent.urls.isEmpty)
    }
}

struct CommandLineToolTests {
    /// The bundled script, run with `open` replaced by a recorder.
    private func run(_ arguments: [String], in directory: URL) throws -> (status: Int32, calls: [String], error: String) {
        let script = try #require(Bundle(for: BundleMarker.self).url(forResource: "omc", withExtension: nil)
                                  ?? Bundle.main.url(forResource: "omc", withExtension: nil))
        let log = directory.appending(path: "open-calls.txt")
        let fake = directory.appending(path: "fake-open")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        try? FileManager.default.removeItem(at: log)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = directory
        process.environment = ["OMC_OPEN_COMMAND": fake.path, "PATH": "/usr/bin:/bin"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return (process.terminationStatus, calls, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private final class BundleMarker {}

    @Test func scriptSendsTheAppWhatToOpen() throws {
        let folder = try makeFolder(["my dir/main.swift": "x\n", "weird:5": "named with a colon\n"])
        let real = FileWatcher.canonicalPath(folder)
        let app = Bundle.main.bundleURL.path

        func decoded(_ call: String) -> OpenRequest? {
            guard let url = call.components(separatedBy: " ").last.flatMap(URL.init(string:)) else { return nil }
            return OpenRequest(external: url)
        }

        var result = try run(["."], in: folder)
        #expect(result.status == 0 && result.calls.count == 1 && result.calls[0].hasPrefix("-a \(app) ohmycode://open?path=%2f"))
        #expect(decoded(result.calls[0]) == OpenRequest(url: URL(filePath: real)))

        result = try run(["-n", "my dir/main.swift:12:5", "weird:5"], in: folder)
        #expect(result.calls.count == 2)
        #expect(decoded(result.calls[0]) == OpenRequest(url: URL(filePath: real + "/my dir/main.swift"), line: 12, column: 5, newWindow: true))
        // A file that's really called "weird:5" is that file, not "weird" at line 5.
        #expect(decoded(result.calls[1]) == OpenRequest(url: URL(filePath: real + "/weird:5"), newWindow: true))

        result = try run(["-r", "notes.md:3"], in: folder)
        #expect(decoded(result.calls[0]) == OpenRequest(url: URL(filePath: real + "/notes.md"), line: 3, reuseWindow: true))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "notes.md").path)) // a new file, created empty

        result = try run(["missing/dir/x.txt"], in: folder)
        #expect(result.status == 1 && result.error.contains("doesn't exist") && result.calls.isEmpty)
        result = try run(["--bogus"], in: folder)
        #expect(result.status == 2 && result.error.contains("unknown option"))
        result = try run([], in: folder)
        #expect(result.calls == ["-a \(app)"])
    }

    @Test func installsAndRemovesTheLink() throws {
        let base = try makeFolder([:])
        let unwritable = base.appending(path: "locked"), first = base.appending(path: "bin"), last = base.appending(path: "home/.local/bin")
        try FileManager.default.createDirectory(at: unwritable, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unwritable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unwritable.path) }
        let script = URL(filePath: "/Applications/Oh My Code.app/Contents/Resources/omc")

        // The first writable folder; the last is created when needed.
        let link = try CommandLineTool.install(script: script, in: [unwritable, last])
        #expect(link.path == last.appending(path: "omc").path)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == script.path)
        #expect(CommandLineTool.installedLink(in: [unwritable, last]) == link)
        // Installed again (another copy of the app): replaced.
        let moved = URL(filePath: "/tmp/Other.app/Contents/Resources/omc")
        try CommandLineTool.install(script: moved, in: [unwritable, last])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == moved.path)

        // Someone else's omc is left alone.
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: first.appending(path: "omc"), atomically: true, encoding: .utf8)
        #expect(throws: CommandLineTool.InstallError.self) { try CommandLineTool.install(script: script, in: [first]) }

        #expect(try CommandLineTool.uninstall(in: [unwritable, last]) == link)
        #expect(!FileManager.default.fileExists(atPath: link.path) && CommandLineTool.installedLink(in: [last]) == nil)
        #expect(try CommandLineTool.uninstall(in: [first]) == nil)
        #expect(CommandLineTool.isOnPath(last, path: "/usr/bin:\(last.path)/") && !CommandLineTool.isOnPath(first, path: "/usr/bin"))
    }
}
