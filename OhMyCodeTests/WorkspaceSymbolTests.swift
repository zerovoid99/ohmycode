import AppKit
import Testing
@testable import Oh_My_Code

@MainActor
struct WorkspaceNavigationTests {
    private func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Waits for the server (the fake one answers everything here).
    private func ready(_ document: EditorDocument) async throws -> Bool {
        try await eventually { document.languageClient?.state == .ready }
    }

    @Test func goesToImplementationsAndTypeDefinitions() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "protocol Shape {}\n// implements Shape\nlet x = 1\n",
            files: ["b.swift": "struct Square {}\n// implements Shape\n"])
        #expect(try await ready(document))
        controller.textView.setSelectedRange(NSRange(location: 10, length: 0)) // in "Shape"
        await workspace.goToImplementation(in: document)?.value
        // Two: listed in the sidebar.
        let list = try #require(workspace.references)
        #expect(list.noun == "implementation" && list.count == 2 && list.results.map(\.path) == ["b.swift", "main.swift"])
        #expect(workspace.sidebarMode == .references)

        // One: opened right away.
        controller.textView.setSelectedRange(NSRange(location: 40, length: 0)) // "x"
        await workspace.goToTypeDefinition(in: document)?.value
        #expect(document.pendingReveal == NSRange(location: 0, length: 4) || controller.textView.selectedRange() == NSRange(location: 0, length: 4))
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func findsSymbolsInTheWholeFolder() async throws {
        let (workspace, document, _, window) = try LanguageClientTests.makeWorkspace(
            text: "func alpha() {}\nfunc beta() {}\n",
            files: ["tools.py": "class Gadget:\n    def gamma(self):\n        pass\n", "README.md": "# Getting started\n",
                    "other.swift": "func gammaRay() {}\n"])
        #expect(try await ready(document))

        // The server's symbols, the syntax trees' and the open file's, each once.
        var results = await workspace.workspaceSymbols(matching: "ga")
        let names = results.map(\.name)
        #expect(Set(["gamma", "Gadget", "gammaRay", "Getting started"]).isSubset(of: Set(names)))
        #expect(!names.contains("beta"))
        #expect(results.filter { $0.name == "gammaRay" }.count == 1)
        let gamma = try #require(results.first { $0.name == "gamma" })
        #expect(gamma.container == "Gadget" && gamma.url.lastPathComponent == "tools.py" && gamma.line == 1 && gamma.column == 8)

        // A file changed on disk is read again.
        let tools = workspace.rootURL!.appending(path: "tools.py")
        try "def gadgetry():\n    pass\n".write(to: tools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: tools.path)
        results = await workspace.workspaceSymbols(matching: "gad")
        let renamed = results.map(\.name)
        #expect(renamed.first == "gadgetry" && !renamed.contains("gamma"), "\(renamed)") // the best match first; the old one's gone

        // #name in quick open: choosing one selects its name in its file.
        workspace.showPalette(.workspaceSymbols)
        let palette = try #require(workspace.palette)
        palette.query = "#gammaR"
        #expect(try await eventually { palette.items.map(\.title) == ["gammaRay"] })
        #expect(palette.items.first?.detail == "fake · other.swift:1")
        palette.acceptSelection()
        let opened = try #require(workspace.activeDocument)
        #expect(opened.url.lastPathComponent == "other.swift" && opened.pendingReveal == NSRange(location: 5, length: 8))
        withExtendedLifetime((workspace, window)) {}
    }

    @Test func showsCallHierarchies() async throws {
        let (workspace, document, controller, window) = try LanguageClientTests.makeWorkspace(
            text: "func top() { middle(); bottom() }\nfunc middle() { bottom(); bottom() }\nfunc bottom() {}\n")
        #expect(try await ready(document))
        controller.textView.setSelectedRange(NSRange(location: 76, length: 0)) // in "bottom" on line 3
        await workspace.showCallHierarchy(in: document)?.value
        let hierarchy = try #require(workspace.callHierarchy)
        #expect(workspace.sidebarMode == .callHierarchy && hierarchy.root.name == "bottom")
        #expect(hierarchy.nodes.map(\.item.name) == ["top", "middle"])
        let middle = hierarchy.nodes[1]
        #expect(middle.ranges.count == 2 && middle.ranges[0].start == LSPPosition(line: 1, character: 16))

        // A level loads when opened: middle's callers.
        await hierarchy.toggle(middle)
        #expect(middle.isExpanded && middle.children?.map(\.item.name) == ["top"])

        // The other way: what it calls.
        await hierarchy.setIncoming(false)
        #expect(hierarchy.nodes.isEmpty)
        controller.textView.setSelectedRange(NSRange(location: 6, length: 0)) // "top"
        await workspace.showCallHierarchy(incoming: false, in: document)?.value
        let outgoing = try #require(workspace.callHierarchy)
        #expect(outgoing.nodes.map(\.item.name) == ["middle", "bottom"]) // by where they're declared

        // Clicking a call opens where it's made.
        workspace.open(outgoing.nodes[0].ranges[0], in: outgoing.nodes[0].rangesURL)
        #expect(controller.textView.selectedRange() == NSRange(location: 13, length: 6))
        withExtendedLifetime((workspace, window)) {}
    }
}
