#!/usr/bin/env python3
"""Minimal LSP server for tests. Mirrors documents from incremental changes (UTF-16
positions), reports a diagnostic for every "BAD", and answers completion/definition."""
import json, os, re, sys
from urllib.parse import unquote, urlparse, quote

docs = {}
root = None

def read():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        line = line.decode().strip()
        if not line:
            break
        if line.lower().startswith("content-length:"):
            length = int(line.split(":")[1])
    return json.loads(sys.stdin.buffer.read(length))

def send(message):
    body = json.dumps(message).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()

def units(text):  # UTF-16 code units
    data = text.encode("utf-16-le")
    return [data[i:i + 2] for i in range(0, len(data), 2)]

def offset(u, pos):
    line, col, i = 0, 0, 0
    while i < len(u) and line < pos["line"]:
        if u[i] == b"\n\x00":
            line += 1
        i += 1
    return i + pos["character"]

def apply(text, change):
    if "range" not in change:
        return change["text"]
    u = units(text)
    start, end = offset(u, change["range"]["start"]), offset(u, change["range"]["end"])
    u[start:end] = units(change["text"])
    return b"".join(u).decode("utf-16-le")

def publish(uri):
    text = docs[uri]
    diagnostics = []
    for line_no, line in enumerate(text.split("\n")):
        col = line.find("BAD")
        while col != -1:
            col16 = len(units(line[:col]))
            diagnostics.append({"range": {"start": {"line": line_no, "character": col16},
                                          "end": {"line": line_no, "character": col16 + 3}},
                                "severity": 1, "message": "BAD is not allowed", "source": "fake"})
            col = line.find("BAD", col + 1)
    send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
          "params": {"uri": uri, "diagnostics": diagnostics}})

def path_of(uri):
    return unquote(urlparse(uri).path)

def text_of(uri):
    if uri in docs:
        return docs[uri]
    with open(path_of(uri), encoding="utf-8") as f:
        return f.read()

def word_at(uri, pos):
    line = text_of(uri).split("\n")[pos["line"]]
    u = units(line)
    # back to str index from UTF-16 column
    col = len(b"".join(u[:pos["character"]]).decode("utf-16-le"))
    for m in re.finditer(r"\w+", line):
        if m.start() <= col <= m.end():
            start16 = len(units(line[:m.start()]))
            return m.group(), {"start": {"line": pos["line"], "character": start16},
                               "end": {"line": pos["line"], "character": start16 + len(units(m.group()))}}
    return None, None

def all_uris():
    uris = set(docs)
    for dirpath, _, files in os.walk(root):
        for name in files:
            if name.endswith(".swift"):
                uris.add("file://" + quote(os.path.join(dirpath, name)))
    # Prefer the open documents' spelling of each path.
    by_path = {}
    for uri in sorted(uris, key=lambda u: u not in docs):
        by_path.setdefault(os.path.realpath(path_of(uri)), uri)
    return sorted(by_path.values())

def functions():
    """Every "func NAME(...) { body }" line: name -> (uri, line number, line)."""
    found = {}
    for uri in all_uris():
        for number, line in enumerate(text_of(uri).split("\n")):
            m = re.match(r"func (\w+)", line)
            if m:
                found.setdefault(m.group(1), (uri, number, line))
    return found

def item(name, uri, number, line):
    start = len(units(line[:line.index(name)]))
    return {"name": name, "kind": 12, "uri": uri, "detail": "fake",
            "range": {"start": {"line": number, "character": 0}, "end": {"line": number, "character": len(units(line))}},
            "selectionRange": {"start": {"line": number, "character": start}, "end": {"line": number, "character": start + len(units(name))}}}

def calls_in(line, name):
    """Ranges of "name(" calls in a function's body (after its "{")."""
    body_start = line.find("{")
    result = []
    if body_start < 0:
        return result
    for m in re.finditer(r"\b%s\(" % re.escape(name), line[body_start:]):
        start = len(units(line[:body_start + m.start()]))
        result.append(start)
    return result

def occurrences(word):
    result = []
    for uri in all_uris():
        for line_no, line in enumerate(text_of(uri).split("\n")):
            for m in re.finditer(r"\b%s\b" % re.escape(word), line):
                start16 = len(units(line[:m.start()]))
                result.append((uri, {"start": {"line": line_no, "character": start16},
                                     "end": {"line": line_no, "character": start16 + len(units(word))}}))
    return result

while True:
    msg = read()
    method, mid, params = msg.get("method"), msg.get("id"), msg.get("params", {})
    if method is None:
        continue  # the client answering our own request (workspace/applyEdit)
    if method == "initialize":
        root = path_of(params["rootUri"])
        send({"jsonrpc": "2.0", "id": mid, "result": {"capabilities": {
            "textDocumentSync": 2, "completionProvider": {"triggerCharacters": ["."]}, "definitionProvider": True,
            "hoverProvider": True, "referencesProvider": True, "renameProvider": {"prepareProvider": True},
            "documentFormattingProvider": True, "documentSymbolProvider": True,
            "implementationProvider": True, "typeDefinitionProvider": True, "callHierarchyProvider": True,
            "workspaceSymbolProvider": True, "codeActionProvider": {"resolveProvider": True},
            "signatureHelpProvider": {"triggerCharacters": ["("], "retriggerCharacters": [","]}}}})
    elif method == "textDocument/hover":
        word, rng = word_at(params["textDocument"]["uri"], params["position"])
        result = None
        if word and word != "nohover":
            result = {"range": rng, "contents": {"kind": "markdown",
                      "value": "```swift\nlet %s: Int\n```\n---\nDocs for **%s**." % (word, word)}}
        send({"jsonrpc": "2.0", "id": mid, "result": result})
    elif method == "textDocument/references":
        word, _ = word_at(params["textDocument"]["uri"], params["position"])
        send({"jsonrpc": "2.0", "id": mid, "result": [{"uri": u, "range": r} for u, r in occurrences(word)] if word else []})
    elif method == "textDocument/prepareRename":
        word, rng = word_at(params["textDocument"]["uri"], params["position"])
        send({"jsonrpc": "2.0", "id": mid, "result": {"range": rng, "placeholder": word} if word and not word[0].isdigit() else None})
    elif method == "textDocument/rename":
        word, _ = word_at(params["textDocument"]["uri"], params["position"])
        by_uri = {}
        for u, r in occurrences(word):
            by_uri.setdefault(u, []).append({"range": r, "newText": params["newName"]})
        # Open documents as documentChanges, the rest in the same list: both shapes are parsed.
        send({"jsonrpc": "2.0", "id": mid, "result": {"documentChanges": [
            {"textDocument": {"uri": u, "version": None}, "edits": e} for u, e in by_uri.items()]}})
    elif method == "textDocument/formatting":
        if "SLOW" in docs[params["textDocument"]["uri"]]:
            import time
            time.sleep(1.0)
        # Trims trailing whitespace and re-indents tab-indented lines with the requested spaces.
        uri = params["textDocument"]["uri"]
        edits = []
        indent = " " * params["options"]["tabSize"]
        for line_no, line in enumerate(docs[uri].split("\n")):
            stripped = line.rstrip(" \t")
            if len(stripped) != len(line):
                edits.append({"range": {"start": {"line": line_no, "character": len(units(stripped))},
                                        "end": {"line": line_no, "character": len(units(line))}}, "newText": ""})
            tabs = len(line) - len(line.lstrip("\t"))
            if tabs and params["options"]["insertSpaces"]:
                edits.append({"range": {"start": {"line": line_no, "character": 0},
                                        "end": {"line": line_no, "character": tabs}}, "newText": indent * tabs})
        send({"jsonrpc": "2.0", "id": mid, "result": edits})
    elif method == "textDocument/didOpen":
        doc = params["textDocument"]
        docs[doc["uri"]] = doc["text"]
        publish(doc["uri"])
    elif method == "textDocument/didChange":
        uri = params["textDocument"]["uri"]
        for change in params["contentChanges"]:
            docs[uri] = apply(docs[uri], change)
        publish(uri)
    elif method == "textDocument/completion":
        send({"jsonrpc": "2.0", "id": mid, "result": {"isIncomplete": False, "items": [
            {"label": "fooBar", "kind": 3, "detail": "(count: Int) -> Int", "insertTextFormat": 2,
             "insertText": "fooBar(${1:count})"},
            {"label": "fooBaz", "kind": 6, "detail": "String"},
            {"label": "other", "kind": 6}]}})
    elif method == "textDocument/definition":
        uri = params["textDocument"]["uri"]
        send({"jsonrpc": "2.0", "id": mid, "result": [{"uri": uri, "range": {
            "start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 10}}}]})
    elif method == "textDocument/documentSymbol":
        # "func NAME" lines, as DocumentSymbols (the name's range as the selection).
        symbols = []
        for number, line in enumerate(text_of(params["textDocument"]["uri"]).split("\n")):
            if line.startswith("func "):
                name = line[5:].split("(")[0].strip()
                symbols.append({"name": name, "detail": "fake", "kind": 12,
                    "range": {"start": {"line": number, "character": 0}, "end": {"line": number, "character": len(units(line))}},
                    "selectionRange": {"start": {"line": number, "character": 5}, "end": {"line": number, "character": 5 + len(name)}}})
        send({"jsonrpc": "2.0", "id": mid, "result": symbols})
    elif method in ("textDocument/implementation", "textDocument/typeDefinition"):
        word, _ = word_at(params["textDocument"]["uri"], params["position"])
        if method == "textDocument/typeDefinition":
            result = {"uri": params["textDocument"]["uri"], "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 4}}}
        else:  # every "func WORD" and "// implements WORD" line
            result = []
            for uri in all_uris():
                for number, line in enumerate(text_of(uri).split("\n")):
                    if word and ("implements " + word) in line:
                        result.append({"uri": uri, "range": {"start": {"line": number, "character": 0}, "end": {"line": number, "character": 1}}})
        send({"jsonrpc": "2.0", "id": mid, "result": result})
    elif method == "workspace/symbol":
        query = params["query"].lower()
        result = []
        for name, (uri, number, line) in sorted(functions().items()):
            if query in name.lower():
                result.append({"name": name, "kind": 12, "containerName": "fake",
                               "location": {"uri": uri, "range": item(name, uri, number, line)["selectionRange"]}})
        send({"jsonrpc": "2.0", "id": mid, "result": result})
    elif method == "textDocument/prepareCallHierarchy":
        word, _ = word_at(params["textDocument"]["uri"], params["position"])
        found = functions().get(word)
        send({"jsonrpc": "2.0", "id": mid, "result": [item(word, *found)] if found else None})
    elif method == "callHierarchy/incomingCalls":
        target = params["item"]["name"]
        result = []
        for name, (uri, number, line) in sorted(functions().items()):
            starts = calls_in(line, target) if name != target else []
            if starts:
                result.append({"from": item(name, uri, number, line), "fromRanges": [
                    {"start": {"line": number, "character": c}, "end": {"line": number, "character": c + len(units(target))}} for c in starts]})
        send({"jsonrpc": "2.0", "id": mid, "result": result})
    elif method == "callHierarchy/outgoingCalls":
        source = params["item"]["name"]
        everything = functions()
        uri, number, line = everything[source]
        result = []
        for name, (other_uri, other_number, other_line) in sorted(everything.items()):
            starts = calls_in(line, name) if name != source else []
            if starts:
                result.append({"to": item(name, other_uri, other_number, other_line), "fromRanges": [
                    {"start": {"line": number, "character": c}, "end": {"line": number, "character": c + len(units(name))}} for c in starts]})
        send({"jsonrpc": "2.0", "id": mid, "result": result})
    elif method == "textDocument/codeAction":
        uri = params["textDocument"]["uri"]
        actions = []
        for diagnostic in params["context"]["diagnostics"]:
            if diagnostic.get("source") == "fake":  # one of ours: its JSON came back as sent
                actions.append({"title": "Replace BAD with good", "kind": "quickfix", "isPreferred": True,
                                "diagnostics": [diagnostic],
                                "edit": {"changes": {uri: [{"range": diagnostic["range"], "newText": "good"}]}}})
        line = params["range"]["start"]["line"]
        actions.append({"title": "Add a comment above", "kind": "refactor.rewrite",
                        "command": {"title": "comment", "command": "fake.comment", "arguments": [uri, line]}})
        actions.append({"title": "Upper-case the line", "kind": "refactor.rewrite", "data": {"uri": uri, "line": line}})
        actions.append({"title": "Not now", "kind": "refactor", "disabled": {"reason": "fake says no"}})
        actions.append({"title": "Organize imports", "kind": "source.organizeImports",
                        "edit": {"changes": {uri: [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
                                                    "newText": "import Sorted\n"}]}}})
        only = params["context"].get("only")
        if only:
            actions = [a for a in actions if any(a["kind"].startswith(k) for k in only)]
        send({"jsonrpc": "2.0", "id": mid, "result": actions})
    elif method == "codeAction/resolve":
        action = dict(params)
        data = action.get("data") or {}
        text = text_of(data["uri"]).split("\n")[data["line"]]
        action["edit"] = {"changes": {data["uri"]: [{"range": {"start": {"line": data["line"], "character": 0},
                                                              "end": {"line": data["line"], "character": len(units(text))}},
                                                    "newText": text.upper()}]}}
        send({"jsonrpc": "2.0", "id": mid, "result": action})
    elif method == "workspace/executeCommand":
        uri, line = params["arguments"]
        # Changes files the way servers do: by asking the client.
        send({"jsonrpc": "2.0", "id": 90000 + line, "method": "workspace/applyEdit", "params": {"label": "Comment",
              "edit": {"changes": {uri: [{"range": {"start": {"line": line, "character": 0}, "end": {"line": line, "character": 0}},
                                         "newText": "// added\n"}]}}}})
        send({"jsonrpc": "2.0", "id": mid, "result": None})
    elif method == "textDocument/signatureHelp":
        uri, pos = params["textDocument"]["uri"], params["position"]
        line = text_of(uri).split("\n")[pos["line"]]
        before = b"".join(units(line)[:pos["character"]]).decode("utf-16-le")
        call = before.rfind("fooBar(")
        if call < 0 or ")" in before[call:]:
            send({"jsonrpc": "2.0", "id": mid, "result": None})
        else:
            send({"jsonrpc": "2.0", "id": mid, "result": {"activeSignature": 0,
                  "activeParameter": before[call:].count(","),
                  "signatures": [{"label": "fooBar(count: Int, name: String) -> Int", "documentation": "Makes a bar.",
                                  "parameters": [{"label": [7, 17], "documentation": "How many."},
                                                 {"label": "name: String"}]}]}})
    elif method == "omc/text":
        send({"jsonrpc": "2.0", "id": mid, "result": docs.get(params["uri"])})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": mid, "result": None})
    elif method == "exit":
        sys.exit(0)
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": None})
