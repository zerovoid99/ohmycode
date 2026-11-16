import AppKit
import Testing
@testable import Oh_My_Code

/// Timings of the editor's hot paths on big files. Run with:
///
///     TEST_RUNNER_OMC_BENCH=1 xcodebuild … test -only-testing:OhMyCodeTests/PerformanceBenchmarks
///
/// Results are printed as `BENCH name: value`. Off in ordinary runs (they take a while).
///
/// Typing, scrolling and cursor moves are timed with their drawing: each step ends as an event
/// does, with layout and the Core Animation commit, where views draw what the step left dirty
/// (text, gutter, overlay). Until November 2026 steps ended with `displayIfNeeded` alone, which
/// draws nothing; the `.nodraw` numbers leave drawing out, comparable with those older runs.
/// `check.windowDraws` says whether drawing really happens. The window is never ordered in.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OMC_BENCH"] == "1"))
struct PerformanceBenchmarks {
    /// Swift-like code: declarations, comments, strings, nesting.
    static func code(bytes: Int) -> String {
        let block = """
        /// A point in the plane, with some helpers.
        struct Point: Equatable {
            var x: Int = 0
            var y: Int = 0

            func moved(by delta: Int) -> Point {
                let next = Point(x: x + delta, y: y + delta)
                if next.x > 10 {
                    print("far away: \\(next.x), \\(next.y)") // log it
                }
                return next
            }
        }

        """
        let count = bytes / block.utf8.count + 1
        var text = ""
        text.reserveCapacity(count * block.utf8.count)
        for index in 0..<count { text += block.replacingOccurrences(of: "Point", with: "Point\(index % 500)") }
        return text
    }

    private func file(_ megabytes: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-bench-\(megabytes)mb-\(UUID().uuidString).swift")
        try Self.code(bytes: Int(megabytes * 1_000_000)).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func ms(_ duration: Duration) -> String {
        String(format: "%.2f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }

    private func report(_ name: String, _ value: String) { print("BENCH \(name): \(value)") }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    /// Counts its draws: tells whether the benchmark window really draws.
    private final class DrawCounter: NSView {
        var draws = 0
        override func draw(_ dirtyRect: NSRect) { draws += 1 }
    }

    /// Draws what's dirty, as the end of an event does: layout, then the Core Animation commit,
    /// where layer-backed views (all of them) draw. `displayIfNeeded` alone draws nothing: views
    /// draw into their layers at the commit, which the run loop does after each event and the
    /// benchmark does here. Works in a window that's never ordered in, so nothing is shown.
    private func draw(_ window: NSWindow) {
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// Opens a file in an editor in a window, as the app does. `layout` includes the first draw.
    private func open(_ url: URL) throws -> (EditorDocument, EditorController, NSWindow, Duration, Duration) {
        let clock = ContinuousClock()
        var document: EditorDocument!
        let load = try clock.measure { document = try EditorDocument(url: url) }
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let layout = clock.measure {
            window.contentView = controller.makeView()
            window.layoutIfNeeded()
            controller.textView.layoutSubtreeIfNeeded()
            draw(window)
        }
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        return (document, controller, window, load, layout)
    }

    /// One event's worth of work: `change` (the edit, scroll or selection change), then what it
    /// left dirty drawn, as AppKit does at the end of an event.
    private func step(_ window: NSWindow, _ change: () -> Void) -> (change: Duration, draw: Duration) {
        let clock = ContinuousClock()
        let changed = clock.measure(change)
        let drawn = clock.measure { draw(window) }
        return (changed, drawn)
    }

    private func median(_ samples: [Duration]) -> Duration { samples.sorted()[samples.count / 2] }
    private func p95(_ samples: [Duration]) -> Duration { samples.sorted()[samples.count * 95 / 100] }
    private func mean(_ samples: [Duration]) -> Duration { samples.reduce(.zero, +) / samples.count }

    @Test(arguments: [1.0, 5.0, 20.0])
    func openTypeScroll(megabytes: Double) async throws {
        let url = try file(megabytes)
        let before = Self.residentMB()
        let (document, controller, window, load, layout) = try open(url)
        let label = "\(Int(megabytes))MB"

        let counter = DrawCounter(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        window.contentView?.addSubview(counter)
        counter.needsDisplay = true
        draw(window)
        report("check.windowDraws \(label)", counter.draws > 0 ? "yes" : "NO (drawing isn't measured)")
        counter.removeFromSuperview()

        report("open.load \(label)", ms(load))
        report("open.firstLayout \(label)", ms(layout))
        // Background work after opening (parse, folds, symbols).
        let clock = ContinuousClock()
        let settle = await clock.measure {
            await document.highlighter?.waitUntilIdle()
            await document.waitForFoldRegions()
        }
        report("open.backgroundParse \(label)", ms(settle))
        report("memory.afterOpen \(label)", String(format: "%.0f MB (+%.0f)", Self.residentMB(), Self.residentMB() - before))

        // Typing in the middle: each keystroke's synchronous work, then its drawing.
        let middle = document.lineIndex.lineStarts[document.lineIndex.lineCount / 2] + 8
        controller.textView.setSelectedRange(NSRange(location: middle, length: 0))
        controller.reveal(NSRange(location: middle, length: 0))
        draw(window)
        var typing: [(change: Duration, draw: Duration)] = []
        for index in 0..<100 {
            let character = index % 10 == 9 ? "\n" : "a"
            typing.append(step(window) {
                controller.textView.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            })
        }
        let typingTotal = typing.map { $0.change + $0.draw }
        report("typing.median \(label)", ms(median(typingTotal)))
        report("typing.p95 \(label)", ms(p95(typingTotal)))
        report("typing.max \(label)", ms(typingTotal.max()!))
        report("typing.nodraw.median \(label)", ms(median(typing.map(\.change))))
        report("typing.draw.median \(label)", ms(median(typing.map(\.draw))))

        // Scrolling: a page down at a time, each laid out and drawn.
        let scrollView = try #require(controller.textView.enclosingScrollView)
        var scrolls: [(change: Duration, draw: Duration)] = []
        for page in 1...30 {
            scrolls.append(step(window) {
                let y = min(controller.textView.bounds.height - scrollView.contentSize.height, CGFloat(page) * scrollView.contentSize.height)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                controller.textView.layoutSubtreeIfNeeded()
            })
        }
        let scrollTotal = scrolls.map { $0.change + $0.draw }
        report("scroll.median \(label)", ms(median(scrollTotal)))
        report("scroll.max \(label)", ms(scrollTotal.max()!))
        report("scroll.nodraw.median \(label)", ms(median(scrolls.map(\.change))))

        // The gutter and the overlay each drawn whole, alone.
        let gutterDraw = clock.measure { for _ in 0..<20 { controller.gutterView.display() } }
        report("draw.gutter \(label)", ms(gutterDraw / 20))
        if let overlay = controller.diagnosticsOverlay {
            let overlayDraw = clock.measure { for _ in 0..<20 { overlay.display() } }
            report("draw.overlay \(label)", ms(overlayDraw / 20))
        }

        // Moving the cursor (selection change: symbol highlights, brackets, blame, lightbulb),
        // then its drawing (current line, gutter, overlay). Means, as before.
        var moves: [(change: Duration, draw: Duration)] = []
        for index in 0..<100 {
            moves.append(step(window) { controller.textView.setSelectedRange(NSRange(location: middle + index, length: 0)) })
        }
        report("cursor.move \(label)", ms(mean(moves.map { $0.change + $0.draw })))
        report("cursor.move.nodraw \(label)", ms(mean(moves.map(\.change))))

        withExtendedLifetime(window) {}
        try? FileManager.default.removeItem(at: url)
    }

    /// Applying syntax colors: after each keystroke's parse, and after each scroll step. The
    /// editor is taken off the highlighter so the colors are applied here, timed alone (their
    /// drawing is in `openTypeScroll`'s typing and scrolling).
    @Test func applyHighlights() async throws {
        let url = try file(1)
        defer { try? FileManager.default.removeItem(at: url) }
        let (document, controller, window, _, _) = try open(url)
        let highlighter = try #require(document.highlighter)
        await highlighter.waitUntilIdle()
        highlighter.removeClient(controller)
        let clock = ContinuousClock()
        let middle = document.lineIndex.lineStarts[document.lineIndex.lineCount / 2] + 8
        controller.textView.setSelectedRange(NSRange(location: middle, length: 0))
        controller.reveal(NSRange(location: middle, length: 0))
        draw(window)
        func apply() async throws -> (Duration, Int, Int) {
            guard let range = controller.highlightRange else { return (.zero, 0, 0) } // nothing laid out
            let highlights = await highlighter.highlights(in: range)
            return (clock.measure { controller.applyHighlights(highlights, in: range) }, highlights.count, range.length)
        }
        _ = try await apply()
        var keys: [Duration] = [], captures = 0, length = 0
        for index in 0..<60 {
            controller.textView.insertText(index % 10 == 9 ? "\n" : "a", replacementRange: NSRange(location: NSNotFound, length: 0))
            draw(window)
            let (time, count, rangeLength) = try await apply()
            keys.append(time)
            (captures, length) = (count, rangeLength)
        }
        report("highlights.keystroke median (\(captures) captures, \(length) chars)", ms(median(keys)))
        report("highlights.keystroke p95", ms(p95(keys)))

        let scrollView = try #require(controller.textView.enclosingScrollView)
        var scrolls: [Duration] = []
        for _ in 0..<40 {
            var origin = scrollView.contentView.bounds.origin
            origin.y += scrollView.contentSize.height / 2 // half a screen: past the highlighted range's overscan, sometimes
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            controller.textView.layoutSubtreeIfNeeded()
            controller.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            scrolls.append(try await apply().0)
        }
        report("highlights.scrollStep median", ms(median(scrolls)))
        report("highlights.scrollStep p95", ms(p95(scrolls)))
        withExtendedLifetime(window) {}
    }
}
