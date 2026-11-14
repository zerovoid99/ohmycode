import Foundation

/// Finds compiler and tool errors in a task's output, line by line: clang/swiftc/gcc
/// (`file:line:col: error: …`), TypeScript (`file(line,col): error TS…`), Rust (`error[E…]: …`
/// then `--> file:line:col`), Go (`file.go:line:col: …`) and ESLint's unix format.
struct ProblemMatcher {
    struct Problem: Equatable, Sendable {
        var url: URL
        /// 1-based, as compilers print them.
        var line: Int
        var column: Int
        var severity: Diagnostic.Severity
        var message: String
        var code: String?

        var diagnostic: Diagnostic {
            let start = LSPPosition(line: max(line - 1, 0), character: max(column - 1, 0))
            return Diagnostic(range: LSPRange(start: start, end: LSPPosition(line: start.line, character: start.character + 1)),
                              severity: severity, message: code.map { "\(message) [\($0)]" } ?? message, source: nil)
        }
    }

    /// Where relative paths are resolved.
    let directory: URL
    /// Only paths of existing files count (so ordinary output that looks alike is left alone).
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    /// A Rust message waiting for its `-->` location line.
    private var pendingRust: (severity: Diagnostic.Severity, message: String, code: String?)?

    init(directory: URL) { self.directory = directory }

    // swiftc / clang / gcc: path:line[:col]: error|warning|note|fatal error: message
    private static let compiler = try! NSRegularExpression(
        pattern: #"^\s*([^\s:][^:]*?):(\d+):(?:(\d+):)?\s*(fatal error|error|warning|note|remark)\s*:\s*(.+)$"#)
    // tsc: path(line,col): error TS2304: message
    private static let typeScript = try! NSRegularExpression(
        pattern: #"^\s*(.+?)\((\d+),(\d+)\):\s+(error|warning)\s+(TS\d+)\s*:\s*(.+)$"#)
    // tsc --pretty: path:line:col - error TS2304: message
    private static let typeScriptPretty = try! NSRegularExpression(
        pattern: #"^\s*(.+?):(\d+):(\d+)\s+-\s+(error|warning)\s+(TS\d+)\s*:\s*(.+)$"#)
    // rustc / cargo: error[E0425]: message   (location on a following line)
    private static let rustHeader = try! NSRegularExpression(
        pattern: #"^(error|warning)(?:\[([A-Za-z0-9_:]+)\])?:\s+(.+)$"#)
    private static let rustLocation = try! NSRegularExpression(pattern: #"^\s*-->\s+(.+?):(\d+):(\d+)\s*$"#)
    // go build / vet / test: path.go:line[:col]: message
    private static let go = try! NSRegularExpression(pattern: #"^\s*(\S+\.go):(\d+)(?::(\d+))?:\s+(.+)$"#)
    // eslint -f unix: path:line:col: message [Error/rule]
    private static let eslint = try! NSRegularExpression(
        pattern: #"^(.+?):(\d+):(\d+):\s+(.+?)\s+\[(Error|Warning)(?:/([^\]]+))?\]$"#)

    /// The problem a line of output reports, if any.
    mutating func match(_ line: String) -> Problem? {
        let line = ProblemMatcher.stripEscapes(line)
        let range = NSRange(line.startIndex..., in: line)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }

        if let pending = pendingRust {
            if let match = Self.rustLocation.firstMatch(in: line, range: range) {
                pendingRust = nil
                return problem(path: group(match, 1), line: group(match, 2), column: group(match, 3),
                               severity: pending.severity, message: pending.message, code: pending.code)
            }
            // The location follows directly; anything else means there's none.
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { pendingRust = nil }
        }
        if let match = Self.rustHeader.firstMatch(in: line, range: range) {
            let message = group(match, 3) ?? ""
            // "error: could not compile `x`" and summaries have no location: they're left out.
            pendingRust = (severity(group(match, 1)), message, group(match, 2))
            return nil
        }
        if let match = Self.typeScript.firstMatch(in: line, range: range) ?? Self.typeScriptPretty.firstMatch(in: line, range: range) {
            return problem(path: group(match, 1), line: group(match, 2), column: group(match, 3),
                           severity: severity(group(match, 4)), message: group(match, 6) ?? "", code: group(match, 5))
        }
        if let match = Self.eslint.firstMatch(in: line, range: range) {
            return problem(path: group(match, 1), line: group(match, 2), column: group(match, 3),
                           severity: severity(group(match, 5)), message: group(match, 4) ?? "", code: group(match, 6))
        }
        if let match = Self.compiler.firstMatch(in: line, range: range) {
            return problem(path: group(match, 1), line: group(match, 2), column: group(match, 3),
                           severity: severity(group(match, 4)), message: group(match, 5) ?? "", code: nil)
        }
        if let match = Self.go.firstMatch(in: line, range: range) {
            return problem(path: group(match, 1), line: group(match, 2), column: group(match, 3),
                           severity: .error, message: group(match, 4) ?? "", code: nil)
        }
        return nil
    }

    private func severity(_ word: String?) -> Diagnostic.Severity {
        switch word?.lowercased() {
        case "warning": .warning
        case "note", "remark": .information
        default: .error
        }
    }

    private func problem(path: String?, line: String?, column: String?, severity: Diagnostic.Severity,
                         message: String, code: String?) -> Problem? {
        guard let path, let lineNumber = line.flatMap(Int.init), lineNumber > 0 else { return nil }
        let url = path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
        let standardized = url.standardizedFileURL
        guard fileExists(standardized.path) else { return nil }
        return Problem(url: standardized, line: lineNumber, column: column.flatMap(Int.init) ?? 1, severity: severity,
                       message: message.trimmingCharacters(in: .whitespaces), code: code)
    }

    private static let escape = try! NSRegularExpression(pattern: #"\u001B(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007\u001B]*(?:\u0007|\u001B\\)|[@-Z\\-_])"#)

    /// The text without terminal escape sequences (colors, cursor movement).
    static func stripEscapes(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return escape.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
