import AppKit
import SwiftTreeSitter
import Testing
@testable import Oh_My_Code

/// The repository (for the build script and the grammar sources the tests compile).
private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private let fixtures = repository.appending(path: "OhMyCodeTests/Fixtures")

private func temporaryFolder(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "omc-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Runs build-tree-sitter-grammar.sh (clang, ad hoc signing) on a fixture grammar.
private func buildGrammar(_ fixture: String, into output: URL, cflags: String = "") throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [repository.appending(path: "ExtensionAPI/tools/build-tree-sitter-grammar.sh").path,
                         fixtures.appending(path: fixture).path, output.path]
    var environment = ProcessInfo.processInfo.environment
    environment["CFLAGS"] = cflags
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "build", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
    }
}

/// An extension folder with the JSON fixture parser built into parser/ (its symbol renamed, so
/// it's told apart from the app's own JSON grammar), and its queries.
private func treeSitterExtension() throws -> URL {
    let folder = try temporaryFolder("ts-ext")
    try buildGrammar("tree-sitter-json", into: folder.appending(path: "parser/libtree-sitter-omcjson.dylib"),
                     cflags: "-Dtree_sitter_json=tree_sitter_omcjson")
    try FileManager.default.createDirectory(at: folder.appending(path: "queries"), withIntermediateDirectories: true)
    for query in ["highlights", "folds"] {
        try FileManager.default.copyItem(at: fixtures.appending(path: "tree-sitter-json/queries/\(query).scm"),
                                         to: folder.appending(path: "queries/\(query).scm"))
    }
    return folder
}

private let hasClang = FileManager.default.isExecutableFile(atPath: "/usr/bin/clang")

@Suite(.serialized, .enabled(if: hasClang, "needs clang to build the test parser"))
struct TreeSitterGrammarTests {
    private func contribution(_ folder: URL, symbol: String = "tree_sitter_omcjson", permitted: Bool = true) -> TreeSitterGrammarContribution {
        TreeSitterGrammarContribution(language: "omcjson", library: "parser/libtree-sitter-omcjson.dylib", symbol: symbol,
                                      queries: ["highlights": folder.appending(path: "queries/highlights.scm"),
                                                "folds": folder.appending(path: "queries/folds.scm")],
                                      extensionID: "test.omcjson", folder: folder, permitted: permitted)
    }

    @Test func buildsAUniversalLibraryAndLoadsIt() async throws {
        let folder = try treeSitterExtension()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = folder.appending(path: "parser/libtree-sitter-omcjson.dylib")
        let lipo = Process()
        lipo.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        lipo.arguments = ["-archs", library.path]
        let pipe = Pipe()
        lipo.standardOutput = pipe
        try lipo.run()
        lipo.waitUntilExit()
        let archs = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(archs.contains("arm64") && archs.contains("x86_64"))

        let language = try NativeGrammarLoader.loadLanguage(library: "parser/libtree-sitter-omcjson.dylib", symbol: "tree_sitter_omcjson",
                                                            folder: folder, permitted: true)
        #expect(NativeGrammarLoader.supportedABIVersions.contains(language.ABIVersion))

        // Its queries drive highlighting and folding like a built-in grammar's.
        let grammar = try NativeGrammarLoader.loadGrammar(contribution(folder))
        let engine = try #require(SyntaxEngine(grammar: grammar))
        let text = "{\n  \"a\": [1,\n    2,\n    true],\n  \"b\": null\n}\n" as NSString
        let highlights = try #require(await engine.process(snapshot: TextSnapshot(string: text), edits: [],
                                                           highlightRange: NSRange(location: 0, length: text.length)))
        let names = Set(highlights.map(\.name))
        #expect(names.isSuperset(of: ["string.special.key", "number", "constant.builtin"]))
        let folds = await engine.foldRegions()
        #expect(folds.contains(FoldRegion(start: 0, end: 4, kind: .code))) // the object, to the line before "}"
        #expect(folds.contains(FoldRegion(start: 1, end: 2, kind: .code))) // the array
    }

    @Test func refusesWhatItShouldNotLoad() throws {
        let folder = try treeSitterExtension()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = "parser/libtree-sitter-omcjson.dylib"
        func failure(_ body: () throws -> Any) -> NativeGrammarLoader.LoadError? {
            do { _ = try body(); return nil } catch { return error as? NativeGrammarLoader.LoadError }
        }
        #expect(failure { try NativeGrammarLoader.loadLanguage(library: library, symbol: "tree_sitter_omcjson", folder: folder, permitted: false) }
                == .permission)
        #expect(failure { try NativeGrammarLoader.loadLanguage(library: library, symbol: "tree_sitter_nothere", folder: folder, permitted: true) }
                == .missingSymbol("tree_sitter_nothere"))
        #expect(failure { try NativeGrammarLoader.loadLanguage(library: library, symbol: "abort", folder: folder, permitted: true) }
                == .invalidSymbol("abort"))
        #expect(failure { try NativeGrammarLoader.loadLanguage(library: "parser/none.dylib", symbol: "tree_sitter_x", folder: folder, permitted: true) }
                == .missing("parser/none.dylib"))
        // A library outside the extension's folder, even through a link.
        let outside = try temporaryFolder("ts-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.copyItem(at: folder.appending(path: library), to: outside.appending(path: "lib.dylib"))
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "linked.dylib"), withDestinationURL: outside.appending(path: "lib.dylib"))
        #expect(failure { try NativeGrammarLoader.loadLanguage(library: "../\(outside.lastPathComponent)/lib.dylib", symbol: "tree_sitter_omcjson",
                                                               folder: folder, permitted: true) }
                == .outside("../\(outside.lastPathComponent)/lib.dylib"))
        #expect(failure { try NativeGrammarLoader.loadLanguage(library: "linked.dylib", symbol: "tree_sitter_omcjson", folder: folder, permitted: true) }
                == .outside("linked.dylib"))
        // A parser for an ABI the runtime can't read.
        try buildGrammar("tree-sitter-future", into: folder.appending(path: "parser/libfuture.dylib"))
        #expect(failure { try NativeGrammarLoader.loadLanguage(library: "parser/libfuture.dylib", symbol: "tree_sitter_future", folder: folder, permitted: true) }
                == .incompatibleABI(99))
        // A query that doesn't compile says which.
        try "(no_such_node) @x".write(to: folder.appending(path: "queries/folds.scm"), atomically: true, encoding: .utf8)
        if case .query(let name, _)? = failure({ try NativeGrammarLoader.loadGrammar(contribution(folder)) }) {
            #expect(name == "folds")
        } else {
            Issue.record("expected a query error")
        }
    }

    @Test func manifestsNeedTheNativeCodePermission() throws {
        let folder = try temporaryFolder("ts-manifest")
        defer { try? FileManager.default.removeItem(at: folder) }
        try "".write(to: folder.appending(path: "main.js"), atomically: true, encoding: .utf8)
        func manifest(permissions: String, library: String = "./parser/lib.dylib") throws -> ExtensionManifest {
            try """
            { "id": "test.ts", "name": "TS", "version": "1", "main": "main.js", "permissions": \(permissions),
              "contributes": { "treeSitterGrammars": [{ "language": "foo", "library": "\(library)", "symbol": "tree_sitter_foo",
                                                        "queries": { "highlights": "./queries/highlights.scm" } }] } }
            """.write(to: folder.appending(path: "extension.json"), atomically: true, encoding: .utf8)
            return try ExtensionManifest.load(from: folder)
        }
        #expect(throws: ExtensionManifest.ValidationError.needsPermission("A tree-sitter grammar", .nativeCode)) {
            try manifest(permissions: "[]")
        }
        #expect(throws: ExtensionManifest.ValidationError.outside("../lib.dylib")) {
            try manifest(permissions: #"["nativeCode"]"#, library: "../lib.dylib")
        }
        let loaded = try manifest(permissions: #"["nativeCode"]"#)
        let contributions = loaded.grammarContributions(in: folder).treeSitter
        #expect(contributions.count == 1 && contributions[0].permitted && contributions[0].symbol == "tree_sitter_foo")
        #expect(ExtensionManifest.Permission.nativeCode.title.contains("native code"))
    }
}

@Suite struct HighlightingPrecedenceTests {
    private func textMate(_ language: String, override: Bool = false) -> TextMateGrammarContribution {
        TextMateGrammarContribution(language: language, scopeName: "source.\(language)", url: URL(fileURLWithPath: "/dev/null"),
                                    override: override, extensionID: "test.tm")
    }

    private func treeSitter(_ language: String, override: Bool = false) -> TreeSitterGrammarContribution {
        TreeSitterGrammarContribution(language: language, library: "x.dylib", symbol: "tree_sitter_x", override: override,
                                      extensionID: "test.ts", folder: URL(fileURLWithPath: "/tmp"), permitted: true)
    }

    @Test func builtInHighlightingStaysUnlessOverriddenOrPicked() {
        let grammars = ContributedGrammars()
        grammars.setContributions(textMate: [textMate("json")], treeSitter: [treeSitter("json")], from: "test.both")
        #expect(grammars.availableEngines(for: .json) == [.builtIn, .treeSitter, .textMate])
        #expect(grammars.preference(for: .json).first == .builtIn)
        #expect(grammars.preference(for: .json, choice: "textmate").first == .textMate)
        #expect(grammars.preference(for: .json, choice: "tree-sitter") == [.treeSitter, .builtIn, .textMate])
        #expect(grammars.preference(for: .json, choice: "nonsense").first == .builtIn)

        grammars.setContributions(textMate: [textMate("json", override: true)], treeSitter: [treeSitter("json")], from: "test.both")
        #expect(grammars.preference(for: .json) == [.textMate, .builtIn, .treeSitter])
        grammars.setContributions(textMate: [textMate("json", override: true)], treeSitter: [treeSitter("json", override: true)], from: "test.both")
        #expect(grammars.preference(for: .json).first == .treeSitter)
        #expect(grammars.preference(for: .json, choice: "builtin").first == .builtIn)
    }

    @Test func aLanguageWithoutBuiltInHighlightingTakesWhatIsContributed() {
        let grammars = ContributedGrammars()
        let toy = SourceLanguage(languageId: "toyx")
        #expect(grammars.preference(for: toy).isEmpty)
        grammars.setContributions(textMate: [textMate("toyx")], treeSitter: [], from: "test.tm")
        #expect(grammars.preference(for: toy) == [.textMate])
        grammars.setContributions(textMate: [], treeSitter: [treeSitter("toyx")], from: "test.ts")
        #expect(grammars.preference(for: toy) == [.treeSitter, .textMate])
        #expect(grammars.preference(for: toy, choice: "textmate") == [.textMate, .treeSitter])
        // Removing an extension removes its grammars.
        grammars.setContributions(textMate: [], treeSitter: [], from: "test.ts")
        #expect(grammars.preference(for: toy) == [.textMate])
        #expect(grammars.injections(into: "source.toyx").isEmpty)
    }
}

@MainActor
private func eventually(_ timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now > deadline { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// Extensions' grammars color files in the editor.
@MainActor
@Suite(.serialized)
struct GrammarExtensionTests {
    private func makeStore() -> ExtensionStore {
        let name = "omc-grammar-tests-\(UUID().uuidString)"
        return ExtensionStore(directory: FileManager.default.temporaryDirectory.appending(path: name), defaults: ScratchDefaults.named(name))
    }

    private func workspace(store: ExtensionStore, files: [String: String]) throws -> (Workspace, URL) {
        let root = try temporaryFolder("grammar-ws")
        for (name, text) in files { try text.write(to: root.appending(path: name), atomically: true, encoding: .utf8) }
        let workspace = Workspace()
        workspace.extensions.store = store
        workspace.extensions.changeDelay = .milliseconds(10)
        workspace.openFolder(root)
        return (workspace, root)
    }

    @Test func theToyExampleIsColoredByItsGrammar() async throws {
        let store = makeStore()
        let template = try #require(ExtensionScaffold.languageTemplateURL)
        try store.install(from: template)
        defer {
            LanguageRegistry.shared.setContributions([], from: "examples.toy-language")
            ContributedGrammars.shared.setContributions(textMate: [], treeSitter: [], from: "examples.toy-language")
        }
        let (workspace, root) = try workspace(store: store, files: ["main.toy": "fn greet(name) do\n  print(\"hi \\n\" + name) # TODO\nend\nlet n = 42\n"])
        await workspace.extensions.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "main.toy"))
        let document = try #require(workspace.activeDocument)
        #expect(document.language.rawValue == "toy")
        #expect(try await eventually { document.highlighter?.engineKey.hasPrefix("textmate:source.toy") == true })
        let highlighter = try #require(document.highlighter)
        let text = document.textStorage.mutableString
        let highlights = await highlighter.highlights(in: NSRange(location: 0, length: text.length))
        func names(at word: String) -> [String] {
            let range = text.range(of: word)
            return highlights.filter { NSLocationInRange(range.location, $0.range) }.map(\.name)
        }
        #expect(names(at: "fn").contains { $0.hasSuffix("storage.type.function.toy") })
        #expect(names(at: "greet").contains { $0.hasSuffix("entity.name.function.toy") })
        #expect(names(at: "\\n").contains { $0.hasSuffix("constant.character.escape.toy") })
        #expect(names(at: "TODO").contains { $0.hasSuffix("keyword.other.todo.toy") })
        #expect(names(at: "42").contains { $0.hasSuffix("constant.numeric.toy") })
        // The theme colors the scopes (built-in themes by role).
        let keyword = try #require(names(at: "fn").first)
        #expect(EditorTheme.color(forCapture: keyword) == EditorTheme.current.syntax["keyword"])

        // Developer: Inspect Editor Tokens and Scopes.
        let inspection = await document.inspectTokens(at: text.range(of: "greet").location + 1)
        #expect(inspection.text == "greet")
        #expect(inspection.engine == "TextMate grammar source.toy")
        #expect(inspection.scopes == ["entity.name.function.toy", "source.toy"])
        #expect(inspection.colorSource == "scope → function")
        #expect(inspection.summary.contains("textmate scopes:\n  entity.name.function.toy\n  source.toy"))
        #expect(inspection.summary.contains("language: Toy (toy)"))

        // Typing re-tokenizes: a new string colors as one.
        let end = text.length
        document.textStorage.replaceCharacters(in: NSRange(location: end, length: 0), with: "let s = \"x\"\n")
        let after = await highlighter.highlights(in: NSRange(location: end, length: text.length - end))
        #expect(after.contains { $0.name.hasSuffix("string.quoted.double.toy") && $0.range.location == end + 9 })
    }

    @Test func aContributedGrammarDoesNotReplaceBuiltInHighlightingUnlessPicked() async throws {
        let store = makeStore()
        let folder = try temporaryFolder("tm-json")
        try "".write(to: folder.appending(path: "main.js"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: fixtures.appending(path: "textmate/json.tmLanguage.json"), to: folder.appending(path: "json.tmLanguage.json"))
        try #"""
        { "id": "test.tmjson", "name": "TM JSON", "version": "1", "main": "main.js",
          "contributes": { "grammars": [{ "language": "json", "scopeName": "source.json.test", "path": "./json.tmLanguage.json" }] } }
        """#.write(to: folder.appending(path: "extension.json"), atomically: true, encoding: .utf8)
        try store.install(from: folder)
        defer {
            ContributedGrammars.shared.setContributions(textMate: [], treeSitter: [], from: "test.tmjson")
            AppSettings.shared.languageHighlighting = [:]
        }
        let (workspace, root) = try workspace(store: store, files: ["a.json": "{ \"a\": 1 }\n"])
        await workspace.extensions.waitUntilIdle()
        workspace.open(fileAt: root.appending(path: "a.json"))
        let document = try #require(workspace.activeDocument)
        #expect(try await eventually { ContributedGrammars.shared.textMateContribution(for: .json) != nil })
        #expect(document.highlighter?.engineKey == "builtin")
        // Picked in Settings ▸ Languages: the open file switches.
        AppSettings.shared.languageHighlighting = ["json": "textmate"]
        #expect(try await eventually { document.highlighter?.engineKey.hasPrefix("textmate:source.json.test") == true })
        let highlights = await document.highlighter!.highlights(in: NSRange(location: 0, length: document.textStorage.length))
        #expect(highlights.contains { $0.name.hasSuffix("constant.numeric.json") })
        AppSettings.shared.languageHighlighting = [:]
        #expect(try await eventually { document.highlighter?.engineKey == "builtin" })
    }
}

@MainActor
@Suite struct VSCodeExtensionImportTests {
    @Test func convertsAndInstallsAnUnpackedVSCodeExtension() throws {
        let staging = try temporaryFolder("vscode-import")
        defer { try? FileManager.default.removeItem(at: staging) }
        let source = try #require(Bundle(for: GrammarBundleToken.self).resourceURL?.appending(path: "Fixtures/vscode-extension"))
        let result = try VSCodeExtensionImporter.convert(source, into: staging)
        let manifest = result.manifest
        #expect(manifest.id == "acme.vscode-acme-lang" && manifest.name == "Acme Language" && manifest.version == "2.1.0")
        #expect(manifest.languages.map(\.id) == ["acme"] && manifest.languages.first?.configuration == "./language-configuration.json")
        #expect(manifest.textMateGrammars.map(\.scopeName) == ["source.acme"])
        #expect(manifest.textMateGrammars.first?.embeddedLanguages == ["meta.embedded.sql": "sql"])
        #expect(manifest.snippetFiles.map(\.path) == ["./snippets/acme.json"])
        #expect(manifest.commands.isEmpty && manifest.grantedPermissions.isEmpty)
        #expect(result.warnings.contains { $0.contains("YAML") })
        #expect(result.warnings.contains { $0.contains("missing.json") })
        #expect(result.warnings.contains { $0.contains("code") })
        for file in ["syntaxes/acme.tmLanguage.json", "language-configuration.json", "snippets/acme.json", "LICENSE", "extension.js"] {
            #expect(FileManager.default.fileExists(atPath: result.folder.appending(path: file).path), "\(file)")
        }
        // It installs like any extension, and its grammar and language configuration load.
        let name = "omc-import-store-\(UUID().uuidString)"
        let store = ExtensionStore(directory: FileManager.default.temporaryDirectory.appending(path: name), defaults: ScratchDefaults.named(name))
        let installed = try store.install(from: result.folder)
        var problems: [String] = []
        let languages = installed.manifest.languageContributions(in: installed.folder, problems: &problems)
        #expect(problems.isEmpty && languages.first?.configuration?.comments?.lineComment == "--")
        let grammar = try TextMateRawGrammar.load(try #require(installed.manifest.grammarContributions(in: installed.folder).textMate.first).url)
        #expect(grammar.scopeName == "source.acme")
    }

    @Test func refusesFoldersWithoutALanguageExtension() throws {
        let folder = try temporaryFolder("vscode-empty")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: VSCodeExtensionImporter.ImportError.self) { try VSCodeExtensionImporter.convert(folder, into: folder) }
        try #"{ "name": "x", "contributes": { "commands": [] } }"#.write(to: folder.appending(path: "package.json"), atomically: true, encoding: .utf8)
        #expect(throws: VSCodeExtensionImporter.ImportError.self) { try VSCodeExtensionImporter.convert(folder, into: folder) }
    }
}

private final class GrammarBundleToken {}
