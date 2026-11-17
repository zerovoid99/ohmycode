import AppKit
import Testing
@testable import Oh_My_Code

/// A text, a selection and an undo stack: what the Vim engine edits, without an editor.
@MainActor
final class VimTestHost: VimHost {
    static var kept: [VimTestHost] = []
    let string: NSMutableString
    var selection = NSRange(location: 0, length: 0)
    var editable = true
    var clipboard: String?
    var lineBreak = "\n"
    var indent = "    "
    var visible = 0...19
    var commands: [VimHostCommand] = []
    var scrolledLines = 0
    private(set) var undoStack: [(String, NSRange)] = []
    private var redoStack: [(String, NSRange)] = []
    private var depth = 0
    private var before: (String, NSRange)?

    init(_ text: String) {
        string = NSMutableString(string: text)
    }

    var vimText: NSString { string }
    var vimLines: LineIndex { LineIndex(string: string) }
    var vimSelection: NSRange { selection }
    func vimSetSelection(_ range: NSRange, reveal: Int) { selection = range }

    func vimApply(_ edits: [TextReplacement]) -> Bool {
        guard let sorted = try? TextReplacement.validated(edits, length: string.length) else { return false }
        let snapshot = (string as String, selection)
        var changed = false
        for edit in sorted.reversed() where edit.range.length > 0 || !edit.text.isEmpty {
            string.replaceCharacters(in: edit.range, with: edit.text)
            changed = true
        }
        if changed, depth == 0 {
            undoStack.append(snapshot)
            redoStack = []
        }
        selection = NSRange(location: min(selection.location, string.length), length: 0)
        return changed
    }

    func vimBeginChange() {
        depth += 1
        if depth == 1 { before = (string as String, selection) }
    }

    func vimEndChange() {
        depth -= 1
        if depth == 0, let before, before.0 != string as String {
            undoStack.append(before)
            redoStack = []
        }
        if depth == 0 { before = nil }
    }

    func vimUndo() -> Bool {
        guard let last = undoStack.popLast() else { return false }
        redoStack.append((string as String, selection))
        string.setString(last.0)
        selection = NSRange(location: min(last.1.location, string.length), length: 0)
        return true
    }

    func vimRedo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append((string as String, selection))
        string.setString(next.0)
        selection = NSRange(location: min(next.1.location, string.length), length: 0)
        return true
    }

    var vimIsEditable: Bool { editable }
    var vimVisibleLines: ClosedRange<Int> { visible }
    func vimScroll(lines: Int) { scrolledLines += lines }
    func vimScrollCursor(to position: VimScrollPosition) {}
    var vimLineBreak: String { lineBreak }
    var vimIndentUnit: String { indent }
    var vimClipboard: String? {
        get { clipboard }
        set { clipboard = newValue }
    }

    func vimRun(_ command: VimHostCommand) -> String? {
        commands.append(command)
        return nil
    }

    func vimStateDidChange() {}
}

@MainActor
struct VimEngineTests {
    /// The engine on `text`, its cursor at "|" (removed).
    private func make(_ text: String) -> (VimEngine, VimTestHost) {
        let marker = (text as NSString).range(of: "|")
        let host = VimTestHost(marker.location == NSNotFound ? text : (text as NSString).replacingCharacters(in: marker, with: ""))
        host.selection = NSRange(location: marker.location == NSNotFound ? 0 : marker.location, length: 0)
        VimTestHost.kept.append(host) // the engine holds its host weakly
        return (VimEngine(host: host), host)
    }

    /// The text with "|" at the cursor.
    private func show(_ host: VimTestHost) -> String {
        (host.string as NSString).replacingCharacters(in: NSRange(location: host.selection.location, length: 0), with: "|")
    }

    /// Types `keys` in Normal mode on `text` (cursor at "|"); the text after, cursor at "|".
    private func run(_ text: String, _ keys: String) -> String {
        let (vim, host) = make(text)
        vim.feed(keys)
        return show(host)
    }

    // MARK: Motions

    @Test func characterAndLineMotions() {
        #expect(run("ab|c", "h") == "a|bc")
        #expect(run("|abc", "h") == "|abc")
        #expect(run("a|bc", "l") == "ab|c")
        #expect(run("ab|c", "l") == "ab|c") // not onto the line break
        #expect(run("a|bcdef", "3l") == "abcd|ef")
        #expect(run("abc|d\nx\nabcdef", "j") == "abcd\n|x\nabcdef")
        // j keeps the column it started at past a shorter line.
        #expect(run("abc|d\nx\nabcdef", "jj") == "abcd\nx\nabc|def")
        #expect(run("abcd\nx\nabc|def", "2k") == "abc|d\nx\nabcdef")
        #expect(run("a\n|b", "j") == "a\n|b") // nowhere to go
        #expect(run("a\nb\nc\n|d", "10k") == "|a\nb\nc\nd")
        #expect(run("  fo|o  ", "0") == "|  foo  ")
        #expect(run("|  foo  ", "^") == "  |foo  ")
        #expect(run("|  foo  ", "$") == "  foo | ")
        #expect(run("|  foo  ", "g_") == "  fo|o  ")
        #expect(run("|ab\ncd\nef", "2$") == "ab\nc|d\nef")
        // $ keeps to line ends going down.
        #expect(run("|abcd\nab\nabc", "$jj") == "abcd\nab\nab|c")
        #expect(run("|a\n  b\nc", "+") == "a\n  |b\nc")
        #expect(run("a\n  b\n|c", "-") == "a\n  |b\nc")
        #expect(run("a\n  b\n|c", "<CR>") == "a\n  b\n|c")
        #expect(run("|a\n  b\nc", "2_") == "a\n  |b\nc")
    }

    @Test func wordMotions() {
        #expect(run("|foo bar", "w") == "foo |bar")
        #expect(run("|foo.bar baz", "w") == "foo|.bar baz")
        #expect(run("|foo.bar baz", "W") == "foo.bar |baz")
        #expect(run("|foo bar baz", "2w") == "foo bar |baz")
        // An empty line is a word; the last word goes to the end of the text.
        #expect(run("fo|o\n\nbar", "w") == "foo\n|\nbar")
        #expect(run("fo|o\n\nbar", "ww") == "foo\n\n|bar")
        #expect(run("foo |bar", "w") == "foo ba|r")
        #expect(run("foo\n    |bar", "b") == "|foo\n    bar")
        #expect(run("foo ba|r", "b") == "foo |bar")
        #expect(run("foo ba|r", "bb") == "|foo bar")
        #expect(run("foo\n\n|bar", "b") == "foo\n|\nbar")
        #expect(run("foo.ba|r", "B") == "|foo.bar")
        #expect(run("|foo bar", "e") == "fo|o bar")
        #expect(run("fo|o bar", "e") == "foo ba|r")
        #expect(run("|foo.bar x", "E") == "foo.ba|r x")
        #expect(run("foo ba|r", "ge") == "fo|o bar")
        #expect(run("foo\n\nba|r", "ge") == "foo\n|\nbar")
        #expect(run("foo.bar ba|z", "gE") == "foo.ba|r baz")
        // Unicode letters are word characters; an emoji is one character.
        #expect(run("|héllo wörld", "w") == "héllo |wörld")
        #expect(run("|naïve café", "e") == "naïv|e café")
        #expect(run("a|😀b", "l") == "a😀|b")
        #expect(run("a😀|b", "h") == "a|😀b")
        #expect(run("|e\u{301}x", "l") == "e\u{301}|x")
        #expect(run("|😀 😀 x", "w") == "😀 |😀 x")
    }

    @Test func fileAndScreenMotions() {
        let text = "one\n  two\nthree\nfour\n"
        #expect(run("|" + text, "G") == "one\n  two\nthree\nfour\n|")
        #expect(run(text + "|", "gg") == "|" + text)
        #expect(run("|" + text, "2G") == "one\n  |two\nthree\nfour\n")
        #expect(run("|" + text, "3gg") == "one\n  two\n|three\nfour\n")
        #expect(run("|one\n  two\nthree\nfour", "50%") == "one\n  |two\nthree\nfour")
        let (vim, host) = make("|a\nb\nc\nd\ne\nf\ng")
        host.visible = 2...6
        vim.feed("H")
        #expect(show(host) == "a\nb\n|c\nd\ne\nf\ng")
        vim.feed("L")
        #expect(show(host) == "a\nb\nc\nd\ne\nf\n|g")
        vim.feed("M")
        #expect(show(host) == "a\nb\nc\nd\n|e\nf\ng")
        vim.feed("2H")
        #expect(show(host) == "a\nb\nc\n|d\ne\nf\ng")
        // ^D moves half a page and scrolls as much.
        vim.feed("<C-d>")
        #expect(show(host) == "a\nb\nc\nd\ne\n|f\ng" && host.scrolledLines == 2)
        vim.feed("<C-u>")
        #expect(show(host) == "a\nb\nc\n|d\ne\nf\ng" && host.scrolledLines == 0)
    }

    @Test func findAndBracketMotions() {
        #expect(run("|a,b,c,d", "f,") == "a|,b,c,d")
        #expect(run("|a,b,c,d", "f,;") == "a,b|,c,d")
        #expect(run("|a,b,c,d", "f,;,") == "a|,b,c,d")
        #expect(run("|a,b,c,d", "2f,") == "a,b|,c,d")
        #expect(run("a,b,c,|d", "F,") == "a,b,c|,d")
        #expect(run("|ab,c,d", "t,") == "a|b,c,d")
        // Repeating t from right before the character goes on to the next one.
        #expect(run("|ab,c,d", "t,;") == "ab,|c,d")
        #expect(run("a,b,c|d", "T,") == "a,b,|cd")
        #expect(run("|abc\nx,", "f,") == "|abc\nx,") // not past the line
        #expect(run("|if (a[1]) {}", "%") == "if (a[1]|) {}")
        #expect(run("if (a[1]|) {}", "%") == "if |(a[1]) {}")
        #expect(run("if (a|[1]) {}", "%") == "if (a[1|]) {}")
        #expect(run("|f {\n  x\n}", "%") == "f {\n  x\n|}")
        #expect(run("|a\nb\n\nc\nd", "}") == "a\nb\n|\nc\nd")
        #expect(run("|a\nb\n\nc\nd", "}}") == "a\nb\n\nc\n|d")
        #expect(run("a\nb\n\nc\n|d", "{") == "a\nb\n|\nc\nd")
        #expect(run("a\nb\n\nc\n|d", "2{") == "|a\nb\n\nc\nd")
    }

    @Test func searchMotions() {
        #expect(run("|foo bar foo", "*") == "foo bar |foo")
        #expect(run("|foo bar foo", "*n") == "|foo bar foo") // wraps
        #expect(run("foo bar |foo", "#") == "|foo bar foo")
        // Whole words only.
        #expect(run("|foo food foo", "*") == "foo food |foo")
        #expect(run("|one two one two", "/two<CR>") == "one |two one two")
        #expect(run("|one two one two", "/two<CR>n") == "one two one |two")
        #expect(run("|one two one two", "/two<CR>nN") == "one |two one two")
        #expect(run("one two one |two", "?one<CR>") == "one two |one two")
        #expect(run("|a1 b22 c333", "/\\d\\{3}<CR>") == "a1 b22 c|333")
        #expect(run("|x foo(bar)", "/(bar<CR>") == "x foo|(bar)")
        #expect(run("|x Foo", "/foo\\c<CR>") == "x |Foo")
        let (vim, host) = make("|abc")
        vim.feed("/zzz<CR>")
        #expect(show(host) == "|abc" && vim.message == "E486: Pattern not found: zzz")
        // Backspace past the start leaves the command line.
        vim.feed("/a<BS><BS>")
        #expect(vim.commandLine == nil && vim.mode == .normal)
    }

    // MARK: Operators

    @Test func deleteWithMotions() {
        #expect(run("a|bc def", "dw") == "a|def")
        #expect(run("|one two three four", "d2w") == "|three four")
        #expect(run("|one two three four", "2dw") == "|three four")
        #expect(run("|one two three four", "2d2w") == "|")
        // The last word on a line: up to the line's end, not into the next line.
        #expect(run("foo |bar\nbaz", "dw") == "foo| \nbaz")
        #expect(run("foo |bar\n  baz", "dw") == "foo| \n  baz")
        #expect(run("|foo bar", "de") == "| bar")
        #expect(run("foo ba|r", "db") == "foo |r")
        #expect(run("ab|cdef", "d$") == "a|b")
        #expect(run("ab|cdef", "D") == "a|b")
        #expect(run("ab|cdef", "d0") == "|cdef")
        #expect(run("  ab|cdef", "d^") == "  |cdef")
        #expect(run("a(b|c)d", "dt)") == "a(b|)d")
        #expect(run("a(b|c)d", "df)") == "a(b|d")
        #expect(run("a|bc", "dh") == "|bc")
        #expect(run("|one two three", "d/thr<CR>") == "|three")
        #expect(run("a\n|b\nc\nd", "dj") == "a\n|d")
        #expect(run("a\nb\n|c\nd", "dk") == "a\n|d")
        #expect(run("a\n|b\nc", "dG") == "|a")
        #expect(run("a\nb\n|c", "dgg") == "|")
        // From the start of a line, } deletes whole lines.
        #expect(run("|a\nb\n\nc", "d}") == "|\nc")
        #expect(run("x |a\nb\n\nc", "d}") == "x| \n\nc")
    }

    @Test func linewiseDeletes() {
        #expect(run("a\n|b\nc", "dd") == "a\n|c")
        #expect(run("a\nb\n|c", "dd") == "a\n|b")
        #expect(run("|abc", "dd") == "|")
        #expect(run("|a\nb\nc\nd", "2dd") == "|c\nd")
        #expect(run("|a\nb", "5dd") == "|")
        #expect(run("x\n  |a\n  b", "dd") == "x\n  |b")
        // With a final line break, the last (empty) line is a line too.
        #expect(run("a\n|b\n", "dd") == "a\n|")
        let (vim, host) = make("a\n|b\nc")
        vim.feed("dd")
        #expect(vim.registerContents(nil) == VimRegister(text: "b\n", linewise: true))
        #expect(host.undoStack.count == 1)
    }

    @Test func changes() {
        let (vim, host) = make("|foo bar")
        vim.feed("cw")
        #expect(vim.mode == .insert && show(host) == "| bar")
        vim.feed("baz<Esc>")
        #expect(vim.mode == .normal && show(host) == "ba|z bar")
        #expect(run("|a b", "cwx<Esc>") == "|x b") // a one-letter word
        #expect(run("|foo  bar", "cwx<Esc>") == "|x  bar")
        #expect(run("|one two three", "c2wx<Esc>") == "|x three")
        #expect(run("  fo|o\nbar", "ccx<Esc>") == "  |x\nbar")
        #expect(run("ab|cd", "Cx<Esc>") == "ab|x")
        #expect(run("ab|cd", "sx<Esc>") == "ab|xd")
        #expect(run("ab|cd", "2sx<Esc>") == "ab|x")
        #expect(run("  ab|cd", "Sx<Esc>") == "  |x")
        #expect(run("|", "sx<Esc>") == "|x")
        // c with a text object.
        #expect(run("f(a, |b)", "ci(x<Esc>") == "f(|x)")
        #expect(run("say \"hel|lo\" now", "ci\"bye<Esc>") == "say \"by|e\" now")
    }

    @Test func simpleEdits() {
        #expect(run("a|bc", "x") == "a|c")
        #expect(run("ab|c", "x") == "a|b")
        #expect(run("|abcd", "3x") == "|d")
        #expect(run("a|bc", "9x") == "|a")
        #expect(run("|\nx", "x") == "|\nx") // nothing on an empty line
        #expect(run("abc|\nd", "x") == "a|b\nd") // a click past the end: on the last character first
        #expect(run("ab|c", "X") == "a|c")
        #expect(run("|😀😀x", "x") == "|😀x")
        #expect(run("|abc", "rx") == "|xbc")
        #expect(run("|abc", "2rx") == "x|xc")
        #expect(run("|abc", "4rx") == "|abc") // not enough characters
        #expect(run("a|bc", "r<CR>") == "a\n|c")
        #expect(run("|abC", "~~~") == "AB|c")
        #expect(run("|abc", "3~") == "AB|C")
        #expect(run("|a\n  b", "J") == "a| b")
        #expect(run("|a \nb", "J") == "a |b")
        #expect(run("|f(\n)", "J") == "f(|)")
        #expect(run("|a\n\nb", "J") == "|a\nb")
        #expect(run("|a\nb\nc\nd", "3J") == "a b| c\nd")
        #expect(run("|a\n  b", "gJ") == "a|  b")
        #expect(run("|a", "J") == "|a")
    }

    @Test func textObjects() {
        #expect(run("one t|wo three", "diw") == "one | three")
        #expect(run("one t|wo three", "daw") == "one |three")
        #expect(run("one t|wo", "daw") == "on|e") // no space after: the one before goes
        #expect(run("a.b|c.d", "diW") == "|")
        #expect(run("one t|wo three four", "d2aw") == "one |four")
        #expect(run("f(a, (|b), c)", "di(") == "f(a, (|), c)")
        #expect(run("f(a, (|b), c)", "da(") == "f(a, |, c)")
        #expect(run("f(a, (|b), c)", "d2i(") == "f(|)")
        #expect(run("f|(a)", "dib") == "f(|)")
        #expect(run("x[1, |2]", "di[") == "x[|]")
        #expect(run("x <a |b>", "di<") == "x <|>")
        #expect(run("{ a |b }", "daB") == "|")
        #expect(run("say 'h|i' x", "di'") == "say '|' x")
        #expect(run("say 'h|i' x", "da'") == "say |x")
        #expect(run("|x = \"a\" + \"b\"", "di\"") == "x = \"|\" + \"b\"")
        #expect(run("a `c|md` b", "di`") == "a `|` b")
        #expect(run("<p><b>h|i</b></p>", "dit") == "<p><b>|</b></p>")
        #expect(run("<p><b>h|i</b></p>", "dat") == "<p>|</p>")
        #expect(run("<p><b>h|i</b></p>", "d2it") == "<p>|</p>")
        #expect(run("a\nb|b\n\nc", "dip") == "|\nc")
        #expect(run("a\nb|b\n\nc", "dap") == "|c")
        // A block on lines of its own: its inner lines.
        #expect(run("f {\n    a|\n    b\n}", "di{") == "f {\n|}")
        #expect(run("f {\n    a|\n    b\n}\n", "ci{x<Esc>") == "f {\n    |x\n}\n")
        let (vim, _) = make("f(a|bc)")
        vim.feed("yi(")
        #expect(vim.registerContents(nil)?.text == "abc")
    }

    @Test func indentAndCase() {
        #expect(run("|a\nb", ">>") == "    |a\nb")
        #expect(run("|a\nb\nc", "2>>") == "    |a\n    b\nc")
        #expect(run("|a\nb\nc", ">j") == "    |a\n    b\nc")
        #expect(run("|a\n\nb", ">2j") == "    |a\n\n    b") // empty lines stay empty
        #expect(run("      |a", "<<") == "  |a")
        #expect(run("\t|a", "<<") == "|a")
        #expect(run("  |a", "<<") == "|a")
        let (vim, host) = make("|a")
        host.indent = "\t"
        vim.feed(">>")
        #expect(show(host) == "\t|a")
        #expect(run("|hello world", "gUiw") == "|HELLO world")
        #expect(run("|Hello World", "guu") == "|hello world")
        #expect(run("|Hello World", "g~~") == "|hELLO wORLD")
        #expect(run("|ab cd", "gUU") == "|AB CD")
        #expect(run("|ab cd", "gUgU") == "|AB CD")
        #expect(run("|ab cd", "g~w") == "|AB cd")
    }

    // MARK: Registers and paste

    @Test func yankAndPut() {
        #expect(run("|a\nb", "yyp") == "a\n|a\nb")
        #expect(run("|a\nb", "yyP") == "|a\na\nb")
        #expect(run("a\n|b", "yyp") == "a\nb\n|b") // after the last line
        #expect(run("|a\nb", "yy2p") == "a\n|a\na\nb")
        #expect(run("  |a\nb", "yyjp") == "  a\nb\n  |a")
        #expect(run("|foo bar", "ywP") == "foo| foo bar")
        #expect(run("|foo bar", "ywp") == "ffoo| oo bar")
        #expect(run("|ab", "xp") == "b|a")
        #expect(run("|a\nb", "ddp") == "b\n|a")
        #expect(run("|abc", "yl3p") == "aaa|abc")
        // yy keeps the cursor where it is; yk goes up.
        #expect(run("a|bc", "yy") == "a|bc")
        #expect(run("x\na|bc", "yk") == "|x\nabc")
        #expect(run("foo b|ar", "yiw") == "foo |bar")
        // Lines put into a CRLF text get its line breaks.
        let (vim, host) = make("|a\r\nb")
        host.lineBreak = "\r\n"
        vim.feed("yyp")
        #expect(host.string as String == "a\r\na\r\nb" && host.selection.location == 3)
        #expect(vim.registerContents(nil)?.text == "a\n")
    }

    @Test func namedRegisters() {
        let (vim, host) = make("|one\ntwo\nthree")
        vim.feed("\"ayyj\"byy")
        #expect(vim.registerContents("a")?.text == "one\n" && vim.registerContents("b")?.text == "two\n")
        vim.feed("\"Ayy") // appends
        #expect(vim.registerContents("a")?.text == "one\ntwo\n")
        vim.feed("G\"ap")
        #expect(host.string as String == "one\ntwo\nthree\none\ntwo")
        // Yanks go to "0, deletes don't touch it; "_ keeps everything.
        let (vim2, host2) = make("|keep\ngone\nx")
        vim2.feed("yyjdd")
        #expect(vim2.registerContents("0")?.text == "keep\n" && vim2.registerContents("1")?.text == "gone\n")
        vim2.feed("\"_dd")
        #expect(vim2.registerContents(nil)?.text == "gone\n" && host2.string as String == "keep")
        vim2.feed("\"0p")
        #expect(host2.string as String == "keep\nkeep")
        // Small deletes go to "-; numbered ones shift.
        let (vim3, _) = make("|a b\nc\nd")
        vim3.feed("xjddjdd")
        #expect(vim3.registerContents("-")?.text == "a")
        #expect(vim3.registerContents("1")?.text == "d\n" && vim3.registerContents("2")?.text == "c\n")
        // + and * are the system pasteboard.
        let (vim4, host4) = make("|word x")
        vim4.feed("\"+yiw")
        #expect(host4.clipboard == "word")
        host4.clipboard = "line\n"
        vim4.feed("\"*p")
        #expect(host4.string as String == "word x\nline")
        let (vim5, host5) = make("|z")
        vim5.feed("p")
        #expect(host5.string as String == "z" && vim5.message?.hasPrefix("E353") == true)
    }

    // MARK: Insert mode

    @Test func insertEntries() {
        #expect(run("a|bc", "ix<Esc>") == "a|xbc")
        #expect(run("a|bc", "ax<Esc>") == "ab|xc")
        #expect(run("  a|bc", "Ix<Esc>") == "  |xabc")
        #expect(run("a|bc", "Ax<Esc>") == "abc|x")
        #expect(run("  a|bc\nd", "ox<Esc>") == "  abc\n  |x\nd")
        #expect(run("  a|bc\nd", "Ox<Esc>") == "  |x\n  abc\nd")
        #expect(run("|", "ax<Esc>") == "|x")
        #expect(run("a|b", "3ix<Esc>") == "axx|xb")
        #expect(run("|a", "2ox<Esc>") == "a\nx\n|x")
        // Esc at the start of a line stays there.
        #expect(run("|ab", "i<Esc>") == "|ab")
        #expect(run("a|b", "i<C-c>") == "|ab")
        let (vim, host) = make("a|b")
        vim.feed("ox")
        #expect(vim.mode == .insert && vim.statusText == "-- INSERT --")
        vim.handle("<C-[>")
        #expect(vim.mode == .normal && show(host) == "ab\n|x")
        // In CRLF text, o adds a CRLF line break.
        let (vim2, host2) = make("|a\r\nb")
        host2.lineBreak = "\r\n"
        vim2.feed("ox<Esc>")
        #expect(host2.string as String == "a\r\nx\r\nb")
    }

    @Test func replaceMode() {
        let (vim, host) = make("|xyz xyz")
        vim.feed("Rab")
        #expect(vim.mode == .replace && vim.statusText == "-- REPLACE --" && show(host) == "ab|z xyz")
        // Backspace puts back what was replaced.
        vim.feed("<BS>")
        #expect(show(host) == "a|yz xyz")
        vim.feed("cd<Esc>")
        #expect(vim.mode == .normal && show(host) == "ac|d xyz")
        vim.feed("w.")
        #expect(show(host) == "acd ac|d")
        #expect(host.undoStack.count == 2)
        // Past the end of the line it adds.
        #expect(run("a|b\nc", "Rxyz<Esc>") == "axy|z\nc")
    }

    // MARK: Repeat and undo

    @Test func dotRepeats() {
        #expect(run("|a b c d", "dw.") == "|c d")
        #expect(run("|abcd", "x..") == "|d")
        #expect(run("|a b c d e f", "dw3.") == "|e f")
        #expect(run("|foo x\nbar y", "ciwnew<Esc>j0.") == "new x\nne|w y")
        #expect(run("|a\nb", "A;<Esc>j.") == "a;\nb|;")
        #expect(run("|a\nb\nc", ">>j.") == "    a\n    |b\nc")
        #expect(run("|ab", "ix<Esc>.") == "|xxab")
        #expect(run("|a", "3ix<Esc>.") == "xxxx|xxa")
        #expect(run("|a\nb\nc\nd\ne", "Vjd.") == "|e")
        #expect(run("|abcdef", "vlld.") == "|")
        #expect(run("|a", "ox<Esc>.") == "a\nx\n|x")
        #expect(run("|ab ab", "rxw.") == "xb |xb")
        #expect(run("|a b", "~w.") == "A |B")
        #expect(run("|a\nb\nc\nd", "J.") == "a b| c\nd")
        #expect(run("|x\ny", "yyp.") == "x\nx\n|x\ny")
        // Backspacing over text before where typing started repeats too.
        #expect(run("ab|c abc", "i<BS>x<Esc>wl.") == "axc |xbc")
    }

    @Test func undoIsOneStepPerChange() {
        let (vim, host) = make("|one two three")
        vim.feed("dwdw")
        #expect(host.string as String == "three" && host.undoStack.count == 2)
        vim.feed("u")
        #expect(host.string as String == "two three")
        vim.feed("<C-r>")
        #expect(host.string as String == "three")
        vim.feed("2u")
        #expect(host.string as String == "one two three")
        vim.feed("u")
        #expect(vim.message == "Already at oldest change")
        // A change with its typing: one step.
        let (vim2, host2) = make("|foo bar")
        vim2.feed("ciwhello<BS><BS>p<Esc>")
        #expect(host2.string as String == "help bar" && host2.undoStack.count == 1)
        vim2.feed("u")
        #expect(host2.string as String == "foo bar")
        // o with its typing, and a count's repetitions: one step.
        let (vim3, host3) = make("|a")
        vim3.feed("3ox<Esc>")
        #expect(host3.string as String == "a\nx\nx\nx" && host3.undoStack.count == 1)
    }

    // MARK: Visual mode

    @Test func visualMode() {
        let (vim, host) = make("|abc def")
        vim.feed("v")
        #expect(vim.mode == .visual && host.selection == NSRange(location: 0, length: 1) && vim.statusText == "-- VISUAL --")
        vim.feed("e")
        #expect(host.selection == NSRange(location: 0, length: 3))
        vim.feed("o")
        #expect(vim.cursorLocation == 0 && host.selection == NSRange(location: 0, length: 3))
        vim.feed("<Esc>")
        #expect(vim.mode == .normal && host.selection == NSRange(location: 0, length: 0))
        vim.feed("gv")
        #expect(vim.mode == .visual && host.selection == NSRange(location: 0, length: 3))
        vim.feed("d")
        #expect(show(host) == "| def" && vim.mode == .normal)

        #expect(run("|ab\ncd\nef", "Vjd") == "|ef")
        #expect(run("a|b\ncd\nef", "vjd") == "|a\nef")
        #expect(run("|ab cd", "vey$p") == "ab cda|b")
        #expect(run("|abc", "vlU") == "|ABc")
        #expect(run("|ABC", "vlu") == "|abC")
        #expect(run("|aBc", "v$~") == "|AbC")
        #expect(run("|abc\nd", "vlrx") == "|xxc\nd")
        #expect(run("|a\nb\nc", "VjJ") == "a| b\nc")
        #expect(run("|a\nb", "Vj>") == "    |a\n    b")
        #expect(run("|a\nb", "Vj2>") == "        |a\n        b")
        #expect(run("|abc def", "viwcx<Esc>") == "|x def")
        #expect(run("|abc\ndef", "vjy") == "|abc\ndef")
        #expect(run("|a\nb", "vD") == "|b")
        #expect(run("x(a|bc)", "vi(d") == "x(|)")
        #expect(run("|a\nb\n\nc", "vipd") == "|\nc")
        // v in Visual line mode makes it charwise; V again leaves.
        let (vim2, host2) = make("a|bc\nd")
        vim2.feed("V")
        #expect(vim2.mode == .visualLine && host2.selection == NSRange(location: 0, length: 4))
        vim2.feed("v")
        #expect(vim2.mode == .visual && host2.selection == NSRange(location: 1, length: 1))
        vim2.feed("v")
        #expect(vim2.mode == .normal)
    }

    @Test func visualPut() {
        let (vim, host) = make("|foo bar")
        vim.feed("yiwwviwp")
        #expect(host.string as String == "foo foo")
        // What was replaced is in the unnamed register now.
        #expect(vim.registerContents(nil)?.text == "bar")
        #expect(run("|a\nb\nc", "yyjVp") == "a\n|a\nc")
        // Lines put over part of a line go on lines of their own.
        #expect(run("|ab\ncd", "yyjvp") == "ab\n\n|ab\nd")
    }

    @Test func selectionFromOutside() {
        let (vim, host) = make("abc def")
        // A drag (or Find) selects in Normal mode: that's Visual mode.
        host.selection = NSRange(location: 4, length: 3)
        vim.selectionDidChange()
        #expect(vim.mode == .visual && vim.cursorLocation == 6)
        vim.feed("d")
        #expect(host.string as String == "abc " && vim.mode == .normal)
        // A click collapses it: Normal again.
        vim.feed("v")
        host.selection = NSRange(location: 1, length: 0)
        vim.selectionDidChange()
        #expect(vim.mode == .normal)
    }

    // MARK: Ex commands

    @Test func substitute() {
        #expect(run("|a a\na a", ":s/a/b/<CR>") == "|b a\na a")
        #expect(run("|a a\na a", ":s/a/b/g<CR>") == "|b b\na a")
        #expect(run("|a a\na a", ":%s/a/b/g<CR>") == "b b\n|b b")
        #expect(run("|x\nx\nx\nx", ":2,3s/x/y/<CR>") == "x\ny\n|y\nx")
        #expect(run("|x\nx\nx", ":.,$s/x/y/<CR>") == "y\ny\n|y")
        #expect(run("|foo bar", ":s/\\(\\w\\+\\) \\(\\w\\+\\)/\\2 \\1/<CR>") == "|bar foo")
        #expect(run("|foo", ":s/o/[&]/g<CR>") == "|f[o][o]")
        #expect(run("|foo bar", ":s/\\<\\w/\\u&/g<CR>") == "|Foo Bar")
        #expect(run("|a,b", ":s/,/\\r/<CR>") == "a\n|b")
        #expect(run("|a/b", ":s#/#-#<CR>") == "|a-b")
        #expect(run("|a/b", ":s/\\//-/<CR>") == "|a-b")
        #expect(run("|Abc", ":s/abc/x/i<CR>") == "|x")
        #expect(run("|foo foo", ":%s/foo//g<CR>") == "| ")
        // An empty pattern is the last search.
        #expect(run("|a b a", "/b<CR>:s//x/<CR>") == "|a x a")
        let (vim, host) = make("|abc")
        vim.feed(":s/z/y/<CR>")
        #expect(host.string as String == "abc" && vim.message == "E486: Pattern not found: z")
        // The Visual range.
        let (vim2, host2) = make("|x\nx\nx\nx")
        vim2.feed("jVj:")
        #expect(vim2.commandLine?.text == "'<,'>" && vim2.statusText == ":'<,'>")
        vim2.feed("s/x/y/<CR>")
        #expect(host2.string as String == "x\ny\ny\nx" && host2.undoStack.count == 1)
        let (vim3, _) = make("|a a a\na")
        vim3.feed(":%s/a/b/g<CR>")
        #expect(vim3.message == "4 substitutions on 2 lines")
    }

    @Test func exCommands() {
        #expect(run("|a\nb\nc\nd", ":3<CR>") == "a\nb\n|c\nd")
        #expect(run("|a\nb\nc\nd", ":$<CR>") == "a\nb\nc\n|d")
        #expect(run("|a\nb\nc\nd", ":2,3d<CR>") == "a\n|d")
        #expect(run("|a\nb\nc", ":d<CR>") == "|b\nc")
        #expect(run("|a\nb\nc", ":2;+1j<CR>") == "a\nb| c")
        #expect(run("|a\nb", ":%><CR>") == "    |a\n    b")
        #expect(run("x|y", ":noh<CR>") == "x|y")
        let (vim, host) = make("|abc")
        for (command, expected) in [(":w", VimHostCommand.write), (":q", .quit(force: false)), (":q!", .quit(force: true)),
                                    (":wq", .writeQuit(onlyIfChanged: false)), (":x", .writeQuit(onlyIfChanged: true)),
                                    (":wa", .writeAll)] {
            vim.feed(command + "<CR>")
            #expect(host.commands.last == expected)
        }
        vim.feed(":frobnicate<CR>")
        #expect(vim.message == "E492: Not an editor command: frobnicate")
        vim.feed(":set nu<CR>")
        #expect(vim.message == "Option not supported: nu")
        vim.feed(":set ic<CR>/ABC<CR>")
        #expect(vim.ignoreCase && vim.message?.contains("E486") != true)
        // Editing the command line.
        vim.feed(":wx<BS><C-u>q")
        #expect(vim.statusText == ":q")
        vim.feed("<Esc>")
        #expect(vim.commandLine == nil && host.commands.count == 6)
        vim.feed(":'x<CR>")
        #expect(vim.message == "E16: Invalid range")
    }

    // MARK: Modes and read-only text

    @Test func statusShowsModeAndPendingKeys() {
        let (vim, _) = make("|abc")
        #expect(vim.statusText == "-- NORMAL --")
        vim.feed("2d")
        #expect(vim.statusText == "-- NORMAL --  2d" && vim.pendingKeys == ["2", "d"])
        vim.feed("<Esc>")
        #expect(vim.statusText == "-- NORMAL --" && vim.isIdle)
        vim.feed("\"a")
        #expect(vim.statusText == "-- NORMAL --  \"a")
        vim.feed("<Esc>V")
        #expect(vim.statusText == "-- VISUAL LINE --")
        vim.feed("<Esc>/ab")
        #expect(vim.statusText == "/ab")
        // An unknown key just goes.
        vim.feed("<Esc>Q")
        #expect(vim.isIdle && vim.mode == .normal)
    }

    @Test func readOnlyTextOnlyMoves() {
        let (vim, host) = make("|one two\nthree")
        host.editable = false
        vim.feed("dd")
        #expect(host.string as String == "one two\nthree" && vim.message != nil)
        vim.feed("wj")
        #expect(show(host) == "one two\nthre|e")
        vim.feed("yy")
        #expect(vim.registerContents(nil)?.text == "three\n")
        vim.feed("i")
        #expect(vim.mode == .normal)
        vim.feed("vk")
        #expect(vim.mode == .visual)
        vim.feed("d")
        #expect(host.string as String == "one two\nthree" && vim.mode == .normal)
        vim.feed(":s/o/x/<CR>")
        #expect(host.string as String == "one two\nthree")
    }

    @Test func crlfText() {
        let (vim, host) = make("|ab\r\ncd\r\nef")
        host.lineBreak = "\r\n"
        vim.feed("$")
        #expect(host.selection.location == 1)
        vim.feed("j")
        #expect(host.selection.location == 5)
        vim.feed("w")
        #expect(host.selection.location == 8)
        vim.feed("ggdd")
        #expect(host.string as String == "cd\r\nef" && vim.registerContents(nil)?.text == "ab\n")
        vim.feed("Gdd")
        #expect(host.string as String == "cd")
        vim.feed("A!<Esc>J")
        #expect(host.string as String == "cd!")
        #expect(run("|a\r\nb", "J") == "a| b")
    }

    @Test func keyNames() {
        #expect(VimEngine.keys("d2w<Esc>") == ["d", "2", "w", "<Esc>"])
        #expect(VimEngine.keys("<<>>") == ["<", "<", ">", ">"])
        #expect(VimEngine.keys("i<C-r>a") == ["i", "<C-r>", "a"])
        #expect(VimEngine.keys("<a>") == ["<", "a", ">"] || VimEngine.keys("<a>") == ["<a>"])
        #expect(VimParser.parse(["d", "i"], visual: false) == .incomplete)
        #expect(VimParser.parse(["d", "q"], visual: false) == .invalid)
        guard case .command(let command) = VimParser.parse(["\"", "a", "3", "d", "2", "w"], visual: false) else {
            Issue.record("not parsed")
            return
        }
        #expect(command.register == "a" && command.count == 6 && command.op == .delete && command.body == ["d", "w"])
    }
}

/// Vim mode in a real editor (an offscreen window): keys through the text view's keyDown.
@MainActor
@Suite(.serialized)
struct VimEditorTests {
    private func makeEditor(_ text: String, vim: Bool = true) throws -> (EditorDocument, EditorController, NSWindow) {
        let url = FileManager.default.temporaryDirectory.appending(path: "omc-vim-\(UUID().uuidString).swift")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)
        let controller = EditorController(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.makeView()
        window.layoutIfNeeded()
        window.makeFirstResponder(controller.textView)
        document.editor = controller
        controller.setVimMode(vim)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        return (document, controller, window)
    }

    private func event(_ key: String, in window: NSWindow) -> NSEvent {
        var characters = key, ignoring = key
        var flags: NSEvent.ModifierFlags = []
        var keyCode: UInt16 = 0
        switch key {
        case "<Esc>": (characters, ignoring, keyCode) = ("\u{1b}", "\u{1b}", 53)
        case "<CR>": (characters, ignoring, keyCode) = ("\r", "\r", 36)
        case "<BS>": (characters, ignoring, keyCode) = ("\u{7f}", "\u{7f}", 51)
        case "<C-[>": (characters, ignoring, flags, keyCode) = ("\u{1b}", "[", .control, 33)
        case "<C-r>": (characters, ignoring, flags, keyCode) = ("\u{12}", "r", .control, 15)
        case "<C-g>": (characters, ignoring, flags, keyCode) = ("\u{07}", "g", .control, 5)
        default: break
        }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode)!
    }

    /// Presses the keys one by one, each its own event (the run loop turns between them).
    private func press(_ keys: String, _ controller: EditorController, _ window: NSWindow) {
        for key in VimEngine.keys(keys) {
            controller.textView.keyDown(with: event(key, in: window))
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }

    @Test func keysEditAndEachChangeIsOneUndoStep() throws {
        let (document, controller, window) = try makeEditor("foo bar\nbaz\n")
        let vim = try #require(controller.vim)
        #expect(vim.engine.mode == .normal && document.vimStatus == "-- NORMAL --")
        press("cw", controller, window)
        #expect(vim.engine.mode == .insert && document.vimStatus == "-- INSERT --")
        press("hello<BS>p", controller, window)
        press("<Esc>", controller, window)
        #expect(document.textStorage.string == "hellp bar\nbaz\n" && vim.engine.mode == .normal)
        #expect(controller.textView.selectedRange() == NSRange(location: 4, length: 0))
        // The whole change, typing included, is one undo step; nothing is left open.
        let undoManager = document.undoManager
        #expect(undoManager.groupingLevel == 0 && undoManager.groupsByEvent)
        press("u", controller, window)
        #expect(document.textStorage.string == "foo bar\nbaz\n")
        #expect(controller.textView.selectedRange().length == 0)
        press("<C-r>", controller, window)
        #expect(document.textStorage.string == "hellp bar\nbaz\n")
        press("jdd", controller, window)
        #expect(document.textStorage.string == "hellp bar\n")
        undoManager.undo()
        #expect(document.textStorage.string == "hellp bar\nbaz\n")
        // ^R and ^[ are Vim's before the app's shortcuts (^R would be Open Recent); ^G isn't.
        #expect(controller.textView.performKeyEquivalent(with: event("<C-r>", in: window)))
        #expect(document.textStorage.string == "hellp bar\n")
        #expect(!vim.handle(event("<C-g>", in: window), isKeyEquivalent: true))
        press("i", controller, window)
        #expect(controller.textView.performKeyEquivalent(with: event("<C-[>", in: window)))
        #expect(vim.engine.mode == .normal)
        // The command line shows in the status bar.
        press(":%s/hellp/x/", controller, window)
        #expect(document.vimStatus == ":%s/hellp/x/▏")
        press("<CR>", controller, window)
        #expect(document.textStorage.string == "x bar\n" && document.vimStatus == "-- NORMAL --")
        withExtendedLifetime(window) {}
    }

    @Test func escapeClosesWhatsOpenFirst() throws {
        let (document, controller, window) = try makeEditor("let a = 1\n")
        let vim = try #require(controller.vim)
        press("A", controller, window)
        controller.inlineSuggestions.show(GhostText(anchor: 9, text: " + 2", editVersion: document.editVersion))
        #expect(controller.inlineSuggestions.ghost != nil)
        press("<Esc>", controller, window)
        #expect(controller.inlineSuggestions.ghost == nil && vim.engine.mode == .insert)
        // The find bar (shown while typing): Esc hides it, then leaves Insert mode.
        controller.showFindInterface()
        window.makeFirstResponder(controller.textView)
        let scrollView = try #require(controller.textView.enclosingScrollView)
        #expect(scrollView.isFindBarVisible)
        press("<Esc>", controller, window)
        #expect(!scrollView.isFindBarVisible && vim.engine.mode == .insert)
        press("<Esc>", controller, window)
        #expect(vim.engine.mode == .normal)
        // Extra cursors: typing goes to all of them (Insert mode); Esc removes them, then
        // a second Esc is Normal mode.
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.toggleCursor(at: 4)
        #expect(controller.hasExtraCursors)
        press("x", controller, window)
        #expect(vim.engine.mode == .insert && document.textStorage.string.filter { $0 == "x" }.count == 2)
        press("<Esc>", controller, window)
        #expect(!controller.hasExtraCursors && vim.engine.mode == .insert)
        press("<Esc>", controller, window)
        #expect(vim.engine.mode == .normal)
        // An input method composing: its keys are its own.
        press("i", controller, window)
        controller.textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                                          replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!vim.handle(event("<Esc>", in: window), isKeyEquivalent: false))
        controller.textView.unmarkText()
        withExtendedLifetime(window) {}
    }

    @Test func aChangeThatChangesNothingIsNoUndoStep() throws {
        let (document, controller, window) = try makeEditor("ABC x\n")
        press("$x", controller, window)
        #expect(document.textStorage.string == "ABC \n")
        press("0gUiw", controller, window) // already upper case
        press("i<Esc>", controller, window)
        press("u", controller, window)
        #expect(document.textStorage.string == "ABC x\n")
        // Insert mode typing (the text view's) from its first key is one step.
        press("ihey<Esc>", controller, window)
        press("ayou<Esc>", controller, window)
        #expect(document.textStorage.string == "heyyouABC x\n")
        press("u", controller, window)
        #expect(document.textStorage.string == "heyABC x\n")
        press("u", controller, window)
        #expect(document.textStorage.string == "ABC x\n")
        withExtendedLifetime(window) {}
    }

    @Test func commandShortcutsAndReadOnlyText() throws {
        let (document, controller, window) = try makeEditor("b\na\n")
        let vim = try #require(controller.vim)
        // ⌘ keys aren't Vim's: ⌘/ comments the line in Normal mode.
        let slash = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "/",
                                                  charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
        #expect(!vim.handle(slash, isKeyEquivalent: false) && !vim.handle(slash, isKeyEquivalent: true))
        #expect(controller.textView.performKeyEquivalent(with: slash))
        #expect(document.textStorage.string == "// b\na\n")
        // Unknown keys in Normal mode don't type.
        press("Q", controller, window)
        #expect(document.textStorage.string == "// b\na\n")
        // A read-only view: moving and yanking only.
        controller.textView.isEditable = false
        press("ddx", controller, window)
        #expect(document.textStorage.string == "// b\na\n")
        press("j", controller, window)
        #expect(controller.textView.selectedRange().location == 5)
        press("yy", controller, window)
        #expect(vim.engine.registerContents(nil)?.text == "a\n")
        press("i", controller, window)
        #expect(vim.engine.mode == .normal)
        withExtendedLifetime(window) {}
    }

    @Test func blockCaretAndTurningVimOff() throws {
        let (document, controller, window) = try makeEditor("abc\n")
        let vim = try #require(controller.vim)
        controller.textView.layoutSubtreeIfNeeded()
        let block = try #require(vim.blockCaretRect())
        let character = try #require(controller.rect(for: NSRange(location: 0, length: 1)))
        #expect(abs(block.minX - character.minX) < 0.5 && abs(block.width - character.width) < 0.5)
        #expect(controller.textView.insertionPointColor == .clear)
        press("i", controller, window)
        #expect(vim.blockCaretRect() == nil && controller.textView.insertionPointColor != .clear)
        press("<Esc>", controller, window)
        // On an empty line (and after the text) there's still a block, a space wide.
        press("j", controller, window)
        #expect(vim.blockCaretRect() != nil)
        // Off: the text view's own caret and keys again.
        controller.setVimMode(false)
        #expect(controller.vim == nil && document.vimStatus == nil && controller.textView.insertionPointColor != .clear)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        press("x", controller, window)
        #expect(document.textStorage.string == "xabc\n")
        withExtendedLifetime(window) {}
    }

    @Test func settingAndPaletteCommand() throws {
        let (_, controller, window) = try makeEditor("abc\n", vim: false)
        let settings = AppSettings.shared
        #expect(!settings.vimMode) // off by default
        defer { settings.vimMode = false }
        settings.vimMode = true
        #expect(controller.vim != nil)
        let command = try #require(PaletteCommand.all.first { $0.id == "edit.toggleVimMode" })
        #expect(command.title == "Toggle Vim Mode")
        settings.vimMode = false
        #expect(controller.vim == nil)
        withExtendedLifetime(window) {}
    }
}
