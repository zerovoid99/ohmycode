import AppKit
import SwiftUI
import Testing
@testable import Oh_My_Code

/// Switching between open tabs, as the app does it: an editor group's SwiftUI view in a
/// window, the active tab changed, then laid out and drawn. Run with:
///
///     TEST_RUNNER_OMC_BENCH=1 xcodebuild … test -only-testing:OhMyCodeTests/TabSwitchBenchmarks
///
/// Results are printed as `BENCH name: value`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OMC_BENCH"] == "1"))
struct TabSwitchBenchmarks {
    /// Just the editor group's view, or (`wholeWindow`) the whole workspace window around it.
    @Test(arguments: [false, true])
    func switchBetweenFiveTabs(wholeWindow: Bool) async throws {
        let fixture = try TabSwitchFixture(files: 5, bytes: 200_000, wholeWindow: wholeWindow)
        defer { fixture.tearDown() }
        // Every tab shown, and its file parsed, before the timing starts.
        for id in fixture.ids { await fixture.show(id) }
        for document in fixture.workspace.documents { await document.highlighter?.waitUntilIdle() }
        for id in fixture.ids { await fixture.show(id) }
        try await Task.sleep(for: .seconds(2))

        let clock = ContinuousClock()
        var samples: [Duration] = []
        for step in 0..<50 {
            let id = fixture.ids[step % fixture.ids.count]
            samples.append(await clock.measure { await fixture.show(id) })
        }
        samples.sort()
        let ms = { (duration: Duration) in String(format: "%.2f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000) }
        print("BENCH tabSwitch\(wholeWindow ? ".window" : "").median: \(ms(samples[samples.count / 2]))")
        print("BENCH tabSwitch\(wholeWindow ? ".window" : "").p90: \(ms(samples[samples.count * 9 / 10]))")
        print("BENCH tabSwitch\(wholeWindow ? ".window" : "").max: \(ms(samples.last!))")
    }
}

/// A workspace with a few files open in one editor group, its view hosted in a window.
@MainActor
struct TabSwitchFixture {
    let root: URL
    let workspace: Workspace
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let ids: [EditorDocument.ID]

    init(files: Int, bytes: Int, wholeWindow: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "omc-tabs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = Workspace()
        workspace.openFolder(root)
        var ids: [EditorDocument.ID] = []
        for index in 0..<files {
            let url = root.appending(path: "file\(index).swift")
            try PerformanceBenchmarks.code(bytes: bytes).write(to: url, atomically: true, encoding: .utf8)
            workspace.open(fileAt: url)
            ids.append(try #require(workspace.activeDocument).id)
        }
        self.ids = ids
        host = NSHostingView(rootView: wholeWindow ? AnyView(WorkspaceView(workspace: workspace))
                                                   : AnyView(EditorGroupView(workspace: workspace, group: workspace.activeGroup)))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }

    /// Makes a tab active and lets it show: layout, drawing, and the main queue's work (an
    /// editor finishes setting itself up there).
    func show(_ id: EditorDocument.ID) async {
        workspace.activeDocumentID = id
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await Task.yield() // after what's queued on the main queue meanwhile
        window.displayIfNeeded()
    }

    /// The editor the group shows for a document, if any.
    func editor(for id: EditorDocument.ID) -> EditorController? {
        workspace.document(id: id)?.editor(inGroup: workspace.activeGroup)
    }

    func tearDown() {
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: root)
    }
}
