import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct TerminalLinkTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-tlink-\(UUID().uuidString)").resolvingSymlinksInPath()
        for path in ["Sources/App/main.swift", "tools/run.py"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "line 1\nline 2\nline three\n".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func findsFilesWithLinesAndURLs() throws {
        let root = try makeFolder()
        let main = root.appending(path: "Sources/App/main.swift").standardizedFileURL
        #expect(TerminalLink.link(in: "Sources/App/main.swift:3:5: error: nope", at: 4, base: root) == .file(main, line: 3, column: 5))
        #expect(TerminalLink.link(in: "  ./Sources/App/main.swift", at: 10, base: root) == .file(main, line: nil, column: nil))
        let python = "  File \"\(root.path)/tools/run.py\", line 2, in <module>"
        #expect(TerminalLink.link(in: python, at: 12, base: nil) == .file(root.appending(path: "tools/run.py").standardizedFileURL, line: 2, column: nil))
        #expect(TerminalLink.link(in: "docs at https://example.com/a(b). ok", at: 12, base: root) == .url(URL(string: "https://example.com/a(b")!))
        // Not there, or not on a link.
        #expect(TerminalLink.link(in: "missing.swift:3: error", at: 2, base: root) == nil)
        #expect(TerminalLink.link(in: "Sources/App/main.swift:3 then text", at: 30, base: root) == nil)
    }

    @Test func readsARowOfTheScreen() async throws {
        let root = try makeFolder()
        let session = try TerminalSession(directory: root, command: ["/bin/echo", "error at Sources/App/main.swift:2:3"])
        let deadline = ContinuousClock.now + .seconds(5)
        while !(session.rowText(0) ?? "").contains("main.swift"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let row = try #require(session.rowText(0))
        #expect(row.hasPrefix("error at Sources/App/main.swift:2:3"))
        #expect(TerminalLink.link(in: row, at: 12, base: session.directory) != nil)
        session.terminate()
    }

    @Test func opensTheFileAtItsLineAndColumn() throws {
        let root = try makeFolder()
        let workspace = Workspace()
        workspace.openFolder(root)
        workspace.openTerminalLink(.file(root.appending(path: "Sources/App/main.swift"), line: 3, column: 6))
        let document = try #require(workspace.activeDocument)
        #expect(document.url.lastPathComponent == "main.swift")
        // Line 3 starts at 14; column 6 is 5 characters in.
        #expect(document.pendingReveal == NSRange(location: 19, length: 0))
    }

    @Test func commandClickInTheViewOpensIt() async throws {
        let root = try makeFolder()
        let session = try TerminalSession(directory: root, command: ["/bin/echo", "Sources/App/main.swift:2"])
        defer { session.terminate() }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.session = session
        let deadline = ContinuousClock.now + .seconds(5)
        while !(session.rowText(0) ?? "").contains("main.swift"), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        var opened: [TerminalLink] = []
        view.onOpenLink = { opened.append($0) }
        // The 5th cell of the first row (the view is flipped: rows go down).
        let point = NSPoint(x: TerminalView.padding + view.cellWidth * 4.5, y: TerminalView.padding + view.cellHeight * 0.5)
        let inWindow = view.convert(point, to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: .command, timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        #expect(opened == [.file(root.appending(path: "Sources/App/main.swift").standardizedFileURL, line: 2, column: nil)])
        // Without ⌘: an ordinary click (selection), nothing opened.
        let plain = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: plain)
        #expect(opened.count == 1)
    }
}
