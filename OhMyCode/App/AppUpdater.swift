import AppKit
import os
import Sparkle

/// Updates from the GitHub releases, through Sparkle. Each release carries an `appcast.xml`
/// (made by scripts/release.sh) describing its DMG and that DMG's EdDSA signature; the feed is
/// the latest release's (`SUFeedURL`), and an update is only installed if its signature matches
/// `SUPublicEDKey`. Sparkle checks at launch and daily (`SUScheduledCheckInterval`), asks before
/// downloading, and relaunches into the new version.
///
/// Off in tests and traced launches, and in debug builds (which would offer to replace
/// themselves with a release) unless `OMC_UPDATE_FEED` names a feed to try: that feed is used
/// instead of the releases', in any build.
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// False while a check or an update is under way.
    private(set) var canCheckForUpdates = false

    /// Whether this build updates itself at all.
    var isAvailable: Bool { controller != nil }

    nonisolated private static var feedOverride: String? {
        ProcessInfo.processInfo.environment["OMC_UPDATE_FEED"]
    }

    private override init() {
        super.init()
        #if DEBUG
        let enabled = Self.feedOverride != nil
        #else
        let enabled = true
        #endif
        guard enabled, !AppSettings.isRunningTests, !LaunchTrace.isEnabled else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        Self.log.info("\("updater started: automatic checks \(updater.automaticallyChecksForUpdates), every \(updater.updateCheckInterval)s, last \(String(describing: updater.lastUpdateCheckDate)), feed \(String(describing: updater.feedURL))", privacy: .public)")
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let can = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
    }

    /// Starts the updater (at launch; its scheduled checks run from then on).
    static func start() { _ = shared }

    /// "Check for Updates…": shows what it finds, or that this is the latest version.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Checking at launch and daily (Sparkle keeps the setting).
    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// When updates were last looked for.
    var lastCheck: Date? {
        access(keyPath: \.canCheckForUpdates) // changes as a check starts and ends
        return controller?.updater.lastUpdateCheckDate
    }

    // MARK: SPUUpdaterDelegate

    nonisolated private static let log = Logger(subsystem: "dev.zerovoid99.ohmycode", category: "updates")

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedOverride
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Self.log.info("\("found \(item.displayVersionString) (\(item.versionString))", privacy: .public)")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Self.log.info("\("no update: \(error.localizedDescription)", privacy: .public)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Self.log.error("\("update aborted: \(error.localizedDescription)", privacy: .public)")
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Self.log.info("\("installing \(item.displayVersionString)", privacy: .public)")
    }
}
