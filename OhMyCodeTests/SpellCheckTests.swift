import AppKit
import Testing
@testable import Oh_My_Code

/// Spell checking: how text is cut into words, what's skipped, the dictionaries, the fixes,
/// and that it stays off the keystroke path. Nothing is learned into the system dictionary:
/// the checker is asked in a spell document of its own, and the dictionaries are temp files.
@MainActor
@Suite(.serialized)
struct SpellCheckTests {
    private func words(_ identifier: String) -> [String] { SpellWords.split(identifier).map(\.word) }

    private func prose(_ text: String) -> [String] {
        SpellWords.proseWords(in: text as NSString, range: NSRange(location: 0, length: (text as NSString).length)).map(\.word)
    }

    // MARK: Words

    @Test func splitsEveryCaseStyle() {
        #expect(words("camelCaseWord") == ["camel", "Case", "Word"])
        #expect(words("PascalCaseWord") == ["Pascal", "Case", "Word"])
        #expect(words("snake_case_word") == ["snake", "case", "word"])
        #expect(words("SCREAMING_CASE_WORD") == ["SCREAMING", "CASE", "WORD"])
        #expect(words("kebab-case-word") == ["kebab", "case", "word"])
        #expect(words("URLSession") == ["URL", "Session"])
        #expect(words("parseHTTPResponse") == ["parse", "HTTP", "Response"])
        #expect(words("sha256Hash") == ["sha", "Hash"])
        #expect(words("utf8String") == ["utf", "String"])
        #expect(words("allURLs") == ["all", "URLs"])
        #expect(words("__init__") == ["init"])
        #expect(words("XMLHttpRequest") == ["XML", "Http", "Request"])
    }

    @Test func identifierWordsSkipNumbersAndKeepRanges() {
        let text = "let parseHTTPResponse = 0x1F + 42; var kebab-name" as NSString
        let tokens = SpellWords.identifierWords(in: text, range: NSRange(location: 0, length: text.length))
        #expect(tokens.map(\.word) == ["let", "parse", "HTTP", "Response", "var", "kebab", "name"])
        #expect(tokens.allSatisfy { text.substring(with: $0.range) == $0.word && $0.isIdentifier })
        // Hyphens join names only where the language has them (CSS).
        let css = SpellWords.identifierWords(in: text, range: NSRange(location: 0, length: text.length), allowsHyphen: true)
        #expect(css.suffix(2).map(\.word) == ["kebab", "name"])
        #expect(css.last.map { NSMaxRange($0.range) } == text.length)
    }

    @Test func proseSkipsWhatIsntWords() {
        #expect(prose("See https://example.com/path?q=1 or www.example.org") == ["See", "or"])
        #expect(prose("mail someone@example.com today") == ["mail", "today"])
        #expect(prose("open ~/Library/Caches and ./build/out and /usr/local/bin") == ["open", "and", "and"])
        #expect(prose("color #ff00aa value 0xDEADBEEF") == ["color", "value"])
        #expect(prose("id 123e4567-e89b-12d3-a456-426614174000 here") == ["id", "here"])
        #expect(prose("token aGVsbG8gd29ybGQgdGhpcyBpcw== end") == ["token", "end"])
        #expect(prose("version v2beta and h264") == ["version", "and"])
        // Apostrophes: possessives check the word; contractions are whole.
        #expect(prose("the workspace's file doesn't load") == ["the", "workspace", "file", "doesn't", "load"])
        // Escapes glued to a word, and names in prose split like code.
        #expect(prose("\\nHello parseHTTPResponse") == ["Hello", "parse", "HTTP", "Response"])
    }

    @Test func skipRules() {
        #expect(SpellRules.skipsWord("buf"))       // short
        #expect(SpellRules.skipsWord("HTTP"))      // acronym
        #expect(SpellRules.skipsWord("abc4def"))   // digits
        #expect(SpellRules.skipsWord("deadbeefcafe"))
        #expect(!SpellRules.skipsWord("recieve"))
        #expect(!SpellRules.skipsWord("SCREAMING"))
        #expect(SpellRules.looksEncoded("dGhpcyBpcyBhIHRlc3Q9PQ=="))
        #expect(!SpellRules.looksEncoded("internationalization"))
        #expect(!SpellRules.skipsChunk("and/or".replacingOccurrences(of: "/", with: "")))
    }

    @Test func directives() {
        let text = """
        // spell-checker: ignore qwzzle Blorft
        a
        /* cspell:disable */
        b
        // spell-checker: enable
        c
        """ as NSString
        let directives = SpellDirectives.parse(text)
        #expect(directives.ignored == ["qwzzle", "blorft"])
        #expect(directives.isDisabled(text.range(of: "\nb\n").location + 1))
        #expect(!directives.isDisabled(text.range(of: "a\n").location))
        #expect(!directives.isDisabled(text.range(of: "c", options: .backwards).location))
        #expect(SpellDirectives.parse("nothing here") == SpellDirectives())
    }

    // MARK: Checking

    @Test func checksCommentsStringsAndNames() {
        let source = "// Thsi is a comment\nlet recieveCount = \"hello wrold\"\nfunc fetch() {}\n" as NSString
        let comment = NSRange(location: 0, length: source.range(of: "\n").location)
        let string = source.range(of: "\"hello wrold\"")
        let keywords = [source.range(of: "let"), source.range(of: "func")]
        var request = SpellCheckRequest(text: source, checkRange: NSRange(location: 0, length: source.length), mode: .code,
                                        proseRanges: [comment, string], excludedRanges: keywords, language: "en")
        request.known = [SpellDictionaries.terms]
        let issues = request.run()
        #expect(issues.map(\.word) == ["Thsi", "recieve", "wrold"])
        #expect(issues.map(\.isIdentifier) == [false, true, false])
        #expect(issues.allSatisfy { source.substring(with: $0.range) == $0.word })
        // Names off: comments and strings only.
        request.checksIdentifiers = false
        #expect(request.run().map(\.word) == ["Thsi", "wrold"])
        // The dictionaries' words are known, whatever their case.
        request.known.append(["thsi", "WROLD".lowercased()])
        #expect(request.run().isEmpty)
    }

    @Test func markdownSkipsCode() {
        let text = "Some wrold text `recieve` here.\n\n```\nlet qwzzle = 1\n```\nAnd mroe.\n" as NSString
        let request = SpellCheckRequest(text: text, checkRange: NSRange(location: 0, length: text.length), mode: .markdown,
                                        language: "en")
        #expect(request.run().map(\.word) == ["wrold", "mroe"])
    }

    @Test func builtInTermsAreLoaded() {
        let terms = SpellDictionaries.terms
        #expect(terms.count > 300)
        for word in ["async", "enum", "init", "args", "params", "config", "uuid", "json", "regex", "localhost", "stdout",
                     "github", "macos", "swiftui", "npm", "repo", "webhook", "middleware", "mutex", "tokenizer"] {
            #expect(terms.contains(word), "\(word)")
        }
    }

    // MARK: Dictionaries

    @Test func dictionaryFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "omc-spell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let dictionaries = SpellDictionaries(userFile: folder.appending(path: "support/OhMyCode/dictionary.txt"))
        #expect(dictionaries.words(at: dictionaries.userFile).isEmpty)
        try dictionaries.add("Qwzzle", to: dictionaries.userFile)
        try dictionaries.add("qwzzle", to: dictionaries.userFile) // already there
        #expect(try String(contentsOf: dictionaries.userFile, encoding: .utf8) == "Qwzzle\n")
        #expect(dictionaries.words(at: dictionaries.userFile) == ["qwzzle"])

        // A folder's: .omc/dictionary.txt, made on demand; edits on disk are read again.
        let project = folder.appending(path: "project")
        let file = SpellDictionaries.folderDictionary(in: project)
        #expect(file.path.hasSuffix("project/.omc/dictionary.txt"))
        try dictionaries.add("blorft", to: file)
        #expect(dictionaries.words(at: file) == ["blorft"])
        try "# words\nblorft\n\n  Zyxx  \n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        #expect(dictionaries.words(at: file) == ["blorft", "zyxx"])

        // The app's own is in OMC_SUPPORT_DIR's folder (a temp file under tests).
        #expect(SpellDictionaries.shared.userFile.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test func suggestionsKeepTheWordsCase() {
        #expect(SpellCase.match("receive", to: "recieve") == "receive")
        #expect(SpellCase.match("receive", to: "Recieve") == "Receive")
        #expect(SpellCase.match("receive", to: "RECIEVE") == "RECEIVE")
        #expect(SpellCase.match("Paris", to: "pariss") == "paris")
        // In a name, only one-word guesses fit; at most five.
        let guesses = ["re ceive", "receive", "relieve", "reprieve", "deceive", "recipe", "receiver"]
        #expect(SpellCase.suggestions(guesses, for: "Recieve", isIdentifier: true) == ["Receive", "Relieve", "Reprieve", "Deceive", "Recipe"])
        #expect(SpellCase.suggestions(guesses, for: "recieve", isIdentifier: false).first == "re ceive")
        #expect(SpellEngine.shared.guesses(for: "recieve", language: "en").contains("receive"))
    }

    // MARK: In the editor

    private func open(_ text: String, extension ext: String) throws -> (EditorDocument, EditorController, NSWindow, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-spell-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        controller.textView.layoutSubtreeIfNeeded()
        document.editor = controller
        document.attach(controller)
        return (document, controller, window, url)
    }

    /// Checks until the editor has found something (highlights arrive in the background).
    private func checked(_ controller: EditorController) async throws {
        for _ in 0..<200 {
            await controller.spelling.check()
            if !controller.spelling.issues.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("nothing was found")
    }

    @Test func fixesReplaceOnlyTheWord() async throws {
        let (document, controller, window, url) = try open("let recieveCount = 1 // the wrold\n", extension: "swift")
        defer { try? FileManager.default.removeItem(at: url) }
        try await checked(controller)
        let spelling = controller.spelling
        #expect(spelling.issues.map(\.word) == ["recieve", "wrold"])
        let issue = try #require(spelling.issue(at: 6))
        #expect(issue.isIdentifier)
        #expect(spelling.suggestions(for: issue).contains("receive"))
        // The menu: suggestions, then the dictionaries.
        let titles = controller.spellingMenuItems(at: 6).map(\.title)
        #expect(titles.contains("receive"))
        #expect(titles.contains("Add “recieve” to User Dictionary") && titles.contains("Ignore “recieve” in This File"))
        #expect(spelling.replace(issue, with: "receive"))
        #expect(document.textStorage.string == "let receiveCount = 1 // the wrold\n")
        // Moved by the edit; still found where it now is.
        #expect(spelling.issue(at: document.textStorage.mutableString.range(of: "wrold").location)?.word == "wrold")
        #expect(spelling.issue(at: 6) == nil)
        withExtendedLifetime(window) {}
    }

    @Test func ignoreInFileAndSpellingOff() async throws {
        let (document, controller, window, url) = try open("Some wrold text and a mroe.\n", extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await checked(controller)
        let spelling = controller.spelling
        #expect(spelling.issues.map(\.word) == ["wrold", "mroe"])
        spelling.ignoreInFile("wrold")
        await spelling.check()
        #expect(spelling.issues.map(\.word) == ["mroe"])
        #expect(SpellDictionaries.shared.ignored(inFile: document.url) == ["wrold"])
        AppSettings.shared.spellCheck = false
        defer { AppSettings.shared.spellCheck = true }
        await spelling.check()
        #expect(spelling.issues.isEmpty)
        #expect(controller.spellingMenuItems(at: 20).isEmpty)
        withExtendedLifetime(window) {}
    }

    // MARK: Performance

    /// Only the text around the viewport is checked, quickly, and typing only moves the words
    /// found (the check waits for a pause).
    @Test func checksTheViewportNotTheFile() async throws {
        let code = PerformanceBenchmarks.code(bytes: 2_000_000) + "// a wrold at the end\n"
        let (document, controller, window, url) = try open(code, extension: "swift")
        defer { try? FileManager.default.removeItem(at: url) }
        let spelling = controller.spelling
        let middle = document.lineIndex.lineStarts[document.lineIndex.lineCount / 2]
        controller.reveal(NSRange(location: middle, length: 0))
        controller.textView.layoutSubtreeIfNeeded()
        controller.refreshHighlights(force: true)
        await document.highlighter?.waitUntilIdle()
        var request: SpellCheckRequest?
        for _ in 0..<200 where request == nil {
            request = spelling.makeRequest()
            if request == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let checked = try #require(request)
        #expect(checked.checkRange.length < 40_000, "checked \(checked.checkRange.length) characters")
        #expect(checked.text.length <= checked.checkRange.length + SpellCheckController.lookBehind)
        let clock = ContinuousClock()
        let duration = clock.measure { _ = checked.run() }
        #expect(duration < .milliseconds(150), "checking the viewport took \(duration)")
        #expect(checked.run().isEmpty) // the word at the end is far off screen

        SpellCheckController.delay = .seconds(30)
        defer { SpellCheckController.delay = .milliseconds(400) }
        let before = spelling.checkCount
        var samples: [Duration] = []
        for _ in 0..<15 {
            samples.append(clock.measure {
                controller.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
                controller.textView.layoutSubtreeIfNeeded()
            })
        }
        let median = samples.sorted()[samples.count / 2]
        #expect(median < .milliseconds(25), "median keystroke took \(median)")
        #expect(spelling.checkCount == before)
        withExtendedLifetime(window) {}
    }

    @Test func movesWordsAfterAnEdit() async throws {
        let (document, controller, window, url) = try open("One wrold.\nTwo mroe.\n", extension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try await checked(controller)
        let spelling = controller.spelling
        #expect(spelling.issues.map(\.word) == ["wrold", "mroe"])
        try document.apply([TextReplacement(range: NSRange(location: 0, length: 0), text: "Hi. ")], actionName: "Type")
        #expect(spelling.issues.map(\.range.location) == [8, 19])
        try document.apply([TextReplacement(range: NSRange(location: 8, length: 5), text: "world")], actionName: "Type")
        #expect(spelling.issues.map(\.word) == ["mroe"])
        withExtendedLifetime(window) {}
    }
}
