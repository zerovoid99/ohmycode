#!/usr/bin/env python3
"""A scripted Agent Client Protocol agent for tests: JSON-RPC, one message per line.

What it does depends on the prompt's text:
  hello            replies "Hello there" in two chunks, with a plan
  read PATH        reads PATH through the editor and replies with its text
  readlines PATH LINE LIMIT  reads some of PATH's lines ("|" for newlines)
  write PATH TEXT  asks permission to write TEXT to PATH; writes it if allowed
  run              runs a command through the editor and replies with its output
  wait             waits until the turn is cancelled
With FAKE_ACP_AUTH=1, sessions need `authenticate` first.
"""
import json
import os
import queue
import sys
import threading

incoming = queue.Queue()
next_id = [1000]
sessions = {}  # id -> {"title": str, "history": [updates]}
config = {"model": "sonnet", "fast": False}
booleans = [False]


def config_options():
    options = [{"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": config["model"],
                "options": [{"group": "claude", "name": "Claude", "options": [
                    {"value": "sonnet", "name": "Sonnet"}, {"value": "opus", "name": "Opus", "description": "Slower"}]},
                            {"group": "other", "name": "Other", "options": [{"value": "small", "name": "Small"}]}]},
               {"id": "future", "name": "Future", "type": "slider", "currentValue": 3}]
    if booleans[0]:
        options.append({"id": "fast", "name": "Fast", "type": "boolean", "currentValue": config["fast"]})
    return options
authenticated = [os.environ.get("FAKE_ACP_AUTH") != "1"]
cancelled = threading.Event()


def reader():
    for line in sys.stdin:
        line = line.strip()
        if line:
            incoming.put(json.loads(line))
    incoming.put(None)


def send(message):
    message["jsonrpc"] = "2.0"
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def update(session, body):
    send({"method": "session/update", "params": {"sessionId": session, "update": body}})


def say(session, text):
    body = {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}
    if session in sessions:
        sessions[session]["history"].append(body)
    update(session, body)


backlog = []


def call(method, params):
    """A request to the editor; waits for its answer (other messages wait their turn)."""
    next_id[0] += 1
    my_id = next_id[0]
    send({"id": my_id, "method": method, "params": params})
    while True:
        message = incoming.get()
        if message is None:
            sys.exit(0)
        if message.get("id") == my_id and "method" not in message:
            return message
        if message.get("method") == "session/cancel":
            cancelled.set()
            continue
        backlog.append(message)


def prompt(session, blocks):
    text = " ".join(b.get("text", "") for b in blocks if b.get("type") == "text").strip()
    links = [b for b in blocks if b.get("type") in ("resource", "resource_link")]
    if links:
        say(session, "attached: " + ", ".join(
            (b.get("resource") or {}).get("uri", b.get("uri", "")) for b in links) + "\n")
    words = text.split(" ", 2)
    if words[0] == "config":
        say(session, "model=%s fast=%s" % (config["model"], config["fast"]))
        return "end_turn"
    if words[0] == "hello":
        update(session, {"sessionUpdate": "plan", "entries": [
            {"content": "Say hello", "priority": "high", "status": "completed"},
            {"content": "Wait", "priority": "low", "status": "pending"}]})
        say(session, "Hello")
        say(session, " there")
        return "end_turn"
    if words[0] == "read":
        answer = call("fs/read_text_file", {"sessionId": session, "path": words[1]})
        if "error" in answer:
            say(session, "error: " + answer["error"]["message"])
        else:
            say(session, "read: " + answer["result"]["content"])
        return "end_turn"
    if words[0] == "readlines":
        line, limit = (int(n) for n in words[2].split(" "))
        answer = call("fs/read_text_file", {"sessionId": session, "path": words[1], "line": line, "limit": limit})
        if "error" in answer:
            say(session, "error: " + answer["error"]["message"])
        else:
            say(session, "lines: " + answer["result"]["content"].replace("\n", "|"))
        return "end_turn"
    if words[0] == "write":
        path, content = words[1], words[2]
        update(session, {"sessionUpdate": "tool_call", "toolCallId": "edit-1", "title": "Edit " + os.path.basename(path),
                         "kind": "edit", "status": "pending",
                         "content": [{"type": "diff", "path": path, "oldText": None, "newText": content}],
                         "locations": [{"path": path, "line": 1}]})
        answer = call("session/request_permission", {"sessionId": session, "toolCall": {"toolCallId": "edit-1"}, "options": [
            {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
            {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]})
        outcome = answer["result"]["outcome"]
        if outcome.get("outcome") == "cancelled":
            update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "edit-1", "status": "failed"})
            return "cancelled"
        if outcome.get("optionId") != "allow":
            update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "edit-1", "status": "failed"})
            say(session, "rejected")
            return "end_turn"
        result = call("fs/write_text_file", {"sessionId": session, "path": path, "content": content})
        update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "edit-1",
                         "status": "failed" if "error" in result else "completed"})
        say(session, "error: " + result["error"]["message"] if "error" in result else "wrote")
        return "end_turn"
    if words[0] == "run":
        created = call("terminal/create", {"sessionId": session, "command": "/bin/sh",
                                            "args": ["-c", "echo out; echo err >&2; exit 3"], "env": [{"name": "X", "value": "1"}]})
        terminal = created["result"]["terminalId"]
        update(session, {"sessionUpdate": "tool_call", "toolCallId": "run-1", "title": "Run", "kind": "execute",
                         "status": "in_progress", "content": [{"type": "terminal", "terminalId": terminal}]})
        exited = call("terminal/wait_for_exit", {"sessionId": session, "terminalId": terminal})["result"]
        output = call("terminal/output", {"sessionId": session, "terminalId": terminal})["result"]
        call("terminal/release", {"sessionId": session, "terminalId": terminal})
        update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "run-1", "status": "completed"})
        say(session, "exit %s: %s" % (exited["exitCode"], output["output"].replace("\n", "|")))
        return "end_turn"
    if words[0] == "wait":
        say(session, "waiting")
        while not cancelled.is_set():
            try:
                message = incoming.get(timeout=0.05)
            except queue.Empty:
                continue
            if message is None:
                sys.exit(0)
            if message.get("method") == "session/cancel":
                cancelled.set()
            else:
                backlog.append(message)
        cancelled.clear()
        return "cancelled"
    say(session, "unknown: " + text)
    return "end_turn"


def handle(message):
    method = message.get("method")
    mid = message.get("id")
    params = message.get("params") or {}
    if method == "initialize":
        caps = params.get("clientCapabilities", {})
        listing = os.environ.get("FAKE_ACP_LIST") == "1"
        loading = listing or os.environ.get("FAKE_ACP_LOAD") == "1"
        booleans[0] = "boolean" in ((caps.get("session") or {}).get("configOptions") or {})
        send({"id": mid, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {"loadSession": loading, "promptCapabilities": {"embeddedContext": True},
                                  "sessionCapabilities": {"list": {}} if listing else {}},
            "agentInfo": {"name": "fake-acp", "title": "Fake Agent", "version": "1.0"},
            "authMethods": [{"id": "token", "name": "Use a token", "description": "Signs in"}]}})
    elif method == "authenticate":
        if params.get("methodId") != "token":
            send({"id": mid, "error": {"code": -32602, "message": "No such method"}})
            return
        authenticated[0] = True
        send({"id": mid, "result": {}})
    elif method == "session/new":
        if not authenticated[0]:
            send({"id": mid, "error": {"code": -32000, "message": "Authentication required"}})
            return
        sid = "session-%d" % (len(sessions) + 1)
        sessions[sid] = {"title": None, "history": []}
        send({"id": mid, "result": {"sessionId": sid, "configOptions": config_options(), "modes": {"currentModeId": "default", "availableModes": [
            {"id": "default", "name": "Default"}, {"id": "plan", "name": "Plan", "description": "Plans only"}]}}})
        update(sid, {"sessionUpdate": "available_commands_update", "availableCommands": [
            {"name": "review", "description": "Review the changes", "input": {"hint": "what to review"}}]})
    elif method == "session/set_config_option":
        if params["configId"] == "model" and params["value"] not in ("sonnet", "opus", "small"):
            send({"id": mid, "error": {"code": -32602, "message": "No such model"}})
            return
        if params["configId"] == "fast" and params.get("type") != "boolean":
            send({"id": mid, "error": {"code": -32602, "message": "Booleans say so"}})
            return
        config[params["configId"]] = params["value"]
        send({"id": mid, "result": {"configOptions": config_options()}})
    elif method == "session/set_mode":
        send({"id": mid, "result": {}})
        update(params["sessionId"], {"sessionUpdate": "current_mode_update", "currentModeId": params["modeId"]})
    elif method == "session/list":
        send({"id": mid, "result": {"sessions": [
            {"sessionId": sid, "cwd": params.get("cwd"), "title": s["title"], "updatedAt": "2026-11-17T10:00:0%dZ" % i}
            for i, (sid, s) in enumerate(sessions.items()) if s["title"]]}})
    elif method == "session/load":
        s = sessions.get(params["sessionId"])
        if s is None:
            send({"id": mid, "error": {"code": -32002, "message": "No such session"}})
            return
        for body in s["history"]:
            update(params["sessionId"], body)
        send({"id": mid, "result": {"configOptions": config_options()}})
    elif method == "session/prompt":
        s = sessions.get(params["sessionId"])
        if s is not None:
            text = " ".join(b.get("text", "") for b in params.get("prompt", []) if b.get("type") == "text")
            if s["title"] is None:
                s["title"] = text
            # As agents replay a user message: in pieces.
            for piece in (text[:3], text[3:]):
                if piece:
                    s["history"].append({"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": piece}})
        reason = prompt(params["sessionId"], params.get("prompt", []))
        send({"id": mid, "result": {"stopReason": reason}})
    elif method == "session/cancel":
        cancelled.set()
    elif mid is not None:
        send({"id": mid, "error": {"code": -32601, "message": "Method not found"}})


def main():
    sys.stderr.write("fake-acp started\n")
    sys.stderr.flush()
    threading.Thread(target=reader, daemon=True).start()
    while True:
        message = backlog.pop(0) if backlog else incoming.get()
        if message is None:
            return
        handle(message)


main()
