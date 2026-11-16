import os

/// Points of Interest intervals around the editor's hot paths (open, edit, highlight, parse,
/// gutter and overlay drawing), shown by Instruments. `begin` returns nil, and nothing else
/// happens, unless something is recording: one flag check per call.
///
///     let signpost = Signposts.begin("Name"); defer { Signposts.end("Name", signpost) }
enum Signposts {
    nonisolated static let log = OSLog(subsystem: "dev.zerovoid99.ohmycode", category: .pointsOfInterest)

    @inline(__always)
    nonisolated static func begin(_ name: StaticString) -> OSSignpostID? {
        guard log.signpostsEnabled else { return nil }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    @inline(__always)
    nonisolated static func end(_ name: StaticString, _ id: OSSignpostID?) {
        guard let id else { return }
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    /// A single point in time (launch milestones).
    nonisolated static func event(_ name: StaticString, _ message: String) {
        guard log.signpostsEnabled else { return }
        os_signpost(.event, log: log, name: name, "%{public}s", message)
    }
}
