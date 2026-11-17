import AppKit
import Foundation
import Testing
@testable import Oh_My_Code

/// Several folders in one window (workspace files, the Explorer's roots, search, git, language
/// servers, tasks, sessions), and a single folder working as before.
@MainActor
struct MultiRootTests {
    /// A temporary folder named `name` (inside a folder of its own) with `files`.
    private func makeFolder(_ name: String, _ files: [String: String] = [:]) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appending(path: "omc-multi-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = parent.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func makeRepository(_ name: String, _ files: [String: String]) throws -> URL {
        let root = try makeFolder(name, files)
        try git(["init", "-q", "-b", "main"], in: root)
        try git(["add", "-A"], in: root)
        try git(["commit", "-q", "-m", "first"], in: root)
        return root
    }

    /// An untitled workspace of `folders`.
    private func openWorkspace(_ folders: [URL]) -> Workspace {
        let workspace = Workspace()
        workspace.openFolder(folders[0])
        for folder in folders.dropFirst() { workspace.addFolder(folder) }
        return workspace
    }

    // MARK: Workspace files

    @Test func workspaceFileRoundTripsWithRelativePaths() throws {
        let base = try makeFolder("project")
        let app = base.appending(path: "app"), api = base.deletingLastPathComponent().appending(path: "api")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        let fileURL = base.appending(path: "Team.omc-workspace")
        let file = WorkspaceFile.make(folders: [(app, nil), (api, "API")], savingAt: fileURL,
                                      settingsJSON: Data(#"{"wordWrap":"on"}"#.utf8))
        #expect(file.folders == [.init(path: "app", name: nil), .init(path: "../api", name: "API")])
        try file.data().write(to: fileURL)

        let read = try WorkspaceFile(contentsOf: fileURL)
        #expect(read.folders == file.folders)
        #expect(read.settings.wordWrap == .on)
        let resolved = read.resolvedFolders(relativeTo: fileURL)
        #expect(resolved.map(\.url.path) == [app.standardizedFileURL.path, api.standardizedFileURL.path])
        #expect(resolved.map(\.name) == [nil, "API"])
        // Far apart: an absolute path.
        #expect(WorkspaceFile.relativePath(from: URL(filePath: "/a/b"), to: URL(filePath: "/c/d")) == "/c/d")
    }

    @Test func opensAVSCodeWorkspaceIgnoringWhatItDoesntKnow() throws {
        let web = try makeFolder("web", ["index.ts": "x\n"])
        let parent = web.deletingLastPathComponent()
        let server = parent.appending(path: "server")
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        let fileURL = parent.appending(path: "All.code-workspace")
        try """
        // VS Code writes comments and trailing commas
        {
          "folders": [
            { "path": "web" },
            { "uri": "\(server.absoluteString)", "name": "Backend" },
            { "path": "missing" },
          ],
          "settings": { "editor.fontSize": 14, "wordWrap": "on" },
          "extensions": { "recommendations": ["x.y"] },
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)
        #expect(WorkspaceFile.isWorkspaceFile(fileURL) && OpenRequest(url: fileURL).isWorkspaceFile)

        let workspace = Workspace()
        #expect(workspace.openWorkspace(file: fileURL))
        // The missing folder is left out; the given name is the folder's label.
        #expect(workspace.folders.map(\.lastPathComponent) == ["web", "server"])
        #expect(workspace.roots.folders.map(\.label) == ["web", "Backend"])
        #expect(workspace.displayName == "All" && workspace.workspaceFile?.lastPathComponent == "All.code-workspace")
        #expect(workspace.workspaceSettings.wordWrap == .on)
        #expect(workspace.sessionKey.hasPrefix("workspace-"))
        #expect(RecentFolders.shared.urls.first?.lastPathComponent == "All.code-workspace")
        #expect(RecentFolders.symbol(for: fileURL) != RecentFolders.symbol(for: web))
        // Opened again (Finder, omc): this window; another workspace file: an empty window or a new one.
        #expect(OpenRouter.route(OpenRequest(url: fileURL), isDirectory: false, workspaces: [workspace]) == .focus(ObjectIdentifier(workspace)))
        let empty = Workspace()
        let other = parent.appending(path: "Other.omc-workspace")
        try #"{ "folders": [{ "path": "web" }] }"#.write(to: other, atomically: true, encoding: .utf8)
        #expect(OpenRouter.route(OpenRequest(url: other), isDirectory: false, workspaces: [workspace, empty]) == .openIn(ObjectIdentifier(empty)))
        #expect(OpenRouter.route(OpenRequest(url: other), isDirectory: false, workspaces: [workspace]) == .newWindow)
    }

    @Test func addingRemovingAndSavingFolders() throws {
        let a = try makeFolder("a", ["one.txt": "1\n"]), b = try makeFolder("b", ["two.txt": "2\n"])
        let workspace = Workspace()
        workspace.openFolder(a)
        #expect(!workspace.isMultiRoot && workspace.displayName == "a")
        workspace.addFolder(b)
        #expect(workspace.isMultiRoot && workspace.displayName == "Untitled (Workspace)")
        #expect(workspace.rootURL == a && workspace.rootNodes.count == 2)
        #expect(workspace.sessionKey.hasPrefix("untitled-"))

        let fileURL = a.deletingLastPathComponent().appending(path: "Both.omc-workspace")
        #expect(workspace.saveWorkspace(as: fileURL))
        #expect(workspace.displayName == "Both" && workspace.sessionKey.hasPrefix("workspace-"))
        #expect(try WorkspaceFile(contentsOf: fileURL).folders.map(\.path) == ["a", "../" + b.deletingLastPathComponent().lastPathComponent + "/b"])

        // An open file in the folder removed closes; the workspace file follows.
        workspace.open(fileAt: b.appending(path: "two.txt"))
        workspace.removeFolder(b)
        #expect(workspace.folders == [a] && workspace.documents.isEmpty)
        #expect(try WorkspaceFile(contentsOf: fileURL).folders.count == 1)
    }

    // MARK: Paths, containment

    @Test func labelsAndPathsAcrossFolders() throws {
        let one = URL(filePath: "/x/app"), two = URL(filePath: "/y/app"), three = URL(filePath: "/z/api")
        let roots = WorkspaceRoots(urls: [one, two, three], names: [three: "Server/API"])
        // Same name: told apart by the parent's; "/" can't be in a label.
        #expect(roots.folders.map(\.label) == ["app (x)", "app (y)", "Server-API"])
        #expect(roots.path(of: URL(filePath: "/y/app/src/main.ts")) == "app (y)/src/main.ts")
        #expect(roots.url(for: "app (x)/src/main.ts")?.path == "/x/app/src/main.ts")
        #expect(roots.path(of: URL(filePath: "/elsewhere/a.ts")) == nil)
        // One folder: paths as always.
        let single = WorkspaceRoots(single: one)
        #expect(single.path(of: URL(filePath: "/x/app/src/main.ts")) == "src/main.ts")
        #expect(single.url(for: "src/main.ts")?.path == "/x/app/src/main.ts")
    }

    @Test func fileOperationsWorkInEveryFolderAndBetweenThem() async throws {
        let a = try makeFolder("a", ["move.txt": "m\n", "dir/keep.txt": "k\n"]), b = try makeFolder("b", ["b.txt": "b\n"])
        let outside = try makeFolder("outside", ["in.txt": "o\n"])
        let workspace = openWorkspace([a, b])
        // New files in the second folder.
        let created = try #require(workspace.newFile(in: b, named: "new.txt"))
        #expect(FileManager.default.fileExists(atPath: created.path))
        // Dropped from one folder onto the other: moved, not copied.
        let moved = await workspace.move(a.appending(path: "move.txt"), into: b)
        #expect(moved?.path == b.appending(path: "move.txt").path)
        #expect(!FileManager.default.fileExists(atPath: a.appending(path: "move.txt").path))
        // From outside: copied.
        let copied = await workspace.move(outside.appending(path: "in.txt"), into: b)
        #expect(copied != nil && FileManager.default.fileExists(atPath: outside.appending(path: "in.txt").path))
        // Not out of the folders, and a folder of the workspace itself doesn't move.
        #expect(await workspace.move(b.appending(path: "b.txt"), to: outside.appending(path: "b.txt")) == nil)
        #expect(await workspace.move(b, into: a.appending(path: "dir")) == nil)
        #expect(workspace.copy(outside.appending(path: "in.txt"), into: outside) == nil)
        // Renames in the second folder.
        #expect(await workspace.rename(b.appending(path: "b.txt"), to: "c.txt")?.lastPathComponent == "c.txt")
    }

    @Test func containmentAcceptsEveryFolderAndNothingElse() throws {
        let a = try makeFolder("a", ["x.txt": "x"]), b = try makeFolder("b", ["y.txt": "y"])
        let outside = try makeFolder("outside", ["secret.txt": "s"])
        try FileManager.default.createSymbolicLink(at: b.appending(path: "link"), withDestinationURL: outside)
        let workspace = openWorkspace([a, b])
        #expect(workspace.isInsideWorkspace(a.appending(path: "x.txt")))
        #expect(workspace.isInsideWorkspace(b.appending(path: "y.txt")))
        #expect(workspace.isInsideWorkspace(b.appending(path: "new/file.txt")))
        #expect(!workspace.isInsideWorkspace(outside.appending(path: "secret.txt")))
        // A link inside pointing outside is outside.
        #expect(!workspace.isInsideWorkspace(b.appending(path: "link/secret.txt")))
        // The Markdown preview serves files from the folders only.
        #expect(LocalFileSchemeHandler.isAllowed(b.appending(path: "y.txt"), in: workspace.folders))
        #expect(!LocalFileSchemeHandler.isAllowed(outside.appending(path: "secret.txt"), in: workspace.folders))
        #expect(!LocalFileSchemeHandler.isAllowed(b.appending(path: "link/secret.txt"), in: workspace.folders))
        // Agents: inside any folder.
        #expect(AgentClient.isInside(b.appending(path: "y.txt"), b) && !AgentClient.isInside(outside.appending(path: "secret.txt"), a))
        #expect(workspace.agentFolders == workspace.folders)
    }

    // MARK: Quick Open, search, symbols

    @Test func quickOpenLabelsAndTellsApartTheSamePath() async throws {
        let web = try makeFolder("web", ["src/index.ts": "a\n"]), api = try makeFolder("api", ["src/index.ts": "b\n"])
        let workspace = openWorkspace([web, api])
        let files = await workspace.searchableFiles()
        #expect(Set(files) == ["web/src/index.ts", "api/src/index.ts"])
        let index = try #require(workspace.fileIndex)
        let candidates = index.files.filter { $0.text.hasSuffix("src/index.ts") }
        #expect(Set(candidates.map { index.url(for: $0).path }) == [web.appending(path: "src/index.ts").path,
                                                                     api.appending(path: "src/index.ts").path])
        // The palette lists both, each under its folder.
        workspace.showPalette(.files)
        let palette = try #require(workspace.palette)
        palette.query = "index"
        #expect(try await LanguageClientTests.eventually { palette.items.count == 2 })
        #expect(Set(palette.items.compactMap(\.detail)) == ["web/src", "api/src"])
        // A recent file of the second folder is listed with its label.
        workspace.open(fileAt: api.appending(path: "src/index.ts"))
        workspace.closePalette()
        workspace.showPalette(.files)
        #expect(workspace.palette?.items.first?.id == "api/src/index.ts")
    }

    @Test func findInFilesSearchesEveryFolderOrOne() async throws {
        let web = try makeFolder("web", ["a.txt": "needle\n", "api/x.txt": "needle\n"])
        let api = try makeFolder("api", ["b.txt": "needle\n"])
        let roots = WorkspaceRoots(urls: [web, api])
        let files = roots.paths(["a.txt", "api/x.txt"], in: roots.folders[0]) + roots.paths(["b.txt"], in: roots.folders[1])
        func search(_ include: String) async throws -> [String] {
            let found = Found()
            try await TextSearch.search(SearchOptions(query: "needle", include: include), roots: roots, files: files,
                                        overrides: [:]) { batch in await found.add(batch) }
            return await found.results.sorted { $0.path < $1.path }.map(\.path)
        }
        #expect(try await search("") == ["api/b.txt", "web/a.txt", "web/api/x.txt"])
        // "api/**" is the api folder, not the web folder's "api" subfolder.
        #expect(try await search("api/**") == ["api/b.txt"])
        #expect(try await search("web") == ["web/a.txt", "web/api/x.txt"])

        // Through the panel: results grouped by folder (their paths start with it).
        let workspace = openWorkspace([web, api])
        #expect(workspace.search.folderLabels == ["web", "api"])
        workspace.search.options.query = "needle"
        #expect(try await LanguageClientTests.eventually { workspace.search.results.count == 3 && !workspace.search.isSearching })
        let first = try #require(workspace.search.results.first)
        #expect(first.path == "api/b.txt" && first.url.path == api.appending(path: "b.txt").path)
    }

    private actor Found {
        var results: [SearchFileResult] = []
        func add(_ batch: [SearchFileResult]) { results += batch }
    }

    @Test func workspaceSymbolsComeFromEveryFolder() async throws {
        let one = try makeFolder("one", ["a.swift": "func alphaOne() {}\n"])
        let two = try makeFolder("two", ["b.swift": "func alphaTwo() {}\n"])
        let workspace = openWorkspace([one, two])
        let names = await workspace.workspaceSymbols(matching: "alpha").map(\.name)
        #expect(Set(names) == ["alphaOne", "alphaTwo"])
    }

    // MARK: Git

    @Test func eachRepositoryHasItsOwnStatusAndSection() async throws {
        let web = try makeRepository("web", ["a.txt": "a\n"]), api = try makeRepository("api", ["b.txt": "b\n"])
        try git(["checkout", "-q", "-b", "feature"], in: api)
        try "changed\n".write(to: web.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "changed\n".write(to: api.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let workspace = openWorkspace([web, api])
        #expect(try await LanguageClientTests.eventually { workspace.repositories.count == 2 })
        #expect(workspace.repositories.map(\.name) == ["web", "api"])
        #expect(workspace.repositories.map(\.status.branch) == ["main", "feature"])
        // Badges from each file's own repository.
        #expect(workspace.gitStatus(for: web.appending(path: "a.txt"), isDirectory: false) == .modified)
        #expect(workspace.gitStatus(for: api.appending(path: "b.txt"), isDirectory: false) == .modified)
        // The status bar's branch is the active file's repository's.
        workspace.open(fileAt: api.appending(path: "b.txt"))
        #expect(workspace.repositoryState(for: workspace.activeFileURL)?.status.branch == "feature")
        // The current repository is the first; picking the other one switches the panel.
        #expect(workspace.gitStatus?.branch == "main")
        let second = try #require(workspace.repositories.last)
        workspace.selectRepository(second)
        #expect(workspace.gitStatus?.branch == "feature")
        // Staging in one repository leaves the other alone.
        workspace.stage(["b.txt"], in: second.repository)
        #expect(try await LanguageClientTests.eventually {
            workspace.repositories.last?.status.stagedChanges.map(\.path) == ["b.txt"] && !workspace.isRunningGitCommand
        })
        #expect(workspace.repositories.first?.status.stagedChanges.isEmpty == true)
        #expect(try git(["diff", "--cached", "--name-only"], in: web).isEmpty)
        // The gutter compares each file with its own repository's index.
        let document = try #require(workspace.document(matching: api.appending(path: "b.txt")))
        #expect(try await LanguageClientTests.eventually { document.diffBaseLines?.first == "changed" })
        // A file of the other repository (not the current one) still compares with its own.
        workspace.open(fileAt: web.appending(path: "a.txt"))
        let other = try #require(workspace.document(matching: web.appending(path: "a.txt")))
        #expect(try await LanguageClientTests.eventually { other.diffBaseLines?.first == "a" })
    }

    @Test func twoFoldersInOneRepositoryShareASection() async throws {
        let repository = try makeRepository("mono", ["front/a.txt": "a\n", "back/b.txt": "b\n"])
        try "x\n".write(to: repository.appending(path: "back/b.txt"), atomically: true, encoding: .utf8)
        let workspace = openWorkspace([repository.appending(path: "front"), repository.appending(path: "back")])
        #expect(try await LanguageClientTests.eventually { workspace.repositories.count == 1 })
        #expect(workspace.repositories.first?.folders.count == 2 && workspace.repositories.first?.name == "mono")
        #expect(workspace.gitStatus(for: repository.appending(path: "back/b.txt"), isDirectory: false) == .modified)
        #expect(workspace.gitStatus(for: repository.appending(path: "front/a.txt"), isDirectory: false) == nil)
    }

    // MARK: Language servers

    private func server(workspaceFolders: Bool) -> LanguageServerConfig {
        let fake = LanguageClientTests.fakeServer
        return LanguageServerConfig(name: fake.name, command: fake.command + (workspaceFolders ? ["--workspace-folders"] : []),
                                    languages: fake.languages)
    }

    private func reported(_ client: LanguageClient) async throws -> [String: Any] {
        try #require(try await client.request("omc/workspaceFolders", params: [String: Any]()) as? [String: Any])
    }

    @Test func aServerTakingSeveralFoldersIsSharedAndHearsChanges() async throws {
        let one = try makeFolder("one", ["a.swift": "let a = 1\n"]), two = try makeFolder("two", ["b.swift": "let b = 1\n"])
        let three = try makeFolder("three")
        let workspace = Workspace()
        workspace.languageServerOverrides[.swift] = server(workspaceFolders: true)
        workspace.openFolder(one)
        workspace.addFolder(two)
        workspace.open(fileAt: one.appending(path: "a.swift"))
        workspace.open(fileAt: two.appending(path: "b.swift"))
        let a = try #require(workspace.document(matching: one.appending(path: "a.swift")))
        let b = try #require(workspace.document(matching: two.appending(path: "b.swift")))
        #expect(try await LanguageClientTests.eventually { a.languageClient?.state == .ready && b.languageClient != nil })
        #expect(a.languageClient === b.languageClient && workspace.languageClients.count == 1)
        let client = try #require(a.languageClient)
        #expect(client.supportsWorkspaceFolders)
        let started = try await reported(client)
        #expect(started["initial"] as? [String] == workspace.folders.map(\.absoluteString))

        workspace.addFolder(three)
        workspace.removeFolder(two)
        #expect(try await LanguageClientTests.eventually { client.workspaceFolders.count == 2 })
        var changes: [[String: [String]]] = []
        for _ in 0..<50 {
            changes = try await reported(client)["changes"] as? [[String: [String]]] ?? []
            if changes.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(changes.first?["added"] == [Workspace.folderURL(three).absoluteString])
        #expect(changes.last?["removed"] == [Workspace.folderURL(two).absoluteString])
    }

    @Test func aServerTakingOneFolderGetsOneClientPerFolder() async throws {
        let one = try makeFolder("one", ["a.swift": "let a = 1\n"]), two = try makeFolder("two", ["b.swift": "let b = 1\n"])
        let workspace = Workspace()
        workspace.languageServerOverrides[.swift] = server(workspaceFolders: false)
        workspace.openFolder(one)
        workspace.addFolder(two)
        workspace.open(fileAt: one.appending(path: "a.swift"))
        workspace.open(fileAt: two.appending(path: "b.swift"))
        let a = try #require(workspace.document(matching: one.appending(path: "a.swift")))
        let b = try #require(workspace.document(matching: two.appending(path: "b.swift")))
        #expect(try await LanguageClientTests.eventually { a.languageClient?.state == .ready && b.languageClient?.state == .ready })
        #expect(a.languageClient !== b.languageClient && workspace.languageClients.count == 2)
        let second = try #require(b.languageClient)
        #expect(second.rootFolder.path == two.path && second.workspaceFolders.map(\.path) == [two.path])
        let report = try await reported(second)
        #expect((report["root"] as? String).map { URL(filePath: $0).standardizedFileURL.path } == two.path)
        #expect((report["documents"] as? [String])?.count == 1)
        // Its folder removed: its client stops.
        workspace.removeFolder(two)
        #expect(workspace.languageClients.count == 1)
    }

    // MARK: Tasks, terminal, settings

    @Test func tasksComeFromEveryFolderAndRunInTheirOwn() async throws {
        let tasks = #"{ "tasks": [{ "label": "where", "command": "true", "cwd": "${workspaceFolder}/sub" }] }"#
        let one = try makeFolder("one", [".omc/tasks.json": tasks]), two = try makeFolder("two", [".omc/tasks.json": tasks])
        let workspace = openWorkspace([one, two])
        let loaded = workspace.loadTasks().filter { $0.label.hasPrefix("where") }
        #expect(loaded.map(\.label) == ["where (one)", "where (two)"])
        let run = try #require(workspace.runTask(loaded[1], reveal: false))
        #expect(run.task.cwd == two.path + "/sub")
        run.terminate()

        // One folder: labels as written.
        let single = Workspace()
        single.openFolder(one)
        #expect(single.loadTasks().contains { $0.label == "where" })
    }

    @Test func settingsComeFromEachFileItsFolderOverTheWorkspaceFile() throws {
        let wraps = try makeFolder("wraps", [".omc/settings.json": #"{ "wordWrap": "on" }"#, "a.txt": "a\n"])
        let plain = try makeFolder("plain", ["b.txt": "b\n"])
        let fileURL = wraps.deletingLastPathComponent().appending(path: "S.omc-workspace")
        try WorkspaceFile.make(folders: [(wraps, nil), (plain, nil)], savingAt: fileURL,
                               settingsJSON: Data(#"{ "wordWrap": "off", "showsCodeLens": false }"#.utf8)).data().write(to: fileURL)
        let workspace = Workspace()
        #expect(workspace.openWorkspace(file: fileURL))
        #expect(workspace.settings(for: wraps.appending(path: "a.txt")).wordWrap == .on)
        #expect(workspace.settings(for: plain.appending(path: "b.txt")).wordWrap == .off)
        #expect(workspace.settings(for: plain.appending(path: "b.txt")).showsCodeLens == false)
        workspace.open(fileAt: plain.appending(path: "b.txt"))
        #expect(workspace.activeDocument?.projectSettings.wordWrap == .off)
        #expect(workspace.isProjectSettingsFile(wraps.appending(path: ".omc/settings.json")))
    }

    // MARK: Sessions

    @Test func anUnsavedWorkspaceComesBackAtLaunch() async throws {
        let a = try makeFolder("a", ["a.txt": "on disk\n"]), b = try makeFolder("b", ["b.txt": "b\n"])
        let workspace = openWorkspace([a, b])
        let id = try #require(workspace.untitledWorkspaceID)
        workspace.open(fileAt: b.appending(path: "b.txt"))
        let document = try #require(workspace.activeDocument)
        _ = try document.apply([TextReplacement(range: NSRange(location: 0, length: 0), text: "unsaved ")], actionName: "Edit")
        workspace.keepSession(wasOpen: true, force: true)
        let session = try #require(SessionStore.shared.read(workspace.sessionKey))
        #expect(session.folders == [a.path, b.path] && session.untitledWorkspaceID == id.uuidString)

        var requests: [OpenRequest] = []
        Workspace.reopenLastSessions { requests.append($0) }
        let request = try #require(requests.first { $0.workspace?.id == id })
        #expect(request.workspace?.folders.map(\.path) == [a.path, b.path])
        workspace.stopEverything()

        // A new window opens it: the folders, the tab and its unsaved text.
        let restored = Workspace()
        let untitled = try #require(request.workspace)
        restored.openUntitledWorkspace(folders: untitled.folders, names: untitled.names, id: untitled.id)
        #expect(restored.folders.map(\.path) == [a.path, b.path] && restored.untitledWorkspaceID == id)
        #expect(restored.document(matching: b.appending(path: "b.txt"))?.textStorage.string == "unsaved b\n")
        // The router sends it to that window, not a new one.
        #expect(OpenRouter.route(request, isDirectory: true, workspaces: [restored]) == .focus(ObjectIdentifier(restored)))
        SessionStore.shared.remove(restored.sessionKey)
    }

    // MARK: One folder

    @Test func aSingleFolderWorksAsBefore() async throws {
        let root = try makeFolder("solo", ["src/a.txt": "a\n"])
        let workspace = Workspace()
        workspace.openFolder(root)
        #expect(workspace.folders == [root] && !workspace.isMultiRoot && workspace.workspaceFile == nil)
        #expect(workspace.untitledWorkspaceID == nil && workspace.displayName == "solo")
        #expect(workspace.sessionKey == SessionStore.key(root: root, windowID: workspace.id))
        #expect(workspace.relativePath(of: root.appending(path: "src/a.txt")) == "src/a.txt")
        #expect(workspace.relativePath(of: root) == nil)
        #expect(await workspace.searchableFiles() == ["src/a.txt"])
        #expect(workspace.loadTasks().allSatisfy { $0.folder == root })
        let (session, _) = workspace.currentSession(wasOpen: true)
        #expect(session.folders == nil && session.untitledWorkspaceID == nil && session.root == root.path)
        #expect(workspace.search.folderLabels.isEmpty)
    }
}
