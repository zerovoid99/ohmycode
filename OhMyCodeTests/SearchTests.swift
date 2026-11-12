import Foundation
import Testing
@testable import Oh_My_Code

struct TextSearchTests {
    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-search-\(UUID().uuidString)")
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func search(_ options: SearchOptions, in root: URL, files: [String],
                        overrides: [String: String] = [:]) async throws -> [String: [SearchMatch]] {
        let collector = Collector()
        try await TextSearch.search(options, root: root, files: files, overrides: overrides) { await collector.add($0) }
        return await collector.byPath
    }

    @Test func literalMatchesWithUTF16Columns() async throws {
        let root = try makeFolder([
            "a.swift": "let café = \"needle\"\n// no match\nneedle needle\n",
            "b/c.md": "Needle in caps\n",
        ])
        let options = SearchOptions(query: "needle", caseSensitive: true)
        let results = try await search(options, in: root, files: ["a.swift", "b/c.md"])
        #expect(results.keys.sorted() == ["a.swift"])
        let matches = try #require(results["a.swift"])
        #expect(matches.map(\.line) == [0, 2, 2])
        // "let café = \"" is 12 UTF-16 units (é is one), 13 UTF-8 bytes.
        #expect(matches[0].column == 12 && matches[0].length == 6)
        #expect(matches.map(\.column) == [12, 0, 7])
        #expect((matches[0].preview as NSString).substring(with: matches[0].previewRange) == "needle")
    }

    @Test func caseInsensitiveWholeWordAndRegex() async throws {
        let root = try makeFolder(["x.txt": "Needle needles NEEDLE\nfoo_needle needle2\nid = 42; id = 7\n"])
        let files = ["x.txt"]
        var options = SearchOptions(query: "needle")
        #expect(try await search(options, in: root, files: files)["x.txt"]?.count == 5)

        options.wholeWord = true
        #expect(try await search(options, in: root, files: files)["x.txt"]?.map(\.column) == [0, 15])

        options = SearchOptions(query: #"id = \d+"#, regex: true)
        let regex = try await search(options, in: root, files: files)["x.txt"] ?? []
        #expect(regex.map(\.length) == [7, 6])
        #expect(regex.allSatisfy { $0.line == 2 })

        options = SearchOptions(query: "CAFÉ") // non-ASCII case folding goes through the regex path
        let unicode = try await search(options, in: try makeFolder(["u.txt": "un café ici"]), files: ["u.txt"])
        #expect(unicode["u.txt"]?.first?.column == 3)
    }

    @Test func invalidRegexThrows() async throws {
        await #expect(throws: TextSearch.SearchError.self) {
            try await TextSearch.search(SearchOptions(query: "(unclosed", regex: true), root: URL(filePath: "/tmp"),
                                        files: [], overrides: [:]) { _ in }
        }
    }

    @Test func includeExcludeBinaryAndUnsavedBuffers() async throws {
        let root = try makeFolder([
            "Sources/App.swift": "token\n", "Sources/Gen/Big.swift": "token\n",
            "Tests/AppTests.swift": "token\n", "README.md": "token\n",
        ])
        try Data([0x74, 0x6F, 0x6B, 0x65, 0x6E, 0x00, 0x01]).write(to: root.appending(path: "blob.bin")) // "token\0"
        let files = ["Sources/App.swift", "Sources/Gen/Big.swift", "Tests/AppTests.swift", "README.md", "blob.bin"]

        var options = SearchOptions(query: "token")
        #expect(try await search(options, in: root, files: files).keys.sorted()
            == ["README.md", "Sources/App.swift", "Sources/Gen/Big.swift", "Tests/AppTests.swift"]) // no binary

        options.include = "*.swift"
        options.exclude = "Gen, Tests/"
        #expect(try await search(options, in: root, files: files).keys.sorted() == ["Sources/App.swift"])

        // An unsaved editor's text wins over the file on disk.
        options = SearchOptions(query: "token")
        let results = try await search(options, in: root, files: files, overrides: ["README.md": "nothing here"])
        #expect(results["README.md"] == nil)
    }

    @Test func pathFilterGlobs() {
        #expect(PathFilter.matches("*.swift", "a/b/c.swift"))
        #expect(PathFilter.matches("build", "build/out.o"))
        #expect(!PathFilter.matches("build", "rebuild/x"))
        #expect(PathFilter.matches("Sources/", "Sources/A/b.swift"))
        #expect(PathFilter.matches("**/*Tests.swift", "Pkg/Tests/FooTests.swift"))
        #expect(!PathFilter.matches("Sources/", "Other/Sources.swift"))
    }

    @Test func searchesLargeTreeQuickly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-search-perf-\(UUID().uuidString)")
        let line = "    let value = compute(input: index, scale: 2) // ordinary source line\n"
        let body = String(repeating: line, count: 170)
        var files: [String] = []
        for i in 0..<3_000 {
            let path = "Module\(i % 40)/File\(i).swift"
            files.append(path)
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (i % 300 == 0 ? body + "let NEEDLE_marker = true\n" : body).write(to: url, atomically: false, encoding: .utf8)
        }
        let megabytes = Double(line.utf8.count * 170 * 3_000) / 1_048_576
        let clock = ContinuousClock()
        for (label, options) in [("literal", SearchOptions(query: "NEEDLE_marker", caseSensitive: true)),
                                 ("ignore-case", SearchOptions(query: "needle_MARKER")),
                                 ("regex", SearchOptions(query: #"NEEDLE_\w+"#, caseSensitive: true, regex: true))] {
            var found: [String: [SearchMatch]] = [:]
            let elapsed = try await clock.measure { found = try await search(options, in: root, files: files) }
            print("PERF search \(label): \(String(format: "%.0f", megabytes)) MB in \(elapsed), files=\(found.count)")
            #expect(found.count == 10)
            #if !DEBUG
            #expect(elapsed < .milliseconds(label == "regex" ? 1500 : 300))
            #endif
        }
    }
}

private actor Collector {
    var byPath: [String: [SearchMatch]] = [:]
    func add(_ results: [SearchFileResult]) {
        for result in results { byPath[result.path] = result.matches }
    }
}

@MainActor
struct SearchModelTests {
    @Test func findInFilesOpensMatchesAndSearchesUnsavedText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-findfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try "first line\nlet target = 1\n".write(to: root.appending(path: "src/a.swift"), atomically: true, encoding: .utf8)
        try "no hits\n".write(to: root.appending(path: "b.txt"), atomically: true, encoding: .utf8)

        let workspace = Workspace()
        workspace.openFolder(root)
        let model = workspace.search
        model.options.query = "target"
        await model.waitUntilDone()
        #expect(model.results.map(\.path) == ["src/a.swift"])
        let match = try #require(model.results.first?.matches.first)
        #expect(match.line == 1 && match.column == 4)

        // Opening a result selects the match.
        model.open(model.results[0], match)
        let document = try #require(workspace.activeDocument)
        #expect(document.url.lastPathComponent == "a.swift")

        // Unsaved edits in an open editor are what gets searched.
        workspace.open(fileAt: root.appending(path: "b.txt"))
        let other = try #require(workspace.activeDocument)
        other.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "target here\n")
        model.refresh()
        await model.waitUntilDone()
        #expect(model.results.map(\.path) == ["b.txt", "src/a.swift"])
        withExtendedLifetime(workspace) {}
    }

    @Test func typingCancelsPreviousSearchesAndInvalidRegexReports() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-findfiles2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "alpha beta\n".write(to: root.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        let model = workspace.search
        for prefix in ["a", "al", "alp", "alph", "beta"] { model.options.query = prefix }
        await model.waitUntilDone()
        #expect(model.results.first?.matches.first?.column == 6) // only the last query's results

        model.options.regex = true
        model.options.query = "(broken"
        await model.waitUntilDone()
        #expect(model.errorMessage?.contains("Invalid regular expression") == true)
        model.options.query = ""
        #expect(model.results.isEmpty && model.errorMessage == nil)
        withExtendedLifetime(workspace) {}
    }
}
