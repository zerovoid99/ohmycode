import Foundation
import SwiftTreeSitter

/// The SQL a connection speaks: decides how text splits into statements (quotes, comments,
/// `$$`, backticks, `DELIMITER`) and how names are quoted.
enum SQLDialect: String, Sendable, CaseIterable {
    case sqlite, postgres, mysql
}

enum SQLKeywords {
    static let all: [String] = [
        "ADD", "ALL", "ALTER", "ANALYZE", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASCADE", "CASE", "CAST",
        "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_DATE", "CURRENT_TIME",
        "CURRENT_TIMESTAMP", "DATABASE", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DROP", "ELSE", "END",
        "EXCEPT", "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FOREIGN", "FROM", "FULL", "GRANT", "GROUP", "HAVING", "IF", "ILIKE",
        "IN", "INDEX", "INNER", "INSERT", "INTERSECT", "INTO", "IS", "JOIN", "KEY", "LATERAL", "LEFT", "LIKE", "LIMIT",
        "NATURAL", "NOT", "NULL", "NULLS", "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRIMARY",
        "PROCEDURE", "FUNCTION", "REFERENCES", "RENAME", "REPLACE", "RETURNING", "REVOKE", "RIGHT", "ROLLBACK", "SCHEMA",
        "SELECT", "SET", "SHOW", "TABLE", "THEN", "TO", "TRANSACTION", "TRIGGER", "TRUE", "TRUNCATE", "UNION", "UNIQUE",
        "UPDATE", "USE", "USING", "VALUES", "VIEW", "WHEN", "WHERE", "WINDOW", "WITH", "RECURSIVE", "CONFLICT", "DO",
        "NOTHING", "ROW", "ROWS", "PRAGMA", "VACUUM", "ATTACH", "DETACH", "TEMP", "TEMPORARY", "AUTOINCREMENT",
        "AUTO_INCREMENT", "ENGINE", "CHARSET", "DELIMITER", "DECLARE", "RETURN", "RETURNS", "LANGUAGE", "IMMUTABLE",
        "VOLATILE", "STABLE", "SECURITY", "OWNER", "EXTENSION", "SEQUENCE", "MATERIALIZED", "REFRESH", "LISTEN", "NOTIFY",
        "COPY", "ONLY", "ASYMMETRIC", "SIMILAR", "ESCAPE", "FILTER", "WITHIN", "GROUPING", "ROLLUP", "CUBE", "SETS",
        "ABORT", "SAVEPOINT", "RELEASE", "START", "WORK", "GLOBAL", "LOCAL", "SESSION", "EACH", "FOR", "AFTER", "BEFORE",
        "INSTEAD", "OF", "EXECUTE", "IGNORE", "DUPLICATE", "INTERVAL", "ZONE", "AT", "BOTH", "LEADING", "TRAILING",
    ]

    static let keywordSet = Set(all)

    /// Words that need quoting as names.
    static let reserved: Set<String> = [
        "ALL", "AND", "ANY", "AS", "ASC", "BETWEEN", "BY", "CASE", "CHECK", "COLUMN", "CONSTRAINT", "CREATE", "CROSS",
        "DEFAULT", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXCEPT", "EXISTS", "FALSE", "FOR", "FOREIGN",
        "FROM", "FULL", "GRANT", "GROUP", "HAVING", "IN", "INDEX", "INNER", "INSERT", "INTERSECT", "INTO", "IS", "JOIN",
        "KEY", "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "PRIMARY", "REFERENCES",
        "RIGHT", "SELECT", "SET", "TABLE", "THEN", "TO", "TRUE", "UNION", "UNIQUE", "UPDATE", "USER", "USING", "VALUES",
        "WHEN", "WHERE", "WITH", "ORDER", "GROUP", "WINDOW",
    ]

    static let types: Set<String> = [
        "INT", "INTEGER", "SMALLINT", "BIGINT", "TINYINT", "MEDIUMINT", "SERIAL", "BIGSERIAL", "SMALLSERIAL", "REAL",
        "FLOAT", "DOUBLE", "PRECISION", "NUMERIC", "DECIMAL", "BOOLEAN", "BOOL", "CHAR", "VARCHAR", "CHARACTER", "VARYING",
        "TEXT", "BLOB", "BYTEA", "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "DATETIME", "YEAR", "JSON", "JSONB", "UUID",
        "INET", "CIDR", "MONEY", "BIT", "BINARY", "VARBINARY", "ENUM", "LONGTEXT", "MEDIUMTEXT", "TINYTEXT", "LONGBLOB",
        "MEDIUMBLOB", "TINYBLOB", "XML", "ARRAY", "HSTORE", "INT2", "INT4", "INT8", "FLOAT4", "FLOAT8", "UNSIGNED",
    ]

    static let constants: Set<String> = ["NULL", "TRUE", "FALSE"]

    /// Functions offered in completion (the common ones every dialect has, more or less).
    static let functions = [
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "LOWER", "UPPER", "LENGTH", "SUBSTRING", "TRIM",
        "ROUND", "ABS", "NOW", "CONCAT", "REPLACE", "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD", "STRING_AGG",
        "GROUP_CONCAT", "JSON_EXTRACT", "DATE_TRUNC", "EXTRACT",
    ]
}

// MARK: Lexing

/// Splits SQL into tokens, the way the dialect quotes and comments (UTF-16 offsets, as the
/// editor's ranges are).
struct SQLLexer {
    enum Kind: Equatable { case space, comment, string, quotedIdentifier, number, word, punctuation }

    struct Token: Equatable {
        var kind: Kind
        var range: NSRange
    }

    let chars: [UInt16]
    let dialect: SQLDialect
    var position: Int

    init(_ text: String, dialect: SQLDialect, from position: Int = 0) {
        chars = Array(text.utf16)
        self.dialect = dialect
        self.position = position
    }

    init(chars: [UInt16], dialect: SQLDialect, from position: Int = 0) {
        self.chars = chars
        self.dialect = dialect
        self.position = position
    }

    private func at(_ i: Int) -> UInt16 { i < chars.count ? chars[i] : 0 }

    static func isIdentifierStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
    }

    func isIdentifierPart(_ c: UInt16) -> Bool {
        Self.isIdentifierStart(c) || (c >= 48 && c <= 57) || (c == 36 && dialect == .postgres)
    }

    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }

    mutating func next() -> Token? {
        guard position < chars.count else { return nil }
        let start = position
        let c = chars[position]
        func token(_ kind: Kind) -> Token { Token(kind: kind, range: NSRange(location: start, length: position - start)) }

        if Self.isSpace(c) {
            while position < chars.count, Self.isSpace(chars[position]) { position += 1 }
            return token(.space)
        }
        // -- and (MySQL) # comments, to the end of the line.
        if (c == 45 && at(position + 1) == 45) || (c == 35 && dialect == .mysql) {
            while position < chars.count, chars[position] != 10 { position += 1 }
            return token(.comment)
        }
        if c == 47 && at(position + 1) == 42 { // /* */, nested in Postgres
            position += 2
            var depth = 1
            while position < chars.count {
                if chars[position] == 42, at(position + 1) == 47 {
                    position += 2
                    depth -= 1
                    if depth == 0 || dialect != .postgres { break }
                } else if dialect == .postgres, chars[position] == 47, at(position + 1) == 42 {
                    position += 2
                    depth += 1
                } else {
                    position += 1
                }
            }
            return token(.comment)
        }
        if c == 39 { // 'string'
            let escapes = dialect == .mysql
                || (dialect == .postgres && start > 0 && (chars[start - 1] == 69 || chars[start - 1] == 101)
                    && (start < 2 || !isIdentifierPart(chars[start - 2])))
            skipQuoted(39, backslashEscapes: escapes)
            return token(.string)
        }
        if c == 34 { // "identifier" (a string in MySQL)
            skipQuoted(34, backslashEscapes: dialect == .mysql)
            return token(dialect == .mysql ? .string : .quotedIdentifier)
        }
        if c == 96 { // `identifier`
            skipQuoted(96, backslashEscapes: false)
            return token(.quotedIdentifier)
        }
        if c == 91, dialect == .sqlite { // [identifier]
            position += 1
            while position < chars.count, chars[position] != 93 { position += 1 }
            position = min(chars.count, position + 1)
            return token(.quotedIdentifier)
        }
        if c == 36, dialect == .postgres, let tagEnd = dollarTagEnd(at: position), start == 0 || !isIdentifierPart(chars[start - 1]) {
            let tag = Array(chars[position..<tagEnd])
            position = tagEnd
            while position < chars.count {
                if chars[position] == 36, position + tag.count <= chars.count, Array(chars[position..<position + tag.count]) == tag {
                    position += tag.count
                    return token(.string)
                }
                position += 1
            }
            return token(.string)
        }
        if Self.isDigit(c) || (c == 46 && Self.isDigit(at(position + 1))) {
            if c == 48, at(position + 1) == 120 || at(position + 1) == 88 {
                position += 2
                while position < chars.count, isHexDigit(chars[position]) { position += 1 }
                return token(.number)
            }
            while position < chars.count, Self.isDigit(chars[position]) || chars[position] == 46 { position += 1 }
            if at(position) == 101 || at(position) == 69 {
                let sign = at(position + 1) == 43 || at(position + 1) == 45 ? 1 : 0
                if Self.isDigit(at(position + 1 + sign)) {
                    position += 1 + sign
                    while position < chars.count, Self.isDigit(chars[position]) { position += 1 }
                }
            }
            // 1abc is a name in MySQL and SQLite; keep it one token.
            while position < chars.count, isIdentifierPart(chars[position]) { position += 1 }
            return token(.number)
        }
        if Self.isIdentifierStart(c) {
            position += 1
            while position < chars.count, isIdentifierPart(chars[position]) { position += 1 }
            return token(.word)
        }
        position += 1
        return token(.punctuation)
    }

    private func isHexDigit(_ c: UInt16) -> Bool {
        Self.isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
    }

    /// `$$` or `$tag$` at `i`: where the tag ends.
    private func dollarTagEnd(at i: Int) -> Int? {
        var j = i + 1
        if at(j) == 36 { return j + 1 }
        guard Self.isIdentifierStart(at(j)) else { return nil }
        while j < chars.count, Self.isIdentifierStart(chars[j]) || Self.isDigit(chars[j]) { j += 1 }
        return at(j) == 36 ? j + 1 : nil
    }

    private mutating func skipQuoted(_ quote: UInt16, backslashEscapes: Bool) {
        position += 1
        while position < chars.count {
            let c = chars[position]
            if backslashEscapes, c == 92 {
                position += 2
                continue
            }
            if c == quote {
                if at(position + 1) == quote { position += 2; continue }
                position += 1
                return
            }
            position += 1
        }
        position = chars.count
    }
}

// MARK: Statements

/// One statement of a SQL text.
struct SQLStatement: Equatable, Sendable {
    /// The statement, without the comments and blank space before it and its delimiter.
    var range: NSRange
    /// From the end of the previous statement through this one's delimiter: where the caret
    /// counts as being in this statement.
    var extent: NSRange
    var text: String
}

enum SQLSplitter {
    /// Statements of `text`: delimited by `;` (or MySQL's `DELIMITER` choice), ignoring
    /// delimiters in strings, quoted names, comments and dollar quotes, and the `;`s inside a
    /// SQLite trigger's BEGIN … END.
    static func split(_ text: String, dialect: SQLDialect) -> [SQLStatement] {
        let ns = text as NSString
        let chars = Array(text.utf16)
        var lexer = SQLLexer(chars: chars, dialect: dialect)
        var statements: [SQLStatement] = []
        var delimiter: [UInt16] = Array(";".utf16)
        var statementStart: Int?
        var lastEnd = 0
        var extentStart = 0
        var words: [String] = [] // the first few, to recognize CREATE TRIGGER
        var blockDepth = 0

        func finish(at end: Int) {
            if let start = statementStart {
                let range = NSRange(location: start, length: lastEnd - start)
                statements.append(SQLStatement(range: range, extent: NSRange(location: extentStart, length: end - extentStart),
                                               text: ns.substring(with: range)))
            }
            statementStart = nil
            extentStart = end
            words = []
            blockDepth = 0
        }

        func matches(_ token: [UInt16], at i: Int) -> Bool {
            i + token.count <= chars.count && Array(chars[i..<i + token.count]) == token
        }

        func isLineStart(_ i: Int) -> Bool {
            var j = i - 1
            while j >= 0, chars[j] == 32 || chars[j] == 9 { j -= 1 }
            return j < 0 || chars[j] == 10 || chars[j] == 13
        }

        while lexer.position < chars.count {
            let i = lexer.position
            // MySQL's DELIMITER command (the client's, never sent): a line of its own.
            if dialect == .mysql, statementStart == nil, isLineStart(i), chars[i] == 68 || chars[i] == 100,
               ns.length >= i + 10, ns.substring(with: NSRange(location: i, length: 9)).uppercased() == "DELIMITER",
               SQLLexer.isSpace(chars[i + 9]) {
                let lineEnd = ns.lineRange(for: NSRange(location: i, length: 0))
                let rest = ns.substring(with: NSRange(location: i + 9, length: NSMaxRange(lineEnd) - i - 9))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let token = rest.split(whereSeparator: \.isWhitespace).first, !token.isEmpty {
                    delimiter = Array(String(token).utf16)
                }
                lexer.position = NSMaxRange(lineEnd)
                extentStart = lexer.position
                continue
            }
            if blockDepth == 0, matches(delimiter, at: i) {
                lexer.position = i + delimiter.count
                finish(at: lexer.position)
                continue
            }
            guard let token = lexer.next() else { break }
            switch token.kind {
            case .space, .comment:
                continue
            case .word:
                let word = ns.substring(with: token.range).uppercased()
                if words.count < 4 { words.append(word) }
                if dialect == .sqlite, isTrigger(words) {
                    if word == "BEGIN" || word == "CASE" { blockDepth += 1 }
                    if word == "END", blockDepth > 0 { blockDepth -= 1 }
                }
            default:
                break
            }
            if statementStart == nil { statementStart = token.range.location }
            lastEnd = NSMaxRange(token.range)
        }
        finish(at: chars.count)
        return statements
    }

    private static func isTrigger(_ words: [String]) -> Bool {
        guard words.first == "CREATE" else { return false }
        return words.dropFirst().prefix(3).contains("TRIGGER")
    }

    /// The statement the caret at `offset` is in (or just after, on the same line).
    static func statement(at offset: Int, in statements: [SQLStatement]) -> SQLStatement? {
        if let hit = statements.first(where: { $0.extent.location <= offset && offset <= NSMaxRange($0.extent) && offset >= $0.range.location }) {
            return hit
        }
        // In the blank space or comments before a statement: that one; after the last: the last.
        return statements.first { offset <= $0.range.location && offset >= $0.extent.location } ?? statements.last { $0.range.location <= offset }
            ?? statements.first
    }
}

// MARK: Highlighting

enum SQLSyntax {
    /// Diagnostics of a run (errors with a position) are kept under this name.
    static let problemSource = "SQL"
    /// The Run lens's command.
    static let runCommand = "sql.runStatementAt"
    /// More statements than this and the file gets no lenses (a dump, say).
    static let maxLenses = 300

    /// A Run lens on the first line of each statement (its offset as the argument).
    static func codeLenses(_ text: String, dialect: SQLDialect, lineIndex: LineIndex) -> [Int: [CodeLens]] {
        let statements = SQLSplitter.split(text, dialect: dialect)
        guard statements.count <= maxLenses else { return [:] }
        var result: [Int: [CodeLens]] = [:]
        for statement in statements {
            let line = lineIndex.line(containing: statement.range.location)
            guard result[line] == nil else { continue }
            let range: [String: Any] = ["start": ["line": line, "character": 0], "end": ["line": line, "character": 0]]
            result[line] = CodeLens(json: ["range": range, "command": ["title": "Run", "command": runCommand,
                                                                          "arguments": [statement.range.location]]]).map { [$0] }
        }
        return result
    }

    /// Highlights for the line highlighter (`SyntaxEngine(lineHighlighter:)`): tokens are read
    /// from shortly before `range` so a comment or string that started above is seen.
    @Sendable static func highlights(in text: NSString, range: NSRange) -> [NamedRange] {
        let lookBack = text.length > 200_000 ? 20_000 : text.length
        var start = max(0, range.location - lookBack)
        if start > 0 { start = text.lineRange(for: NSRange(location: start, length: 0)).location }
        let end = NSMaxRange(range)
        let string = text.substring(with: NSRange(location: start, length: min(text.length, end + 2_000) - start))
        var lexer = SQLLexer(string, dialect: .postgres)
        var result: [NamedRange] = []
        var pending: (range: NSRange, word: String)?
        func flushWord(followedByParen: Bool) {
            guard let word = pending else { return }
            pending = nil
            let upper = word.word.uppercased()
            let name: String? = SQLKeywords.constants.contains(upper) ? "constant.builtin"
                : SQLKeywords.types.contains(upper) ? "type"
                : SQLKeywords.keywordSet.contains(upper) ? "keyword"
                : followedByParen ? "function" : nil
            if let name { result.append(NamedRange(name: name, range: word.range)) }
        }
        while let token = lexer.next() {
            let absolute = NSRange(location: token.range.location + start, length: token.range.length)
            if absolute.location > end {
                flushWord(followedByParen: token.kind == .punctuation && (string as NSString).character(at: token.range.location) == 40)
                break
            }
            switch token.kind {
            case .space: continue
            case .word:
                flushWord(followedByParen: false)
                pending = (absolute, (string as NSString).substring(with: token.range))
                continue
            case .punctuation:
                flushWord(followedByParen: (string as NSString).character(at: token.range.location) == 40)
                continue
            default:
                flushWord(followedByParen: false)
            }
            guard NSMaxRange(absolute) >= range.location else { continue }
            switch token.kind {
            case .comment: result.append(NamedRange(name: "comment", range: absolute))
            case .string: result.append(NamedRange(name: "string", range: absolute))
            case .number: result.append(NamedRange(name: "number", range: absolute))
            case .quotedIdentifier: result.append(NamedRange(name: "property", range: absolute))
            default: break
            }
        }
        flushWord(followedByParen: false)
        return result.filter { NSMaxRange($0.range) >= range.location && $0.range.location <= end }
    }
}

// MARK: Completion

enum SQLCompletion {
    enum Kind { static let keyword = 14, table = 7, view = 22, column = 5, schema = 9, function = 3 }

    /// Names a statement reads from (`FROM`, `JOIN`, `UPDATE`, `INTO`), with their aliases.
    static func tableReferences(in statement: String) -> [(table: String, schema: String?, alias: String?)] {
        let pattern = #"(?i)\b(?:FROM|JOIN|UPDATE|INTO)\s+((?:[`"\[]?[\w$]+[`"\]]?\s*\.\s*)?[`"\[]?[\w$]+[`"\]]?)(?:\s+(?:AS\s+)?([A-Za-z_][\w$]*))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = statement as NSString
        let stopWords: Set<String> = ["WHERE", "ON", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "GROUP", "ORDER",
                                      "LIMIT", "SET", "VALUES", "USING", "NATURAL", "UNION", "HAVING", "SELECT", "RETURNING",
                                      "OFFSET", "WINDOW", "AS", "DEFAULT", "LATERAL"]
        return regex.matches(in: statement, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let name = ns.substring(with: match.range(at: 1))
            let parts = name.split(separator: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "`\"[] ")) }
            var alias = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : nil
            if let a = alias, stopWords.contains(a.uppercased()) { alias = nil }
            guard let table = parts.last, !stopWords.contains(table.uppercased()) else { return nil }
            return (table, parts.count > 1 ? parts[0] : nil, alias)
        }
    }

    /// Whether the end of `text` is inside a comment, string or quoted name.
    static func isInsideLiteral(_ text: String, dialect: SQLDialect) -> Bool {
        var lexer = SQLLexer(text, dialect: dialect)
        var last: SQLLexer.Token?
        while let token = lexer.next() { last = token }
        guard let last, NSMaxRange(last.range) == lexer.chars.count else { return false }
        let chars = lexer.chars
        switch last.kind {
        case .comment:
            let isBlock = chars[last.range.location] == 47
            return !isBlock || last.range.length < 4 || chars[NSMaxRange(last.range) - 1] != 47
        case .string, .quotedIdentifier:
            let open = chars[last.range.location]
            let close: UInt16 = open == 91 ? 93 : open
            return last.range.length < 2 || chars[NSMaxRange(last.range) - 1] != close
        default:
            return false
        }
    }

    /// Items for the caret at `cursor` on zero-based `line` (starting at `lineStart`): after
    /// `name.`, the columns of that table (or alias) or the tables of that schema; else
    /// keywords, tables and the columns of the tables the statement uses.
    static func items(text: NSString, cursor: Int, line: Int, lineStart: Int, catalog: DBCatalog?, dialect: SQLDialect,
                      firstID: Int) -> [CompletionItem] {
        let before = text.substring(with: NSRange(location: lineStart, length: cursor - lineStart)) as NSString
        var prefixStart = before.length
        while prefixStart > 0 {
            let c = before.character(at: prefixStart - 1)
            guard SQLLexer.isIdentifierStart(c) || SQLLexer.isDigit(c) || c == 36 else { break }
            prefixStart -= 1
        }
        // Not after a digit-led token, nor inside a comment or string on this line.
        if prefixStart < before.length, SQLLexer.isDigit(before.character(at: prefixStart)) { return [] }
        if isInsideLiteral(before as String, dialect: dialect) { return [] }
        var nextID = firstID
        func item(_ label: String, _ detail: String?, _ kind: Int, insert: String? = nil, sort: String) -> CompletionItem {
            var item = CompletionItem(id: nextID, label: label, detail: detail, kind: kind, sortText: sort, insertText: insert ?? label, isSnippet: false)
            item.editRange = LSPRange(start: LSPPosition(line: line, character: prefixStart),
                                      end: LSPPosition(line: line, character: before.length))
            nextID += 1
            return item
        }
        // The statement around the caret, for its tables and aliases.
        let statements = SQLSplitter.split(text as String, dialect: dialect)
        let statementText = SQLSplitter.statement(at: cursor, in: statements)?.text ?? ""
        let references = tableReferences(in: statementText)

        // After "qualifier.".
        if prefixStart > 0, before.character(at: prefixStart - 1) == 46 {
            var qualifierStart = prefixStart - 1
            while qualifierStart > 0 {
                let c = before.character(at: qualifierStart - 1)
                guard SQLLexer.isIdentifierStart(c) || SQLLexer.isDigit(c) || c == 36 || c == 34 || c == 96 else { break }
                qualifierStart -= 1
            }
            let qualifier = before.substring(with: NSRange(location: qualifierStart, length: prefixStart - 1 - qualifierStart))
                .trimmingCharacters(in: CharacterSet(charactersIn: "`\""))
            guard let catalog, !qualifier.isEmpty else { return [] }
            var items: [CompletionItem] = []
            let reference = references.first { $0.alias?.lowercased() == qualifier.lowercased() || $0.table.lowercased() == qualifier.lowercased() }
            if let table = reference.flatMap({ catalog.table(named: $0.table, schema: $0.schema) }) ?? catalog.table(named: qualifier) {
                items += table.columns.map { item($0.name, $0.type, Kind.column, insert: dialect.quote($0.name), sort: "0" + $0.name) }
            }
            if let schema = catalog.schemas.first(where: { $0.name.lowercased() == qualifier.lowercased() }) {
                items += schema.tables.map {
                    item($0.name, $0.kind == .view ? "View" : "Table", $0.kind == .view ? Kind.view : Kind.table,
                         insert: dialect.quote($0.name), sort: "1" + $0.name)
                }
            }
            return items
        }
        let prefix = before.substring(from: prefixStart)
        guard !prefix.isEmpty else { return [] }
        var items: [CompletionItem] = []
        var seen = Set<String>()
        if let catalog {
            for reference in references {
                guard let table = catalog.table(named: reference.table, schema: reference.schema) else { continue }
                for column in table.columns where seen.insert("c:" + column.name).inserted {
                    items.append(item(column.name, "\(column.type) — \(table.name)", Kind.column, insert: dialect.quote(column.name),
                                      sort: "0" + column.name))
                }
            }
            for table in catalog.allTables {
                let label = table.schema == catalog.defaultSchema || dialect == .sqlite ? table.name : table.schema + "." + table.name
                guard seen.insert("t:" + label).inserted else { continue }
                items.append(item(label, (table.kind == .view ? "View" : "Table") + " in \(table.schema)",
                                  table.kind == .view ? Kind.view : Kind.table,
                                  insert: dialect.qualified(table, defaultSchema: dialect == .sqlite ? table.schema : catalog.defaultSchema),
                                  sort: "1" + table.name))
            }
            for schema in catalog.schemas where schema.name != catalog.defaultSchema && seen.insert("s:" + schema.name).inserted {
                items.append(item(schema.name, "Schema", Kind.schema, insert: dialect.quote(schema.name), sort: "2" + schema.name))
            }
        }
        // Keywords in the case being typed.
        let lowercase = prefix.first.map { $0.isLowercase } ?? false
        for keyword in SQLKeywords.all {
            let label = lowercase ? keyword.lowercased() : keyword
            items.append(item(label, "Keyword", Kind.keyword, sort: "3" + keyword))
        }
        for function in SQLKeywords.functions {
            let label = lowercase ? function.lowercased() : function
            items.append(item(label, "Function", Kind.function, sort: "4" + function))
        }
        let lowerPrefix = prefix.lowercased()
        return items.filter { $0.filterText.lowercased().hasPrefix(lowerPrefix) || $0.label.lowercased().contains("." + lowerPrefix) }
    }
}
