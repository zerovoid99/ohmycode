import Foundation

/// What the Vim engine works on: the editor's text, its selection and its commands. The
/// engine itself knows nothing of windows or views, so it can be tested with a plain string.
@MainActor
protocol VimHost: AnyObject {
    var vimText: NSString { get }
    var vimLines: LineIndex { get }
    var vimSelection: NSRange { get }
    /// Selects `range` and scrolls `reveal` into view.
    func vimSetSelection(_ range: NSRange, reveal: Int)
    /// Makes the edits (in the current text's offsets); false when nothing changed.
    @discardableResult func vimApply(_ edits: [TextReplacement]) -> Bool
    /// A change starts: everything until `vimEndChange` is one undo step.
    func vimBeginChange()
    func vimEndChange()
    func vimUndo() -> Bool
    func vimRedo() -> Bool
    var vimIsEditable: Bool { get }
    /// The lines in view (zero-based).
    var vimVisibleLines: ClosedRange<Int> { get }
    func vimScroll(lines: Int)
    func vimScrollCursor(to position: VimScrollPosition)
    var vimLineBreak: String { get }
    var vimIndentUnit: String { get }
    /// The system pasteboard (registers + and *).
    var vimClipboard: String? { get set }
    /// Runs a command of the app's (`:w`, `:q`); returns a message to show, if any.
    func vimRun(_ command: VimHostCommand) -> String?
    /// The mode, the pending keys or the message changed.
    func vimStateDidChange()
}

enum VimHostCommand: Equatable {
    case write, writeAll
    case quit(force: Bool)
    case writeQuit(onlyIfChanged: Bool)
}

/// Vim's Normal, Visual, Insert and Replace modes over a `VimHost`: keys in, edits and cursor
/// moves out. In Insert mode the host types as usual and only Esc comes here.
@MainActor
final class VimEngine {
    private(set) var mode: VimMode = .normal
    private(set) var pendingKeys: [String] = []
    /// Shown in the status bar until the next key (an error, "3 substitutions").
    private(set) var message: String?
    private(set) var commandLine: CommandLine?
    var registers: [String: VimRegister] = [:]
    var ignoreCase = false
    var smartCase = false
    private(set) var lastSearch: (pattern: String, forward: Bool)?
    private var lastFind: (target: String, forward: Bool, till: Bool)?
    /// The column `j` and `k` keep to (`Int.max` after `$`).
    private var desiredColumn: Int?
    private var anchor = 0
    private var head = 0
    private(set) var lastVisual: (anchor: Int, head: Int, linewise: Bool)?
    private(set) var lastChange: RecordedChange?
    private var insertSession: InsertSession?
    private var replaceSession: ReplaceSession?
    private var changeOpen = false
    private var isReplaying = false
    /// Set while the engine moves the selection (the host reports it back).
    private(set) var isSettingSelection = false
    private weak var host: VimHost?

    struct CommandLine: Equatable {
        var kind: Character
        var text: String
        /// An operator waiting for the search (`d/foo`).
        var pending: VimCommand?
        var count: Int?
    }

    /// The last change, for `.`.
    struct RecordedChange: Equatable {
        var register: String?
        var count: Int?
        var body: [String]
        /// Typed in the Insert mode the command started (and how much was deleted before it).
        var inserted: String?
        var deletedBefore = 0
        /// Typed in Replace mode.
        var replaced: [String] = []
        /// A Visual mode change: how much it covered, from the cursor.
        var visual: VisualExtent?
    }

    struct VisualExtent: Equatable {
        var linewise: Bool
        var lines: Int
        var characters: Int
        var lastColumn: Int
    }

    private struct InsertSession {
        var start: Int
        var snapshot: NSString
        var count: Int
        /// Typed before each repetition of the text (`3o`: a line break and the indent).
        var repeatPrefix: String
        var record: RecordedChange?
    }

    private struct ReplaceSession {
        var stack: [(location: Int, original: String, length: Int)] = []
        var typed: [String] = []
        var record: RecordedChange
    }

    init(host: VimHost) {
        self.host = host
    }

    var isVisual: Bool { mode == .visual || mode == .visualLine }
    /// Nothing typed but not yet done.
    var isIdle: Bool { pendingKeys.isEmpty && commandLine == nil }

    /// The status bar's text: the mode and pending keys, the command line, or a message.
    var statusText: String {
        if let commandLine { return String(commandLine.kind) + commandLine.text }
        if let message { return message }
        let label = switch mode {
        case .normal: "-- NORMAL --"
        case .insert: "-- INSERT --"
        case .visual: "-- VISUAL --"
        case .visualLine: "-- VISUAL LINE --"
        case .replace: "-- REPLACE --"
        }
        return pendingKeys.isEmpty ? label : label + "  " + pendingKeys.joined()
    }

    /// Where the block cursor is (Visual mode: the moving end).
    var cursorLocation: Int { isVisual ? head : (host?.vimSelection.location ?? 0) }

    private var text: VimText {
        guard let host else { return VimText("") }
        return VimText(host.vimText, lines: host.vimLines)
    }

    private var cursor: Int { host?.vimSelection.location ?? 0 }

    private var lineBreak: String { host?.vimLineBreak ?? "\n" }

    // MARK: Keys

    /// Handles a key; false when it isn't Vim's (Insert mode typing): the host handles it.
    @discardableResult
    func handle(_ key: String) -> Bool {
        defer { host?.vimStateDidChange() }
        switch mode {
        case .insert:
            guard VimParser.isEscape(key) else { return false }
            finishInsert()
            return true
        case .replace:
            handleReplace(key)
            return true
        default:
            break
        }
        message = nil
        if commandLine != nil {
            handleCommandLine(key)
            return true
        }
        syncSelection()
        // A click can leave the cursor after a line's last character; Normal mode's is on it.
        if mode == .normal, pendingKeys.isEmpty, let host, host.vimSelection.length == 0 {
            let location = host.vimSelection.location
            if clampNormal(location) != location { setCursor(clampNormal(location)) }
        }
        pendingKeys.append(key)
        switch VimParser.parse(pendingKeys, visual: isVisual) {
        case .incomplete:
            break
        case .invalid:
            pendingKeys = []
        case .command(let command):
            pendingKeys = []
            execute(command)
        }
        return true
    }

    /// Types several keys ("2dw", "ci(<Esc>"); tests and `.` use it.
    func feed(_ keys: String) {
        for key in Self.keys(keys) where !handle(key) {
            // Insert mode: typed into the text.
            insertTyped(key)
        }
    }

    /// Splits "d2w<Esc>" into keys: names in angle brackets are one.
    static func keys(_ string: String) -> [String] {
        var keys: [String] = []
        var index = string.startIndex
        while index < string.endIndex {
            if string[index] == "<", let close = string[index...].firstIndex(of: ">") {
                let name = String(string[index...close])
                if name.count > 2, !name.dropFirst().dropLast().contains("<"), name.dropFirst().first?.isLetter == true {
                    keys.append(name)
                    index = string.index(after: close)
                    continue
                }
            }
            keys.append(String(string[index]))
            index = string.index(after: index)
        }
        return keys
    }

    /// Text typed in Insert mode by `feed` (the host's typing does this in the editor).
    private func insertTyped(_ key: String) {
        guard let host else { return }
        let location = host.vimSelection.location
        if key == "<BS>" {
            guard location > 0 else { return }
            let start = text.previous(location)
            host.vimApply([TextReplacement(range: NSRange(location: start, length: location - start), text: "")])
            setCursor(start)
            return
        }
        let typed = key == "<CR>" ? lineBreak : key == "<Tab>" ? "\t" : key
        guard VimParser.isCharacter(key) || typed != key else { return }
        host.vimApply([TextReplacement(range: host.vimSelection, text: typed)])
        setCursor(location + (typed as NSString).length)
    }

    /// The selection changed from outside (a click, a drag, Find): a selection in Normal mode
    /// is taken as Visual mode's.
    func selectionDidChange() {
        guard !isSettingSelection, mode != .insert, mode != .replace else { return }
        syncSelection()
        host?.vimStateDidChange()
    }

    private func syncSelection() {
        guard let host else { return }
        let selection = host.vimSelection
        let text = text
        switch mode {
        case .normal where selection.length > 0:
            anchor = selection.location
            head = text.previous(NSMaxRange(selection))
            mode = .visual
        case .visual, .visualLine:
            guard selection != visualRange() else { return }
            if selection.length == 0 {
                mode = .normal
                return
            }
            let last = text.previous(NSMaxRange(selection))
            if head >= anchor { (anchor, head) = (selection.location, last) } else { (anchor, head) = (last, selection.location) }
            mode = .visual
        default:
            break
        }
    }

    /// Leaves whatever mode for Normal (Vim mode turned off, the editor closed).
    func reset() {
        if mode == .insert { finishInsert() }
        if mode == .replace { finishReplace() }
        endChange()
        mode = .normal
        pendingKeys = []
        commandLine = nil
        message = nil
    }

    /// Insert mode for typing at several cursors (the extra cursors stay).
    func enterInsertKeepingSelection() {
        guard mode != .insert else { return }
        if mode == .replace { finishReplace() }
        mode = .normal
        pendingKeys = []
        commandLine = nil
        beginInsert(at: cursor, count: 1, record: nil, moveCursor: false)
        host?.vimStateDidChange()
    }

    // MARK: Selection

    private func setCursor(_ location: Int) {
        guard let host else { return }
        isSettingSelection = true
        host.vimSetSelection(NSRange(location: min(max(0, location), host.vimText.length), length: 0), reveal: location)
        isSettingSelection = false
    }

    private func clampNormal(_ location: Int) -> Int {
        let text = text
        let location = min(max(0, location), text.length)
        return min(location, text.lastChar(ofLine: text.line(of: location)))
    }

    private func visualRange() -> NSRange {
        let text = text
        let anchor = min(anchor, text.length), head = min(head, text.length)
        if mode == .visualLine {
            let first = text.start(ofLine: text.line(of: min(anchor, head)))
            let end = text.end(ofLine: text.line(of: max(anchor, head)))
            return NSRange(location: first, length: end - first)
        }
        let start = min(anchor, head)
        let end = min(text.next(max(anchor, head)), text.length)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func updateVisualSelection() {
        guard let host else { return }
        isSettingSelection = true
        host.vimSetSelection(visualRange(), reveal: head)
        isSettingSelection = false
    }

    // MARK: Changes

    private func beginChange() {
        guard !changeOpen else { return }
        changeOpen = true
        host?.vimBeginChange()
    }

    private func endChange() {
        guard changeOpen else { return }
        changeOpen = false
        host?.vimEndChange()
    }

    @discardableResult
    private func apply(_ edits: [TextReplacement]) -> Bool {
        guard let host, !edits.isEmpty else { return false }
        beginChange()
        return host.vimApply(edits)
    }

    private var isEditable: Bool { host?.vimIsEditable ?? false }

    private func refuse(_ text: String = "The text can't be changed here") {
        message = text
    }

    private func record(_ command: VimCommand) {
        lastChange = RecordedChange(register: command.register, count: command.count, body: command.body)
    }

    // MARK: Commands

    private func execute(_ command: VimCommand) {
        switch command.target {
        case .motion(let motion):
            if let op = command.op {
                operate(op, motion: motion, command: command)
            } else if isVisual {
                moveVisual(motion, count: command.count)
            } else {
                moveCursor(motion, count: command.count)
            }
        case .object(let inner, let kind):
            if isVisual {
                selectObject(kind, inner: inner, count: command.total)
            } else if let op = command.op {
                guard let span = object(kind, inner: inner, at: cursor, count: command.total) else { return }
                let text = text
                let region: Region = span.linewise
                    ? .lines(text.line(of: span.start), text.line(of: max(span.start, span.end - 1)))
                    : .chars(span.start, span.end)
                applyOperator(op, region, command: command)
            }
        case .lines:
            guard let op = command.op else { return }
            let text = text
            let first = text.line(of: cursor)
            let last = text.clampLine(first + command.total - 1)
            applyOperator(op, .lines(first, last), command: command)
        case .selection:
            guard let op = command.op else { return }
            operateOnSelection(op, command: command)
        case .action(let action):
            perform(action, command: command)
        }
    }

    // MARK: Motions

    private struct Movement {
        var target: Int
        var linewise = false
        var inclusive = false
        var keepsColumn = false
    }

    private func evaluate(_ motion: VimMotion, from location: Int, count: Int?, forOperator: Bool) -> Movement? {
        let text = text
        let n = max(1, count ?? 1)
        let line = text.line(of: location)
        func lineStart(_ target: Int) -> Movement {
            Movement(target: text.firstNonBlank(ofLine: text.clampLine(target)), linewise: true)
        }
        switch motion {
        case .left:
            let start = text.start(ofLine: line)
            guard location > start else { return nil }
            var target = location
            for _ in 0..<n where target > start { target = text.previous(target) }
            return Movement(target: target)
        case .right:
            let end = text.contentEnd(ofLine: line)
            var target = location
            for _ in 0..<n where target < end { target = text.next(target) }
            if !forOperator { target = min(target, text.lastChar(ofLine: line)) }
            guard target != location else { return nil }
            return Movement(target: target)
        case .up, .down:
            let targetLine = motion == .down ? min(line + n, text.lastLine) : max(line - n, 0)
            guard targetLine != line else { return nil }
            let column = desiredColumn ?? text.column(of: location)
            return Movement(target: text.offset(line: targetLine, column: column), linewise: true, keepsColumn: true)
        case .word(let big):
            var target = location
            for step in 0..<n {
                let from = target
                target = text.wordForward(from: target, big: big)
                // The last word on a line: the operator stops at the line's end.
                if forOperator, step == n - 1, text.line(of: target) > text.line(of: from) {
                    let end = text.contentEnd(ofLine: text.line(of: from))
                    if from < end { target = end }
                }
            }
            guard target != location else { return nil }
            return Movement(target: target)
        case .back(let big):
            var target = location
            for _ in 0..<n { target = text.wordBackward(from: target, big: big) }
            guard target != location else { return nil }
            return Movement(target: target)
        case .end(let big):
            var target = location
            for _ in 0..<n {
                guard let end = text.wordEnd(from: target, big: big) else { break }
                target = end
            }
            guard target != location else { return nil }
            return Movement(target: target, inclusive: true)
        case .backEnd(let big):
            var target = location
            for _ in 0..<n { target = text.wordEndBackward(from: target, big: big) }
            guard target != location else { return nil }
            return Movement(target: target, inclusive: true)
        case .lineStart:
            return Movement(target: text.start(ofLine: line))
        case .firstNonBlank:
            return Movement(target: text.firstNonBlank(ofLine: line))
        case .lineEnd:
            let last = text.clampLine(line + n - 1)
            if forOperator { return Movement(target: text.contentEnd(ofLine: last)) }
            return Movement(target: text.lastChar(ofLine: last))
        case .lastNonBlank:
            let last = text.clampLine(line + n - 1)
            let start = text.start(ofLine: last)
            var end = text.contentEnd(ofLine: last)
            while end > start, text.isSpace(text.char(end - 1)) { end -= 1 }
            return Movement(target: end > start ? text.previous(end) : start, inclusive: end > start)
        case .lineDown:
            guard line + n <= text.lastLine else { return nil }
            return lineStart(line + n)
        case .lineUp:
            guard line - n >= 0 else { return nil }
            return lineStart(line - n)
        case .currentLine:
            return lineStart(line + n - 1)
        case .gotoLine:
            return lineStart(count.map { $0 - 1 } ?? text.lastLine)
        case .firstLine:
            return lineStart((count ?? 1) - 1)
        case .find(let target, let forward, let till):
            lastFind = (target, forward, till)
            guard let found = text.find(target, from: location, forward: forward, till: till, count: n) else { return nil }
            return Movement(target: found, inclusive: forward)
        case .repeatFind(let reverse):
            guard let last = lastFind else { return nil }
            let forward = reverse ? !last.forward : last.forward
            guard let found = text.find(last.target, from: location, forward: forward, till: last.till, count: n,
                                        skipAdjacent: true) else { return nil }
            return Movement(target: found, inclusive: forward)
        case .bracket:
            if let count {
                return lineStart((count * text.lineCount + 99) / 100 - 1)
            }
            guard let found = text.matchingBracket(from: location) else { return nil }
            return Movement(target: found, inclusive: true)
        case .paragraphForward:
            var target = location
            for _ in 0..<n { target = text.paragraphForward(from: target) }
            guard target != location else { return nil }
            return Movement(target: target)
        case .paragraphBackward:
            var target = location
            for _ in 0..<n { target = text.paragraphBackward(from: target) }
            guard target != location else { return nil }
            return Movement(target: target)
        case .screenTop, .screenMiddle, .screenBottom:
            guard let visible = host?.vimVisibleLines else { return nil }
            let first = text.clampLine(visible.lowerBound), last = text.clampLine(visible.upperBound)
            let target = switch motion {
            case .screenTop: min(first + n - 1, last)
            case .screenBottom: max(last - n + 1, first)
            default: (first + last) / 2
            }
            return lineStart(target)
        case .searchNext(let reverse):
            guard let last = lastSearch else {
                message = "E35: No previous regular expression"
                return nil
            }
            guard let found = search(last.pattern, forward: reverse ? !last.forward : last.forward, from: location, count: n) else {
                return nil
            }
            return Movement(target: found)
        case .searchWord(let forward):
            guard let (word, start) = word(at: location) else {
                message = "E348: No string under cursor"
                return nil
            }
            let isKeyword = text.charClass(at: start) == .word
            let escaped = Self.escape(word)
            let pattern = isKeyword ? "\\<" + escaped + "\\>" : escaped
            lastSearch = (pattern, forward)
            guard let found = search(pattern, forward: forward, from: start, count: n) else { return nil }
            message = (forward ? "/" : "?") + pattern
            return Movement(target: found)
        case .search:
            return nil
        }
    }

    /// The word under or after the cursor on its line, for `*` and `#`.
    private func word(at location: Int) -> (String, Int)? {
        let text = text
        let line = text.line(of: location)
        let end = text.contentEnd(ofLine: line)
        var start = location
        while start < end, text.charClass(at: start) != .word { start = text.next(start) }
        if start >= end {
            start = location
            while start < end, text.charClass(at: start) == .blank { start = text.next(start) }
            guard start < end else { return nil }
        }
        let cls = text.charClass(at: start)
        while start > text.start(ofLine: line), text.charClass(at: text.previous(start)) == cls { start = text.previous(start) }
        var stop = start
        while stop < end, text.charClass(at: stop) == cls { stop = text.next(stop) }
        return (text.substring(start, stop), start)
    }

    /// A string as a Vim pattern that matches it literally.
    static func escape(_ string: String) -> String {
        var output = ""
        for character in string {
            if "\\^$.*[]~/".contains(character) { output += "\\" }
            output.append(character)
        }
        return output
    }

    /// The start of the `count`th match of `pattern` after (or before) `location`, wrapping.
    private func search(_ pattern: String, forward: Bool, from location: Int, count: Int) -> Int? {
        guard let regex = VimRegex.make(pattern, ignoreCase: ignoreCase, smartCase: smartCase) else {
            message = "E486: Pattern not found: \(pattern)"
            return nil
        }
        let string = text.string as String
        let length = (string as NSString).length
        let options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        var position = location
        for _ in 0..<count {
            if forward {
                let from = min(position + 1, length)
                if let match = regex.firstMatch(in: string, options: options, range: NSRange(location: from, length: length - from)) {
                    position = match.range.location
                } else if let match = regex.firstMatch(in: string, options: options, range: NSRange(location: 0, length: length)) {
                    position = match.range.location
                    message = "search hit BOTTOM, continuing at TOP"
                } else {
                    message = "E486: Pattern not found: \(pattern)"
                    return nil
                }
            } else {
                var before: Int?, last: Int?
                regex.enumerateMatches(in: string, options: options, range: NSRange(location: 0, length: length)) { match, _, _ in
                    guard let match else { return }
                    if match.range.location < position { before = match.range.location }
                    last = match.range.location
                }
                if let before {
                    position = before
                } else if let last {
                    position = last
                    message = "search hit TOP, continuing at BOTTOM"
                } else {
                    message = "E486: Pattern not found: \(pattern)"
                    return nil
                }
            }
        }
        return position
    }

    private func moveCursor(_ motion: VimMotion, count: Int?) {
        if case .search(let forward) = motion {
            commandLine = CommandLine(kind: forward ? "/" : "?", text: "", count: count)
            return
        }
        let start = cursor
        guard let movement = evaluate(motion, from: start, count: count, forOperator: false) else { return }
        updateDesiredColumn(motion, movement, from: start)
        setCursor(clampNormal(movement.target))
    }

    private func updateDesiredColumn(_ motion: VimMotion, _ movement: Movement, from start: Int) {
        if movement.keepsColumn {
            if desiredColumn == nil { desiredColumn = text.column(of: start) }
        } else {
            desiredColumn = motion == .lineEnd ? Int.max : nil
        }
    }

    // MARK: Operators

    private enum Region: Equatable {
        case chars(Int, Int)
        case lines(Int, Int)
    }

    private func operate(_ op: VimOperator, motion: VimMotion, command: VimCommand) {
        if case .search(let forward) = motion {
            commandLine = CommandLine(kind: forward ? "/" : "?", text: "", pending: command, count: command.count)
            return
        }
        let text = text
        let location = cursor
        var movement: Movement
        if op == .change, case .word(let big) = motion, text.charClass(at: location, big: big) == .word
            || text.charClass(at: location, big: big) == .punctuation {
            // `cw` on a word changes to its end (like `ce`, but not past a one-letter word).
            var target = text.endOfCurrentWord(from: location, big: big)
            for _ in 1..<command.total {
                guard let end = text.wordEnd(from: target, big: big) else { break }
                target = end
            }
            movement = Movement(target: target, inclusive: true)
        } else {
            guard let found = evaluate(motion, from: location, count: command.count, forOperator: true) else {
                // `cl`/`s` on an empty line still changes (nothing).
                if op == .change, motion == .right || motion == .lineEnd { applyOperator(op, .chars(location, location), command: command) }
                return
            }
            movement = found
        }
        var start = min(location, movement.target), end = max(location, movement.target)
        if movement.linewise {
            applyOperator(op, .lines(text.line(of: start), text.line(of: end)), command: command)
            return
        }
        if movement.inclusive {
            end = min(text.next(end), text.length)
        } else if end > start, text.line(of: end) > text.line(of: start), end == text.start(ofLine: text.line(of: end)) {
            // An exclusive motion to the start of a line ends at the line before; from the
            // start of a line's text, it's the whole lines.
            let startLine = text.line(of: start)
            let indentEnd = (text.start(ofLine: startLine)..<text.contentEnd(ofLine: startLine))
                .first { !text.isSpace(text.char($0)) } ?? text.contentEnd(ofLine: startLine)
            if start <= indentEnd {
                applyOperator(op, .lines(startLine, text.line(of: end) - 1), command: command)
                return
            }
            end = text.contentEnd(ofLine: text.line(of: end) - 1)
        }
        if end < start { swap(&start, &end) }
        applyOperator(op, .chars(start, end), command: command)
    }

    /// The region's offsets: whole lines with their line breaks (and the one before, for the
    /// text's last lines), and its text for a register.
    private func span(of region: Region, forDelete: Bool = false) -> (range: NSRange, register: VimRegister) {
        let text = text
        switch region {
        case .chars(let start, let end):
            let range = NSRange(location: start, length: max(0, end - start))
            return (range, VimRegister(text: Self.normalize(text.substring(start, end)), linewise: false))
        case .lines(let first, let last):
            var start = text.start(ofLine: first)
            let end = text.end(ofLine: last)
            var content = Self.normalize(text.substring(start, end))
            if !content.hasSuffix("\n") { content += "\n" }
            if forDelete, last == text.lastLine, first > 0 { start = text.contentEnd(ofLine: first - 1) }
            return (NSRange(location: start, length: end - start), VimRegister(text: content, linewise: true))
        }
    }

    static func normalize(_ string: String) -> String {
        string.contains("\r\n") ? string.replacingOccurrences(of: "\r\n", with: "\n") : string
    }

    private func applyOperator(_ op: VimOperator, _ region: Region, command: VimCommand, visual: Bool = false) {
        guard op == .yank || isEditable else { return refuse() }
        let text = text
        if op != .yank, !visual { record(command) }
        switch op {
        case .yank:
            let (_, register) = span(of: region)
            store(register, name: command.register, isYank: true)
            switch region {
            case .chars(let start, _):
                setCursor(clampNormal(visual ? start : min(start, cursor)))
            case .lines(let first, _):
                if visual || text.line(of: cursor) != first {
                    setCursor(text.offset(line: first, column: visual ? 0 : text.column(of: cursor)))
                }
            }
        case .delete:
            let (range, register) = span(of: region, forDelete: true)
            guard range.length > 0 else { return }
            store(register, name: command.register, isYank: false)
            apply([TextReplacement(range: range, text: "")])
            endChange()
            let after = self.text
            switch region {
            case .chars(let start, _): setCursor(clampNormal(start))
            case .lines(let first, _): setCursor(after.firstNonBlank(ofLine: after.clampLine(first)))
            }
        case .change:
            switch region {
            case .chars(let start, let end):
                let (range, register) = span(of: region)
                if range.length > 0 { store(register, name: command.register, isYank: false) }
                beginChange()
                apply([TextReplacement(range: range, text: "")])
                beginInsert(at: start, count: 1, record: lastChange)
                _ = end
            case .lines(let first, let last):
                let (_, register) = span(of: region)
                store(register, name: command.register, isYank: false)
                let start = text.start(ofLine: first)
                let indent = text.substring(start, text.firstNonBlankRaw(ofLine: first))
                beginChange()
                apply([TextReplacement(range: NSRange(location: start, length: text.contentEnd(ofLine: last) - start), text: indent)])
                beginInsert(at: start + (indent as NSString).length, count: 1, record: lastChange)
            }
        case .indent, .outdent:
            let lines: (Int, Int) = switch region {
            case .chars(let start, let end): (text.line(of: start), text.line(of: max(start, end - 1)))
            case .lines(let first, let last): (first, last)
            }
            shift(lines: lines.0...lines.1, outdent: op == .outdent, times: visual ? command.total : 1)
        case .lower, .upper, .toggleCase:
            let (range, _) = span(of: region)
            let original = (text.string.substring(with: range))
            let changed = switch op {
            case .lower: original.lowercased()
            case .upper: original.uppercased()
            default: Self.toggleCase(original)
            }
            apply([TextReplacement(range: range, text: changed)])
            endChange()
            switch region {
            case .chars(let start, _): setCursor(clampNormal(start))
            case .lines(let first, _): setCursor(visual ? self.text.start(ofLine: first) : clampNormal(cursor))
            }
        }
    }

    static func toggleCase(_ string: String) -> String {
        String(string.map { character -> String in
            let upper = character.uppercased()
            return upper == String(character) ? character.lowercased() : upper
        }.joined())
    }

    private func shift(lines: ClosedRange<Int>, outdent: Bool, times: Int) {
        let text = text
        let unit = host?.vimIndentUnit ?? "    "
        let width = unit == "\t" ? 4 : max(1, (unit as NSString).length)
        var edits: [TextReplacement] = []
        for line in lines {
            let start = text.start(ofLine: line)
            if outdent {
                var index = start
                let end = text.contentEnd(ofLine: line)
                for _ in 0..<times {
                    if index < end, text.char(index) == 0x09 { index += 1; continue }
                    var spaces = 0
                    while spaces < width, index < end, text.char(index) == 0x20 { index += 1; spaces += 1 }
                }
                if index > start { edits.append(TextReplacement(range: NSRange(location: start, length: index - start), text: "")) }
            } else if !text.isEmpty(line: line) {
                edits.append(TextReplacement(range: NSRange(location: start, length: 0), text: String(repeating: unit, count: times)))
            }
        }
        apply(edits)
        endChange()
        let after = self.text
        setCursor(after.firstNonBlank(ofLine: lines.lowerBound))
    }

    // MARK: Text objects

    private func object(_ kind: String, inner: Bool, at location: Int, count: Int) -> VimText.Span? {
        let text = text
        guard text.length > 0 || kind == "w" || kind == "W" || kind == "p" else { return nil }
        switch kind {
        case "w", "W": return text.wordObject(at: location, big: kind == "W", around: !inner, count: count)
        case "(", ")", "b": return text.bracketObject(open: 0x28, close: 0x29, at: location, around: !inner, count: count)
        case "{", "}", "B": return text.bracketObject(open: 0x7B, close: 0x7D, at: location, around: !inner, count: count)
        case "[", "]": return text.bracketObject(open: 0x5B, close: 0x5D, at: location, around: !inner, count: count)
        case "<", ">": return text.bracketObject(open: 0x3C, close: 0x3E, at: location, around: !inner, count: count)
        case "\"", "'", "`": return text.quoteObject(quote: (kind as NSString).character(at: 0), at: location, around: !inner)
        case "t": return text.tagObject(at: location, around: !inner, count: count)
        case "p": return text.paragraphObject(at: location, around: !inner, count: count)
        default: return nil
        }
    }

    private func selectObject(_ kind: String, inner: Bool, count: Int) {
        guard let span = object(kind, inner: inner, at: head, count: count), span.end > span.start else { return }
        let text = text
        anchor = span.start
        head = text.previous(span.end)
        if span.linewise { mode = .visualLine } else if mode == .visualLine { mode = .visual }
        updateVisualSelection()
    }

    // MARK: Visual mode

    private func enterVisual(linewise: Bool) {
        anchor = cursor
        head = cursor
        mode = linewise ? .visualLine : .visual
        updateVisualSelection()
    }

    private func exitVisual() {
        lastVisual = (anchor, head, mode == .visualLine)
        mode = .normal
        setCursor(clampNormal(head))
    }

    private func moveVisual(_ motion: VimMotion, count: Int?) {
        if case .search(let forward) = motion {
            commandLine = CommandLine(kind: forward ? "/" : "?", text: "", count: count)
            return
        }
        guard let movement = evaluate(motion, from: head, count: count, forOperator: false) else { return }
        updateDesiredColumn(motion, movement, from: head)
        head = min(movement.target, text.length)
        updateVisualSelection()
    }

    private var visualRegion: Region {
        let text = text
        let start = min(anchor, head), end = max(anchor, head)
        if mode == .visualLine { return .lines(text.line(of: start), text.line(of: end)) }
        return .chars(start, min(text.next(end), text.length))
    }

    private func visualExtent(linewise: Bool) -> VisualExtent {
        let text = text
        let start = min(anchor, head), end = max(anchor, head)
        let lines = text.line(of: end) - text.line(of: start) + 1
        var characters = 0
        var index = start
        while index <= end, index < text.length {
            index = text.next(index)
            characters += 1
        }
        return VisualExtent(linewise: linewise, lines: lines, characters: characters, lastColumn: text.column(of: end))
    }

    private func operateOnSelection(_ op: VimOperator, command: VimCommand) {
        let linewise = mode == .visualLine || command.linewise
        var region = visualRegion
        if command.linewise, case .chars(let start, let end) = region {
            let text = text
            region = .lines(text.line(of: start), text.line(of: max(start, end - 1)))
        }
        if op != .yank {
            guard isEditable else {
                exitVisual()
                return refuse()
            }
            var change = RecordedChange(register: command.register, count: command.count, body: command.body)
            change.visual = visualExtent(linewise: linewise)
            lastChange = change
        }
        lastVisual = (anchor, head, mode == .visualLine)
        mode = .normal
        applyOperator(op, region, command: command, visual: true)
        if op == .change, mode == .insert {
            insertSession?.record = lastChange
        }
    }

    // MARK: Insert and Replace modes

    private func beginInsert(at location: Int, count: Int, repeatPrefix: String = "", record: RecordedChange?, moveCursor: Bool = true) {
        guard let host else { return }
        beginChange()
        mode = .insert
        desiredColumn = nil
        if moveCursor { setCursor(location) }
        insertSession = InsertSession(start: location, snapshot: host.vimText.copy() as! NSString, count: count,
                                      repeatPrefix: repeatPrefix, record: record)
    }

    private func finishInsert() {
        guard let host else { return }
        defer {
            endChange()
            mode = .normal
            desiredColumn = nil
        }
        guard let session = insertSession else { return }
        insertSession = nil
        var location = host.vimSelection.location
        let (deletedBefore, inserted) = typedText(in: session, cursor: location)
        if session.count > 1, !inserted.isEmpty {
            let more = String(repeating: session.repeatPrefix + inserted, count: session.count - 1)
            host.vimApply([TextReplacement(range: NSRange(location: location, length: 0), text: more)])
            location += (more as NSString).length
        }
        if var change = session.record {
            change.inserted = inserted
            change.deletedBefore = deletedBefore
            lastChange = change
        }
        let text = text
        let lineStart = text.start(ofLine: text.line(of: location))
        setCursor(location > lineStart ? text.previous(location) : location)
    }

    /// What Insert mode typed: the text between where it started and the cursor, worked out
    /// from the text before and after (so whatever typed it, completion or auto-closed
    /// brackets too, counts), and how much was deleted before where it started.
    private func typedText(in session: InsertSession, cursor: Int) -> (deletedBefore: Int, text: String) {
        let old = session.snapshot
        let text = text
        let new = text.string
        let oldLength = old.length, newLength = new.length
        var low = text.start(ofLine: text.line(of: min(session.start, cursor)))
        var tail = newLength - text.end(ofLine: text.line(of: cursor))
        if low > oldLength || low > newLength { low = 0 }
        if tail > oldLength - low || tail > newLength - low { tail = 0 }
        var prefix = low
        let limit = min(oldLength - tail, newLength - tail)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var oldEnd = oldLength - tail, newEnd = newLength - tail
        while oldEnd > prefix, newEnd > prefix, old.character(at: oldEnd - 1) == new.character(at: newEnd - 1) {
            oldEnd -= 1
            newEnd -= 1
        }
        let inserted = new.substring(with: NSRange(location: prefix, length: newEnd - prefix))
        return (max(0, min(session.start, oldEnd) - prefix), Self.normalize(inserted))
    }

    private func handleReplace(_ key: String) {
        guard var session = replaceSession else { mode = .normal; return }
        let text = text
        let location = cursor
        if VimParser.isEscape(key) { return finishReplace() }
        if key == "<BS>" {
            if let last = session.stack.popLast() {
                apply([TextReplacement(range: NSRange(location: last.location, length: last.length), text: last.original)])
                session.typed.removeLast()
                setCursor(last.location)
            } else if location > text.start(ofLine: text.line(of: location)) {
                setCursor(text.previous(location))
            }
            replaceSession = session
            return
        }
        let typed: String
        if key == "<CR>" { typed = lineBreak } else if key == "<Tab>" { typed = "\t" } else if VimParser.isCharacter(key) { typed = key } else { return }
        let length = (typed as NSString).length
        let end = text.contentEnd(ofLine: text.line(of: location))
        let replaced = key != "<CR>" && location < end ? NSRange(location: location, length: text.next(location) - location) : NSRange(location: location, length: 0)
        let original = text.string.substring(with: replaced)
        apply([TextReplacement(range: replaced, text: typed)])
        session.stack.append((location, original, length))
        session.typed.append(key)
        replaceSession = session
        setCursor(location + length)
    }

    private func finishReplace() {
        if var session = replaceSession {
            session.record.replaced = session.typed
            lastChange = session.record
        }
        replaceSession = nil
        endChange()
        mode = .normal
        let location = cursor
        let text = text
        if location > text.start(ofLine: text.line(of: location)) { setCursor(text.previous(location)) }
    }

    // MARK: Registers

    private func store(_ register: VimRegister, name: String?, isYank: Bool) {
        let name = name ?? "\""
        if name == "_" { return }
        if name == "+" || name == "*" {
            host?.vimClipboard = register.text
        } else if let first = name.first, first.isUppercase {
            let lower = name.lowercased()
            if var existing = registers[lower] {
                if register.linewise, !existing.linewise { existing.text += "\n" }
                existing.text += register.text
                existing.linewise = existing.linewise || register.linewise
                registers[lower] = existing
            } else {
                registers[lower] = register
            }
        } else if name != "\"" {
            registers[name] = register
        }
        registers["\""] = name.first?.isUppercase == true ? registers[name.lowercased()] : register
        guard name == "\"" else { return }
        if isYank {
            registers["0"] = register
        } else if register.linewise || register.text.contains("\n") {
            for index in stride(from: 9, to: 1, by: -1) { registers[String(index)] = registers[String(index - 1)] }
            registers["1"] = register
        } else {
            registers["-"] = register
        }
    }

    func registerContents(_ name: String?) -> VimRegister? {
        let name = name ?? "\""
        if name == "+" || name == "*" {
            guard let text = host?.vimClipboard else { return nil }
            let normalized = Self.normalize(text)
            return VimRegister(text: normalized, linewise: normalized.hasSuffix("\n"))
        }
        return registers[name.lowercased()]
    }

    // MARK: Actions

    private func perform(_ action: VimAction, command: VimCommand) {
        let n = command.total
        switch action {
        case .deleteChar: operate(.delete, motion: .right, command: command)
        case .deleteCharBefore: operate(.delete, motion: .left, command: command)
        case .substituteChar: operate(.change, motion: .right, command: command)
        case .substituteLine: execute(VimCommand(register: command.register, count: command.count, body: command.body, op: .change, target: .lines))
        case .deleteToEnd: operate(.delete, motion: .lineEnd, command: command)
        case .changeToEnd: operate(.change, motion: .lineEnd, command: command)
        case .yankLine: execute(VimCommand(register: command.register, count: command.count, body: command.body, op: .yank, target: .lines))
        case .replaceChar(let replacement): replaceCharacters(with: replacement, command: command)
        case .toggleCaseChar: toggleCaseAtCursor(command: command)
        case .join(let spaces):
            if isVisual {
                let text = text
                let first = text.line(of: min(anchor, head)), last = text.line(of: max(anchor, head))
                if isEditable {
                    var change = RecordedChange(register: nil, count: nil, body: command.body)
                    change.visual = visualExtent(linewise: mode == .visualLine)
                    lastChange = change
                }
                lastVisual = (anchor, head, mode == .visualLine)
                mode = .normal
                join(first: first, count: max(2, last - first + 1), spaces: spaces)
            } else {
                record(command)
                join(first: text.line(of: cursor), count: max(2, n), spaces: spaces)
            }
        case .put(let before):
            if isVisual { putOverSelection(command: command) } else { put(before: before, command: command) }
        case .undo: undo(n, redo: false)
        case .redo: undo(n, redo: true)
        case .repeatChange: repeatChange(count: command.count)
        case .insert(let kind): insert(kind, command: command)
        case .visual(let linewise):
            if isVisual {
                if (mode == .visualLine) == linewise { exitVisual() } else {
                    mode = linewise ? .visualLine : .visual
                    updateVisualSelection()
                }
            } else {
                enterVisual(linewise: linewise)
            }
        case .reselect:
            guard let last = lastVisual else { return }
            let length = text.length
            anchor = min(last.anchor, max(0, length - 1))
            head = min(last.head, max(0, length - 1))
            mode = last.linewise ? .visualLine : .visual
            updateVisualSelection()
        case .swapEnds:
            swap(&anchor, &head)
            updateVisualSelection()
        case .replaceMode:
            guard isEditable else { return refuse() }
            beginChange()
            mode = .replace
            replaceSession = ReplaceSession(record: RecordedChange(register: nil, count: command.count, body: command.body))
        case .commandLine:
            if isVisual {
                exitVisual()
                commandLine = CommandLine(kind: ":", text: "'<,'>")
            } else {
                commandLine = CommandLine(kind: ":", text: command.count.map { ".,.+\($0 - 1)" } ?? "")
            }
        case .scroll(let kind): scroll(kind, count: command.count)
        case .scrollCursor(let position): host?.vimScrollCursor(to: position)
        case .escape:
            if isVisual { exitVisual() }
        }
    }

    private func replaceCharacters(with replacement: String, command: VimCommand) {
        guard isEditable else { return refuse() }
        let text = text
        let replacement = replacement == "\n" ? lineBreak : replacement
        if isVisual {
            let range = visualRange()
            var output = ""
            var index = range.location
            while index < NSMaxRange(range) {
                let next = text.next(index)
                output += text.isLineBreak(at: index) ? text.substring(index, next) : replacement
                index = next
            }
            var change = RecordedChange(register: nil, count: nil, body: command.body)
            change.visual = visualExtent(linewise: mode == .visualLine)
            lastChange = change
            lastVisual = (anchor, head, mode == .visualLine)
            mode = .normal
            apply([TextReplacement(range: range, text: output)])
            endChange()
            setCursor(clampNormal(range.location))
            return
        }
        let location = cursor
        let end = text.contentEnd(ofLine: text.line(of: location))
        var stop = location
        for _ in 0..<command.total {
            guard stop < end else { return }
            stop = text.next(stop)
        }
        record(command)
        let isBreak = replacement == lineBreak
        let output = isBreak ? replacement : String(repeating: replacement, count: command.total)
        apply([TextReplacement(range: NSRange(location: location, length: stop - location), text: output)])
        endChange()
        let length = (replacement as NSString).length
        setCursor(isBreak ? location + length : location + (command.total - 1) * length)
    }

    private func toggleCaseAtCursor(command: VimCommand) {
        guard isEditable else { return refuse() }
        let text = text
        let location = cursor
        let end = text.contentEnd(ofLine: text.line(of: location))
        guard location < end else { return }
        var stop = location
        for _ in 0..<command.total where stop < end { stop = text.next(stop) }
        record(command)
        let original = text.substring(location, stop)
        let changed = Self.toggleCase(original)
        apply([TextReplacement(range: NSRange(location: location, length: stop - location), text: changed)])
        endChange()
        setCursor(clampNormal(location + (changed as NSString).length))
    }

    private func join(first: Int, count: Int, spaces: Bool) {
        guard isEditable else { return refuse() }
        let text = text
        let last = text.clampLine(first + count - 1)
        guard last > first else { return }
        var edits: [TextReplacement] = []
        var cursorAt = 0
        var shift = 0
        for line in first..<last {
            let end = text.contentEnd(ofLine: line)
            let nextStart = text.start(ofLine: line + 1)
            var removeTo = nextStart
            var separator = ""
            if spaces {
                let nextEnd = text.contentEnd(ofLine: line + 1)
                while removeTo < nextEnd, text.isSpace(text.char(removeTo)) { removeTo += 1 }
                let endsInSpace = end > text.start(ofLine: line) && text.isSpace(text.char(end - 1))
                let nextIsEmpty = removeTo == nextEnd
                let closes = removeTo < nextEnd && text.char(removeTo) == 0x29
                if !endsInSpace, !nextIsEmpty, !closes, end > text.start(ofLine: line) { separator = " " }
            }
            edits.append(TextReplacement(range: NSRange(location: end, length: removeTo - end), text: separator))
            cursorAt = end + shift
            shift += (separator as NSString).length - (removeTo - end)
        }
        apply(edits)
        endChange()
        setCursor(clampNormal(cursorAt))
    }

    private func put(before: Bool, command: VimCommand) {
        guard isEditable else { return refuse() }
        guard let register = registerContents(command.register) else {
            message = "E353: Nothing in register \(command.register ?? "\"")"
            return
        }
        record(command)
        let text = text
        let location = cursor
        let line = text.line(of: location)
        let lineBreak = lineBreak
        var content = register.text
        if lineBreak != "\n" { content = content.replacingOccurrences(of: "\n", with: lineBreak) }
        let repeated = String(repeating: content, count: command.total)
        if register.linewise {
            if before {
                let start = text.start(ofLine: line)
                apply([TextReplacement(range: NSRange(location: start, length: 0), text: repeated)])
                endChange()
                setCursor(self.text.firstNonBlank(ofLine: line))
            } else if line < text.lastLine {
                apply([TextReplacement(range: NSRange(location: text.end(ofLine: line), length: 0), text: repeated)])
                endChange()
                setCursor(self.text.firstNonBlank(ofLine: line + 1))
            } else {
                // After the last line (no line break of its own): one goes before the text.
                let body = repeated.hasSuffix(lineBreak) ? String(repeated.dropLast(lineBreak.count)) : repeated
                apply([TextReplacement(range: NSRange(location: text.length, length: 0), text: lineBreak + body)])
                endChange()
                setCursor(self.text.firstNonBlank(ofLine: line + 1))
            }
            return
        }
        let empty = text.isEmpty(line: line)
        let at = before || empty ? location : min(text.next(location), text.contentEnd(ofLine: line))
        apply([TextReplacement(range: NSRange(location: at, length: 0), text: repeated)])
        endChange()
        let length = (repeated as NSString).length
        if repeated.contains(lineBreak) || length == 0 {
            setCursor(at)
        } else {
            setCursor(self.text.previous(at + length))
        }
    }

    private func putOverSelection(command: VimCommand) {
        guard isEditable else {
            exitVisual()
            return refuse()
        }
        guard let register = registerContents(command.register) else {
            exitVisual()
            message = "E353: Nothing in register \(command.register ?? "\"")"
            return
        }
        let linewiseSelection = mode == .visualLine
        let region = visualRegion
        var change = RecordedChange(register: command.register, count: nil, body: command.body)
        change.visual = visualExtent(linewise: linewiseSelection)
        lastChange = change
        lastVisual = (anchor, head, linewiseSelection)
        mode = .normal
        let (range, replaced) = span(of: region)
        let lineBreak = lineBreak
        var content = register.text
        if register.linewise, !linewiseSelection {
            content = "\n" + String(content.dropLast()) + "\n"
        } else if !register.linewise, linewiseSelection {
            content += "\n"
        }
        if lineBreak != "\n" { content = content.replacingOccurrences(of: "\n", with: lineBreak) }
        apply([TextReplacement(range: range, text: content)])
        endChange()
        // The text replaced goes to the unnamed register (unless one was named).
        if command.register == nil { registers["\""] = replaced }
        let text = self.text
        if register.linewise {
            let line = text.line(of: range.location) + (linewiseSelection ? 0 : 1)
            setCursor(text.firstNonBlank(ofLine: text.clampLine(line)))
        } else {
            setCursor(clampNormal(range.location))
        }
    }

    private func insert(_ kind: VimAction.Insert, command: VimCommand) {
        guard isEditable else { return refuse() }
        record(command)
        let text = text
        let location = cursor
        let line = text.line(of: location)
        switch kind {
        case .before:
            beginInsert(at: location, count: command.total, record: lastChange)
        case .after:
            let at = text.isEmpty(line: line) ? location : min(text.next(location), text.contentEnd(ofLine: line))
            beginInsert(at: at, count: command.total, record: lastChange)
        case .lineStart:
            beginInsert(at: text.firstNonBlankRaw(ofLine: line), count: command.total, record: lastChange)
        case .lineEnd:
            beginInsert(at: text.contentEnd(ofLine: line), count: command.total, record: lastChange)
        case .below, .above:
            let start = text.start(ofLine: line)
            let indent = text.substring(start, text.firstNonBlankRaw(ofLine: line))
            let lineBreak = lineBreak
            let change = lastChange
            if kind == .below {
                let end = text.contentEnd(ofLine: line)
                apply([TextReplacement(range: NSRange(location: end, length: 0), text: lineBreak + indent)])
                let at = end + ((lineBreak + indent) as NSString).length
                beginInsert(at: at, count: command.total, repeatPrefix: lineBreak + indent, record: change)
            } else {
                apply([TextReplacement(range: NSRange(location: start, length: 0), text: indent + lineBreak)])
                beginInsert(at: start + (indent as NSString).length, count: command.total, repeatPrefix: lineBreak + indent, record: change)
            }
        }
    }

    private func undo(_ count: Int, redo: Bool) {
        guard let host else { return }
        var done = 0
        for _ in 0..<count {
            guard redo ? host.vimRedo() : host.vimUndo() else { break }
            done += 1
        }
        if done == 0 { message = redo ? "Already at newest change" : "Already at oldest change" }
        if isVisual { mode = .normal }
        setCursor(clampNormal(host.vimSelection.location))
    }

    private func scroll(_ kind: VimAction.Scroll, count: Int?) {
        guard let host else { return }
        let text = text
        let visible = host.vimVisibleLines
        let page = max(1, visible.upperBound - visible.lowerBound + 1)
        let lines: Int = switch kind {
        case .halfDown, .halfUp: count ?? max(1, page / 2)
        case .pageDown, .pageUp: max(1, page - 2) * (count ?? 1)
        case .lineDown, .lineUp: count ?? 1
        }
        let down = kind == .halfDown || kind == .pageDown || kind == .lineDown
        host.vimScroll(lines: down ? lines : -lines)
        let location = isVisual ? head : cursor
        let line = text.line(of: location)
        var target = line
        switch kind {
        case .lineDown, .lineUp:
            // The cursor stays, unless it scrolled out of view.
            let first = visible.lowerBound + (down ? lines : -lines), last = visible.upperBound + (down ? lines : -lines)
            target = min(max(line, first), last)
        default:
            target = line + (down ? lines : -lines)
        }
        target = text.clampLine(target)
        guard target != line else { return }
        let column = desiredColumn ?? text.column(of: location)
        if desiredColumn == nil { desiredColumn = column }
        let destination = text.offset(line: target, column: column)
        if isVisual {
            head = destination
            updateVisualSelection()
        } else {
            setCursor(destination)
        }
    }

    // MARK: Repeat

    private func repeatChange(count: Int?) {
        guard let change = lastChange else { return }
        guard isEditable else { return refuse() }
        isReplaying = true
        defer { isReplaying = false }
        var keys: [String] = []
        if let register = change.register { keys += ["\"", register] }
        if let count = count ?? change.count { keys += String(count).map(String.init) }
        keys += change.body
        if let extent = change.visual {
            let text = text
            let location = cursor
            let line = text.line(of: location)
            anchor = location
            if extent.linewise {
                head = text.start(ofLine: text.clampLine(line + extent.lines - 1))
                mode = .visualLine
            } else if extent.lines == 1 {
                var target = location
                let end = text.contentEnd(ofLine: line)
                for _ in 1..<max(1, extent.characters) where text.next(target) < end { target = text.next(target) }
                head = target
                mode = .visual
            } else {
                head = text.offset(line: text.clampLine(line + extent.lines - 1), column: extent.lastColumn)
                mode = .visual
            }
            updateVisualSelection()
        }
        for key in keys { handle(key) }
        if mode == .insert, let host {
            let location = host.vimSelection.location
            var at = location
            if change.deletedBefore > 0 {
                let start = max(0, location - change.deletedBefore)
                host.vimApply([TextReplacement(range: NSRange(location: start, length: location - start), text: "")])
                at = start
            }
            if var inserted = change.inserted, !inserted.isEmpty {
                if lineBreak != "\n" { inserted = inserted.replacingOccurrences(of: "\n", with: lineBreak) }
                host.vimApply([TextReplacement(range: NSRange(location: at, length: 0), text: inserted)])
                at += (inserted as NSString).length
            }
            setCursor(at)
            handle("<Esc>")
            // The insert's record is the one replayed (its count may be new).
            lastChange?.inserted = change.inserted
            lastChange?.deletedBefore = change.deletedBefore
        } else if mode == .replace {
            for key in change.replaced { handle(key) }
            handle("<Esc>")
        }
        if let visual = change.visual, var last = lastChange { last.visual = visual; lastChange = last }
    }

    // MARK: Command line

    private func handleCommandLine(_ key: String) {
        guard var line = commandLine else { return }
        if VimParser.isEscape(key) {
            commandLine = nil
            return
        }
        switch key {
        case "<CR>":
            commandLine = nil
            runCommandLine(line)
            return
        case "<BS>":
            if line.text.isEmpty { commandLine = nil; return }
            line.text.removeLast()
        case "<C-u>":
            line.text = ""
        case "<C-w>":
            while line.text.last == " " { line.text.removeLast() }
            while let last = line.text.last, last != " " { line.text.removeLast() }
        case "<Tab>":
            line.text += "\t"
        default:
            guard VimParser.isCharacter(key) else { return }
            line.text += key
        }
        commandLine = line
    }

    /// Text pasted into the command line.
    func typeIntoCommandLine(_ text: String) {
        guard var line = commandLine else { return }
        line.text += text
        commandLine = line
        host?.vimStateDidChange()
    }

    private func runCommandLine(_ line: CommandLine) {
        if line.kind == ":" {
            runEx(line.text)
            return
        }
        let pattern = line.text.isEmpty ? lastSearch?.pattern : line.text
        guard let pattern else {
            message = "E35: No previous regular expression"
            return
        }
        lastSearch = (pattern, line.kind == "/")
        if let pending = line.pending, let op = pending.op {
            var command = pending
            command.target = .motion(.searchNext(reverse: false))
            command.body = (command.body.first.map { [$0] } ?? []) + [String(line.kind)] + VimEngine.keys(pattern) + ["<CR>"]
            if op == .yank || isEditable {
                operate(op, motion: .searchNext(reverse: false), command: command)
            }
        } else if isVisual {
            moveVisual(.searchNext(reverse: false), count: line.count)
        } else {
            moveCursor(.searchNext(reverse: false), count: line.count)
        }
    }

    // MARK: Ex commands

    func runEx(_ input: String) {
        guard let host else { return }
        var rest = Substring(input).drop { $0 == " " || $0 == ":" }
        let range: ClosedRange<Int>?
        do {
            range = try parseRange(&rest)
        } catch {
            message = "E16: Invalid range"
            return
        }
        rest = rest.drop { $0 == " " }
        var name = String(rest.prefix { $0.isLetter })
        if name.isEmpty, let first = rest.first, first == ">" || first == "<" || first == "&" { name = String(first) }
        rest = rest.dropFirst(name.count)
        let bang = rest.first == "!"
        if bang { rest = rest.dropFirst() }
        let argument = String(rest).trimmingCharacters(in: .whitespaces)
        let text = text
        let current = text.line(of: cursor)
        let lines = range ?? current...current

        func run(_ command: VimHostCommand) {
            if let reply = host.vimRun(command) { message = reply }
        }
        // `:s` takes its pattern right after the name: `:s/a/b/`, `:s#a#b#`.
        if name == "s" || name == "substitute" {
            substitute(lines: lines, argument: String(rest))
            return
        }
        switch name {
        case "":
            guard let range else { return }
            desiredColumn = nil
            setCursor(text.firstNonBlank(ofLine: text.clampLine(range.upperBound)))
        case "w", "write": run(.write)
        case "wa", "wall": run(.writeAll)
        case "q", "quit", "clo", "close", "qa", "qall", "quita", "quitall": run(.quit(force: bang))
        case "wq": run(.writeQuit(onlyIfChanged: false))
        case "x", "xit", "exi", "exit": run(.writeQuit(onlyIfChanged: true))
        case "noh", "nohl", "nohlsearch": break
        case "set", "se": setOptions(argument)
        case "d", "de", "del", "delete":
            let register = argument.first.map(String.init).flatMap { VimParser.registers.contains($0) ? $0 : nil }
            applyOperator(.delete, .lines(lines.lowerBound, lines.upperBound),
                          command: VimCommand(register: register, target: .lines))
        case "y", "ya", "yank":
            let register = argument.first.map(String.init).flatMap { VimParser.registers.contains($0) ? $0 : nil }
            applyOperator(.yank, .lines(lines.lowerBound, lines.upperBound), command: VimCommand(register: register, target: .lines))
        case ">", "<":
            guard isEditable else { return refuse() }
            shift(lines: lines, outdent: name == "<", times: 1 + argument.filter { String($0) == name }.count)
        case "j", "join":
            join(first: lines.lowerBound, count: max(2, lines.count), spaces: !bang)
        case "u", "un", "undo": undo(1, redo: false)
        case "red", "redo": undo(1, redo: true)
        default:
            message = "E492: Not an editor command: \(input)"
        }
    }

    private struct RangeError: Error {}

    private func parseRange(_ input: inout Substring) throws -> ClosedRange<Int>? {
        let text = text
        let current = text.line(of: cursor)
        if input.first == "%" {
            input = input.dropFirst()
            return 0...text.lastLine
        }
        guard let first = try parseAddress(&input, current: current) else { return nil }
        var second = first
        if input.first == "," || input.first == ";" {
            input = input.dropFirst()
            second = try parseAddress(&input, current: current) ?? current
        }
        let low = text.clampLine(min(first, second)), high = text.clampLine(max(first, second))
        return low...high
    }

    private func parseAddress(_ input: inout Substring, current: Int) throws -> Int? {
        let text = text
        var base: Int?
        if let first = input.first, first.isNumber {
            let digits = input.prefix { $0.isNumber }
            input = input.dropFirst(digits.count)
            base = (Int(digits) ?? 1) - 1
        } else if input.first == "." {
            input = input.dropFirst()
            base = current
        } else if input.first == "$" {
            input = input.dropFirst()
            base = text.lastLine
        } else if input.first == "'" {
            input = input.dropFirst()
            guard let mark = input.first, mark == "<" || mark == ">", let visual = lastVisual else { throw RangeError() }
            input = input.dropFirst()
            let lines = (text.line(of: min(visual.anchor, text.length)), text.line(of: min(visual.head, text.length)))
            base = mark == "<" ? min(lines.0, lines.1) : max(lines.0, lines.1)
        }
        while let sign = input.first, sign == "+" || sign == "-" {
            input = input.dropFirst()
            let digits = input.prefix { $0.isNumber }
            input = input.dropFirst(digits.count)
            let amount = digits.isEmpty ? 1 : (Int(digits) ?? 1)
            base = (base ?? current) + (sign == "+" ? amount : -amount)
        }
        return base
    }

    private func setOptions(_ argument: String) {
        var unknown: [String] = []
        for option in argument.split(separator: " ").map(String.init) {
            switch option {
            case "ic", "ignorecase": ignoreCase = true
            case "noic", "noignorecase": ignoreCase = false
            case "scs", "smartcase": smartCase = true
            case "noscs", "nosmartcase": smartCase = false
            case "hls", "hlsearch", "nohls", "nohlsearch", "is", "incsearch", "nois", "noincsearch": break
            default: unknown.append(option)
            }
        }
        if !unknown.isEmpty { message = "Option not supported: " + unknown.joined(separator: " ") }
    }

    private func substitute(lines: ClosedRange<Int>, argument: String) {
        guard let host else { return }
        guard let delimiter = argument.first, !delimiter.isLetter, !delimiter.isNumber, delimiter != "\\", delimiter != " " else {
            message = "E492: Not an editor command: s" + argument
            return
        }
        // pattern, replacement, flags: split at unescaped delimiters.
        var parts: [String] = [""]
        var escaped = false
        for character in argument.dropFirst() {
            if escaped {
                if character != delimiter { parts[parts.count - 1].append("\\") }
                parts[parts.count - 1].append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == delimiter, parts.count < 3 {
                parts.append("")
            } else {
                parts[parts.count - 1].append(character)
            }
        }
        if escaped { parts[parts.count - 1].append("\\") }
        var pattern = parts[0]
        let replacement = parts.count > 1 ? parts[1] : ""
        let flags = parts.count > 2 ? parts[2] : ""
        if pattern.isEmpty {
            guard let last = lastSearch?.pattern else {
                message = "E35: No previous regular expression"
                return
            }
            pattern = last
        }
        var caseInsensitive = ignoreCase
        if flags.contains("i") { caseInsensitive = true }
        if flags.contains("I") { caseInsensitive = false }
        guard let regex = VimRegex.make(pattern, ignoreCase: caseInsensitive, smartCase: smartCase && !flags.contains("i")) else {
            message = "E486: Pattern not found: \(pattern)"
            return
        }
        lastSearch = (pattern, true)
        let text = text
        let string = text.string as String
        let nsString = string as NSString
        var edits: [TextReplacement] = []
        var changedLines = 0
        for line in lines {
            let start = text.start(ofLine: line)
            let range = NSRange(location: start, length: text.contentEnd(ofLine: line) - start)
            var matches = regex.matches(in: string, options: [.withTransparentBounds, .withoutAnchoringBounds], range: range)
            if !flags.contains("g") { matches = Array(matches.prefix(1)) }
            guard !matches.isEmpty else { continue }
            changedLines += 1
            for match in matches {
                edits.append(TextReplacement(range: match.range,
                                             text: VimRegex.expand(replacement, match: match, in: nsString, lineBreak: lineBreak)))
            }
        }
        guard let lastEdit = edits.last else {
            if !flags.contains("e") { message = "E486: Pattern not found: \(pattern)" }
            return
        }
        guard isEditable else { return refuse() }
        let shift = edits.dropLast().reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
        apply(edits)
        endChange()
        let after = self.text
        // The last line changed (a replacement with line breaks: its last line).
        let lastEnd = lastEdit.range.location + shift + (lastEdit.text as NSString).length
        setCursor(after.firstNonBlank(ofLine: after.line(of: lastEnd)))
        _ = host
        if edits.count > 1 {
            message = "\(edits.count) substitutions on \(changedLines) line\(changedLines == 1 ? "" : "s")"
        }
    }
}

extension VimText {
    /// The end of the line's indentation (its end, for a blank line).
    func firstNonBlankRaw(ofLine line: Int) -> Int {
        let end = contentEnd(ofLine: line)
        var index = start(ofLine: line)
        while index < end, isSpace(char(index)) { index += 1 }
        return index
    }
}
