import AppKit

/// An extension found in the extensions folder.
struct InstalledExtension: Sendable, Equatable, Identifiable {
    let manifest: ExtensionManifest
    /// Its folder (a symbolic link to the source folder for one installed for development).
    let folder: URL
    /// Installed as a link to its source folder: rebuilding it and reloading picks up changes.
    let isDevelopment: Bool

    var id: String { manifest.id }
    var mainURL: URL { folder.appending(path: manifest.main) }
}

/// Where extensions live (~/Library/Application Support/OhMyCode/Extensions/<id>), whether each
/// is enabled, and their settings and storage. Shared by every window: a change is posted as
/// `didChange` and each window's host reloads.
@MainActor
final class ExtensionStore {
    static let shared = ExtensionStore(
        directory: AppSettings.isRunningTests
            ? FileManager.default.temporaryDirectory.appending(path: "omc-test-extensions-\(UUID().uuidString)")
            : URL.applicationSupportDirectory.appending(path: "OhMyCode/Extensions"),
        defaults: AppSettings.isRunningTests ? UserDefaults(suiteName: "dev.zerovoid99.ohmycode.tests.extensions")! : .standard)

    static let didChange = Notification.Name("omcExtensionsDidChange")

    var directory: URL
    private let defaults: UserDefaults
    /// Problems with folders in the extensions folder that aren't valid extensions, by folder name.
    private(set) var problems: [String: String] = [:]

    init(directory: URL, defaults: UserDefaults) {
        self.directory = directory
        self.defaults = defaults
    }

    private enum Keys {
        static let disabled = "extensions.disabled"
        static func settings(_ id: String) -> String { "extensions.settings.\(id)" }
        static func storage(_ id: String) -> String { "extensions.storage.\(id)" }
    }

    // MARK: Installed extensions

    /// The valid extensions, by name; folders that aren't go to `problems`.
    func installed() -> [InstalledExtension] {
        problems = [:]
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                     options: .skipsHiddenFiles)) ?? []
        var result: [InstalledExtension] = []
        for folder in folders {
            let isLink = (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            do {
                let manifest = try ExtensionManifest.load(from: folder)
                result.append(InstalledExtension(manifest: manifest, folder: folder, isDevelopment: isLink))
            } catch {
                problems[folder.lastPathComponent] = error.localizedDescription
            }
        }
        return result.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    enum InstallError: LocalizedError {
        case alreadyInstalled(String)
        var errorDescription: String? {
            switch self {
            case .alreadyInstalled(let id): "\(id) is already installed."
            }
        }
    }

    /// Copies (or, for development, links) an extension folder into the extensions folder,
    /// replacing an installed version when `replacing`.
    @discardableResult
    func install(from source: URL, development: Bool = false, replacing: Bool = false) throws -> InstalledExtension {
        let manifest = try ExtensionManifest.load(from: source)
        let destination = directory.appending(path: manifest.id)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Not `fileExists`: it follows links, and a development link may point nowhere now.
        if (try? fileManager.attributesOfItem(atPath: destination.path)) != nil {
            guard replacing else { throw InstallError.alreadyInstalled(manifest.id) }
            try fileManager.removeItem(at: destination)
        }
        if development {
            try fileManager.createSymbolicLink(at: destination, withDestinationURL: source.standardizedFileURL)
        } else {
            try fileManager.copyItem(at: source, to: destination)
        }
        changed()
        return InstalledExtension(manifest: manifest, folder: destination, isDevelopment: development)
    }

    /// Removes an extension (a development link, not its source), with its settings and storage.
    func uninstall(_ installed: InstalledExtension) throws {
        try FileManager.default.removeItem(at: installed.folder)
        defaults.removeObject(forKey: Keys.settings(installed.id))
        defaults.removeObject(forKey: Keys.storage(installed.id))
        setEnabled(installed.id, true, notify: false)
        changed()
    }

    // MARK: Enabled

    func isEnabled(_ id: String) -> Bool {
        !(defaults.stringArray(forKey: Keys.disabled) ?? []).contains(id)
    }

    func setEnabled(_ id: String, _ enabled: Bool, notify: Bool = true) {
        var disabled = Set(defaults.stringArray(forKey: Keys.disabled) ?? [])
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(disabled.sorted(), forKey: Keys.disabled)
        if notify { changed() }
    }

    // MARK: Settings and storage

    /// A setting's value: what the user set, or the manifest's default.
    func setting(_ key: String, of manifest: ExtensionManifest) -> JSONValue? {
        if let stored = dictionary(Keys.settings(manifest.id))[key] { return stored }
        return manifest.settings[key]?.default
    }

    func setSetting(_ key: String, to value: JSONValue?, of id: String) {
        var values = dictionary(Keys.settings(id))
        values[key] = value
        setDictionary(values, for: Keys.settings(id))
        NotificationCenter.default.post(name: Self.settingDidChange, object: nil, userInfo: ["id": id, "key": key])
    }

    static let settingDidChange = Notification.Name("omcExtensionSettingDidChange")

    func stored(_ key: String, of id: String) -> JSONValue? { dictionary(Keys.storage(id))[key] }

    func store(_ value: JSONValue?, for key: String, of id: String) {
        var values = dictionary(Keys.storage(id))
        values[key] = value
        setDictionary(values, for: Keys.storage(id))
    }

    private func dictionary(_ key: String) -> [String: JSONValue] {
        guard let text = defaults.string(forKey: key), let value = JSONValue(json: text) else { return [:] }
        return value.object ?? [:]
    }

    private func setDictionary(_ values: [String: JSONValue], for key: String) {
        defaults.set(JSONValue.object(values).json, forKey: key)
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
