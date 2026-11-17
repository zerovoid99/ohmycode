import AppKit
import Observation

/// Everything that makes the editor yours, in one file: settings, keyboard shortcuts, snippets
/// and which extensions are off.
struct SettingsProfile: Codable, Equatable {
    var name: String
    var settings: [String: JSONValue]
    var keybindings: [Keybindings.Rule]
    /// The user's snippet files, by name.
    var snippets: [String: String]
    var disabledExtensions: [String]
    var savedAt: Date

    static let fileExtension = "omcprofile"

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> SettingsProfile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SettingsProfile.self, from: Data(contentsOf: url))
    }
}

/// Named profiles to switch between ("Work", "Presenting"), kept as files in a folder: the
/// app's, or one you sync (iCloud Drive, Dropbox, a git repository), so other Macs share them.
/// The current profile's file follows your changes; coming back to the app picks up a newer
/// one written elsewhere.
@MainActor
@Observable
final class ProfileManager {
    static let shared = ProfileManager(
        defaults: AppSettings.isRunningTests ? UserDefaults(suiteName: "dev.zerovoid99.ohmycode.tests.profiles")! : .standard,
        appFolder: AppSettings.isRunningTests
            ? FileManager.default.temporaryDirectory.appending(path: "omc-test-profiles-\(ProcessInfo.processInfo.processIdentifier)")
            : URL.omcApplicationSupport.appending(path: "OhMyCode/Profiles"))

    struct Parts {
        var settings: AppSettings
        var keybindings: Keybindings
        var snippets: SnippetLibrary
        var extensions: ExtensionStore
    }

    static let defaultName = "Default"

    private(set) var current: String
    private(set) var names: [String] = []
    /// A folder chosen to sync through (nil: the app's own).
    private(set) var syncFolder: URL?
    private(set) var lastError: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appFolder: URL
    @ObservationIgnored private var parts: Parts?
    /// When the current profile's file was last written or read here (kept across launches:
    /// only a newer file, written elsewhere, is applied).
    private var knownDate: Date? {
        get { defaults.object(forKey: "profiles.known.\(url(for: current).path)") as? Date }
        set { defaults.set(newValue, forKey: "profiles.known.\(url(for: current).path)") }
    }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isApplying = false

    init(defaults: UserDefaults, appFolder: URL) {
        self.defaults = defaults
        self.appFolder = appFolder
        current = defaults.string(forKey: "profiles.current") ?? Self.defaultName
        syncFolder = defaults.string(forKey: "profiles.syncFolder").map { URL(filePath: $0) }
        reloadNames()
    }

    var folder: URL { syncFolder ?? appFolder }
    /// Its stored state (tests make a second manager over it, as a relaunch).
    var defaultsForTesting: UserDefaults { defaults }

    func url(for name: String) -> URL { folder.appending(path: "\(name).\(SettingsProfile.fileExtension)") }

    /// What profiles capture and change (the app's shared settings, by default).
    func attach(_ parts: Parts) {
        self.parts = parts
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        // Changes are written to the current profile shortly after.
        for name in [AppSettings.didChange, ExtensionStore.didChange, Keybindings.didChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSave() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullIfChanged() }
        })
        // Leaving the app: what changed unannounced (snippet files) goes into the profile too.
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        })
        // This Mac's state is the profile's, unless another Mac wrote a newer one since.
        if knownDate != nil, FileManager.default.fileExists(atPath: url(for: current).path) { pullIfChanged() } else { saveNow() }
    }

    func reloadNames() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var found = files.filter { $0.hasSuffix("." + SettingsProfile.fileExtension) }
            .map { ($0 as NSString).deletingPathExtension }
        if !found.contains(current) { found.append(current) }
        names = found.sorted { $0 == Self.defaultName ? true : $1 == Self.defaultName ? false : $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Capturing and applying

    func capture(name: String? = nil) -> SettingsProfile? {
        guard let parts else { return nil }
        return SettingsProfile(name: name ?? current, settings: parts.settings.snapshot, keybindings: parts.keybindings.rules,
                               snippets: parts.snippets.userFiles(), disabledExtensions: parts.extensions.disabledIDs,
                               savedAt: Date())
    }

    func apply(_ profile: SettingsProfile) {
        guard let parts else { return }
        isApplying = true
        defer { isApplying = false }
        parts.settings.apply(profile.settings)
        parts.keybindings.replaceRules(profile.keybindings)
        do { try parts.snippets.replaceUserFiles(profile.snippets) } catch { lastError = error.localizedDescription }
        parts.extensions.disabledIDs = profile.disabledExtensions
    }

    // MARK: The current profile's file

    private func scheduleSave() {
        guard !isApplying else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the current state to the current profile (snippet edits aren't watched: they're
    /// written with the next other change, a switch, or this).
    func saveNow() {
        saveTask?.cancel()
        guard let profile = capture() else { return }
        do {
            try profile.write(to: url(for: current))
            knownDate = Self.modificationDate(url(for: current))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reloadNames()
    }

    /// Another Mac (through the sync folder) wrote the current profile since: use it.
    func pullIfChanged() {
        let url = url(for: current)
        guard let date = Self.modificationDate(url), knownDate.map({ date > $0 }) ?? !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let profile = try SettingsProfile.read(from: url)
            knownDate = date
            apply(profile)
        } catch {
            lastError = "\(url.lastPathComponent) can't be read: \(error.localizedDescription)"
        }
        reloadNames()
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    // MARK: Managing

    /// Saves the current profile, then switches to `name` (a new one starts as a copy).
    func switchTo(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != current, !name.contains("/") else { return }
        let url = url(for: name)
        // A profile that's there but can't be read isn't written over with this one's state.
        var profile: SettingsProfile?
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                profile = try SettingsProfile.read(from: url)
            } catch {
                lastError = "\(url.lastPathComponent) can't be read: \(error.localizedDescription)"
                return
            }
        }
        saveNow()
        current = name
        defaults.set(name, forKey: "profiles.current")
        if let profile {
            apply(profile)
            knownDate = Self.modificationDate(url)
        } else {
            saveNow() // new: the current state under its name
        }
        reloadNames()
    }

    func delete(_ name: String) {
        guard name != current else { return }
        try? FileManager.default.removeItem(at: url(for: name))
        reloadNames()
    }

    func rename(_ name: String, to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespaces)
        // Names differing only in case are one file on most Macs: renaming onto one would replace it.
        guard !newName.isEmpty, newName != name, !newName.contains("/"),
              !names.contains(where: { $0 != name && $0.caseInsensitiveCompare(newName) == .orderedSame }) else { return }
        if name == current { saveNow() }
        do {
            try FileManager.default.moveItem(at: url(for: name), to: url(for: newName))
        } catch {
            lastError = "Couldn't rename \(name): \(error.localizedDescription)"
            return
        }
        if var profile = try? SettingsProfile.read(from: url(for: newName)) {
            profile.name = newName
            try? profile.write(to: url(for: newName))
        }
        if name == current {
            current = newName
            defaults.set(newName, forKey: "profiles.current")
            knownDate = Self.modificationDate(url(for: newName))
        }
        reloadNames()
    }

    /// Everything to one file (to move to another Mac, or keep).
    func export(to url: URL) throws {
        guard let profile = capture() else { return }
        try profile.write(to: url)
    }

    /// A profile file's settings become the current profile's.
    func importProfile(from url: URL) throws {
        let profile = try SettingsProfile.read(from: url)
        apply(profile)
        saveNow()
    }

    /// Keeps profiles in `folder` (nil: the app's own): the ones there are used; the current
    /// one is copied there if it has none by that name.
    func setSyncFolder(_ folder: URL?) {
        saveNow()
        syncFolder = folder
        defaults.set(folder?.path, forKey: "profiles.syncFolder")
        if FileManager.default.fileExists(atPath: url(for: current).path) {
            // The folder's profile by this name is the one used: as if never seen, so it's
            // applied now (or when the settings are attached), not written over.
            knownDate = .distantPast
            if parts != nil { pullIfChanged() }
        } else {
            knownDate = nil
            saveNow()
        }
        reloadNames()
    }
}
