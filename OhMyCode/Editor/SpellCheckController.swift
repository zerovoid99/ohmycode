import AppKit
import SwiftTreeSitter
import SwiftUI

/// An editor's spell checking: the text around what's on screen is checked in the background
/// a moment after typing or scrolling stops, and the unknown words are underlined with dots
/// (see `DiagnosticsOverlayView`). A keystroke only moves the words found after it.
///
/// In code, comments and strings are checked as prose (the syntax highlights say where they
/// are) and names are split into words; Markdown and plain text are prose throughout.
@MainActor
final class SpellCheckController: NSObject {
    private weak var editor: EditorController?
    /// The unknown words in the text last checked, by position (moved by edits since).
    private(set) var issues: [SpellIssue] = []
    /// Comments and strings, and what isn't a name to check (keywords, numbers, library
    /// names), in the latest highlights; and the edit and range they're for.
    private var syntax: (version: Int, range: NSRange, prose: [NSRange], excluded: [NSRange])?
    private var task: Task<Void, Never>?
    /// Whether this editor's words are in Problems.
    private var publishedProblems = false

    /// How long after the last keystroke or scroll the text is checked.
    nonisolated(unsafe) static var delay: Duration = .milliseconds(400)
    /// How far above the text checked `spell-checker:` comments (and Markdown fences) are looked for.
    static let lookBehind = 64 * 1024
    static let problemSource = "Spelling"

    /// Tests: the checks run, and the characters the last one covered.
    private(set) var checkCount = 0
    private(set) var lastCheckedRange: NSRange?

    init(editor: EditorController) {
        self.editor = editor
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(dictionariesChanged),
                                               name: SpellDictionaries.didChange, object: nil)
    }

    /// The folder's setting over the app's.
    var isEnabled: Bool {
        guard let editor else { return false }
        return editor.document.projectSettings.spellCheck ?? AppSettings.shared.spellCheck
    }

    // MARK: Triggers

    /// Highlights arrived: where comments and strings are is known for this text.
    func highlightsArrived(_ highlights: [NamedRange], in range: NSRange) {
        guard let editor else { return }
        var prose: [NSRange] = [], excluded: [NSRange] = []
        for highlight in highlights {
            if Self.isProse(highlight.name) {
                prose.append(highlight.range)
            } else if Self.isExcluded(highlight.name) {
                excluded.append(highlight.range)
            }
        }
        syntax = (editor.document.editVersion, range, SpellCheckRequest.merged(prose), excluded)
        schedule()
    }

    /// The text changed: words after the edit move with it, words in it go until checked again.
    func textEdited(start: Int, oldEnd: Int, newLength: Int) {
        if !issues.isEmpty {
            let delta = newLength - (oldEnd - start)
            issues = issues.compactMap { issue in
                if NSMaxRange(issue.range) < start { return issue }
                if issue.range.location > oldEnd {
                    var moved = issue
                    moved.range.location += delta
                    return moved
                }
                return nil
            }
        }
        schedule()
    }

    /// Scrolled: checks again once the text in view wasn't all checked.
    func viewportChanged() {
        guard let editor, let visible = editor.visibleCharacterRange() else { return }
        if let checked = lastCheckedRange, NSIntersectionRange(checked, visible) == visible { return }
        // A highlighted file is checked when its highlights arrive.
        if editor.document.highlighter == nil || syntax.map({ NSIntersectionRange($0.range, visible) == visible }) == true {
            schedule(after: .milliseconds(150))
        }
    }

    func settingsChanged() {
        lastCheckedRange = nil
        schedule(after: .zero)
    }

    @objc private func dictionariesChanged() { settingsChanged() }

    func schedule(after delay: Duration? = nil) {
        task?.cancel()
        let delay = delay ?? Self.delay
        task = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }

    /// Checks the text around the viewport now (tests; the scheduled check calls it).
    func check() async {
        guard let editor, editor.textView != nil, !editor.isParked else { return }
        guard isEnabled, let request = makeRequest() else {
            if !isEnabled { update([], checked: nil) }
            return
        }
        let document = editor.document
        let version = document.editVersion
        checkCount += 1
        let found = await Task.detached(priority: .utility) { request.run() }.value
        guard !Task.isCancelled, document.editVersion == version else { return }
        update(found, checked: request.checkRange)
    }

    // MARK: The request

    /// Comments and strings (tree-sitter captures, TextMate scopes).
    static func isProse(_ name: String) -> Bool {
        if TextMateScopes.isScopeList(name) {
            return name.contains(" comment") || (name.contains(" string") && !name.contains("regex"))
        }
        return name.hasPrefix("comment") || (name.hasPrefix("string") && !name.contains("regex") && !name.contains("escape")
            && !name.contains("special"))
    }

    private static let excludedCaptures = ["keyword", "conditional", "repeat", "include", "exception", "storageclass",
                                           "boolean", "number", "operator", "escape", "preproc", "define"]

    /// Not a name to check: keywords, numbers, built-in and library names.
    static func isExcluded(_ name: String) -> Bool {
        if TextMateScopes.isScopeList(name) {
            return name.contains(" keyword") || name.contains(" storage") || name.contains(" constant.numeric")
                || name.contains(" constant.language") || name.contains(" support.")
        }
        return name.contains("builtin") || excludedCaptures.contains { name.hasPrefix($0) }
    }

    /// What to check now: the text around the viewport (the highlighted range in code), with
    /// where its comments and strings are. Nil when there's nothing to check yet.
    func makeRequest() -> SpellCheckRequest? {
        guard let editor else { return nil }
        let document = editor.document
        let settings = AppSettings.shared
        let language = document.language
        let text = document.textStorage.mutableString
        var request: SpellCheckRequest
        if language == .markdown || language == .plaintext {
            guard let range = editor.highlightRange else { return nil }
            request = SpellCheckRequest(text: "", checkRange: range, mode: language == .markdown ? .markdown : .prose)
        } else if document.highlighter != nil {
            // Comments and strings as the highlights for this text say.
            guard let syntax, syntax.version == document.editVersion, NSMaxRange(syntax.range) <= text.length else { return nil }
            request = SpellCheckRequest(text: "", checkRange: syntax.range, mode: .code, proseRanges: syntax.prose,
                                        excludedRanges: syntax.excluded, checksIdentifiers: settings.spellCheckIdentifiers)
        } else {
            // No highlighting: only the line comments (names would include the keywords).
            guard let range = editor.highlightRange, let marker = language.lineComment, !marker.isEmpty else { return nil }
            request = SpellCheckRequest(text: "", checkRange: range, mode: .code,
                                        proseRanges: Self.lineComments(in: text, range: range, marker: marker), checksIdentifiers: false)
        }
        let start = max(0, request.checkRange.location - Self.lookBehind)
        let end = min(text.length, NSMaxRange(request.checkRange))
        guard end > start else { return nil }
        request.text = text.substring(with: NSRange(location: start, length: end - start)) as NSString
        request.offset = start
        request.allowsHyphen = language == .css || language == .html
        request.language = settings.spellCheckLanguage.isEmpty ? nil : settings.spellCheckLanguage
        let dictionaries = SpellDictionaries.shared
        request.known = [SpellDictionaries.terms, dictionaries.words(at: dictionaries.userFile), dictionaries.ignored(inFile: document.url)]
        if let folder = folderURL { request.known.append(dictionaries.words(at: SpellDictionaries.folderDictionary(in: folder))) }
        return request
    }

    /// From each line comment marker to its line's end (strings aren't known here).
    static func lineComments(in text: NSString, range: NSRange, marker: String) -> [NSRange] {
        var result: [NSRange] = []
        var position = range.location
        while position < NSMaxRange(range) {
            let found = text.range(of: marker, options: .literal, range: NSRange(location: position, length: NSMaxRange(range) - position))
            guard found.location != NSNotFound else { break }
            let lineEnd = NSMaxRange(text.lineRange(for: found))
            result.append(NSRange(location: NSMaxRange(found), length: lineEnd - NSMaxRange(found)))
            position = max(lineEnd, NSMaxRange(found))
        }
        return result
    }

    /// The workspace folder the file is in (for its dictionary).
    var folderURL: URL? {
        guard let document = editor?.document else { return nil }
        return document.workspace?.folder(containing: document.url) ?? document.workspaceRoot
    }

    // MARK: Results

    /// New results: the underlines that changed are redrawn, Problems updated.
    private func update(_ found: [SpellIssue], checked: NSRange?) {
        guard let editor else { return }
        let old = issues
        let cursor = editor.textView.selectedRange().location
        let hadCursorIssue = issue(at: cursor) != nil
        issues = found
        lastCheckedRange = checked
        if old != found, let overlay = editor.diagnosticsOverlay {
            let before = Set(old.map { "\($0.range.location):\($0.range.length)" })
            let after = Set(found.map { "\($0.range.location):\($0.range.length)" })
            for issue in old + found where before.contains("\(issue.range.location):\(issue.range.length)") != after.contains("\(issue.range.location):\(issue.range.length)") {
                for rect in segments(of: issue.range) { overlay.setNeedsDisplay(rect.insetBy(dx: -2, dy: -3)) }
            }
        }
        if hadCursorIssue != (issue(at: cursor) != nil) { editor.lightbulb.update() }
        publishProblems()
    }

    /// Spelling as information in Problems (when the setting is on).
    private func publishProblems() {
        guard let document = editor?.document, let problems = document.workspace?.problems else { return }
        if AppSettings.shared.spellCheckProblems, isEnabled {
            let diagnostics = issues.map { issue in
                Diagnostic(range: LSPRange(start: document.lspPosition(at: issue.range.location),
                                           end: document.lspPosition(at: NSMaxRange(issue.range))),
                           severity: .information, message: "Unknown word “\(issue.word)”.", source: Self.problemSource)
            }
            problems.set(diagnostics, for: document.url, source: Self.problemSource)
            publishedProblems = true
        } else if publishedProblems {
            problems.set([], for: document.url, source: Self.problemSource)
            publishedProblems = false
        }
    }

    /// The unknown word at (or just before) a position, if its text is still that word.
    func issue(at index: Int) -> SpellIssue? {
        guard let document = editor?.document else { return nil }
        let text = document.textStorage.mutableString
        return issues.first { issue in
            (NSLocationInRange(index, issue.range) || NSMaxRange(issue.range) == index)
                && NSMaxRange(issue.range) <= text.length && text.substring(with: issue.range) == issue.word
        }
    }

    // MARK: Drawing

    /// Where each laid-out word is (text view coordinates), one rect per line it's on.
    func segments(of range: NSRange) -> [NSRect] {
        guard let textView = editor?.textView, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(contentManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        let origin = textView.textContainerOrigin
        var rects: [NSRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return rects
    }

    /// The underlines to draw: the words in the laid-out viewport.
    func underlineRects() -> [NSRect] {
        guard !issues.isEmpty, let editor, let viewport = editor.visibleCharacterRange() else { return [] }
        let length = editor.document.textStorage.length
        return issues.filter { NSIntersectionRange($0.range, viewport).length > 0 && NSMaxRange($0.range) <= length }
            .flatMap { segments(of: $0.range) }
    }

    // MARK: Fixes

    /// The checker's suggestions for an unknown word, written like it (up to five).
    func suggestions(for issue: SpellIssue) -> [String] {
        let language = AppSettings.shared.spellCheckLanguage
        return SpellCase.suggestions(SpellEngine.shared.guesses(for: issue.word, language: language.isEmpty ? nil : language),
                                     for: issue.word, isIdentifier: issue.isIdentifier)
    }

    /// Replaces just the word (in a name, just its part).
    @discardableResult
    func replace(_ issue: SpellIssue, with replacement: String) -> Bool {
        guard let document = editor?.document, self.issue(at: issue.range.location) == issue else { return false }
        return (try? document.apply([TextReplacement(range: issue.range, text: replacement)], actionName: "Fix Spelling")) ?? false
    }

    func addToFolderDictionary(_ word: String) {
        guard let folder = folderURL else { NSSound.beep(); return }
        add(word, to: SpellDictionaries.folderDictionary(in: folder))
    }

    func addToUserDictionary(_ word: String) {
        add(word, to: SpellDictionaries.shared.userFile)
    }

    private func add(_ word: String, to url: URL) {
        do {
            try SpellDictionaries.shared.add(word, to: url)
        } catch {
            editor?.document.workspace?.errorMessage = "“\(word)” couldn't be added to \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func ignoreInFile(_ word: String) {
        guard let document = editor?.document else { return }
        SpellDictionaries.shared.ignore(word, inFile: document.url)
    }

    /// The fixes for the unknown word at `index`: suggestions, then the dictionaries.
    func menuItems(at index: Int) -> [NSMenuItem] {
        guard let editor, let issue = issue(at: index) else { return [] }
        var items: [NSMenuItem] = []
        let bold = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
        for suggestion in suggestions(for: issue) {
            let item = ClosureMenuItem(suggestion) { [weak self] in self?.replace(issue, with: suggestion) }
            item.attributedTitle = NSAttributedString(string: suggestion, attributes: [.font: bold])
            items.append(item)
        }
        if items.isEmpty {
            let none = NSMenuItem(title: "No Spelling Suggestions", action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        if issue.isIdentifier, editor.document.canUse(.rename, .rename) {
            items.append(ClosureMenuItem("Rename Symbol…") { [weak editor] in
                editor?.textView.setSelectedRange(NSRange(location: issue.range.location, length: 0))
                editor?.perform(.rename)
            })
        }
        let folder = ClosureMenuItem("Add “\(issue.word)” to Folder Dictionary") { [weak self] in self?.addToFolderDictionary(issue.word) }
        folder.isEnabled = folderURL != nil
        items += [
            folder,
            ClosureMenuItem("Add “\(issue.word)” to User Dictionary") { [weak self] in self?.addToUserDictionary(issue.word) },
            ClosureMenuItem("Ignore “\(issue.word)” in This File") { [weak self] in self?.ignoreInFile(issue.word) },
        ]
        return items
    }
}

extension EditorController {
    /// The spelling fixes for the word at `index` (context menu, ⌘.), none when it's known.
    func spellingMenuItems(at index: Int) -> [NSMenuItem] {
        spelling.menuItems(at: index)
    }
}

extension Workspace {
    static let spellingPaletteCommands: [PaletteCommand] = [
        PaletteCommand(id: "spelling.toggle", title: "Spelling: Toggle Spell Checker", icon: "textformat.abc.dottedunderline", key: nil,
                       isAvailable: { _ in true }, perform: { _ in AppSettings.shared.spellCheck.toggle() }),
        PaletteCommand(id: "spelling.addToFolderDictionary", title: "Spelling: Add Word to Folder Dictionary", icon: "character.book.closed",
                       key: nil, isAvailable: { $0.activeDocument?.editor != nil && $0.rootURL != nil },
                       perform: { $0.addWordAtCursorToFolderDictionary() }),
    ]

    /// The unknown word at the cursor, else the selection or the word there, to the folder's dictionary.
    func addWordAtCursorToFolderDictionary() {
        guard let editor = activeDocument?.editor else { NSSound.beep(); return }
        let selection = editor.textView.selectedRange()
        let text = editor.document.textStorage.mutableString
        let word: String? = if let issue = editor.spelling.issue(at: selection.location) {
            issue.word
        } else if selection.length > 0 {
            text.substring(with: selection)
        } else {
            editor.wordRange(at: selection.location).map { text.substring(with: $0) }
        }
        guard let word = word?.trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty, !word.contains(where: \.isNewline) else {
            NSSound.beep()
            return
        }
        editor.spelling.addToFolderDictionary(word)
    }
}

/// Settings ▸ Editor's spell checking.
struct SpellCheckSettings: View {
    @Bindable var settings: AppSettings

    private var languages: [String] {
        var all = SpellEngine.availableLanguages
        if !all.contains(settings.spellCheckLanguage) { all.insert(settings.spellCheckLanguage, at: 0) }
        return all
    }

    var body: some View {
        Section {
            Toggle("Check spelling in comments, strings and text", isOn: $settings.spellCheck)
            Toggle("Check names in code too (split into words)", isOn: $settings.spellCheckIdentifiers)
                .disabled(!settings.spellCheck)
            Picker("Language", selection: $settings.spellCheckLanguage) {
                ForEach(languages, id: \.self) { code in
                    Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                }
            }
            .disabled(!settings.spellCheck)
            Toggle("List unknown words in Problems (as information)", isOn: $settings.spellCheckProblems)
                .disabled(!settings.spellCheck)
        } header: {
            Text("Spell Check")
        } footer: {
            Text("Words to accept go in a folder's .omc/dictionary.txt, or in yours with “Add to User Dictionary” on an underlined word.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
