import AppKit
import Metal
import QuartzCore
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
        // What the GPU actually drew (rendered offscreen, read back).
        let bitmap = try #require(view.snapshot(scale: 2))
        #expect(bitmap.pixelsWide == 1000)
        var red = 0, light = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<min(bitmap.pixelsHigh, 120) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.6 && c.greenComponent < 0.45 && c.blueComponent < 0.45 { red += 1 }
                if c.brightnessComponent > 0.7 && c.saturationComponent < 0.2 { light += 1 }
            }
        }
        #expect(red > 50, "red SGR text not drawn")
        #expect(light > 50, "default foreground text not drawn")
    }

    /// Backgrounds, a block cursor, emoji in color, and rows surviving an atlas reset.
    @Test func drawsBackgroundsCursorAndColorGlyphs() async throws {
        let session = try TerminalSession(directory: FileManager.default.temporaryDirectory, command: [
            "/bin/sh", "-c", #"printf '\033[44m  BLUE  \033[0m \360\237\230\200 \033[4munder\033[0m\n> '; sleep 5"#,
        ])
        defer { session.terminate() }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.session = session
        for _ in 0..<250 where !(session.text(selectionOnly: false) ?? "").contains("under") {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100)) // the prompt after it

        func count(_ bitmap: NSBitmapImageRep, rows: Range<Int>, columns: Range<Int>,
                   _ match: (NSColor) -> Bool) -> Int {
            var total = 0
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let y0 = Int((TerminalView.padding + CGFloat(rows.lowerBound) * view.cellHeight) * scale)
            let y1 = Int((TerminalView.padding + CGFloat(rows.upperBound) * view.cellHeight) * scale)
            let x0 = Int((TerminalView.padding + CGFloat(columns.lowerBound) * view.cellWidth) * scale)
            let x1 = Int((TerminalView.padding + CGFloat(columns.upperBound) * view.cellWidth) * scale)
            for y in y0..<y1 { for x in x0..<x1 {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), match(c) { total += 1 }
            } }
            return total
        }
        let isBlue: (NSColor) -> Bool = { $0.blueComponent > $0.redComponent + 0.15 && $0.saturationComponent > 0.25 }
        let isEmojiYellow: (NSColor) -> Bool = { $0.redComponent > 0.8 && $0.greenComponent > 0.6 && $0.blueComponent < 0.4 }
        let isLight: (NSColor) -> Bool = { $0.brightnessComponent > 0.7 && $0.saturationComponent < 0.2 }

        for pass in 0..<2 {
            if pass == 1 {
                // Cached rows must be rebuilt: after a reset, other glyphs reuse the atlas space.
                let atlas = try #require(TerminalRenderer.shared?.atlas)
                atlas.reset()
                for scalar in UnicodeScalar("A").value...UnicodeScalar("z").value {
                    _ = atlas.glyph(String(UnicodeScalar(scalar)!), font: .boldSystemFont(ofSize: 30), scale: 2)
                }
            }
            let bitmap = try #require(view.snapshot(scale: 2))
            let cellArea = Int(view.cellWidth * view.cellHeight * 4)
            #expect(count(bitmap, rows: 0..<1, columns: 0..<8, isBlue) > cellArea * 4, "background run not filled (pass \(pass))")
            #expect(count(bitmap, rows: 0..<1, columns: 9..<11, isEmojiYellow) > 20, "emoji not drawn in color (pass \(pass))")
            #expect(count(bitmap, rows: 0..<1, columns: 12..<17, isLight) > 20, "underlined text missing (pass \(pass))")
            // Unfocused: a hollow cursor after "> " (an outline, not a filled cell).
            let cursorPixels = count(bitmap, rows: 1..<2, columns: 2..<3, isLight)
            #expect(cursorPixels > 40 && cursorPixels < cellArea / 2, "hollow cursor not drawn (pass \(pass)): \(cursorPixels) px, cell \(cellArea)")
        }

        // Focused: a filled block.
        view.focusOverride = true
        let focused = try #require(view.snapshot(scale: 2))
        let cellArea = Int(view.cellWidth * view.cellHeight * 4)
        #expect(count(focused, rows: 1..<2, columns: 2..<3, isLight) > cellArea * 3 / 4, "block cursor not drawn")

        // On screen, the display link renders into the view's Metal layer at the window's scale,
        // once per change: new output wakes it, an idle terminal draws nothing.
        window.orderFront(nil)
        for _ in 0..<50 where view.presentedFrames == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let framesWhenIdle = view.presentedFrames
        try await Task.sleep(for: .milliseconds(200))
        #expect(view.presentedFrames == framesWhenIdle, "an idle terminal keeps rendering")
        session.feed(Data("more output\r\n".utf8))
        for _ in 0..<50 where view.presentedFrames == framesWhenIdle { try await Task.sleep(for: .milliseconds(20)) }
        #expect(view.presentedFrames == framesWhenIdle + 1, "frames: \(framesWhenIdle) → \(view.presentedFrames)")
        let layer = try #require(view.layer as? CAMetalLayer)
        #expect(view.presentedFrames >= 1)
        #expect(layer.drawableSize.width == (view.bounds.width * window.backingScaleFactor).rounded())
        window.orderOut(nil)
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
        _ = view.makeFrame(scale: 2) // warm up the glyph atlas
        session.feed(chunk) // every row dirty
        // CPU cost on the main thread: rebuild every row's geometry. Then the GPU's part.
        var frame = TerminalFrame()
        let fullFrame = clock.measure { frame = view.makeFrame(scale: 2) }
        let cleanFrame = clock.measure { frame = view.makeFrame(scale: 2) }
        let renderer = try #require(TerminalRenderer.shared)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: TerminalRenderer.pixelFormat,
                                                                  width: 3200, height: 2000, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        renderer.render(frame, to: texture)?.waitUntilCompleted() // warm up
        let gpu = clock.measure { renderer.render(frame, to: texture)?.waitUntilCompleted() }

        print("PERF terminal parse=\(Int(megabytesPerSecond)) MB/s (\(bytes / 1024) KB in \(parse)), "
              + "\(session.columns)x\(session.rows) full-dirty frame (CPU)=\(fullFrame), clean frame (CPU)=\(cleanFrame), "
              + "GPU encode+render 3200x2000=\(gpu), glyphs=\(frame.glyphs.count) rects=\(frame.rects.count)")
        #if !DEBUG
        #expect(megabytesPerSecond > 50)
        #expect(fullFrame < .milliseconds(4))
        #expect(gpu < .milliseconds(8))
        #endif
    }
}

/// Drives a real TerminalView with synthesized AppKit events; `cat -v` echoes what reached the
/// program, making escape sequences visible as text (ESC shows as ^[).
@MainActor
struct TerminalInputTests {
    private func makeView(_ command: [String] = ["/bin/cat", "-v"]) throws -> (TerminalView, TerminalSession, NSWindow) {
        let session = try TerminalSession(directory: FileManager.default.temporaryDirectory, command: command)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.session = session
        window.makeFirstResponder(view)
        return (view, session, window)
    }

    private func screen(_ session: TerminalSession) -> String { session.text(selectionOnly: false) ?? "" }

    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// `xFraction` is where in the cell the pointer is: a drag includes the end cell only past
    /// its midpoint, as with macOS text selection.
    private func mouse(_ type: NSEvent.EventType, in view: TerminalView, column: Int, row: Int, xFraction: CGFloat = 0.5,
                       clickCount: Int = 1, time: TimeInterval = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let point = NSPoint(x: TerminalView.padding + (CGFloat(column) + xFraction) * view.cellWidth,
                            y: TerminalView.padding + (CGFloat(row) + 0.5) * view.cellHeight)
        return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags,
                                  timestamp: time, windowNumber: view.window!.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func typingGoesThroughTheInputMethod() async throws {
        let (view, session, window) = try makeView()
        defer { session.terminate() }
        view.keyDown(with: key("a", code: 0, in: window))
        view.keyDown(with: key("b", code: 11, in: window))
        view.keyDown(with: key("\r", code: 36, in: window))
        #expect(try await eventually { screen(session).contains("ab\nab") })
    }

    @Test func composedTextIsHeldUntilCommitted() async throws {
        let (view, session, _) = try makeView()
        defer { session.terminate() }
        view.setMarkedText("かん", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        try await Task.sleep(for: .milliseconds(150))
        #expect(!screen(session).contains("かん"), "uncommitted text must not reach the program")

        view.insertText("漢字", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(try await eventually { screen(session).contains("漢字") })
    }

    @Test func clicksAreReportedWhenTheProgramTracksTheMouse() async throws {
        let (view, session, _) = try makeView()
        defer { session.terminate() }
        session.feed(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8)) // normal tracking, SGR format
        view.mouseDown(with: mouse(.leftMouseDown, in: view, column: 2, row: 1))
        view.mouseUp(with: mouse(.leftMouseUp, in: view, column: 2, row: 1))
        // SGR is 1-based: column 3, row 2; M = press, m = release.
        #expect(try await eventually { screen(session).contains("^[[<0;3;2M^[[<0;3;2m") })
    }

    @Test func shiftClickSelectsLocallyEvenWithTracking() async throws {
        let (view, session, _) = try makeView()
        defer { session.terminate() }
        session.feed(Data("\u{1b}[?1000h\u{1b}[?1006hhello world".utf8))
        view.mouseDown(with: mouse(.leftMouseDown, in: view, column: 0, row: 0, xFraction: 0.1, flags: .shift))
        view.mouseDragged(with: mouse(.leftMouseDragged, in: view, column: 4, row: 0, xFraction: 0.9, flags: .shift))
        view.mouseUp(with: mouse(.leftMouseUp, in: view, column: 4, row: 0, xFraction: 0.9, flags: .shift))
        try await Task.sleep(for: .milliseconds(150))
        #expect(!screen(session).contains("^[[<"))
        #expect(session.text(selectionOnly: true) == "hello")
    }

    @Test func doubleClickSelectsWordTripleClickSelectsLine() throws {
        let (view, session, _) = try makeView()
        defer { session.terminate() }
        session.feed(Data("hello world foo".utf8))
        for clicks in 1...2 {
            let time = Double(clicks) * 0.05
            view.mouseDown(with: mouse(.leftMouseDown, in: view, column: 7, row: 0, clickCount: clicks, time: time))
            view.mouseUp(with: mouse(.leftMouseUp, in: view, column: 7, row: 0, clickCount: clicks, time: time))
        }
        #expect(session.text(selectionOnly: true) == "world")

        view.mouseDown(with: mouse(.leftMouseDown, in: view, column: 7, row: 0, clickCount: 3, time: 0.15))
        view.mouseUp(with: mouse(.leftMouseUp, in: view, column: 7, row: 0, clickCount: 3, time: 0.15))
        #expect(session.text(selectionOnly: true) == "hello world foo")

        // A later single click clears it.
        view.mouseDown(with: mouse(.leftMouseDown, in: view, column: 1, row: 0, time: 5))
        view.mouseUp(with: mouse(.leftMouseUp, in: view, column: 1, row: 0, time: 5))
        #expect(!session.hasSelection)
    }

    @Test func wheelSendsArrowsInFullScreenPrograms() async throws {
        let (view, session, _) = try makeView()
        defer { session.terminate() }
        let geometry = TerminalSession.Geometry(width: 600, height: 300, cellWidth: view.cellWidth,
                                                cellHeight: view.cellHeight, padding: TerminalView.padding)
        session.feed(Data("\u{1b}[?1049h".utf8)) // alternate screen, as less/man use
        session.scrollWheel(rows: 2, x: 10, y: 10, geometry: geometry, mods: 0)
        #expect(try await eventually { screen(session).contains("^[[A^[[A") })
    }
}

@MainActor
struct TerminalTabsTests {
    @Test func newSelectCloseAndRestartTabs() throws {
        let workspace = Workspace()
        workspace.openFolder(FileManager.default.temporaryDirectory)
        workspace.newTerminal()
        workspace.newTerminal()
        #expect(workspace.terminals.count == 2)
        let first = workspace.terminals[0], second = workspace.terminals[1]
        #expect(workspace.terminal === second)

        workspace.selectTerminal(first)
        #expect(workspace.terminal === first)

        workspace.restartTerminal()
        #expect(workspace.terminals.count == 2)
        #expect(workspace.terminals[0] !== first) // replaced in place
        #expect(workspace.terminal === workspace.terminals[0])

        workspace.closeTerminal(workspace.terminals[0])
        #expect(workspace.terminal === second)
        workspace.closeTerminal(second)
        #expect(workspace.terminals.isEmpty)
        #expect(!workspace.isTerminalVisible)
    }
}

@MainActor
struct TerminalSplitTests {
    @Test func splitsShareATabAndCloseIntoTheirNeighbour() throws {
        let workspace = Workspace()
        workspace.openFolder(FileManager.default.temporaryDirectory)
        defer { workspace.terminals.forEach { workspace.closeTerminal($0) } }
        workspace.newTerminal()
        let a = try #require(workspace.terminal)
        workspace.splitTerminal()
        let b = try #require(workspace.terminal)
        #expect(a !== b && workspace.terminalGroups == [[a.id, b.id]])
        #expect(workspace.activeTerminalGroup.map(\.id) == [a.id, b.id])
        workspace.newTerminal()
        let c = try #require(workspace.terminal)
        #expect(workspace.terminalGroups == [[a.id, b.id], [c.id]] && workspace.activeTerminalGroup.map(\.id) == [c.id])

        // A split inserts after the active pane.
        workspace.selectTerminal(a)
        workspace.splitTerminal()
        let d = try #require(workspace.terminal)
        #expect(workspace.terminalGroups == [[a.id, d.id, b.id], [c.id]])

        // Closing a pane: its left neighbour in the split takes over.
        workspace.closeTerminal(d)
        #expect(workspace.terminal === a && workspace.terminalGroups == [[a.id, b.id], [c.id]])
        // Restarting keeps its place (and name).
        a.customName = "server"
        workspace.restartTerminal()
        let restarted = try #require(workspace.terminal)
        #expect(workspace.terminalGroups == [[restarted.id, b.id], [c.id]] && restarted.displayTitle == "server")
        // The last pane of a tab: the tab goes, the next tab is shown.
        workspace.closeTerminal(restarted)
        workspace.closeTerminal(b)
        #expect(workspace.terminalGroups == [[c.id]] && workspace.terminal === c)
    }

    @Test func renameShowsTheNameUntilCleared() throws {
        let workspace = Workspace()
        workspace.openFolder(FileManager.default.temporaryDirectory)
        workspace.newTerminal()
        let session = try #require(workspace.terminal)
        defer { workspace.closeTerminal(session) }
        let saved = Workspace.promptForName
        defer { Workspace.promptForName = saved }
        Workspace.promptForName = { _, _ in "build" }
        workspace.renameTerminal()
        #expect(session.displayTitle == "build" && session.customName == "build")
        Workspace.promptForName = { _, _ in session.title } // back to the shell's own title
        workspace.renameTerminal()
        #expect(session.customName == nil)
    }
}

struct PTYProcessTests {
    /// Starts `arguments`, terminates it, and waits for it to be gone. A zombie still answers
    /// kill(pid, 0); only once reaped (by the process object, not here) is it gone.
    private func terminateAndWait(_ arguments: [String]) async throws -> pid_t {
        let process = try PTYProcess(executable: arguments[0], arguments: arguments, environment: [:],
                                     directory: "/", size: PTYProcess.Size(columns: 80, rows: 24))
        let pid = process.pid
        try await Task.sleep(for: .milliseconds(200)) // started (and set up its traps)
        #expect(kill(pid, 0) == 0)
        process.terminate()
        process.write(Data("ignored after close\n".utf8)) // the fd is gone: nothing written, no crash
        process.resize(PTYProcess.Size(columns: 100, rows: 30))
        let deadline = ContinuousClock.now + .seconds(10)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return pid
    }

    private func isReaped(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        guard kill(pid, 0) == -1, errno == ESRCH else { return false }
        return waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD
    }

    /// Closing a terminal hangs up its shell and reaps it: no zombie left behind.
    @Test func terminateReapsTheChild() async throws {
        #expect(isReaped(try await terminateAndWait(["/bin/sleep", "30"])))
    }

    /// One that ignores the hangup is killed after a while, and reaped too.
    @Test func terminateKillsAChildIgnoringTheHangup() async throws {
        #expect(isReaped(try await terminateAndWait(["/bin/sh", "-c", "trap '' HUP; exec /bin/sleep 30"])))
    }
}
