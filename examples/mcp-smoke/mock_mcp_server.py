#!/usr/bin/env python3
"""
A zero-dependency mock MCP server (stdio transport) for smoke-testing Wireline's
MCP integration. Speaks JSON-RPC 2.0 over stdin/stdout, newline-delimited —
exactly what Wireline's MCPClient expects.

Tools it exposes:
  - echo         (read-only)  → returns the text you pass
  - server_time  (read-only)  → returns the current time
  - append_note  (MUTATING)   → appends a line to /tmp/wireline-mcp-note.txt

`echo` / `server_time` carry annotations.readOnlyHint = true, so Wireline runs
them without prompting. `append_note` is unmarked (treated as mutating), so
Wireline asks for confirmation before calling it — good for exercising the
confirm dialog and the "always allow" path.

Run standalone (it just waits on stdin); Wireline launches it for you when you
add it as a server. To sanity-check by hand:  python3 mock_mcp_server.py
"""
import sys
import json
import time
import datetime

NOTE_PATH = "/tmp/wireline-mcp-note.txt"

TOOLS = [
    {
        "name": "echo",
        "description": "Echo back the provided text (read-only demo tool).",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string", "description": "text to echo"}},
            "required": ["text"],
        },
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "server_time",
        "description": "Return the mock server's current local time (read-only).",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "append_note",
        "description": "Append a line to a local note file (mutating — writes to disk).",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string", "description": "line to append"}},
            "required": ["text"],
        },
        # No readOnlyHint → Wireline treats it as mutating and asks first.
    },
]


def call_tool(name, args):
    if name == "echo":
        return args.get("text", "")
    if name == "server_time":
        return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if name == "append_note":
        line = args.get("text", "")
        with open(NOTE_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        return f"Appended to {NOTE_PATH}: {line}"
    raise ValueError(f"unknown tool: {name}")


def handle(msg):
    """Return a response dict, or None for notifications (no id)."""
    method = msg.get("method")
    mid = msg.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": mid,
            "result": {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "wireline-mock-mcp", "version": "1.0"},
            },
        }
    if method == "notifications/initialized":
        return None  # notification: no reply
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        params = msg.get("params", {})
        try:
            text = call_tool(params.get("name"), params.get("arguments", {}))
            return {"jsonrpc": "2.0", "id": mid,
                    "result": {"content": [{"type": "text", "text": text}], "isError": False}}
        except Exception as e:  # report tool errors in-band
            return {"jsonrpc": "2.0", "id": mid,
                    "result": {"content": [{"type": "text", "text": str(e)}], "isError": True}}
    if mid is not None:
        return {"jsonrpc": "2.0", "id": mid,
                "error": {"code": -32601, "message": f"method not found: {method}"}}
    return None


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            continue
        resp = handle(msg)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
