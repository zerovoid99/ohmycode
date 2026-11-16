import AppKit
import Darwin

/// Launch timing, on with `OMC_LAUNCH_TRACE=1` (the launch benchmark sets it): milestones are
/// timed from the process's start (as the kernel recorded it, so dyld and static setup count)
/// and printed as `LAUNCH name: 12.3 ms` once every one named in `OMC_LAUNCH_TRACE_UNTIL`
/// (comma-separated) is reached; then the app exits at once (nothing saved, no quit dialogs).
/// Windows are made transparent and click-through, so a traced launch shows and takes nothing
/// on screen. Milestones are also Points of Interest events, for Instruments.
///
/// Milestones: `app.init`, `app.didFinishLaunching`, `window.attached`, `window.visible`,
/// `editor.firstLayout`, `editor.firstDraw` (the gutter's first draw), `highlight.first`.
@MainActor
enum LaunchTrace {
    nonisolated static let isEnabled = ProcessInfo.processInfo.environment["OMC_LAUNCH_TRACE"] == "1"

    @inline(__always)
    static func mark(_ name: String) {
        if isEnabled { record(name) }
    }

    private static var marks: [(name: String, ms: Double)] = []
    private static let until = Set((ProcessInfo.processInfo.environment["OMC_LAUNCH_TRACE_UNTIL"] ?? "")
        .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    private static var finished = false

    /// When the kernel started this process (seconds since 1970, like `Date`).
    private static let processStart: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }()

    private static func record(_ name: String) {
        let now = Date().timeIntervalSince1970
        guard !finished, !marks.contains(where: { $0.name == name }) else { return }
        if marks.isEmpty {
            // A launch that never gets there still ends.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { finish(timedOut: true) }
        }
        marks.append((name, (now - processStart) * 1000))
        Signposts.event("Launch", name)
        if !until.isEmpty, until.isSubset(of: marks.map(\.name)) { finish(timedOut: false) }
    }

    private static func finish(timedOut: Bool) {
        guard !finished else { return }
        finished = true
        for mark in marks { print("LAUNCH \(mark.name): " + String(format: "%.1f ms", mark.ms)) }
        if timedOut { print("LAUNCH timeout: waiting for \(until.subtracting(marks.map(\.name)).sorted())") }
        fflush(stdout)
        exit(timedOut ? 1 : 0)
    }

    /// A window got its content: hidden from the screen, and watched until it's ordered in.
    static func windowAttached(_ window: NSWindow) {
        guard isEnabled else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        record("window.attached")
        waitUntilVisible(window)
    }

    private static func waitUntilVisible(_ window: NSWindow) {
        guard !window.isVisible else { return record("window.visible") }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { waitUntilVisible(window) }
    }
}
