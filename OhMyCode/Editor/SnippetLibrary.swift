import Foundation

/// A snippet that can be inserted (by its prefix, from completion or Insert Snippet…).
struct SnippetDefinition: Equatable, Sendable {
    var name: String
    var prefixes: [String]
    var body: String
    var description: String?
    /// Where it's defined: "Built-in", "User" or the file's name.
    var source: String
}

/// The snippets for a language: the built-in ones, the user's (VS Code format, in
/// ~/Library/Application Support/OhMyCode/Snippets: `<language>.json`, or `*.code-snippets`
/// with an optional "scope") and the folder's (`.omc/snippets/` and `.vscode/*.code-snippets`).
/// User and folder snippets with a built-in's prefix replace it.
final class SnippetLibrary: @unchecked Sendable {
    static let shared = SnippetLibrary()

    let userDirectory: URL
    private let lock = NSLock()
    /// Parsed files, kept while their modification date is the same.
    private var cache: [String: (date: Date, snippets: [(SnippetDefinition, scope: Set<String>?)])] = [:]

    init(userDirectory: URL = URL.applicationSupportDirectory.appending(path: "OhMyCode/Snippets")) {
        self.userDirectory = userDirectory
    }

    func snippets(for languageId: String, root: URL?) -> [SnippetDefinition] {
        var files: [(url: URL, source: String, language: String?)] = []
        func add(_ directory: URL, source: String?, languageFiles: Bool) {
            let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                switch url.pathExtension {
                case "code-snippets": files.append((url, source ?? url.lastPathComponent, nil))
                case "json" where languageFiles && url.deletingPathExtension().lastPathComponent == languageId:
                    files.append((url, source ?? url.lastPathComponent, languageId))
                default: break
                }
            }
        }
        add(userDirectory, source: "User", languageFiles: true)
        if let root {
            add(root.appending(path: ".omc/snippets"), source: nil, languageFiles: true)
            add(root.appending(path: ".vscode"), source: nil, languageFiles: false)
        }
        var custom: [SnippetDefinition] = []
        for file in files {
            for (snippet, scope) in load(file.url, source: file.source) {
                if let scope, !scope.contains(languageId) { continue }
                custom.append(snippet)
            }
        }
        let taken = Set(custom.flatMap(\.prefixes))
        let builtIn = (Self.builtIn[languageId] ?? []).filter { taken.isDisjoint(with: $0.prefixes) }
        return custom + builtIn
    }

    private func load(_ url: URL, source: String) -> [(SnippetDefinition, scope: Set<String>?)] {
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        lock.lock()
        if let cached = cache[url.path], cached.date == date { lock.unlock(); return cached.snippets }
        lock.unlock()
        let snippets = Self.parse((try? Data(contentsOf: url)) ?? Data(), source: source)
        lock.lock()
        cache[url.path] = (date, snippets)
        lock.unlock()
        return snippets
    }

    /// A VS Code snippets file: `{ "Name": { "prefix": "p" or [...], "body": "…" or [lines], "description": "…", "scope": "a,b" } }`.
    static func parse(_ data: Data, source: String) -> [(SnippetDefinition, scope: Set<String>?)] {
        let text = VSCodeTheme.stripJSONC(String(decoding: data, as: UTF8.self))
        guard let object = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))?.object else { return [] }
        return object.keys.sorted().compactMap { name in
            guard let entry = object[name] else { return nil }
            let prefixes = entry["prefix"]?.string.map { [$0] } ?? entry["prefix"]?.array?.compactMap(\.string) ?? []
            let body = entry["body"]?.string ?? entry["body"]?.array?.compactMap(\.string).joined(separator: "\n")
            guard !prefixes.isEmpty, let body else { return nil }
            let description = entry["description"]?.string ?? entry["description"]?.array?.compactMap(\.string).joined(separator: "\n")
            let scope = entry["scope"]?.string.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
            return (SnippetDefinition(name: name, prefixes: prefixes, body: body, description: description, source: source), scope)
        }
    }

    /// The user's snippets file for a language (written with an example first), for editing.
    func userFile(for languageId: String) throws -> URL {
        let url = userDirectory.appending(path: "\(languageId).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let text = """
        {
          // Snippets for \(languageId) files: type the prefix, then Tab (or pick it from completion).
          // $1, $2… are where Tab goes next, ${1:text} has a default, $0 is where the cursor ends;
          // $TM_FILENAME, $TM_SELECTED_TEXT, $CURRENT_YEAR, $CLIPBOARD and others are filled in.
          // "Print": {
          //   "prefix": "log",
          //   "body": ["print(\\"$1\\")", "$0"],
          //   "description": "Print a value"
          // }
        }

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Built-in

    private static func make(_ list: [(String, String, String)]) -> [SnippetDefinition] {
        list.map { SnippetDefinition(name: $0.1, prefixes: [$0.0], body: $0.2, description: $0.1, source: "Built-in") }
    }

    private static let cFamily: [(String, String, String)] = [
        ("for", "For loop", "for (${1:int} ${2:i} = 0; $2 < ${3:count}; $2++) {\n\t$0\n}"),
        ("if", "If statement", "if (${1:condition}) {\n\t$0\n}"),
        ("ifelse", "If-else statement", "if (${1:condition}) {\n\t$2\n} else {\n\t$0\n}"),
        ("while", "While loop", "while (${1:condition}) {\n\t$0\n}"),
        ("switch", "Switch statement", "switch (${1:value}) {\ncase ${2:0}:\n\t$0\n\tbreak;\ndefault:\n\tbreak;\n}"),
        ("main", "Main function", "int main(int argc, char *argv[]) {\n\t$0\n\treturn 0;\n}"),
        ("inc", "#include", "#include <${1:stdio.h}>"),
        ("struct", "Struct", "typedef struct ${1:Name} {\n\t$0\n} $1;"),
    ]

    private static let javaScript: [(String, String, String)] = [
        ("log", "Console log", "console.log($1);$0"),
        ("fn", "Function", "function ${1:name}(${2:params}) {\n\t$0\n}"),
        ("afn", "Arrow function", "const ${1:name} = (${2:params}) => {\n\t$0\n};"),
        ("for", "For loop", "for (let ${1:i} = 0; $1 < ${2:array}.length; $1++) {\n\tconst ${3:element} = $2[$1];\n\t$0\n}"),
        ("forof", "For-of loop", "for (const ${1:item} of ${2:items}) {\n\t$0\n}"),
        ("if", "If statement", "if (${1:condition}) {\n\t$0\n}"),
        ("try", "Try-catch", "try {\n\t$1\n} catch (${2:error}) {\n\t$0\n}"),
        ("class", "Class", "class ${1:Name} {\n\tconstructor(${2:params}) {\n\t\t$0\n\t}\n}"),
        ("imp", "Import", "import { $2 } from '${1:module}';$0"),
        ("af", "Async function", "async function ${1:name}(${2:params}) {\n\t$0\n}"),
    ]

    static let builtIn: [String: [SnippetDefinition]] = {
        var table: [String: [SnippetDefinition]] = [
            "swift": make([
                ("func", "Function", "func ${1:name}(${2:}) ${3:-> ${4:Void} }{\n\t$0\n}"),
                ("if", "If statement", "if ${1:condition} {\n\t$0\n}"),
                ("iflet", "If let", "if let ${1:value} = ${2:optional} {\n\t$0\n}"),
                ("guard", "Guard", "guard ${1:condition} else {\n\t${2:return}\n}$0"),
                ("for", "For-in loop", "for ${1:item} in ${2:items} {\n\t$0\n}"),
                ("switch", "Switch", "switch ${1:value} {\ncase ${2:pattern}:\n\t$3\ndefault:\n\t$0\n}"),
                ("struct", "Struct", "struct ${1:Name} {\n\t$0\n}"),
                ("class", "Class", "final class ${1:Name} {\n\tinit(${2:}) {\n\t\t$0\n\t}\n}"),
                ("enum", "Enum", "enum ${1:Name} {\n\tcase ${2:first}\n\t$0\n}"),
                ("ext", "Extension", "extension ${1:Type} {\n\t$0\n}"),
                ("init", "Initializer", "init(${1:}) {\n\t$0\n}"),
                ("do", "Do-catch", "do {\n\t${1:try }\n} catch {\n\t$0\n}"),
                ("test", "Test function", "@Test func ${1:name}() ${2:async throws }{\n\t$0\n}"),
                ("mark", "MARK comment", "// MARK: ${1:Section}"),
                ("view", "SwiftUI view", "struct ${1:Name}: View {\n\tvar body: some View {\n\t\t${0:Text(\"$1\")}\n\t}\n}"),
            ]),
            "python": make([
                ("def", "Function", "def ${1:name}(${2:}):\n\t${0:pass}"),
                ("class", "Class", "class ${1:Name}:\n\tdef __init__(self${2:}):\n\t\t${0:pass}"),
                ("if", "If statement", "if ${1:condition}:\n\t${0:pass}"),
                ("for", "For loop", "for ${1:item} in ${2:items}:\n\t${0:pass}"),
                ("while", "While loop", "while ${1:condition}:\n\t${0:pass}"),
                ("try", "Try-except", "try:\n\t${1:pass}\nexcept ${2:Exception} as ${3:error}:\n\t${0:raise}"),
                ("with", "With statement", "with ${1:expression} as ${2:name}:\n\t${0:pass}"),
                ("main", "Main guard", "if __name__ == \"__main__\":\n\t${0:main()}"),
                ("pr", "Print", "print($1)$0"),
            ]),
            "rust": make([
                ("fn", "Function", "fn ${1:name}(${2:}) ${3:-> ${4:()} }{\n\t$0\n}"),
                ("struct", "Struct", "struct ${1:Name} {\n\t$0\n}"),
                ("impl", "Impl block", "impl ${1:Type} {\n\t$0\n}"),
                ("match", "Match", "match ${1:value} {\n\t${2:pattern} => $3,\n\t_ => $0,\n}"),
                ("for", "For loop", "for ${1:item} in ${2:items} {\n\t$0\n}"),
                ("if", "If statement", "if ${1:condition} {\n\t$0\n}"),
                ("test", "Test", "#[test]\nfn ${1:name}() {\n\t$0\n}"),
                ("println", "println!", "println!(\"${1:{\\}}\", $2);$0"),
            ]),
            "go": make([
                ("func", "Function", "func ${1:name}(${2:}) ${3:error }{\n\t$0\n}"),
                ("iferr", "If error", "if err != nil {\n\treturn ${1:err}\n}$0"),
                ("for", "For loop", "for ${1:i} := 0; $1 < ${2:n}; $1++ {\n\t$0\n}"),
                ("forr", "For range", "for ${1:_}, ${2:v} := range ${3:items} {\n\t$0\n}"),
                ("struct", "Struct", "type ${1:Name} struct {\n\t$0\n}"),
                ("test", "Test", "func Test${1:Name}(t *testing.T) {\n\t$0\n}"),
                ("pf", "fmt.Printf", "fmt.Printf(\"${1:%v}\\n\", $2)$0"),
            ]),
            "c": make(cFamily),
            "cpp": make(cFamily + [
                ("class", "Class", "class ${1:Name} {\npublic:\n\t$1();\n\t$0\n};"),
                ("cout", "std::cout", "std::cout << $1 << std::endl;$0"),
            ]),
            "objective-c": make(cFamily),
            "javascript": make(javaScript),
            "typescript": make(javaScript + [
                ("intf", "Interface", "interface ${1:Name} {\n\t$0\n}"),
                ("type", "Type alias", "type ${1:Name} = $0;"),
            ]),
            "shellscript": make([
                ("if", "If statement", "if [ ${1:condition} ]; then\n\t$0\nfi"),
                ("for", "For loop", "for ${1:item} in ${2:items}; do\n\t$0\ndone"),
                ("fn", "Function", "${1:name}() {\n\t$0\n}"),
                ("shebang", "Shebang", "#!/usr/bin/env ${1:bash}\nset -euo pipefail\n$0"),
            ]),
            "markdown": make([
                ("link", "Link", "[${1:text}](${2:https://})$0"),
                ("img", "Image", "![${1:alt}](${2:path})$0"),
                ("code", "Code block", "```${1:language}\n$0\n```"),
                ("table", "Table", "| ${1:Column} | ${2:Column} |\n| --- | --- |\n| $3 | $4 |$0"),
                ("task", "Task list item", "- [ ] ${0:task}"),
            ]),
            "html": make([
                ("html5", "HTML document", "<!doctype html>\n<html lang=\"${1:en}\">\n<head>\n\t<meta charset=\"utf-8\">\n\t<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\t<title>${2:Title}</title>\n</head>\n<body>\n\t$0\n</body>\n</html>"),
                ("div", "div", "<div${1: class=\"$2\"}>$0</div>"),
                ("a", "Link", "<a href=\"${1:#}\">$0</a>"),
            ]),
        ]
        table["typescriptreact"] = table["typescript"]
        return table
    }()
}
