import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct RangeFormattingTests {
    @Test func linesAsAnLSPRange() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-rf-\(UUID().uuidString).swift")
        try "ab\r\ncd\nef".write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        #expect(document.lspRange(ofLines: 0..<1) == LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 2)))
        #expect(document.lspRange(ofLines: 1..<3) == LSPRange(start: LSPPosition(line: 1, character: 0), end: LSPPosition(line: 2, character: 2)))
        try "ab\ncd\nef".write(to: url, atomically: true, encoding: .utf8)
        let lf = try EditorDocument(url: url)
        lf.setDiffBase("ab\nef")
        #expect(lf.changedLineRanges() == [1..<2])
        document.setDiffBase("ab\r\ncd\nef")
        #expect(document.changedLineRanges() == [])
        document.setDiffBase(nil)
        #expect(document.changedLineRanges() == nil)
    }

    @Test func formatsTheSelectedLines() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(text: "a  \nb  \nc  \n")
        #expect(try await LanguageClientTests.eventually { document.languageClient?.state == .ready })
        #expect(workspace.canFormatRanges(document))
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0)) // on "b"
        await workspace.formatSelection(document)?.value
        #expect(document.textStorage.string == "a  \nb\nc  \n")
        // Lines 1–3 selected (ending at the start of a line doesn't take it).
        controller.textView.setSelectedRange(NSRange(location: 0, length: 6))
        await workspace.formatSelection(document)?.value
        #expect(document.textStorage.string == "a\nb\nc  \n")
        #expect(document.undoManager.canUndo)
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func formatOnSaveCanFormatOnlyChangedLines() async throws {
        let (workspace, document, _, window) = try LanguageClientTests.makeWorkspace(text: "a  \nb  \n")
        #expect(try await LanguageClientTests.eventually { document.languageClient?.state == .ready })
        let settings = AppSettings.shared
        settings.formatOnSaveScope = .modifications
        defer { settings.formatOnSaveScope = .file }
        workspace.formatOnSave = true
        // As committed: the two lines; then a line is added.
        document.setDiffBase("a  \nb  \n")
        document.textStorage.replaceCharacters(in: NSRange(location: document.textStorage.length, length: 0), with: "c\t \n")
        #expect(await workspace.saveActive()?.value == true)
        #expect(try String(contentsOf: document.url, encoding: .utf8) == "a  \nb  \nc\n")

        // Not in git: the whole file.
        document.setDiffBase(nil)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z \n")
        #expect(await workspace.saveActive()?.value == true)
        #expect(try String(contentsOf: document.url, encoding: .utf8) == "z\na\nb\nc\n")
        withExtendedLifetime((workspace, window)) {}
    }
}
