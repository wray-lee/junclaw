#!/usr/bin/env python3
"""Deterministic stdio MCP server for scripts/mcp-stdio-smoke.sh.

Speaks newline-delimited JSON-RPC on stdin/stdout. No network, no files.
Tools (server-side names; junclaw exposes them as mcp_fake_<name>):

  echo  - returns ECHO:<msg>
  fail  - answers with a JSON-RPC error (FAILED_INTENTIONALLY)
  big   - returns BIG_BEGIN, 70 KB of x, then BIG_TAIL_MARKER
  slow  - sleeps 30 s before answering, so the client timeout fires
  hidden- returned by tools/list but excluded by the config allowlist

Only the smoke test starts this process; it is never imported by the
product.
"""

import json
import sys
import time

BIG_BODY = "BIG_BEGIN\n" + ("x" * 70000) + "\nBIG_TAIL_MARKER"
TOOLS = [
    {"name": "echo", "description": "echo the msg argument",
     "inputSchema": {"type": "object", "properties": {"msg": {"type": "string"}}}},
    {"name": "fail", "description": "always fails",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "big", "description": "returns more than 64 KB",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "slow", "description": "answers after 30 s",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "hidden", "description": "must never reach the model",
     "inputSchema": {"type": "object", "properties": {}}},
]


def reply(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def call_tool(name, arguments):
    if name == "echo":
        return {"content": [{"type": "text", "text": "ECHO:" + str(arguments.get("msg", ""))}]}
    if name == "big":
        return {"content": [{"type": "text", "text": BIG_BODY}]}
    if name == "fail":
        raise RuntimeError("FAILED_INTENTIONALLY")
    if name == "slow":
        time.sleep(30)
        return {"content": [{"type": "text", "text": "SLOW_DONE"}]}
    if name == "hidden":
        return {"content": [{"type": "text", "text": "HIDDEN_SHOULD_NOT_BE_VISIBLE"}]}
    raise ValueError("unknown tool " + name)


def handle(request):
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        reply({"jsonrpc": "2.0", "id": request_id, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "fake-mcp", "version": "1"},
        }})
    elif method == "notifications/initialized":
        pass
    elif method == "tools/list":
        reply({"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        params = request.get("params") or {}
        try:
            result = call_tool(params.get("name", ""), params.get("arguments") or {})
        except ValueError as err:
            reply({"jsonrpc": "2.0", "id": request_id,
                   "error": {"code": -32602, "message": str(err)}})
            return
        except Exception as err:
            reply({"jsonrpc": "2.0", "id": request_id,
                   "error": {"code": -32000, "message": str(err)}})
            return
        reply({"jsonrpc": "2.0", "id": request_id, "result": result})
    else:
        reply({"jsonrpc": "2.0", "id": request_id,
               "error": {"code": -32601, "message": "method not found"}})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle(request)


if __name__ == "__main__":
    main()
