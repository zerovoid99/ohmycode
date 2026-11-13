import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

struct LogFilterTests {
    @Test func buildsArgumentsAndSpotsHashes() {
        #expect(LogFilter(kind: .message, text: "fix.").arguments == ["--fixed-strings", "--regexp-ignore-case", "--grep=fix."])
        #expect(LogFilter(kind: .author, text: "ann").arguments.last == "--author=ann")
        #expect(LogFilter(kind: .code, text: "total(").arguments == ["-Stotal("])
        #expect(LogFilter(kind: .message, text: "AbC123").hashPrefix == "abc123")
        #expect(LogFilter(kind: .message, text: "abc").hashPrefix == nil)    // too short
        #expect(LogFilter(kind: .message, text: "fix bug").hashPrefix == nil)
    }
}

@MainActor
struct CommitSearchTests {
    @discardableResult
    private func git(_ arguments: [String], author: String = "Ann", in directory: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=\(author)", "-c", "user.email=\(author.lowercased())@example.invalid",
                             "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func summaries(_ workspace: Workspace) -> [String] { workspace.repoHistory?.commits.map(\.summary) ?? [] }

    @Test func searchesMessagesAuthorsCodeAndHashes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: root)
        let commits: [(String, String, String)] = [
            ("Add cart", "Ann", "struct Cart {}\n"),
            ("Fix totals (v1.2)", "Bob", "struct Cart { var total = 0 }\n"),
            ("fix TAX rounding", "Ann", "struct Cart { var total = 0; var tax = 1 }\n"),
            ("Refactor 1-2", "Bob", "struct Basket { var total = 0; var tax = 1 }\n"),
        ]
        for (message, author, text) in commits {
            try text.write(to: root.appending(path: "Cart.swift"), atomically: true, encoding: .utf8)
            try git(["add", "."], author: author, in: root)
            try git(["commit", "-qm", message], author: author, in: root)
        }
        let workspace = Workspace()
        workspace.openFolder(root)
        for _ in 0..<300 where workspace.gitRepository == nil { try await Task.sleep(for: .milliseconds(20)) }
        workspace.loadRepoHistory()
        await workspace.waitForRepoHistory()
        #expect(workspace.repoHistory?.graph.count == 4)

        // Message: any case, and "." is a plain dot (not "any character").
        workspace.repoHistoryFilter = LogFilter(kind: .message, text: "fix")
        await workspace.waitForRepoHistory()
        #expect(summaries(workspace) == ["fix TAX rounding", "Fix totals (v1.2)"])
        #expect(workspace.repoHistory?.graph.isEmpty == true) // no graph for search results
        workspace.repoHistoryFilter = LogFilter(kind: .message, text: "1.2") // as a pattern it'd match "1-2" too
        await workspace.waitForRepoHistory()
        #expect(summaries(workspace) == ["Fix totals (v1.2)"])

        workspace.repoHistoryFilter = LogFilter(kind: .author, text: "bob")
        await workspace.waitForRepoHistory()
        #expect(summaries(workspace) == ["Refactor 1-2", "Fix totals (v1.2)"])

        // Code: commits that added or removed the text.
        workspace.repoHistoryFilter = LogFilter(kind: .code, text: "var tax")
        await workspace.waitForRepoHistory()
        #expect(summaries(workspace) == ["fix TAX rounding"])
        workspace.repoHistoryFilter = LogFilter(kind: .code, text: "Cart")
        await workspace.waitForRepoHistory()
        #expect(summaries(workspace) == ["Refactor 1-2", "Add cart"]) // added, then removed

        // A hash finds its commit (listed first) even when no message matches; paging still
        // lists every match once.
        let first = try git(["rev-list", "--max-parents=0", "HEAD"], in: root)
        workspace.repoHistoryPageSize = 1
        workspace.repoHistoryFilter = LogFilter(kind: .message, text: String(first.prefix(8)))
        await workspace.waitForRepoHistory()
        #expect(summaries(workspace) == ["Add cart"])
        #expect(workspace.repoHistory?.pinned?.sha == first)
        workspace.repoHistoryFilter = LogFilter(kind: .author, text: "ann")
        await workspace.waitForRepoHistory()
        #expect(summaries(workspace) == ["fix TAX rounding"] && workspace.repoHistory?.hasMore == true)
        workspace.loadRepoHistory(more: true)
        await workspace.waitForRepoHistory()
        workspace.loadRepoHistory(more: true)
        await workspace.waitForRepoHistory()
        #expect(summaries(workspace) == ["fix TAX rounding", "Add cart"] && workspace.repoHistory?.hasMore == false)

        // Cleared: the whole log and its graph again.
        workspace.repoHistoryPageSize = 200
        workspace.repoHistoryFilter = nil
        await workspace.waitForRepoHistory()
        #expect(summaries(workspace).count == 4 && workspace.repoHistory?.graph.count == 4)
        withExtendedLifetime(workspace) {}
    }

    /// Switching sidebar tabs rebuilds the panel: showing it again keeps the search.
    @Test func reopeningThePanelKeepsTheSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "omc-search-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: root)
        try "a\n".write(to: root.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: root)
        try git(["commit", "-qm", "Fix it"], in: root)
        let workspace = Workspace()
        workspace.openFolder(root)
        for _ in 0..<300 where workspace.gitRepository == nil { try await Task.sleep(for: .milliseconds(20)) }
        workspace.historyScope = .repository
        let filter = LogFilter(kind: .author, text: "ann")
        workspace.repoHistoryFilter = filter

        let host = NSHostingView(rootView: TimelineView(workspace: workspace).frame(width: 300, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        #expect(workspace.repoHistoryFilter == filter)
        withExtendedLifetime(window) {}
    }
}
