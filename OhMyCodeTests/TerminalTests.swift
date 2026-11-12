import AppKit
import Foundation
import GhosttyVt
import Testing
@testable import Oh_My_Code

@MainActor
struct TerminalSessionTests {
    private let home = FileManager.default.temporaryDirectory

    private func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func screen(_ session: TerminalSession) -> String { session.text(selectionOnly: false) ?? "" }

    @Test func runsCommandAndReportsExit() async throws {
        let session = try TerminalSession(directory: home, command: ["/bin/sh", "-c", "printf 'hello \\033[1mghostty\\033[0m'; exit 3"])
        #expect(try await eventually { !session.isRunning })
        #expect(session.exitCode == 3)
        #expect(screen(session).contains("hello ghostty"))
        #expect(screen(session).contains("[Process exited with code 3]"))
    }

    @Test func startsInWorkspaceDirectory() async throws {
        let directory = home.appending(path: "omc-term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Wide enough that the temp path doesn't soft-wrap.
        let session = try TerminalSession(directory: directory, command: ["/bin/sh", "-c", "pwd -P"], columns: 250)
        #expect(try await eventually { !session.isRunning })
        #expect(screen(session).contains(FileWatcher.canonicalPath(directory)))
    }

    @Test func typedKeysReachTheProgram() async throws {
        let session = try TerminalSession(directory: home, command: ["/bin/cat"])
        for character in "hi" {
            let key = character == "h" ? GHOSTTY_KEY_H : GHOSTTY_KEY_I
            session.send(.init(key: key, mods: 0, text: String(character),
                               unshiftedCodepoint: character.unicodeScalars.first!.value))
        }
        session.send(.init(key: GHOSTTY_KEY_ENTER, mods: 0))
        // The pty echoes "hi", then cat prints it back.
        #expect(try await eventually { screen(session).components(separatedBy: "hi").count - 1 >= 2 })
        session.send(.init(key: GHOSTTY_KEY_D, mods: GhosttyMods(GHOSTTY_MODS_CTRL), unshiftedCodepoint: 100))
        #expect(try await eventually { !session.isRunning })
    }

    @Test func keyEncodingFollowsTerminalModes() throws {
        let session = try TerminalSession(directory: home, command: ["/bin/cat"])
        defer { session.terminate() }
        let ctrlC = session.encode(.init(key: GHOSTTY_KEY_C, mods: GhosttyMods(GHOSTTY_MODS_CTRL), unshiftedCodepoint: 99))
        #expect(ctrlC == Data([0x03]))
        #expect(session.encode(.init(key: GHOSTTY_KEY_ARROW_UP, mods: 0)) == Data("\u{1b}[A".utf8))

        session.feed(Data("\u{1b}[?1h".utf8)) // application cursor keys, as vim/less enable
        #expect(session.encode(.init(key: GHOSTTY_KEY_ARROW_UP, mods: 0)) == Data("\u{1b}OA".utf8))
    }

    @Test func resizeUpdatesPtyWindowSize() async throws {
        let session = try TerminalSession(directory: home, command: ["/bin/sh", "-c", "sleep 0.3; stty size"])
        session.resize(columns: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        #expect(try await eventually { !session.isRunning })
        #expect(screen(session).contains("30 100"))
    }

    @Test func pasteIsBracketedWhenRequested() async throws {
        let session = try TerminalSession(directory: home, command: ["/bin/cat", "-v"])
        defer { session.terminate() }
        session.feed(Data("\u{1b}[?2004h".utf8)) // the program enables bracketed paste
        session.paste("echo 1\n")
        // cat -v makes the ESC of the bracket markers visible as ^[.
        #expect(try await eventually { screen(session).contains("^[[200~echo 1") })
    }

    @Test func selectionCopiesText() throws {
        let session = try TerminalSession(directory: home, command: ["/bin/cat"])
        defer { session.terminate() }
        session.feed(Data("first line\r\nsecond line".utf8))
        #expect(!session.hasSelection)
        session.select(from: (x: 0, y: 1), to: (x: 5, y: 1))
        #expect(session.text(selectionOnly: true) == "second")
        session.clearSelection()
        #expect(session.text(selectionOnly: true) == nil)
    }
}

@MainActor
struct TerminalViewTests {
    @Test func rendersColoredOutputAndSizesGrid() async throws {
        let session = try TerminalSession(directory: FileManager.default.temporaryDirectory, command: [
            "/bin/sh", "-c", #"printf '\033[31mRED RED RED RED\033[0m plain text here\n'; sleep 5"#,
        ])
        defer { session.terminate() }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.session = session

        // The pty and terminal follow the view's size.
        let expectedColumns = Int((500 - 2 * TerminalView.padding) / view.cellWidth)
        #expect(Int(session.columns) == expectedColumns)

        for _ in 0..<100 where !(session.text(selectionOnly: false) ?? "").contains("plain") {
            try await Task.sleep(for: .milliseconds(20))
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var red = 0, light = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<min(bitmap.pixelsHigh, 60) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.6 && c.greenComponent < 0.45 && c.blueComponent < 0.45 { red += 1 }
                if c.brightnessComponent > 0.7 && c.saturationComponent < 0.2 { light += 1 }
            }
        }
        #expect(red > 50, "red SGR text not drawn")
        #expect(light > 50, "default foreground text not drawn")
    }
}

@MainActor
struct TerminalWorkspaceTests {
    @Test func toggleCreatesOneSessionAndRestartReplacesIt() throws {
        let workspace = Workspace()
        workspace.openFolder(FileManager.default.temporaryDirectory)
        #expect(workspace.terminal == nil)

        workspace.toggleTerminal()
        let first = try #require(workspace.terminal)
        #expect(workspace.isTerminalVisible)

        workspace.toggleTerminal()
        #expect(!workspace.isTerminalVisible)
        workspace.toggleTerminal()
        #expect(workspace.terminal === first) // hiding keeps the shell alive

        workspace.restartTerminal()
        #expect(workspace.terminal !== first)
        workspace.openFolder(FileManager.default.temporaryDirectory)
        #expect(workspace.terminal == nil)
        #expect(!workspace.isTerminalVisible)
    }
}

@MainActor
struct TerminalPerformanceTests {
    @Test func parsingAndRenderingThroughput() throws {
        let session = try TerminalSession(directory: FileManager.default.temporaryDirectory, command: ["/bin/cat"],
                                          columns: 200, rows: 60)
        defer { session.terminate() }
        let line = "\u{1b}[32m2026-11-13\u{1b}[0m INFO request handled path=/api/v1/items status=200 took=3ms\r\n"
        let chunk = Data(String(repeating: line, count: 1_000).utf8)
        let clock = ContinuousClock()

        var bytes = 0
        let parse = clock.measure {
            for _ in 0..<100 { session.feed(chunk); bytes += chunk.count }
        }
        let megabytesPerSecond = Double(bytes) / 1_048_576 / (Double(parse.components.attoseconds) / 1e18 + Double(parse.components.seconds))

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.session = session
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap) // warm up
        session.feed(chunk) // every row dirty
        let fullFrame = clock.measure { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let cleanFrame = clock.measure { view.cacheDisplay(in: view.bounds, to: bitmap) }

        print("PERF terminal parse=\(Int(megabytesPerSecond)) MB/s (\(bytes / 1024) KB in \(parse)), "
              + "full-dirty frame \(session.columns)x\(session.rows)=\(fullFrame), clean frame=\(cleanFrame)")
        #if !DEBUG
        #expect(megabytesPerSecond > 50)
        #expect(fullFrame < .milliseconds(16))
        #endif
    }
}
