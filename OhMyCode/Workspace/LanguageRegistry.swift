import Foundation
import Synchronization

/// A language an extension adds or extends (`contributes.languages` in its extension.json).
struct LanguageContribution: Sendable, Equatable {
    var id: String
    var aliases: [String] = []
    /// ".toy", with the dot (as VS Code writes them); several dots for ".d.toy".
    var extensions: [String] = []
    /// Whole names: "Toyfile".
    var filenames: [String] = []
    /// Globs on the path: "*.toy.txt", "**/toys/*.cfg".
    var filenamePatterns: [String] = []
    /// A regular expression the first line matches: a shebang, a modeline.
    var firstLine: String?
    var configuration: LanguageConfiguration?
}

/// Every language the editor knows: the built-in ones and those extensions contribute, and
/// which one a file is in. Contributions come from the enabled extensions of every window
/// (they're declared, so they work before an extension activates). Reads are safe from any
/// thread (highlighting works in the background); changes post `didChange` on the main thread.
final class LanguageRegistry: @unchecked Sendable {
    static let shared = LanguageRegistry()
    static let didChange = Notification.Name("omcLanguageRegistryDidChange")

    private struct State {
        /// By extension id, in the order they were added.
        var contributions: [(extensionID: String, languages: [LanguageContribution])] = []
    }

    private let state = Mutex(State())

    // MARK: Contributions

    /// What one extension contributes (empty: it contributes nothing any more).
    func setContributions(_ languages: [LanguageContribution], from extensionID: String) {
        let changed = state.withLock { state -> Bool in
            let index = state.contributions.firstIndex { $0.extensionID == extensionID }
            if let index, state.contributions[index].languages == languages { return false }
            if languages.isEmpty {
                guard let index else { return false }
                state.contributions.remove(at: index)
            } else if let index {
                state.contributions[index].languages = languages
            } else {
                state.contributions.append((extensionID, languages))
            }
            return true
        }
        guard changed else { return }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        } else {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
        }
    }

    private var all: [LanguageContribution] { state.withLock { $0.contributions.flatMap(\.languages) } }

    private func contributions(for language: SourceLanguage) -> [LanguageContribution] {
        all.filter { SourceLanguage(languageId: $0.id) == language }
    }

    // MARK: Languages

    /// Every language, built-in and contributed, with its name, sorted by name.
    var languages: [(language: SourceLanguage, name: String)] {
        var seen = Set<SourceLanguage>()
        var result: [(SourceLanguage, String)] = []
        for language in SourceLanguage.builtIns + all.map({ SourceLanguage(languageId: $0.id) }) where seen.insert(language).inserted {
            result.append((language, language.displayName))
        }
        return result.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    /// Whether any extension contributes `language` (a new one, or more for a built-in one).
    func isContributed(_ language: SourceLanguage) -> Bool { !contributions(for: language).isEmpty }

    /// A contribution's first alias: what the status bar and picker call the language.
    func displayName(for language: SourceLanguage) -> String? {
        contributions(for: language).lazy.compactMap(\.aliases.first).first
    }

    /// The language configurations contributed for `language`, later ones over earlier ones.
    func configuration(for language: SourceLanguage) -> LanguageConfiguration? {
        let configurations = contributions(for: language).compactMap(\.configuration)
        guard let first = configurations.first else { return nil }
        return configurations.dropFirst().reduce(first) { $0.merged(with: $1) }
    }

    /// A language by one of its names (id, alias, built-in name), case-insensitively.
    func language(named name: String) -> SourceLanguage? {
        let lowered = name.lowercased()
        if let contribution = all.first(where: { $0.id.lowercased() == lowered || $0.aliases.contains { $0.lowercased() == lowered } }) {
            return SourceLanguage(languageId: contribution.id)
        }
        return SourceLanguage.builtIns.first {
            $0.rawValue == lowered || $0.languageId == lowered || SourceLanguage.builtInNames[$0]?.lowercased() == lowered
        }
    }

    // MARK: Resolving files

    /// The language of a file by its extension alone.
    func language(forExtension ext: String) -> SourceLanguage {
        let lowered = ext.lowercased()
        if !lowered.isEmpty, let contribution = all.last(where: { $0.extensions.contains { Self.dotted($0) == "." + lowered } }) {
            return SourceLanguage(languageId: contribution.id)
        }
        return SourceLanguage.builtIn(fileExtension: lowered)
    }

    /// The language of a file: `associations` (`files.associations`: glob → language id) first,
    /// then the extensions' `filenames`, `filenamePatterns`, `extensions` and `firstLine`, in
    /// that order, then the built-in table. Later contributions win over earlier ones.
    func language(for url: URL, firstLine: String? = nil, associations: [String: String] = [:]) -> SourceLanguage {
        let name = url.lastPathComponent
        let path = String(url.standardizedFileURL.path.drop { $0 == "/" })
        // The most specific association wins: a whole name over a glob, a longer glob over a shorter one.
        for (glob, id) in associations.sorted(by: { ($0.key.contains("*") ? 0 : 1, $0.key.count) > ($1.key.contains("*") ? 0 : 1, $1.key.count) })
        where Self.matches(glob, name: name, path: path) {
            return language(named: id) ?? SourceLanguage(languageId: id)
        }
        let contributions = all.reversed()
        let lowered = name.lowercased()
        if let found = contributions.first(where: { $0.filenames.contains(name) }) { return SourceLanguage(languageId: found.id) }
        if let found = contributions.first(where: { $0.filenamePatterns.contains { Self.matches($0, name: name, path: path) } }) {
            return SourceLanguage(languageId: found.id)
        }
        // The longest matching extension (".d.toy" over ".toy").
        var best: (length: Int, id: String)?
        for contribution in contributions {
            for ext in contribution.extensions.map(Self.dotted) where lowered.hasSuffix(ext) && ext.count > (best?.length ?? 0) {
                best = (ext.count, contribution.id)
            }
        }
        if let best { return SourceLanguage(languageId: best.id) }
        if let firstLine {
            for contribution in contributions {
                guard let pattern = contribution.firstLine else { continue }
                if LanguageConfiguration.Pattern(source: pattern).matches(firstLine) { return SourceLanguage(languageId: contribution.id) }
            }
        }
        return SourceLanguage.builtIn(fileExtension: url.pathExtension)
    }

    /// ".toy" for "toy" or ".TOY".
    static func dotted(_ ext: String) -> String { ext.hasPrefix(".") ? ext.lowercased() : "." + ext.lowercased() }

    /// A `files.associations` or `filenamePatterns` glob: on the name when it has no "/", else on
    /// the path.
    static func matches(_ glob: String, name: String, path: String) -> Bool {
        glob.contains("/") ? EditorConfig.matches(glob, relative: path) : EditorConfig.matches("/" + glob, relative: name)
    }

    /// The first line of a file on disk (for `firstLine` patterns), at most 1 KB of it.
    static func firstLine(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    /// The first line of a text, at most 1,024 characters of it (only those are looked at: a
    /// huge one-line file isn't scanned).
    static func firstLine(of text: NSString) -> String {
        let limit = min(text.length, 1024)
        let end = text.range(of: "\n", options: .literal, range: NSRange(location: 0, length: limit)).location
        return text.substring(to: end == NSNotFound ? limit : end)
    }
}
