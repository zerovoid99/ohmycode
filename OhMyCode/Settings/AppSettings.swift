import AppKit
import Observation

extension URL {
    /// ~/Library/Application Support, or the folder in `OMC_SUPPORT_DIR` when it's set: the
    /// launch benchmark starts the app with one, so it never reads or writes the user's
    /// sessions, history, profiles or snippets.
    static var omcApplicationSupport: URL {
        if let path = ProcessInfo.processInfo.environment["OMC_SUPPORT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return .applicationSupportDirectory
    }
}

extension UserDefaults {
    /// The app's own defaults: the standard ones, or with `OMC_SUPPORT_DIR` set a store inside
    /// that folder, so a run started with one (the launch benchmark, a trial run) doesn't add to
    /// the user's recent folders, settings or agents.
    nonisolated(unsafe) static let omc = store(environment: ProcessInfo.processInfo.environment)

    static func store(environment: [String: String]) -> UserDefaults {
        guard let path = environment["OMC_SUPPORT_DIR"], !path.isEmpty else { return .standard }
        let folder = URL(fileURLWithPath: path, isDirectory: true).appending(path: "OhMyCode")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return UserDefaults(suiteName: folder.appending(path: "Defaults").path) ?? .standard
    }

    /// Started with `OMC_SUPPORT_DIR`: nothing of the user's is read or written (the Keychain
    /// included).
    static var isolated: Bool { ProcessInfo.processInfo.environment["OMC_SUPPORT_DIR"].map { !$0.isEmpty } ?? false }
}

/// Named UserDefaults stores for tests (the test host is the app itself, so tests never touch the
/// user's own). Each is a plist in a temporary folder of the run's own, named by its path: a
/// suite named the usual way would land in ~/Library/Preferences and stay there. So every run
/// starts with empty stores.
enum ScratchDefaults {
    static let folder = FileManager.default.temporaryDirectory
        .appending(path: "omc-test-defaults/\(ProcessInfo.processInfo.processIdentifier)")

    static func named(_ name: String) -> UserDefaults {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return UserDefaults(suiteName: folder.appending(path: name).path)!
    }
}

/// User preferences (Settings window, ⌘,), persisted in UserDefaults and applied live: views
/// listen for `AppSettings.didChange`.
@MainActor
@Observable
final class AppSettings {
    /// Under tests, a scratch store that starts at the defaults: tests never see or overwrite
    /// the user's real settings (the test host is the app itself).
    static let shared = AppSettings(defaults: isRunningTests ? scratchDefaults() : .omc)

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func scratchDefaults() -> UserDefaults {
        ScratchDefaults.named("dev.zerovoid99.ohmycode.tests")
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
    var formatOnSaveScope: FormatOnSaveScope { didSet { changed() } }
    /// Git blame of the cursor's line, shown at its end.
    var showsLineBlame: Bool { didSet { changed() } }
    /// The path and symbols above the editor.
    var showsBreadcrumbs: Bool { didSet { changed() } }
    /// Types and parameter names the language server shows inside the code.
    var showsInlayHints: Bool { didSet { changed() } }
    /// Where the symbol under the cursor appears, highlighted.
    var highlightsOccurrences: Bool { didSet { changed() } }
    /// The bracket matching the one beside the cursor, outlined.
    var highlightsMatchingBrackets: Bool { didSet { changed() } }
    /// Thin lines at each indentation level.
    var showsIndentGuides: Bool { didSet { changed() } }
    var wordWrap: WordWrap { didSet { changed() } }
    var renderWhitespace: RenderWhitespace { didSet { changed() } }
    /// The language server's classification of names colors them (types, functions, properties).
    var semanticHighlighting: Bool { didSet { changed() } }
    /// Zen mode also makes the window full screen.
    var zenModeFullScreen: Bool { didSet { changed() } }
    /// The language server's lenses ("3 references") after the lines they're about.
    var showsCodeLens: Bool { didSet { changed() } }
    var autoSave: AutoSave { didSet { changed() } }
    /// Seconds without typing before auto save (after a delay).
    var autoSaveDelay: Double { didSet { changed() } }
    /// Quitting keeps unsaved changes for next time instead of asking about them.
    var hotExit: Bool { didSet { changed() } }
    /// Editing a tag's name edits its closing (or opening) tag's too.
    var linkedEditing: Bool { didSet { changed() } }
    /// Saving a file git reports as conflicted, with no conflict markers left, stages it.
    var stagesResolvedConflicts: Bool { didSet { changed() } }
    /// Closing brackets and quotes typed for you.
    var autoClosePairs: Bool { didSet { changed() } }
    /// Vim's modes and keys in the code editor.
    var vimMode: Bool { didSet { changed() } }
    /// `files.associations`: a glob on the file name (or path) → the language id its files are in.
    var fileAssociations: [String: String] { didSet { changed() } }
    /// `languageServers.<id>.enabled`: servers turned off (false) or on; unlisted ones are on.
    var languageServersEnabled: [String: Bool] { didSet { changed() } }
    /// `languages.highlighting`: language id → what colors it ("builtin", "tree-sitter",
    /// "textmate"); unlisted languages use the default order (see `ContributedGrammars`).
    var languageHighlighting: [String: String] { didSet { changed() } }

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
        formatOnSaveScope = FormatOnSaveScope(rawValue: defaults.string(forKey: Keys.formatOnSaveScope) ?? "") ?? .file
        showsLineBlame = defaults.object(forKey: Keys.showsLineBlame) as? Bool ?? true
        showsBreadcrumbs = defaults.object(forKey: Keys.showsBreadcrumbs) as? Bool ?? true
        showsInlayHints = defaults.object(forKey: Keys.showsInlayHints) as? Bool ?? true
        highlightsOccurrences = defaults.object(forKey: Keys.highlightsOccurrences) as? Bool ?? true
        highlightsMatchingBrackets = defaults.object(forKey: Keys.highlightsMatchingBrackets) as? Bool ?? true
        showsIndentGuides = defaults.object(forKey: Keys.showsIndentGuides) as? Bool ?? true
        wordWrap = WordWrap(rawValue: defaults.string(forKey: Keys.wordWrap) ?? "") ?? .prose
        renderWhitespace = RenderWhitespace(rawValue: defaults.string(forKey: Keys.renderWhitespace) ?? "") ?? .selection
        semanticHighlighting = defaults.object(forKey: Keys.semanticHighlighting) as? Bool ?? true
        zenModeFullScreen = defaults.object(forKey: Keys.zenModeFullScreen) as? Bool ?? true
        showsCodeLens = defaults.object(forKey: Keys.showsCodeLens) as? Bool ?? true
        autoSave = AutoSave(rawValue: defaults.string(forKey: Keys.autoSave) ?? "") ?? .off
        autoSaveDelay = min(max(defaults.object(forKey: Keys.autoSaveDelay) as? Double ?? 1, 0.2), 60)
        hotExit = defaults.object(forKey: Keys.hotExit) as? Bool ?? true
        linkedEditing = defaults.object(forKey: Keys.linkedEditing) as? Bool ?? true
        stagesResolvedConflicts = defaults.object(forKey: Keys.stagesResolvedConflicts) as? Bool ?? true
        autoClosePairs = defaults.object(forKey: Keys.autoClosePairs) as? Bool ?? true
        vimMode = defaults.object(forKey: Keys.vimMode) as? Bool ?? false
        fileAssociations = defaults.dictionary(forKey: Keys.fileAssociations) as? [String: String] ?? [:]
        languageServersEnabled = defaults.dictionary(forKey: Keys.languageServersEnabled) as? [String: Bool] ?? [:]
        languageHighlighting = defaults.dictionary(forKey: Keys.languageHighlighting) as? [String: String] ?? [:]
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
        static let formatOnSaveScope = "formatOnSaveScope"
        static let showsLineBlame = "showsLineBlame"
        static let showsBreadcrumbs = "showsBreadcrumbs"
        static let showsInlayHints = "showsInlayHints"
        static let highlightsOccurrences = "highlightsOccurrences"
        static let highlightsMatchingBrackets = "highlightsMatchingBrackets"
        static let showsIndentGuides = "showsIndentGuides"
        static let wordWrap = "wordWrap"
        static let renderWhitespace = "renderWhitespace"
        static let semanticHighlighting = "semanticHighlighting"
        static let zenModeFullScreen = "zenModeFullScreen"
        static let showsCodeLens = "showsCodeLens"
        static let autoSave = "autoSave"
        static let autoSaveDelay = "autoSaveDelay"
        static let hotExit = "hotExit"
        static let linkedEditing = "linkedEditing"
        static let stagesResolvedConflicts = "stagesResolvedConflicts"
        static let autoClosePairs = "autoClosePairs"
        static let vimMode = "vimMode"
        static let fileAssociations = "files.associations"
        static let languageServersEnabled = "languageServers.enabled"
        static let languageHighlighting = "languages.highlighting"
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
        defaults.set(formatOnSaveScope.rawValue, forKey: Keys.formatOnSaveScope)
        defaults.set(showsLineBlame, forKey: Keys.showsLineBlame)
        defaults.set(showsBreadcrumbs, forKey: Keys.showsBreadcrumbs)
        defaults.set(showsInlayHints, forKey: Keys.showsInlayHints)
        defaults.set(highlightsOccurrences, forKey: Keys.highlightsOccurrences)
        defaults.set(highlightsMatchingBrackets, forKey: Keys.highlightsMatchingBrackets)
        defaults.set(showsIndentGuides, forKey: Keys.showsIndentGuides)
        defaults.set(wordWrap.rawValue, forKey: Keys.wordWrap)
        defaults.set(renderWhitespace.rawValue, forKey: Keys.renderWhitespace)
        defaults.set(semanticHighlighting, forKey: Keys.semanticHighlighting)
        defaults.set(zenModeFullScreen, forKey: Keys.zenModeFullScreen)
        defaults.set(showsCodeLens, forKey: Keys.showsCodeLens)
        defaults.set(autoSave.rawValue, forKey: Keys.autoSave)
        defaults.set(autoSaveDelay, forKey: Keys.autoSaveDelay)
        defaults.set(hotExit, forKey: Keys.hotExit)
        defaults.set(linkedEditing, forKey: Keys.linkedEditing)
        defaults.set(stagesResolvedConflicts, forKey: Keys.stagesResolvedConflicts)
        defaults.set(autoClosePairs, forKey: Keys.autoClosePairs)
        defaults.set(vimMode, forKey: Keys.vimMode)
        defaults.set(fileAssociations, forKey: Keys.fileAssociations)
        defaults.set(languageServersEnabled, forKey: Keys.languageServersEnabled)
        defaults.set(languageHighlighting, forKey: Keys.languageHighlighting)
        guard self === AppSettings.shared else { return } // test instances don't restyle the app
        EditorTheme.invalidate()
        applyAppearance()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Profiles

    /// Every setting, by name (a profile's settings).
    var snapshot: [String: JSONValue] {
        [
            "appearance": .string(appearance.rawValue), "theme": .string(themeID),
            "editorFontFamily": .string(editorFontFamily), "editorFontSize": .number(editorFontSize),
            "terminalFontFamily": .string(terminalFontFamily), "terminalFontSize": .number(terminalFontSize),
            "showsMinimap": .bool(showsMinimap), "stickyScroll": .bool(stickyScroll), "formatOnSave": .bool(formatOnSave),
            "showsLineBlame": .bool(showsLineBlame), "showsBreadcrumbs": .bool(showsBreadcrumbs),
            "showsInlayHints": .bool(showsInlayHints), "stagesResolvedConflicts": .bool(stagesResolvedConflicts),
            "autoClosePairs": .bool(autoClosePairs), "vimMode": .bool(vimMode), "highlightsOccurrences": .bool(highlightsOccurrences),
            "highlightsMatchingBrackets": .bool(highlightsMatchingBrackets), "showsIndentGuides": .bool(showsIndentGuides),
            "wordWrap": .string(wordWrap.rawValue), "renderWhitespace": .string(renderWhitespace.rawValue),
            "semanticHighlighting": .bool(semanticHighlighting), "formatOnSaveScope": .string(formatOnSaveScope.rawValue),
            "zenModeFullScreen": .bool(zenModeFullScreen), "showsCodeLens": .bool(showsCodeLens),
            "autoSave": .string(autoSave.rawValue), "autoSaveDelay": .number(autoSaveDelay), "hotExit": .bool(hotExit),
            "linkedEditing": .bool(linkedEditing),
            "files.associations": .object(fileAssociations.mapValues(JSONValue.string)),
            "languageServers.enabled": .object(languageServersEnabled.mapValues(JSONValue.bool)),
            "languages.highlighting": .object(languageHighlighting.mapValues(JSONValue.string)),
        ]
    }

    /// Sets what `values` has (unknown names and wrong types are left as they are), as one change.
    func apply(_ values: [String: JSONValue]) {
        isLoading = true
        if let value = values["appearance"]?.string.flatMap(Appearance.init(rawValue:)) { appearance = value }
        if let value = values["theme"]?.string { themeID = value }
        if let value = values["editorFontFamily"]?.string { editorFontFamily = value }
        if let value = values["editorFontSize"]?.number { editorFontSize = value }
        if let value = values["terminalFontFamily"]?.string { terminalFontFamily = value }
        if let value = values["terminalFontSize"]?.number { terminalFontSize = value }
        if let value = values["showsMinimap"]?.bool { showsMinimap = value }
        if let value = values["stickyScroll"]?.bool { stickyScroll = value }
        if let value = values["formatOnSave"]?.bool { formatOnSave = value }
        if let value = values["showsLineBlame"]?.bool { showsLineBlame = value }
        if let value = values["showsBreadcrumbs"]?.bool { showsBreadcrumbs = value }
        if let value = values["showsInlayHints"]?.bool { showsInlayHints = value }
        if let value = values["highlightsOccurrences"]?.bool { highlightsOccurrences = value }
        if let value = values["highlightsMatchingBrackets"]?.bool { highlightsMatchingBrackets = value }
        if let value = values["showsIndentGuides"]?.bool { showsIndentGuides = value }
        if let value = values["wordWrap"]?.string.flatMap(WordWrap.init(rawValue:)) { wordWrap = value }
        if let value = values["renderWhitespace"]?.string.flatMap(RenderWhitespace.init(rawValue:)) { renderWhitespace = value }
        if let value = values["semanticHighlighting"]?.bool { semanticHighlighting = value }
        if let value = values["zenModeFullScreen"]?.bool { zenModeFullScreen = value }
        if let value = values["showsCodeLens"]?.bool { showsCodeLens = value }
        if let value = values["autoSave"]?.string.flatMap(AutoSave.init(rawValue:)) { autoSave = value }
        if let value = values["autoSaveDelay"]?.number { autoSaveDelay = min(max(value, 0.2), 60) }
        if let value = values["hotExit"]?.bool { hotExit = value }
        if let value = values["linkedEditing"]?.bool { linkedEditing = value }
        if let value = values["formatOnSaveScope"]?.string.flatMap(FormatOnSaveScope.init(rawValue:)) { formatOnSaveScope = value }
        if let value = values["stagesResolvedConflicts"]?.bool { stagesResolvedConflicts = value }
        if let value = values["autoClosePairs"]?.bool { autoClosePairs = value }
        if let value = values["vimMode"]?.bool { vimMode = value }
        if let value = values["files.associations"]?.object { fileAssociations = value.compactMapValues(\.string) }
        if let value = values["languageServers.enabled"]?.object { languageServersEnabled = value.compactMapValues(\.bool) }
        if let value = values["languages.highlighting"]?.object { languageHighlighting = value.compactMapValues(\.string) }
        isLoading = false
        changed()
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
