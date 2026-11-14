import AppKit
import Observation

/// User preferences (Settings window, ⌘,), persisted in UserDefaults and applied live: views
/// listen for `AppSettings.didChange`.
@MainActor
@Observable
final class AppSettings {
    /// Under tests, a scratch store that starts at the defaults: tests never see or overwrite
    /// the user's real settings (the test host is the app itself).
    static let shared = AppSettings(defaults: isRunningTests ? scratchDefaults() : .standard)

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func scratchDefaults() -> UserDefaults {
        let name = "dev.zerovoid99.ohmycode.tests"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
    static let didChange = Notification.Name("omcSettingsDidChange")

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    static let fontSizes: ClosedRange<Double> = 8...36
    static let defaultEditorFontSize: Double = 13
    static let defaultTerminalFontSize: Double = 12

    var appearance: Appearance { didSet { changed() } }
    var themeID: String { didSet { changed() } }
    /// Font family; empty means the system monospaced font (SF Mono).
    var editorFontFamily: String { didSet { changed() } }
    var editorFontSize: Double { didSet { changed() } }
    /// Empty means the same family as the editor.
    var terminalFontFamily: String { didSet { changed() } }
    var terminalFontSize: Double { didSet { changed() } }

    var showsMinimap: Bool { didSet { changed() } }
    var stickyScroll: Bool { didSet { changed() } }
    var formatOnSave: Bool { didSet { changed() } }
    /// Git blame of the cursor's line, shown at its end.
    var showsLineBlame: Bool { didSet { changed() } }
    /// The path and symbols above the editor.
    var showsBreadcrumbs: Bool { didSet { changed() } }
    /// Saving a file git reports as conflicted, with no conflict markers left, stages it.
    var stagesResolvedConflicts: Bool { didSet { changed() } }
    /// Closing brackets and quotes typed for you.
    var autoClosePairs: Bool { didSet { changed() } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isLoading = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isLoading = true
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        themeID = defaults.string(forKey: Keys.theme) ?? EditorTheme.defaultTheme.id
        editorFontFamily = defaults.string(forKey: Keys.editorFontFamily) ?? ""
        editorFontSize = Self.clampedSize(defaults.object(forKey: Keys.editorFontSize) as? Double ?? Self.defaultEditorFontSize)
        terminalFontFamily = defaults.string(forKey: Keys.terminalFontFamily) ?? ""
        terminalFontSize = Self.clampedSize(defaults.object(forKey: Keys.terminalFontSize) as? Double ?? Self.defaultTerminalFontSize)
        showsMinimap = defaults.object(forKey: Keys.showsMinimap) as? Bool ?? true
        stickyScroll = defaults.object(forKey: Keys.stickyScroll) as? Bool ?? true
        formatOnSave = defaults.object(forKey: Keys.formatOnSave) as? Bool ?? false
        showsLineBlame = defaults.object(forKey: Keys.showsLineBlame) as? Bool ?? true
        showsBreadcrumbs = defaults.object(forKey: Keys.showsBreadcrumbs) as? Bool ?? true
        stagesResolvedConflicts = defaults.object(forKey: Keys.stagesResolvedConflicts) as? Bool ?? true
        autoClosePairs = defaults.object(forKey: Keys.autoClosePairs) as? Bool ?? true
        isLoading = false
    }

    private enum Keys {
        static let appearance = "appearance"
        static let theme = "editorTheme"
        static let editorFontFamily = "editorFontFamily"
        static let editorFontSize = "editorFontSize"
        static let terminalFontFamily = "terminalFontFamily"
        static let terminalFontSize = "terminalFontSize"
        static let showsMinimap = "showsMinimap"
        static let stickyScroll = "stickyScroll"
        static let formatOnSave = "formatOnSave"
        static let showsLineBlame = "showsLineBlame"
        static let showsBreadcrumbs = "showsBreadcrumbs"
        static let stagesResolvedConflicts = "stagesResolvedConflicts"
        static let autoClosePairs = "autoClosePairs"
    }

    private static func clampedSize(_ size: Double) -> Double {
        min(max(size.rounded(), fontSizes.lowerBound), fontSizes.upperBound)
    }

    private func changed() {
        guard !isLoading else { return }
        // Keep sizes in range however they were set (stepper, zoom, typed value). `isLoading`
        // keeps these nested sets from re-entering.
        isLoading = true
        editorFontSize = Self.clampedSize(editorFontSize)
        terminalFontSize = Self.clampedSize(terminalFontSize)
        isLoading = false
        defaults.set(appearance.rawValue, forKey: Keys.appearance)
        defaults.set(themeID, forKey: Keys.theme)
        defaults.set(editorFontFamily, forKey: Keys.editorFontFamily)
        defaults.set(editorFontSize, forKey: Keys.editorFontSize)
        defaults.set(terminalFontFamily, forKey: Keys.terminalFontFamily)
        defaults.set(terminalFontSize, forKey: Keys.terminalFontSize)
        defaults.set(showsMinimap, forKey: Keys.showsMinimap)
        defaults.set(stickyScroll, forKey: Keys.stickyScroll)
        defaults.set(formatOnSave, forKey: Keys.formatOnSave)
        defaults.set(showsLineBlame, forKey: Keys.showsLineBlame)
        defaults.set(showsBreadcrumbs, forKey: Keys.showsBreadcrumbs)
        defaults.set(stagesResolvedConflicts, forKey: Keys.stagesResolvedConflicts)
        defaults.set(autoClosePairs, forKey: Keys.autoClosePairs)
        guard self === AppSettings.shared else { return } // test instances don't restyle the app
        EditorTheme.invalidate()
        applyAppearance()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// A light or dark theme decides the appearance; the Default theme follows the setting.
    var themeSetsAppearance: Bool {
        EditorTheme.themes.first { $0.id == themeID }?.isDark != nil
    }

    var effectiveAppearance: NSAppearance? {
        if let isDark = EditorTheme.themes.first(where: { $0.id == themeID })?.isDark {
            return NSAppearance(named: isDark ? .darkAqua : .aqua)
        }
        return switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Sets the app-wide light/dark appearance (windows, sidebar, menus).
    func applyAppearance() {
        guard NSApp != nil else { return }
        let target = effectiveAppearance
        if NSApp.appearance != target { NSApp.appearance = target }
    }

    // MARK: Fonts

    var editorFont: NSFont { Self.font(family: editorFontFamily, size: editorFontSize) }

    func terminalFont(bold: Bool = false) -> NSFont {
        Self.font(family: terminalFontFamily.isEmpty ? editorFontFamily : terminalFontFamily,
                  size: terminalFontSize, bold: bold)
    }

    static func font(family: String, size: Double, bold: Bool = false) -> NSFont {
        let size = CGFloat(size)
        if !family.isEmpty,
           let font = NSFontManager.shared.font(withFamily: family, traits: bold ? .boldFontMask : [],
                                                 weight: bold ? 9 : 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// Installed fixed-pitch font families, for the font pickers.
    static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }.filter { !$0.hasPrefix(".") })
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    // MARK: Zoom (⌘+ / ⌘- / ⌘0)

    func zoom(by step: Double) {
        editorFontSize += step
        terminalFontSize += step
    }

    func resetZoom() {
        editorFontSize = Self.defaultEditorFontSize
        terminalFontSize = Self.defaultTerminalFontSize
    }

    func restoreDefaults() {
        appearance = .system
        themeID = EditorTheme.defaultTheme.id
        editorFontFamily = ""
        terminalFontFamily = ""
        showsMinimap = true
        stickyScroll = true
        formatOnSave = false
        showsLineBlame = true
        stagesResolvedConflicts = true
        autoClosePairs = true
        resetZoom()
    }
}
