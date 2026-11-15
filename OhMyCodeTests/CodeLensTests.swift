import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct CodeLensTests {
    private func titles(_ document: EditorDocument) -> [String] {
        document.codeLenses.keys.sorted().flatMap { line in document.codeLenses[line]!.compactMap(\.title).map { "\(line):\($0)" } }
    }

    @Test func lensesAreResolvedDrawnAndRun() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "func helper() {}\nfunc unused() {}\nhelper()\nhelper()\n")
        #expect(try await LanguageClientTests.eventually { titles(document) == ["0:2 references", "1:0 references"] })

        controller.textView.layoutSubtreeIfNeeded()
        let marks = controller.codeLensMarks()
        #expect(marks.map(\.title) == ["2 references", "0 references"])
        // After the line's end.
        let lineEnd = try #require(controller.rect(for: NSRange(location: 15, length: 1)))
        #expect(marks[0].rect.minX > lineEnd.maxX)

        // Clicking it shows the references.
        let point = NSPoint(x: marks[0].rect.midX, y: marks[0].rect.midY)
        #expect(controller.handleCodeLensClick(at: point))
        #expect(workspace.sidebarMode == .references && workspace.references?.results.first?.matches.count == 2)
        #expect(!controller.handleCodeLensClick(at: NSPoint(x: 1, y: 1)))

        // Lines added above: lenses move with their lines at once.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\n\n")
        #expect(titles(document).first == "2:2 references")

        AppSettings.shared.showsCodeLens = false
        defer { AppSettings.shared.showsCodeLens = true }
        #expect(try await LanguageClientTests.eventually { document.codeLenses.isEmpty })
        #expect(controller.codeLensMarks().isEmpty)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func readsLenses() {
        let lens = CodeLens(json: ["range": ["start": ["line": 3, "character": 0], "end": ["line": 3, "character": 4]],
                                   "command": ["title": "Run", "command": "x.run"]])
        #expect(lens?.title == "Run" && lens?.commandName == "x.run" && lens?.range.start.line == 3)
        #expect(CodeLens(json: ["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 0]]])?.title == nil)
    }
}
