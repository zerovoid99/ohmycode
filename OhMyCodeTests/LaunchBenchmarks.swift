import AppKit
import Testing
@testable import Oh_My_Code

/// App launch times, from the process's start to the first window, the first editor drawn and
/// its first highlight. Run with:
///
///     TEST_RUNNER_OMC_BENCH=1 xcodebuild … test -only-testing:OhMyCodeTests/LaunchBenchmarks
///
/// The built app (this test's host) is copied with its own bundle ID (so its preferences and
/// saved windows aren't the user's, and it claims no files or URLs) and launched with `open -g`
/// (no activation) and `OMC_LAUNCH_TRACE=1`: its windows are transparent and click-through, and
/// it prints its milestones (see `LaunchTrace`) and exits by itself. `OMC_SUPPORT_DIR` points it
/// at a scratch Application Support folder, so the user's sessions are never read or written.
/// Each scenario runs once untimed (the first launch of a new copy checks its signature), then
/// `runs` times; medians are reported as `BENCH launch.<scenario>.<milestone>: ms`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OMC_BENCH"] == "1"))
struct LaunchBenchmarks {
    static let runs = 7
    static let bundleID = "dev.zerovoid99.ohmycode.launchbench"

    /// The host app, copied to `folder` under the benchmark's bundle ID and signed again.
    private func copyApp(to folder: URL) throws -> URL {
        let source = Bundle.main.bundleURL
        try #require(source.pathExtension == "app", "the tests' host isn't the app: \(source.path)")
        let app = folder.appending(path: "Oh My Code Launch Benchmark.app")
        try FileManager.default.copyItem(at: source, to: app)
        try? FileManager.default.removeItem(at: app.appending(path: "Contents/PlugIns")) // these tests
        let infoURL = app.appending(path: "Contents/Info.plist")
        var info = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
        info["CFBundleIdentifier"] = Self.bundleID
        info["CFBundleURLTypes"] = nil
        info["CFBundleDocumentTypes"] = nil
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        let status = try run("/usr/bin/codesign", ["--force", "--sign", "-", "--preserve-metadata=entitlements", app.path])
        try #require(status == 0, "codesign failed")
        return app
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // Not the test runner's: `open` passes its environment on, and with XCTest's in it the
        // app would think it's under test (scratch settings, no session restore).
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// One launch: milestones in ms since the process started.
    private func launch(_ app: URL, support: URL, until: [String], scratch: URL) throws -> [String: Double] {
        let output = scratch.appending(path: "launch-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        try run("/usr/bin/open", [
            "-n", "-g", "-W", "-F",
            "--env", "OMC_LAUNCH_TRACE=1",
            "--env", "OMC_LAUNCH_TRACE_UNTIL=" + until.joined(separator: ","),
            "--env", "OMC_SUPPORT_DIR=" + support.path,
            "--stdout", output.path, "--stderr", "/dev/null",
            app.path,
            "--args", "-ApplePersistenceIgnoreState", "YES",
        ])
        var marks: [String: Double] = [:]
        for line in try String(contentsOf: output, encoding: .utf8).split(separator: "\n") where line.hasPrefix("LAUNCH ") {
            let parts = line.dropFirst("LAUNCH ".count).split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0] == "timeout" { Issue.record("launch timed out: \(parts[1])"); continue }
            marks[String(parts[0])] = Double(parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ms", with: ""))
        }
        return marks
    }

    private func measure(_ name: String, app: URL, scratch: URL, until: [String], prepare: (URL) throws -> Void) throws {
        var runs: [[String: Double]] = []
        for index in 0...Self.runs {
            let support = scratch.appending(path: "support-\(name)-\(index)")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try prepare(support)
            let marks = try launch(app, support: support, until: until, scratch: scratch)
            #expect(Set(until).isSubset(of: marks.keys), "\(name): missing milestones, got \(marks)")
            if index > 0 { runs.append(marks) } // the first launch of the copy is slower
        }
        let names = Set(runs.flatMap(\.keys)).sorted { (runs[0][$0] ?? 0) < (runs[0][$1] ?? 0) }
        for mark in names {
            let values = runs.compactMap { $0[mark] }.sorted()
            print("BENCH launch.\(name).\(mark): " + String(format: "%.1f ms (min %.1f, max %.1f, n=%d)",
                                                             values[values.count / 2], values.first!, values.last!, values.count))
        }
    }

    @Test func launch() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "omc-launch-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: scratch)
            // The copy's own preferences and window state (`-ApplePersistenceIgnoreState` puts
            // the latter in the temporary folder).
            _ = try? run("/usr/bin/defaults", ["delete", Self.bundleID])
            for leftover in [URL.libraryDirectory.appending(path: "Preferences/\(Self.bundleID).plist"),
                             URL.libraryDirectory.appending(path: "Saved Application State/\(Self.bundleID).savedState"),
                             FileManager.default.temporaryDirectory.appending(path: "\(Self.bundleID).savedState")] {
                try? FileManager.default.removeItem(at: leftover)
            }
        }
        let app = try copyApp(to: scratch)
        defer {
            _ = try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-u", app.path])
        }

        // Nothing to restore: the welcome window.
        try measure("empty", app: app, scratch: scratch, until: ["window.visible"]) { _ in }

        // Hot exit: a folder's window with 5 files open (the active one 5 MB, another unsaved).
        let project = scratch.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var files: [URL] = []
        for (index, bytes) in [8_000, 20_000, 40_000, 80_000, 5_000_000].enumerated() {
            let url = project.appending(path: "File\(index).swift")
            try PerformanceBenchmarks.code(bytes: bytes).write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
        }
        let unsaved = files[1]
        let unsavedText = try String(contentsOf: unsaved, encoding: .utf8) + "\n// not saved\n"
        try measure("restore5Files", app: app, scratch: scratch, until: ["editor.firstDraw", "highlight.first"]) { support in
            let store = SessionStore(directory: support.appending(path: "OhMyCode/Sessions"))
            let buffer = WindowSession.Buffer(path: unsaved.path, file: "unsaved-\(unsaved.lastPathComponent).txt",
                                              diskDate: try? unsaved.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let session = WindowSession(root: project.path, files: files.map(\.path), activeFile: files[4].path,
                                        unsaved: [buffer], wasOpen: true)
            store.write(session, texts: [buffer.file: unsavedText], key: SessionStore.key(root: project, windowID: UUID()))
        }
    }
}
