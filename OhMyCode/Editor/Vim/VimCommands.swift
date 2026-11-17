import Foundation

/// Vim's modes (Operator-pending is Normal mode with keys pending).
enum VimMode: Equatable {
    case normal, insert, visual, visualLine, replace
}

/// A register's text ("\n" line breaks) and whether it's whole lines.
struct VimRegister: Equatable {
    var text: String
    var linewise: Bool
}

enum VimOperator: Equatable {
    case delete, change, yank, indent, outdent, lower, upper, toggleCase
}

enum VimMotion: Equatable {
    case left, right, up, down
    case word(big: Bool), back(big: Bool), end(big: Bool), backEnd(big: Bool)
    case lineStart, firstNonBlank, lineEnd, lastNonBlank
    case lineDown, lineUp, currentLine
    case gotoLine, firstLine
    case find(String, forward: Bool, till: Bool)
    case repeatFind(reverse: Bool)
    case bracket, paragraphForward, paragraphBackward
    case screenTop, screenMiddle, screenBottom
    case searchNext(reverse: Bool), searchWord(forward: Bool)
    /// `/` and `?`: opens the command line for the pattern.
    case search(forward: Bool)
}

enum VimScrollPosition: Equatable { case top, center, bottom }

enum VimAction: Equatable {
    enum Insert: Equatable { case before, after, lineStart, lineEnd, below, above }
    enum Scroll: Equatable { case halfDown, halfUp, pageDown, pageUp, lineDown, lineUp }

    case deleteChar, deleteCharBefore, substituteChar, substituteLine, deleteToEnd, changeToEnd, yankLine
    case replaceChar(String), toggleCaseChar, join(spaces: Bool), put(before: Bool)
    case undo, redo, repeatChange
    case insert(Insert)
    case visual(linewise: Bool), reselect, swapEnds, replaceMode
    case commandLine
    case scroll(Scroll), scrollCursor(VimScrollPosition)
    case escape
}

enum VimTarget: Equatable {
    case motion(VimMotion)
    case object(inner: Bool, kind: String)
    /// A doubled operator (`dd`, `>>`, `gUU`): whole lines.
    case lines
    /// An operator in Visual mode: the selection.
    case selection
    case action(VimAction)
}

/// One Normal or Visual mode command, as typed.
struct VimCommand: Equatable {
    var register: String?
    /// The counts typed (before the operator and before the motion, multiplied); nil: none.
    var count: Int?
    /// The keys without the register and the counts (what `.` types again).
    var body: [String] = []
    var op: VimOperator?
    var target: VimTarget
    /// A Visual mode operator on whole lines (`D`, `X`, `Y`, `C`, `S`, `R`).
    var linewise = false

    var total: Int { count ?? 1 }
}

/// Reads keys typed in Normal or Visual mode into commands. Keys are strings: a typed
/// character, or a name in angle brackets for the others ("<Esc>", "<CR>", "<BS>", "<C-r>").
enum VimParser {
    enum Result: Equatable {
        case incomplete, invalid
        case command(VimCommand)
    }

    static let registers = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\"+*_-".map(String.init))
    static let objects = Set(["w", "W", "(", ")", "b", "{", "}", "B", "[", "]", "<", ">", "\"", "'", "`", "t", "p"])

    static func isEscape(_ key: String) -> Bool { key == "<Esc>" || key == "<C-[>" || key == "<C-c>" }

    /// A key that stands for a character typed (not a named key like "<Esc>").
    static func isCharacter(_ key: String) -> Bool { !(key.count > 1 && key.hasPrefix("<") && key.hasSuffix(">")) }

    static func parse(_ keys: [String], visual: Bool) -> Result {
        var index = 0
        var command = VimCommand(target: .action(.escape))
        func key(_ offset: Int = 0) -> String? { index + offset < keys.count ? keys[index + offset] : nil }
        func readCount() -> Int? {
            var value: Int?
            while let key = key(), key.count == 1, let digit = Int(key), value != nil || digit != 0 {
                value = min((value ?? 0) * 10 + digit, 99_999)
                index += 1
            }
            return value
        }
        if key() == "\"" {
            guard let name = key(1) else { return .incomplete }
            guard registers.contains(name) else { return .invalid }
            command.register = name
            index += 2
        }
        let firstCount = readCount()
        command.count = firstCount
        guard let first = key() else { return .incomplete }

        func done(_ target: VimTarget, _ used: Int) -> Result {
            command.body += keys[index..<(index + used)]
            command.target = target
            return .command(command)
        }

        if visual {
            let operators: [String: (VimOperator, Bool)] = [
                "d": (.delete, false), "x": (.delete, false), "<Del>": (.delete, false), "X": (.delete, true), "D": (.delete, true),
                "y": (.yank, false), "Y": (.yank, true), "c": (.change, false), "s": (.change, false),
                "C": (.change, true), "S": (.change, true), "R": (.change, true),
                ">": (.indent, false), "<": (.outdent, false), "~": (.toggleCase, false), "u": (.lower, false), "U": (.upper, false),
            ]
            if let (op, linewise) = operators[first] {
                command.op = op
                command.linewise = linewise
                return done(.selection, 1)
            }
            switch first {
            case "g":
                guard let next = key(1) else { return .incomplete }
                let ops: [String: VimOperator] = ["u": .lower, "U": .upper, "~": .toggleCase]
                if let op = ops[next] { command.op = op; return done(.selection, 2) }
                if next == "J" { return done(.action(.join(spaces: false)), 2) }
            case "J": return done(.action(.join(spaces: true)), 1)
            case "r":
                guard let next = key(1) else { return .incomplete }
                guard let text = replacementText(next) else { return .invalid }
                return done(.action(.replaceChar(text)), 2)
            case "p", "P": return done(.action(.put(before: first == "P")), 1)
            case "o", "O": return done(.action(.swapEnds), 1)
            case "v", "V": return done(.action(.visual(linewise: first == "V")), 1)
            case ":": return done(.action(.commandLine), 1)
            case "i", "a":
                guard let kind = key(1) else { return .incomplete }
                guard objects.contains(kind) else { return .invalid }
                return done(.object(inner: first == "i", kind: kind), 2)
            default:
                if isEscape(first) { return done(.action(.escape), 1) }
            }
        }

        // An operator, its count, then a motion, a text object or the operator again.
        let operators: [String: VimOperator] = ["d": .delete, "c": .change, "y": .yank, ">": .indent, "<": .outdent]
        var op: VimOperator?
        var opKeys: [String] = []
        if !visual, let found = operators[first] {
            op = found
            opKeys = [first]
        } else if !visual, first == "g", let next = key(1), let found = ["u": VimOperator.lower, "U": .upper, "~": .toggleCase][next] {
            op = found
            opKeys = ["g", next]
        } else if !visual, first == "g", key(1) == nil {
            return .incomplete
        }
        if let op {
            command.op = op
            command.body = opKeys
            index += opKeys.count
            let secondCount = readCount()
            if firstCount != nil || secondCount != nil { command.count = (firstCount ?? 1) * (secondCount ?? 1) }
            guard let next = key() else { return .incomplete }
            // Doubled: `dd`, `>>`, `guu`, `gugu`.
            if next == opKeys.last! && (opKeys.count == 1 || next != "g") { return done(.lines, 1) }
            if opKeys.count == 2, next == "g" {
                guard let after = key(1) else { return .incomplete }
                if after == opKeys[1] { return done(.lines, 2) }
            }
            if next == "i" || next == "a" {
                guard let kind = key(1) else { return .incomplete }
                guard objects.contains(kind) else { return .invalid }
                return done(.object(inner: next == "i", kind: kind), 2)
            }
            switch motion(keys, at: index) {
            case .incomplete: return .incomplete
            case .none, .invalid: return .invalid
            case .motion(let motion, let used): return done(.motion(motion), used)
            }
        }

        switch motion(keys, at: index) {
        case .incomplete: return .incomplete
        case .invalid: return .invalid
        case .motion(let motion, let used): return done(.motion(motion), used)
        case .none: break
        }
        if visual { return .invalid }

        let simple: [String: VimAction] = [
            "x": .deleteChar, "<Del>": .deleteChar, "X": .deleteCharBefore, "s": .substituteChar, "S": .substituteLine,
            "D": .deleteToEnd, "C": .changeToEnd, "Y": .yankLine, "~": .toggleCaseChar, "J": .join(spaces: true),
            "p": .put(before: false), "P": .put(before: true), "u": .undo, "<C-r>": .redo, ".": .repeatChange,
            "i": .insert(.before), "<Insert>": .insert(.before), "a": .insert(.after), "I": .insert(.lineStart),
            "A": .insert(.lineEnd), "o": .insert(.below), "O": .insert(.above),
            "v": .visual(linewise: false), "V": .visual(linewise: true), "R": .replaceMode, ":": .commandLine,
            "<C-d>": .scroll(.halfDown), "<C-u>": .scroll(.halfUp), "<C-f>": .scroll(.pageDown), "<C-b>": .scroll(.pageUp),
            "<PageDown>": .scroll(.pageDown), "<PageUp>": .scroll(.pageUp), "<C-e>": .scroll(.lineDown), "<C-y>": .scroll(.lineUp),
        ]
        if let action = simple[first] { return done(.action(action), 1) }
        if isEscape(first) { return done(.action(.escape), 1) }
        switch first {
        case "r":
            guard let next = key(1) else { return .incomplete }
            guard let text = replacementText(next) else { return .invalid }
            return done(.action(.replaceChar(text)), 2)
        case "g":
            guard let next = key(1) else { return .incomplete }
            if next == "v" { return done(.action(.reselect), 2) }
            if next == "J" { return done(.action(.join(spaces: false)), 2) }
            if next == "I" { return done(.action(.insert(.lineStart)), 2) }
            return .invalid
        case "z":
            guard let next = key(1) else { return .incomplete }
            let positions: [String: VimScrollPosition] = ["z": .center, ".": .center, "t": .top, "<CR>": .top, "b": .bottom, "-": .bottom]
            guard let position = positions[next] else { return .invalid }
            return done(.action(.scrollCursor(position)), 2)
        default:
            return .invalid
        }
    }

    /// What `r` replaces with: the character typed (Enter: a line break, Tab: a tab).
    static func replacementText(_ key: String) -> String? {
        if key == "<CR>" { return "\n" }
        if key == "<Tab>" { return "\t" }
        return isCharacter(key) ? key : nil
    }

    enum MotionResult: Equatable {
        case none, incomplete, invalid
        case motion(VimMotion, Int)
    }

    static func motion(_ keys: [String], at index: Int) -> MotionResult {
        guard index < keys.count else { return .incomplete }
        let first = keys[index]
        let next: String? = index + 1 < keys.count ? keys[index + 1] : nil
        let simple: [String: VimMotion] = [
            "h": .left, "<Left>": .left, "<BS>": .left, "<C-h>": .left, "l": .right, "<Right>": .right, " ": .right,
            "j": .down, "<Down>": .down, "<C-j>": .down, "<C-n>": .down, "k": .up, "<Up>": .up, "<C-p>": .up,
            "w": .word(big: false), "W": .word(big: true), "b": .back(big: false), "B": .back(big: true),
            "e": .end(big: false), "E": .end(big: true), "0": .lineStart, "<Home>": .lineStart, "^": .firstNonBlank,
            "$": .lineEnd, "<End>": .lineEnd, "+": .lineDown, "<CR>": .lineDown, "-": .lineUp, "_": .currentLine,
            "G": .gotoLine, ";": .repeatFind(reverse: false), ",": .repeatFind(reverse: true), "%": .bracket,
            "}": .paragraphForward, "{": .paragraphBackward, "H": .screenTop, "M": .screenMiddle, "L": .screenBottom,
            "n": .searchNext(reverse: false), "N": .searchNext(reverse: true), "*": .searchWord(forward: true),
            "#": .searchWord(forward: false), "/": .search(forward: true), "?": .search(forward: false),
        ]
        if let motion = simple[first] { return .motion(motion, 1) }
        switch first {
        case "f", "F", "t", "T":
            guard let next else { return .incomplete }
            guard isCharacter(next) || next == "<Tab>" else { return .invalid }
            return .motion(.find(next == "<Tab>" ? "\t" : next, forward: first == "f" || first == "t", till: first == "t" || first == "T"), 2)
        case "g":
            guard let next else { return .incomplete }
            let motions: [String: VimMotion] = ["g": .firstLine, "e": .backEnd(big: false), "E": .backEnd(big: true), "_": .lastNonBlank]
            if let motion = motions[next] { return .motion(motion, 2) }
            return .none
        default:
            return .none
        }
    }
}
