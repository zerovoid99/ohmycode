#!/usr/bin/env python3
"""Minimal LSP server for tests. Mirrors documents from incremental changes (UTF-16
positions), reports a diagnostic for every "BAD", and answers completion/definition."""
import json, sys

docs = {}

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

while True:
    msg = read()
    method, mid, params = msg.get("method"), msg.get("id"), msg.get("params", {})
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"capabilities": {
            "textDocumentSync": 2, "completionProvider": {"triggerCharacters": ["."]}, "definitionProvider": True}}})
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
    elif method == "omc/text":
        send({"jsonrpc": "2.0", "id": mid, "result": docs.get(params["uri"])})
    elif method == "shutdown":
        send({"jsonrpc": "2.0", "id": mid, "result": None})
    elif method == "exit":
        sys.exit(0)
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": None})
