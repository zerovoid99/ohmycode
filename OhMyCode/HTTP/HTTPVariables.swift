import Foundation

/// What system variables (`{{$guid}}`, `{{$datetime …}}`) read: injectable so tests get a
/// fixed clock, fixed random numbers and their own environment.
struct HTTPSystemContext: Sendable {
    var now: @Sendable () -> Date = { Date() }
    /// A number in `min..<max`.
    var randomInt: @Sendable (Int, Int) -> Int = { Int.random(in: $0..<$1) }
    var uuid: @Sendable () -> String = { UUID().uuidString.lowercased() }
    var processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    /// The `.env` file's values (next to the `.http` file, else in its folder).
    var dotenv: [String: String] = [:]
    /// For `$localDatetime`.
    var timeZone: TimeZone = .current
}

/// A request sent earlier and its response: what `{{name.response.body.$.x}}` and
/// `{{name.request.headers.X}}` read.
struct HTTPExchangeRecord: Sendable, Equatable {
    var requestHeaders: [HTTPHeader]
    var requestBody: Data?
    var statusCode: Int
    var responseHeaders: [HTTPHeader]
    var responseBody: Data
}

enum HTTPVariableError: LocalizedError, Equatable {
    case unknown(String)
    case notSent(String)
    case badReference(String, String)
    case cycle(String)
    case badSystemVariable(String, String)

    var errorDescription: String? {
        switch self {
        case .unknown(let name): "Unknown variable “\(name)”."
        case .notSent(let name): "The request “\(name)” hasn't been sent yet: send it first, then this one."
        case .badReference(let reference, let why): "“\(reference)”: \(why)"
        case .cycle(let name): "The variable “\(name)” refers to itself."
        case .badSystemVariable(let variable, let why): "“{{\(variable)}}”: \(why)"
        }
    }
}

/// Replaces `{{…}}` in request text: prompt answers, request variables, file variables, the
/// environment's, and system variables (`$guid`, `$randomInt`, `$timestamp`, `$datetime`,
/// `$localDatetime`, `$processEnv`, `$dotenv`). Values may refer to other variables.
struct HTTPVariableResolver: Sendable {
    var fileVariables: [String: String] = [:]
    var environment: [String: String] = [:]
    var prompts: [String: String] = [:]
    /// Sent requests by name.
    var exchanges: [String: HTTPExchangeRecord] = [:]
    /// Names of the file's requests (to tell "not sent yet" from "unknown").
    var requestNames: Set<String> = []
    var system = HTTPSystemContext()

    static let systemNames: Set<String> = ["$guid", "$uuid", "$randomInt", "$timestamp", "$isoTimestamp", "$datetime",
                                           "$localDatetime", "$processEnv", "$dotenv"]
    private static let maxDepth = 16

    /// `{{ name }}` occurrences in a line or text: what's inside each, trimmed, and where (UTF-16).
    static func references(in text: String) -> [(name: String, range: NSRange)] {
        let string = text as NSString
        var result: [(String, NSRange)] = []
        var position = 0
        while position < string.length {
            let open = string.range(of: "{{", options: .literal, range: NSRange(location: position, length: string.length - position))
            guard open.location != NSNotFound else { break }
            let rest = NSMaxRange(open)
            let close = string.range(of: "}}", options: .literal, range: NSRange(location: rest, length: string.length - rest))
            guard close.location != NSNotFound else { break }
            let inside = string.substring(with: NSRange(location: rest, length: close.location - rest))
                .trimmingCharacters(in: .whitespaces)
            result.append((inside, NSRange(location: open.location, length: NSMaxRange(close) - open.location)))
            position = NSMaxRange(close)
        }
        return result
    }

    func resolve(_ text: String) throws -> String {
        try resolve(text, depth: 0, seen: [])
    }

    private func resolve(_ text: String, depth: Int, seen: Set<String>) throws -> String {
        let references = Self.references(in: text)
        guard !references.isEmpty else { return text }
        let string = text as NSString
        var result = ""
        var position = 0
        for (name, range) in references {
            result += string.substring(with: NSRange(location: position, length: range.location - position))
            result += try value(of: name, depth: depth, seen: seen)
            position = NSMaxRange(range)
        }
        result += string.substring(from: position)
        return result
    }

    private func value(of expression: String, depth: Int, seen: Set<String>) throws -> String {
        guard depth < Self.maxDepth, !seen.contains(expression) else { throw HTTPVariableError.cycle(expression) }
        if expression.hasPrefix("$") { return try systemValue(expression) }
        if let answer = prompts[expression] { return answer }
        if let reference = Self.requestReference(expression) { return try requestValue(reference, expression: expression) }
        let seen = seen.union([expression])
        if let raw = fileVariables[expression] { return try resolve(raw, depth: depth + 1, seen: seen) }
        if let raw = environment[expression] { return try resolve(raw, depth: depth + 1, seen: seen) }
        throw HTTPVariableError.unknown(expression)
    }

    /// Whether `{{expression}}` can be filled in without sending anything (diagnostics): a known
    /// name, a system variable, or a reference to a request of the file.
    func isDefined(_ expression: String, prompts promptNames: Set<String> = []) -> Bool {
        if expression.hasPrefix("$") {
            let name = expression.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? expression
            return Self.systemNames.contains(name)
        }
        if promptNames.contains(expression) || prompts[expression] != nil { return true }
        if let reference = Self.requestReference(expression) {
            return requestNames.contains(reference.request) || exchanges[reference.request] != nil
        }
        return fileVariables[expression] != nil || environment[expression] != nil
    }

    // MARK: Request variables

    struct RequestReference: Equatable {
        var request: String
        var isResponse: Bool
        var isBody: Bool
        /// `*`, a JSONPath (`$.a[0].b`) or a header name.
        var path: String
    }

    /// `name.response.body.$.x`, `name.response.headers.X`, `name.request.body.*`, …
    static func requestReference(_ expression: String) -> RequestReference? {
        let parts = expression.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, !parts[0].isEmpty, parts[1] == "response" || parts[1] == "request",
              parts[2] == "body" || parts[2] == "headers" else { return nil }
        return RequestReference(request: parts[0], isResponse: parts[1] == "response", isBody: parts[2] == "body", path: parts[3])
    }

    private func requestValue(_ reference: RequestReference, expression: String) throws -> String {
        guard let exchange = exchanges[reference.request] else {
            throw requestNames.contains(reference.request) ? HTTPVariableError.notSent(reference.request)
                                                          : HTTPVariableError.unknown(expression)
        }
        if !reference.isBody {
            let headers = reference.isResponse ? exchange.responseHeaders : exchange.requestHeaders
            guard let value = headers.value(for: reference.path) else {
                throw HTTPVariableError.badReference(expression, "there's no header “\(reference.path)”.")
            }
            return value
        }
        let body = reference.isResponse ? exchange.responseBody : (exchange.requestBody ?? Data())
        if reference.path == "*" { return String(decoding: body, as: UTF8.self) }
        guard reference.path.hasPrefix("$") else {
            throw HTTPVariableError.badReference(expression, "only JSONPath (“$.a.b[0]”) and “*” are supported.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            throw HTTPVariableError.badReference(expression, "the body isn't JSON.")
        }
        guard let value = try JSONPath.evaluate(reference.path, in: json) else {
            throw HTTPVariableError.badReference(expression, "nothing at “\(reference.path)”.")
        }
        return JSONPath.string(value)
    }

    // MARK: System variables

    /// A system variable's arguments: words, or quoted strings (either quote).
    static func arguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken { result.append(current); current = ""; hasToken = false }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }

    private func systemValue(_ expression: String) throws -> String {
        let arguments = Self.arguments(expression)
        guard let name = arguments.first else { throw HTTPVariableError.unknown(expression) }
        let rest = Array(arguments.dropFirst())
        func fail(_ why: String) -> HTTPVariableError { .badSystemVariable(expression, why) }
        switch name {
        case "$guid", "$uuid":
            return system.uuid()
        case "$randomInt":
            guard rest.count == 2, let low = Int(rest[0]), let high = Int(rest[1]) else { throw fail("expected “$randomInt min max”.") }
            guard high > low else { throw fail("max must be greater than min.") }
            return String(system.randomInt(low, high))
        case "$timestamp":
            let date = try Self.offset(system.now(), rest, timeZone: TimeZone(identifier: "UTC")!, fail: fail)
            return String(Int(date.timeIntervalSince1970.rounded(.down)))
        case "$isoTimestamp":
            return Self.format(system.now(), "iso8601", timeZone: TimeZone(identifier: "UTC")!, utc: true)
        case "$datetime", "$localDatetime":
            guard let format = rest.first else { throw fail("expected a format: rfc1123, iso8601 or a quoted one.") }
            let zone = name == "$datetime" ? TimeZone(identifier: "UTC")! : system.timeZone
            let date = try Self.offset(system.now(), Array(rest.dropFirst()), timeZone: zone, fail: fail)
            return Self.format(date, format, timeZone: zone, utc: name == "$datetime")
        case "$processEnv":
            guard let variable = rest.first else { throw fail("expected an environment variable's name.") }
            let key = try indirect(variable, expression: expression)
            guard let value = system.processEnvironment[key] else { throw fail("the environment variable “\(key)” isn't set.") }
            return value
        case "$dotenv":
            guard let variable = rest.first else { throw fail("expected a name from the .env file.") }
            let key = try indirect(variable, expression: expression)
            guard let value = system.dotenv[key] else { throw fail("“\(key)” isn't in a .env file next to the request file.") }
            return value
        default:
            throw HTTPVariableError.unknown(expression)
        }
    }

    /// `%name`: the name is the value of an environment variable of the selected environment.
    private func indirect(_ name: String, expression: String) throws -> String {
        guard name.hasPrefix("%") else { return name }
        let key = String(name.dropFirst())
        guard let raw = environment[key] else { throw HTTPVariableError.unknown(key) }
        return try resolve(raw, depth: 1, seen: [expression])
    }

    /// `now` moved by `[offset unit]` (units: y, M, w, d, h, m, s, ms).
    static func offset(_ date: Date, _ arguments: [String], timeZone: TimeZone,
                       fail: (String) -> HTTPVariableError) throws -> Date {
        guard !arguments.isEmpty else { return date }
        guard arguments.count == 2, let amount = Int(arguments[0]) else { throw fail("expected an offset and a unit (“1 d”).") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let component: Calendar.Component
        var value = amount
        switch arguments[1] {
        case "y": component = .year
        case "M": component = .month
        case "w": component = .day; value *= 7
        case "d": component = .day
        case "h": component = .hour
        case "m": component = .minute
        case "s": component = .second
        case "ms": return date.addingTimeInterval(Double(amount) / 1000)
        default: throw fail("unknown unit “\(arguments[1])” (y, M, w, d, h, m, s, ms).")
        }
        return calendar.date(byAdding: component, value: value, to: date) ?? date
    }

    /// rfc1123, iso8601, or a Day.js-style format (`YYYY-MM-DD HH:mm:ss`).
    static func format(_ date: Date, _ format: String, timeZone: TimeZone, utc isUTC: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        switch format.lowercased() {
        case "rfc1123":
            formatter.dateFormat = isUTC ? "EEE, dd MMM yyyy HH:mm:ss 'GMT'" : "EEE, dd MMM yyyy HH:mm:ss xx"
        case "iso8601":
            formatter.dateFormat = isUTC ? "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'" : "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
        default:
            if format == "X" { return String(Int(date.timeIntervalSince1970)) }
            if format == "x" { return String(Int(date.timeIntervalSince1970 * 1000)) }
            formatter.dateFormat = dateFormat(fromDayJS: format)
        }
        return formatter.string(from: date)
    }

    /// Day.js format tokens as a DateFormatter pattern; other letters are kept as text, and
    /// `[text]` is literal.
    static func dateFormat(fromDayJS format: String) -> String {
        let tokens: [(String, String)] = [
            ("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
            ("DD", "dd"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"), ("dd", "EEEEEE"),
            ("HH", "HH"), ("H", "H"), ("hh", "hh"), ("h", "h"), ("mm", "mm"), ("m", "m"),
            ("ss", "ss"), ("s", "s"), ("SSS", "SSS"), ("A", "a"), ("a", "a"), ("ZZ", "xx"), ("Z", "xxx"),
        ]
        var result = ""
        var literal = ""
        func flush() {
            guard !literal.isEmpty else { return }
            result += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
            literal = ""
        }
        var rest = Substring(format)
        outer: while let first = rest.first {
            if first == "[", let close = rest.firstIndex(of: "]") {
                literal += rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                continue
            }
            for (token, pattern) in tokens where rest.hasPrefix(token) {
                flush()
                result += pattern
                rest = rest.dropFirst(token.count)
                continue outer
            }
            literal.append(first)
            rest = rest.dropFirst()
        }
        flush()
        return result
    }
}

/// The JSONPath that request variables use: `$`, `.key`, `['key']`, `[index]`.
enum JSONPath {
    enum Step: Equatable { case key(String), index(Int) }

    static func steps(_ path: String) throws -> [Step] {
        guard path.hasPrefix("$") else { throw HTTPVariableError.badReference(path, "a JSONPath starts with “$”.") }
        var steps: [Step] = []
        var rest = path.dropFirst()
        while let first = rest.first {
            if first == "." {
                rest = rest.dropFirst()
                let key = rest.prefix { $0 != "." && $0 != "[" }
                guard !key.isEmpty else { throw HTTPVariableError.badReference(path, "expected a name after “.”.") }
                steps.append(.key(String(key)))
                rest = rest.dropFirst(key.count)
            } else if first == "[" {
                guard let close = rest.firstIndex(of: "]") else { throw HTTPVariableError.badReference(path, "“[” isn't closed.") }
                let inside = rest[rest.index(after: rest.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                if let index = Int(inside) {
                    steps.append(.index(index))
                } else if inside.count >= 2, let quote = inside.first, quote == "'" || quote == "\"", inside.last == quote {
                    steps.append(.key(String(inside.dropFirst().dropLast())))
                } else {
                    throw HTTPVariableError.badReference(path, "expected an index or a quoted name in “[…]”.")
                }
                rest = rest[rest.index(after: close)...]
            } else {
                throw HTTPVariableError.badReference(path, "unexpected “\(first)”.")
            }
        }
        return steps
    }

    /// The value at `path` (nil when there's nothing there).
    static func evaluate(_ path: String, in json: Any) throws -> Any? {
        var current: Any = json
        for step in try steps(path) {
            switch step {
            case .key(let key):
                guard let object = current as? [String: Any], let next = object[key] else { return nil }
                current = next
            case .index(let index):
                guard let array = current as? [Any] else { return nil }
                let position = index < 0 ? array.count + index : index
                guard array.indices.contains(position) else { return nil }
                current = array[position]
            }
        }
        return current
    }

    /// A JSON value as text: strings as they are, other values as JSON.
    static func string(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case is NSNull: return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "\(value)" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
