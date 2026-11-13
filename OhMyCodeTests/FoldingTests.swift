import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct FoldingTests {
    static let source = """
    struct A {
        func one() {
            let x = 1

            print(x)
        }

        func two() {
            print(2)
        }
    }
    let tail = 0
    """
    // Lines: 0 struct, 1 func one, 2 let, 3 blank, 4 print, 5 }, 6 blank, 7 func two, 8 print, 9 }, 10 }, 11 tail

    private func makeEditor(_ text: String = source) throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-fold-\(UUID().uuidString).swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        document.attach(controller)
        document.editor = controller
        return (document, controller, window)
    }

    private func lineTop(_ controller: EditorController, _ line: Int) -> CGFloat? {
        controller.textView.layoutSubtreeIfNeeded()
        let document = controller.document
        let start = document.lineIndex.lineStarts[line]
        return controller.rect(for: NSRange(location: start, length: start < document.textStorage.length ? 1 : 0))?.minY
    }

    /// Lines the viewport has laid out, without forcing layout (what the gutter and text draw).
    private func viewportLines(_ controller: EditorController) -> [Int] {
        controller.textView.layoutSubtreeIfNeeded()
        let layoutManager = controller.textView.textLayoutManager!
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange else { return [] }
        var lines: [Int] = []
        layoutManager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            let offset = layoutManager.offset(from: layoutManager.documentRange.location, to: fragment.rangeInElement.location)
            lines.append(controller.document.lineIndex.line(containing: offset))
            return true
        }
        return lines
    }

    @Test func regionsFollowIndentation() throws {
        let (document, _, window) = try makeEditor()
        #expect(document.foldRange(atLine: 0) == 1...9)   // up to the struct's closing brace
        #expect(document.foldRange(atLine: 1) == 2...4)   // blank line inside kept, "}" stays visible
        #expect(document.foldRange(atLine: 7) == 8...8)
        #expect(document.foldRange(atLine: 2) == nil)
        #expect(document.foldRange(atLine: 3) == nil)     // blank
        #expect(document.foldRange(atLine: 11) == nil)
        #expect((0..<12).filter(document.isFoldable) == [0, 1, 7])
        withExtendedLifetime(window) {}
    }

    @Test func foldingHidesLinesInEveryEditorAndUnfoldsOnDemand() throws {
        let (document, controller, window) = try makeEditor()
        let (_, other, otherWindow) = try makeEditor() // a different document: unaffected
        let headerTop = try #require(lineTop(controller, 1))
        let lineHeight = try #require(lineTop(controller, 2)) - headerTop

        document.foldLines(atHeader: 1)
        #expect(document.isFolded(line: 1))
        #expect(lineTop(controller, 3) == nil)                      // hidden
        #expect(abs((lineTop(controller, 5) ?? 0) - (headerTop + lineHeight)) < 0.5) // "}" right after the header
        #expect(controller.foldPlaceholderRects().map(\.header) == [1])
        #expect(lineTop(other, 3) != nil)

        // A second editor of the same document (split view) shows the fold too.
        let split = EditorController(document: document)
        let splitWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                                   backing: .buffered, defer: false)
        splitWindow.contentView = split.makeView()
        splitWindow.layoutIfNeeded()
        document.attach(split)
        #expect(lineTop(split, 3) == nil)

        // Clicking "⋯" unfolds.
        let placeholder = try #require(controller.foldPlaceholderRects().first)
        #expect(controller.textView.onClick?(NSPoint(x: placeholder.rect.midX, y: placeholder.rect.midY)) == true)
        #expect(!document.isFolded(line: 1))
        #expect(lineTop(controller, 3) != nil && lineTop(split, 3) != nil)

        // Moving the cursor into folded lines (arrow keys, find, go to line) unfolds them.
        document.foldLines(atHeader: 1)
        controller.reveal(NSRange(location: document.lineIndex.lineStarts[4], length: 0))
        #expect(document.folds.isEmpty)
        withExtendedLifetime((window, otherWindow, splitWindow)) {}
    }

    @Test func editsKeepOrOpenFolds() throws {
        let (document, controller, window) = try makeEditor()
        document.foldLines(atHeader: 7)
        // Typing above (or on the header line) keeps the fold on its lines.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "// top\n")
        #expect(document.isFolded(line: 8))
        let header = document.lineIndex.lineStarts[8]
        document.textStorage.replaceCharacters(in: NSRange(location: header + 4, length: 0), with: "x")
        #expect(document.isFolded(line: 8))
        #expect(lineTop(controller, 9) == nil)

        // Editing inside hidden lines shows all of them, not just the edited one.
        document.unfoldAll()
        document.foldLines(atHeader: 2) // func one: lines 3–5 hidden
        #expect(!viewportLines(controller).contains(5) && viewportLines(controller).contains(6))
        let hidden = document.lineIndex.lineStarts[3]
        document.textStorage.replaceCharacters(in: NSRange(location: hidden + 4, length: 0), with: "y")
        #expect(document.folds.isEmpty)
        #expect(viewportLines(controller).contains(5), "unedited hidden line stayed hidden: \(viewportLines(controller))")
        withExtendedLifetime(window) {}
    }

    @Test func foldCommandsAtTheCursorAndForEverything() throws {
        let (document, controller, window) = try makeEditor()
        // From inside a body, the enclosing region folds and the cursor moves to its header.
        controller.textView.setSelectedRange(NSRange(location: document.lineIndex.lineStarts[2] + 6, length: 0))
        controller.foldAtCursor(true)
        #expect(document.isFolded(line: 1))
        #expect(document.lineIndex.line(containing: controller.textView.selectedRange().location) == 1)
        controller.foldAtCursor(false)
        #expect(document.folds.isEmpty)

        document.foldAll()
        #expect(Set(document.folds.map { document.lineIndex.line(containing: $0.location) - 1 }) == [0, 1, 7])
        #expect(lineTop(controller, 1) == nil)  // inside the folded struct
        document.unfold(atHeader: 0)            // inner folds stay folded
        #expect(document.isFolded(line: 1) && document.isFolded(line: 7))
        #expect(lineTop(controller, 1) != nil && lineTop(controller, 2) == nil)
        document.unfoldAll()
        #expect(document.folds.isEmpty && lineTop(controller, 8) != nil)
        withExtendedLifetime(window) {}
    }
}
