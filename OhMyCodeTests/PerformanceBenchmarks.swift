import AppKit
import Testing
@testable import Oh_My_Code

/// Timings of the editor's hot paths on big files. Run with:
///
///     TEST_RUNNER_OMC_BENCH=1 xcodebuild … test -only-testing:OhMyCodeTests/PerformanceBenchmarks
///
/// Results are printed as `BENCH name: value`. Off in ordinary runs (they take a while).
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

    /// Opens a file in an editor in a window, as the app does.
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
            controller.textView.displayIfNeeded()
        }
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        return (document, controller, window, load, layout)
    }

    @Test(arguments: [1.0, 5.0, 20.0])
    func openTypeScroll(megabytes: Double) async throws {
        let url = try file(megabytes)
        let before = Self.residentMB()
        let (document, controller, window, load, layout) = try open(url)
        let label = "\(Int(megabytes))MB"
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

        // Typing in the middle: the synchronous part of each keystroke.
        let middle = document.lineIndex.lineStarts[document.lineIndex.lineCount / 2] + 8
        controller.textView.setSelectedRange(NSRange(location: middle, length: 0))
        controller.reveal(NSRange(location: middle, length: 0))
        controller.textView.displayIfNeeded()
        var samples: [Duration] = []
        for index in 0..<100 {
            let character = index % 10 == 9 ? "\n" : "a"
            samples.append(clock.measure {
                controller.textView.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
                controller.textView.displayIfNeeded()
            })
        }
        samples.sort()
        report("typing.median \(label)", ms(samples[samples.count / 2]))
        report("typing.p95 \(label)", ms(samples[samples.count * 95 / 100]))
        report("typing.max \(label)", ms(samples.last!))

        // Scrolling: a page down at a time, each drawn.
        let scrollView = try #require(controller.textView.enclosingScrollView)
        var scrolls: [Duration] = []
        for step in 1...30 {
            scrolls.append(clock.measure {
                let y = min(controller.textView.bounds.height - scrollView.contentSize.height, CGFloat(step) * scrollView.contentSize.height)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                controller.textView.layoutSubtreeIfNeeded()
                scrollView.displayIfNeeded()
            })
        }
        scrolls.sort()
        report("scroll.median \(label)", ms(scrolls[scrolls.count / 2]))
        report("scroll.max \(label)", ms(scrolls.last!))

        // The gutter drawn alone.
        let gutterDraw = clock.measure { for _ in 0..<20 { controller.gutterView.display() } }
        report("draw.gutter \(label)", ms(gutterDraw / 20))

        // Moving the cursor (selection change: symbol highlights, brackets, blame, lightbulb).
        let moveDuration = clock.measure {
            for index in 0..<100 { controller.textView.setSelectedRange(NSRange(location: middle + index, length: 0)) }
        }
        report("cursor.move \(label)", ms(moveDuration / 100))

        withExtendedLifetime(window) {}
        try? FileManager.default.removeItem(at: url)
    }
}
