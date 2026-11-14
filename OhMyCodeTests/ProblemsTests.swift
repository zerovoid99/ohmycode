import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct ProblemsTests {
    private func diagnostic(_ line: Int, _ column: Int, _ severity: Diagnostic.Severity, _ message: String,
                            source: String? = nil) -> Diagnostic {
        Diagnostic(range: LSPRange(start: LSPPosition(line: line, character: column),
                                   end: LSPPosition(line: line, character: column + 3)),
                   severity: severity, message: message, source: source)
    }

    @Test func storeGroupsSortsFiltersAndClearsBySource() {
        let store = ProblemStore()
        let a = URL(filePath: "/tmp/omc-problems/a.swift")
        let b = URL(filePath: "/tmp/omc-problems/b.swift")
        store.set([diagnostic(9, 0, .warning, "unused x"), diagnostic(2, 4, .hint, "could be let")], for: a, source: "lsp:sk")
        store.set([diagnostic(1, 0, .error, "no such module", source: "swiftc")], for: b, source: "task:build")
        store.set([diagnostic(0, 0, .information, "TODO")], for: a, source: "ext#1")

        // Files with errors first; each file's problems by position, whatever the source.
        let files = store.files()
        #expect(files.map(\.url.lastPathComponent) == ["b.swift", "a.swift"])
        #expect(files[1].diagnostics.map(\.message) == ["TODO", "could be let", "unused x"])
        #expect(store.errorCount == 1 && store.warningCount == 1 && store.totalCount == 4)

        // Filtering: text, source, file name; and errors and warnings only.
        #expect(store.files(filter: "UNUSED").flatMap(\.diagnostics).map(\.message) == ["unused x"])
        #expect(store.files(filter: "swiftc").map(\.url.lastPathComponent) == ["b.swift"])
        #expect(store.files(filter: "a.swift").first?.diagnostics.count == 3)
        #expect(store.files(minimum: .warning).flatMap(\.diagnostics).map(\.message) == ["no such module", "unused x"])

        // A source replaces its own list; others stay.
        store.set([], for: a, source: "lsp:sk")
        #expect(store.sources(for: a).keys.sorted() == ["ext#1"])
        store.clear { $0.hasPrefix("task:") }
        #expect(store.files().map(\.url.lastPathComponent) == ["a.swift"])
        store.removeAll()
        #expect(store.totalCount == 0)
    }

    @Test func openingAProblemSelectsItsRange() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-problems-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "first\nsecond line\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        let url = root.appending(path: "f.txt")
        workspace.problems.set([diagnostic(1, 7, .error, "bad")], for: url, source: "test")

        workspace.toggleProblems()
        #expect(workspace.isTerminalVisible && workspace.bottomPanel == .problems)
        let problem = try #require(workspace.problems.files().first?.diagnostics.first)
        workspace.open(problem: problem, in: url)
        let document = try #require(workspace.activeDocument)
        #expect(document.url.lastPathComponent == "f.txt")
        #expect(document.pendingReveal == NSRange(location: 13, length: 3))
        workspace.toggleProblems()
        #expect(!workspace.isTerminalVisible)

        // Opening another folder starts with no problems.
        workspace.openFolder(FileManager.default.temporaryDirectory)
        #expect(workspace.problems.totalCount == 0)
    }
}
