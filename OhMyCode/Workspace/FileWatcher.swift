import CoreServices
import Foundation

/// Recursive file-system watcher backed by FSEvents, delivering per-file events on the main thread.
/// FSEvents coalesces bursts within `latency`, so a build touching thousands of files costs a few
/// callbacks, not thousands.
/// `@unchecked Sendable`: the stream is created, delivered on and torn down from the main queue only.
final class FileWatcher: @unchecked Sendable {
    struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags

        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        var isStructural: Bool {
            has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved)
                || has(kFSEventStreamEventFlagItemRenamed)
        }
        var requiresRescan: Bool {
            has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagRootChanged)
                || has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped)
        }
    }

    private var stream: FSEventStreamRef?
    private let handler: @MainActor ([Event]) -> Void

    init?(path: String, latency: TimeInterval = 0.15, handler: @escaping @MainActor ([Event]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathList = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let events = (0..<count).map { Event(path: pathList[$0], flags: flags[$0]) }
            // Scheduled on the main queue below.
            MainActor.assumeIsolated { watcher.handler(events) }
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Canonical path as FSEvents reports it (e.g. `/var` → `/private/var`).
    /// `URL.resolvingSymlinksInPath()` strips `/private`, so use realpath(3).
    static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
