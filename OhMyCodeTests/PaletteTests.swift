import AppKit
import Foundation
import Testing
@testable import Oh_My_Code

struct FuzzyMatcherTests {
    private func rank(_ query: String, _ paths: [String]) -> [String] {
        let candidates = paths.map(FuzzyCandidate.init)
        return FuzzyMatcher.search(query, in: candidates, limit: 50).map { candidates[$0.index].text }
    }

    @Test func rejectsNonSubsequence() {
        #expect(FuzzyMatcher.match(FuzzyMatcher.prepareQuery("xyz"), FuzzyCandidate("OhMyCode/App.swift")) == nil)
    }

    @Test func caseInsensitiveAndIgnoresSpaces() {
        let match = FuzzyMatcher.match(FuzzyMatcher.prepareQuery("line IDX"), FuzzyCandidate("LineIndex.swift"))
        #expect(match?.positions == [0, 1, 2, 3, 4, 6, 8]) // L i n e I n d e x
    }

    @Test func prefersFileNameOverDirectory() {
        let ranked = rank("editor", ["OhMyCode/Editor/GutterView.swift", "OhMyCode/Workspace/EditorDocument.swift"])
        #expect(ranked.first == "OhMyCode/Workspace/EditorDocument.swift")
    }

    @Test func prefersWordBoundariesAndCamelCase() {
        let ranked = rank("fi", ["OhMyCode/Views/WelcomeView.swift", "OhMyCode/Search/FileIndex.swift",
                                 "OhMyCode/Views/FileTreeView.swift"])
        #expect(ranked.prefix(2).allSatisfy { $0.contains("File") })
        #expect(rank("ftv", ["a/FileTreeView.swift", "a/fat/v.swift"]).first == "a/FileTreeView.swift")
    }

    @Test func prefersShorterTighterMatches() {
        #expect(rank("app", ["Sources/AppDelegate.swift", "App.swift"]).first == "App.swift")
        #expect(rank("lineindex", ["OhMyCode/Workspace/LineIndex.swift", "OhMyCodeTests/LineIndexTests.swift"])
            .first == "OhMyCode/Workspace/LineIndex.swift")
    }

    @Test func searchesLargeIndexQuickly() {
        let dirs = ["Sources", "Tests", "Packages/Core", "Packages/UI/Components", "Vendor/third_party"]
        let names = ["View", "Model", "Controller", "Service", "Manager", "Helper", "Store", "Router"]
        var paths: [String] = []
        for i in 0..<100_000 {
            paths.append("\(dirs[i % dirs.count])/Module\(i % 997)/\(names[i % names.count])\(i).swift")
        }
        let candidates = paths.map(FuzzyCandidate.init)
        let clock = ContinuousClock()
        var results: [(index: Int, match: FuzzyMatch)] = []
        let elapsed = clock.measure { results = FuzzyMatcher.search("mod12cont", in: candidates, limit: 60) }
        print("PERF fuzzy search 100k paths: \(elapsed), \(results.count) results")
        #expect(!results.isEmpty)
        #if !DEBUG
        #expect(elapsed < .milliseconds(50))
        #endif
    }
}

struct FileIndexerTests {
    private func makeTree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-index-\(UUID().uuidString)")
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func git(_ args: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test func respectsGitignoreInRepositories() throws {
        let root = try makeTree(["src/main.swift", "dist/bundle.js", ".gitignore", "notes.md"])
        try "dist/\n".write(to: root.appending(path: ".gitignore"), atomically: true, encoding: .utf8)
        try git(["init", "-q"], in: root)

        let files = Set(FileIndexer.build(root: root).files.map(\.text))
        #expect(files == ["src/main.swift", ".gitignore", "notes.md"])
    }

    @Test func walksPlainFoldersSkippingDependencies() throws {
        let root = try makeTree(["a/b.txt", "node_modules/pkg/index.js", "build/out.o", "c.txt"])
        let files = Set(FileIndexer.build(root: root).files.map(\.text))
        #expect(files == ["a/b.txt", "c.txt"])
    }
}

@MainActor
struct PaletteModelTests {
    private func makeWorkspace() throws -> (Workspace, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-ws-\(UUID().uuidString)")
        for (path, text) in [("Sources/App.swift", "let a = 1\nlet b = 2\nlet c = 3\n"),
                             ("Sources/Views/MainView.swift", "struct MainView {}\n"),
                             ("README.md", "# Hi\n")] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let workspace = Workspace()
        workspace.openFolder(root)
        return (workspace, root)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func quickOpenFindsAndOpensFile() async throws {
        let (workspace, root) = try makeWorkspace()
        try await waitUntil { workspace.fileIndex != nil }

        workspace.showPalette(.files)
        let palette = try #require(workspace.palette)
        palette.query = "mainv"
        try await waitUntil { palette.items.first?.title == "MainView.swift" }
        #expect(palette.items.first?.detail == "Sources/Views")

        palette.acceptSelection()
        #expect(workspace.palette == nil)
        #expect(workspace.activeDocument?.url.standardizedFileURL.path
            == root.appending(path: "Sources/Views/MainView.swift").standardizedFileURL.path)
    }

    @Test func emptyQueryListsRecentFilesFirst() async throws {
        let (workspace, root) = try makeWorkspace()
        try await waitUntil { workspace.fileIndex != nil }
        workspace.open(fileAt: root.appending(path: "README.md"))

        workspace.showPalette(.files)
        #expect(workspace.palette?.items.first?.title == "README.md")
        #expect(workspace.palette?.items.count == 3)
    }

    @Test func commandModeFiltersAndRuns() throws {
        let (workspace, root) = try makeWorkspace()
        workspace.open(fileAt: root.appending(path: "README.md"))
        workspace.open(fileAt: root.appending(path: "Sources/App.swift"))

        workspace.showPalette(.commands)
        let palette = try #require(workspace.palette)
        #expect(palette.query == ">")
        palette.query = ">next ed"
        #expect(palette.items.first?.title == "View: Next Editor")

        palette.acceptSelection()
        #expect(workspace.palette == nil)
        #expect(workspace.activeDocument?.fileName == "README.md")
    }

    @Test func unavailableCommandsAreHidden() throws {
        let workspace = Workspace()
        workspace.showPalette(.commands)
        let titles = workspace.palette?.items.map(\.title) ?? []
        #expect(titles.contains("File: Open Folder…"))
        #expect(!titles.contains("File: Save"))
    }

    @Test func goToLineValidatesAndReveals() throws {
        let (workspace, root) = try makeWorkspace()
        workspace.open(fileAt: root.appending(path: "Sources/App.swift"))
        let document = try #require(workspace.activeDocument)

        workspace.showPalette(.goToLine)
        let palette = try #require(workspace.palette)
        palette.query = ":99"
        #expect(palette.items.isEmpty)
        #expect(palette.emptyMessage?.contains("out of range") == true)

        palette.query = ":3"
        #expect(palette.items.first?.title == "Go to line 3")

        // Attach a real editor so the reveal lands in a text view.
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        document.editor = controller

        palette.acceptSelection()
        #expect(controller.textView.selectedRange() == NSRange(location: 20, length: 0))
        #expect(document.cursorLine == 3)
    }

    @Test func selectionWrapsAround() throws {
        let (workspace, _) = try makeWorkspace()
        workspace.showPalette(.commands)
        let palette = try #require(workspace.palette)
        let count = palette.items.count
        #expect(count > 1)
        palette.moveSelection(-1)
        #expect(palette.selection == count - 1)
        palette.moveSelection(1)
        #expect(palette.selection == 0)
    }
}
