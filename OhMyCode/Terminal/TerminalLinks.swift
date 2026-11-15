import AppKit

/// What ⌘-click opens in the terminal: a web address, or a file (with the line and column
/// compilers and test runners print, `path:12:5`).
enum TerminalLink: Equatable {
    case url(URL)
    case file(URL, line: Int?, column: Int?)

    private static let urlPattern = try! NSRegularExpression(pattern: #"\b(?:https?|file)://[^\s'"<>`]+"#)
    /// A path (relative or absolute) with a file extension, and maybe `:line` or `:line:column`
    /// (or Python's `", line 12"`).
    /// Groups: 1 the path, 2 the line, 3 the column, 4 Python's line.
    private static let pathPattern = try! NSRegularExpression(
        pattern: #"((?:~|\.{1,2})?/?(?:[\w.@+-]+/)*[\w.@+-]+\.[A-Za-z0-9]+)(?::(\d+)(?::(\d+))?)?(?:", line (\d+))?"#)

    /// The link at a column (0-based, in characters) of a line, with files resolved against
    /// `base` and kept only when they exist.
    static func link(in line: String, at column: Int, base: URL?) -> TerminalLink? {
        let text = line as NSString
        let index = (line.prefix(column) as Substring).utf16.count
        let whole = NSRange(location: 0, length: text.length)
        for match in urlPattern.matches(in: line, range: whole) where NSLocationInRange(index, match.range) {
            var found = text.substring(with: match.range)
            while let last = found.last, ".,;:!?)]}'\"".contains(last) { found.removeLast() }
            if let url = URL(string: found) { return .url(url) }
        }
        for match in pathPattern.matches(in: line, range: whole) where NSLocationInRange(index, match.range) {
            let path = text.substring(with: match.range(at: 1))
            let number = { (range: NSRange) in range.location == NSNotFound ? nil : Int(text.substring(with: range)) }
            let lineNumber = number(match.range(at: 2)) ?? number(match.range(at: 4))
            let columnNumber = number(match.range(at: 3))
            let expanded = (path as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : (base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appending(path: expanded)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            return .file(url.standardizedFileURL, line: lineNumber, column: columnNumber)
        }
        return nil
    }
}

extension TerminalSession {
    /// The text of a row on screen (plain, trailing spaces trimmed).
    func rowText(_ row: UInt16) -> String? {
        text(from: (0, row), to: (columns > 0 ? columns - 1 : 0, row))
    }
}

extension Workspace {
    /// ⌘-click on a link in the terminal.
    func openTerminalLink(_ link: TerminalLink) {
        switch link {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .file(let url, let line, let column):
            open(fileAt: url)
            guard let line, let document = activeDocument else { return }
            let index = min(max(line, 1), document.lineIndex.lineCount) - 1
            let start = document.lineIndex.lineStarts[index]
            let end = index + 1 < document.lineIndex.lineCount ? document.lineIndex.lineStarts[index + 1] - 1 : document.textStorage.length
            document.reveal(NSRange(location: min(start + max(0, (column ?? 1) - 1), max(start, end)), length: 0))
            document.editor?.focus()
        }
    }
}
