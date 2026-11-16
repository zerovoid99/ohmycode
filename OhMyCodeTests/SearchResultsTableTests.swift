import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

/// The Find in Files results list: a table that makes only the rows in view.
@MainActor
struct SearchResultsTableTests {
    private static func results(files: Int, matchesPerFile: Int, tag: String = "") -> [SearchFileResult] {
        (0..<files).map { file in
            let path = "dir\(file % 20)/file\(file)\(tag).swift"
            return SearchFileResult(path: path, url: URL(filePath: "/tmp/\(path)"), matches: (0..<matchesPerFile).map { line in
                SearchMatch(line: line, column: 4, length: 6, preview: "let needle\(line) = value // \(file)",
                            previewRange: NSRange(location: 4, length: 6))
            })
        }
    }

    private final class Recorder {
        var opened: [(String, Int)] = []
        var replacedFiles: [String] = []
    }

    private static func table(_ results: [SearchFileResult], replacement: String? = nil, recorder: Recorder) -> SearchResultsTable {
        SearchResultsTable(results: results, replacement: replacement, replacementPreview: { _ in replacement ?? "" },
                           onOpen: { recorder.opened.append(($0.path, $1.line)) },
                           onReplaceFile: { recorder.replacedFiles.append($0.path) },
                           onReplaceMatch: { _, _ in })
    }

    private static func tableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews { if let table = tableView(in: subview) { return table } }
        return nil
    }

    /// An update at 20,000 results makes the rows in view only. As a SwiftUI List it took
    /// 100–220 ms of the main thread, ten times a second while a search ran.
    @Test func updatesAtTwentyThousandResultsAreCheap() throws {
        let recorder = Recorder()
        let host = NSHostingView(rootView: Self.table(Self.results(files: 2_000, matchesPerFile: 10), recorder: recorder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        let table = try #require(Self.tableView(in: host))
        #expect(table.numberOfRows == 22_000)

        var slowest = Duration.zero
        for round in 0..<5 {
            // A new array each time, as a running search publishes (a file more each time).
            host.rootView = Self.table(Self.results(files: 2_000 + round, matchesPerFile: 10, tag: "\(round)"), recorder: recorder)
            let update = ContinuousClock().measure {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            slowest = max(slowest, update)
            #expect(table.numberOfRows == 22_000 + round * 11)
        }
        #expect(slowest < .milliseconds(60), "an update took \(slowest)")
        // Only the rows in view (and a few more) are views.
        #expect(table.rows(in: table.visibleRect).length < 60)
        withExtendedLifetime(window) {}
    }

    @Test func clicksOpenMatchesAndFoldFiles() throws {
        let recorder = Recorder()
        let results = Self.results(files: 3, matchesPerFile: 4)
        let host = NSHostingView(rootView: Self.table(results, recorder: recorder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        let table = try #require(Self.tableView(in: host))
        let coordinator = try #require(table.delegate as? SearchResultsTable.Coordinator)
        #expect(table.numberOfRows == 15)

        // A match opens.
        coordinator.activate(row: 2)
        #expect(recorder.opened.count == 1 && recorder.opened[0] == (results[0].path, 1))

        // A file's row folds its matches away, and they stay folded as results update.
        coordinator.activate(row: 0)
        #expect(table.numberOfRows == 11)
        host.rootView = Self.table(results + Self.results(files: 1, matchesPerFile: 2, tag: "new"), recorder: recorder)
        host.layoutSubtreeIfNeeded()
        #expect(table.numberOfRows == 14)
        coordinator.activate(row: 0)
        #expect(table.numberOfRows == 18)

        // Rows show the file and the line.
        let fileCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SearchFileCell)
        #expect(fileCell.accessibilityLabel()?.hasPrefix(results[0].path) == true)
        let matchCell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SearchMatchCell)
        #expect(matchCell.toolTip == "Line 1")
        withExtendedLifetime(window) {}
    }

    @Test func replacementPreviewsStrikeTheMatch() {
        let match = SearchMatch(line: 0, column: 4, length: 3, preview: "let foo = 1", previewRange: NSRange(location: 4, length: 3))
        let plain = SearchMatchCell.text(match, replacement: nil)
        #expect(plain.string == "let foo = 1")
        #expect(plain.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil)
        #expect(plain.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)

        let replaced = SearchMatchCell.text(match, replacement: "bar\nbaz")
        #expect(replaced.string == "let foobar⏎baz = 1")
        #expect(replaced.attribute(.strikethroughStyle, at: 4, effectiveRange: nil) != nil)
        #expect(replaced.attribute(.strikethroughStyle, at: 7, effectiveRange: nil) == nil)
    }
}
