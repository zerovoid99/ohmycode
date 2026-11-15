import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct FoldRegionTests {
    private static let code = """
    import Foundation
    import AppKit

    /// Doc line one
    /// Doc line two
    func f(
        a: Int,
        b: Int
    ) {
        let x = [
            1,
            2,
        ]
    }

    // MARK: - Section
    let y = 1

    /* block
       comment */

    """

    private func makeDocument(_ text: String = code) async throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-fold-\(UUID().uuidString).swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        await document.waitForFoldRegions()
        return document
    }

    private func region(_ document: EditorDocument, _ line: Int) -> String? {
        document.structuralFold(atLine: line).map { "\($0.kind.rawValue):\($0.end)" }
    }

    @Test func regionsFromTheSyntaxTree() async throws {
        let document = try await makeDocument()
        #expect(region(document, 0) == "imports:1")
        #expect(region(document, 3) == "comment:4")
        // The function folds from its first line to the line before its closing brace.
        #expect(region(document, 5) == "code:12")
        // Its body's `) {` line adds nothing.
        #expect(region(document, 8) == nil && !document.isFoldable(line: 8))
        #expect(region(document, 9) == "code:11")
        #expect(region(document, 15) == "region:19")
        #expect(region(document, 18) == "comment:19")
        #expect(region(document, 16) == nil)

        #expect(document.foldRange(atLine: 5) == 6...12)
        #expect(document.isFoldable(line: 0) && document.isFoldable(line: 3) && !document.isFoldable(line: 16))
        // Folding hides the lines; the closing brace stays.
        document.foldLines(atHeader: 5)
        #expect(document.isHidden(document.lineIndex.lineStarts[12]) && !document.isHidden(document.lineIndex.lineStarts[13]))
    }

    @Test func levelsAndComments() async throws {
        let document = try await makeDocument()
        let levels = document.allFoldRegions().map { "\($0.lines.lowerBound - 1):\($0.level)" }
        #expect(levels.contains("5:1") && levels.contains("9:2") && levels.contains("18:2"))
        document.foldAllComments()
        #expect(document.isFolded(line: 3) && document.isFolded(line: 18) && !document.isFolded(line: 5))
        document.unfoldAll()
        document.foldLevel(2)
        #expect(document.isFolded(line: 9) && !document.isFolded(line: 5))
    }

    @Test func regionsFollowEdits() async throws {
        let document = try await makeDocument()
        // Two lines added above: the regions move down at once, before the tree is read again.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// a\n// b\n")
        #expect(region(document, 7) == "code:14")
        await document.waitForFoldRegions()
        #expect(region(document, 7) == "code:14")
        #expect(region(document, 0) == "comment:1")
    }

    @Test func indentationStillFoldsElsewhere() async throws {
        // Python blocks have no closing brackets: indentation folds them.
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-fold-\(UUID().uuidString).py")
        try "def f():\n    a = 1\n    b = 2\nprint(f)\n".write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        await document.waitForFoldRegions()
        #expect(document.foldRange(atLine: 0) == 1...2)
    }

    /// Against Xcode's real sourcekit-lsp: its ranges replace the tree's, ending before the brace.
    @Test(.timeLimit(.minutes(2)))
    func sourceKitFoldingRanges() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-fold-skl-\(UUID().uuidString)")
        let sources = root.appending(path: "Sources/Demo")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Demo", targets: [.executableTarget(name: "Demo")])
        """.write(to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8)
        try "struct Point {\n    var x = 0\n    var y = 0\n}\nprint(Point())\n"
            .write(to: sources.appending(path: "main.swift"), atomically: true, encoding: .utf8)
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.open(fileAt: sources.appending(path: "main.swift"))
        let document = try #require(workspace.activeDocument)
        let deadline = ContinuousClock.now + .seconds(90)
        while document.languageClient?.state != .ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(document.languageClient?.supports(.foldingRange) == true)
        document.refreshFoldRegions()
        await document.waitForFoldRegions()
        #expect(document.foldRange(atLine: 0) == 1...2)
        withExtendedLifetime(workspace) {}
    }
}
