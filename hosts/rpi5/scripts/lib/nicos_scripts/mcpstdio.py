"""Minimal stdio MCP server: initialize / ping / tools/list / tools/call over
newline-delimited JSON-RPC. Not the `mcp` SDK: it pulls pydantic, anyio and
starlette into processes that live as long as hermes, on a 4 GB box.

`tools` maps a tool name to its {description, inputSchema}; `handlers` has a
method of the same name per tool. A tool that raises becomes an isError result,
never a dead server.
"""

import json
import sys

PROTOCOL = "2025-06-18"


def _result(rid, payload):
    return {"jsonrpc": "2.0", "id": rid, "result": payload}


def _error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def _text(data):
    return {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}]}


def handle(msg, tools, handlers, server, log):
    """One JSON-RPC message -> reply dict, or None for a notification."""
    method, rid = msg.get("method"), msg.get("id")
    if rid is None:
        return None
    if method == "initialize":
        asked = (msg.get("params") or {}).get("protocolVersion") or PROTOCOL
        return _result(
            rid,
            {
                "protocolVersion": asked,
                "capabilities": {"tools": {}},
                "serverInfo": server,
            },
        )
    if method == "ping":
        return _result(rid, {})
    if method == "tools/list":
        return _result(
            rid, {"tools": [{"name": n, **spec} for n, spec in tools.items()]}
        )
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        if name not in tools:
            return _error(rid, -32602, f"outil inconnu : {name}")
        try:
            return _result(
                rid, _text(getattr(handlers, name)(**(params.get("arguments") or {})))
            )
        except Exception as e:  # noqa: BLE001 — reported to the model, not raised
            log(f"{name} failed: {type(e).__name__}: {e}")
            return _result(
                rid,
                {
                    "isError": True,
                    "content": [{"type": "text", "text": f"{type(e).__name__}: {e}"}],
                },
            )
    return _error(rid, -32601, f"méthode inconnue : {method}")


def serve(tools, handlers, server, log, stdin=None, stdout=None):
    stdin, stdout = stdin or sys.stdin, stdout or sys.stdout
    for line in stdin:
        if not line.strip():
            continue
        try:
            reply = handle(json.loads(line), tools, handlers, server, log)
        except ValueError:
            reply = _error(None, -32700, "JSON invalide")
        if reply is not None:
            stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
            stdout.flush()
