"""Minimal MCP server: initialize / ping / tools/list / tools/call over
newline-delimited JSON-RPC on stdio, or stateless Streamable HTTP (one JSON
reply per POST, no session, no SSE). Not the `mcp` SDK: it pulls pydantic,
anyio and starlette, on a 4 GB box.

`tools` maps a tool name to its {description, inputSchema}; `handlers` has a
method of the same name per tool. A tool that raises becomes an isError result,
never a dead server.
"""

import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

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


def http_handler(tools, handlers, server, log, token=None):
    """Request handler class: POST /mcp is JSON-RPC, GET /health is readiness."""
    return dispatch_handler(
        lambda msg: handle(msg, tools, handlers, server, log), token
    )


def dispatch_handler(dispatch, token=None):
    """POST /mcp goes to `dispatch(msg) -> reply | None`. With `token`, POST needs
    `Authorization: Bearer <token>`; /health stays open for the readiness probe."""
    expected = f"Bearer {token}".encode() if token else None

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _send(self, status, body=None):
            data = (
                b"" if body is None else json.dumps(body, ensure_ascii=False).encode()
            )
            self.send_response(status)
            if body is not None:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/health":
                return self._send(200, {})
            self._send(405)

        def do_DELETE(self):
            self._send(405)

        def do_POST(self):
            if self.path != "/mcp":
                return self._send(404)
            # Token first: an unauthenticated peer never gets a body read.
            if expected and not hmac.compare_digest(
                (self.headers.get("Authorization") or "").encode(), expected
            ):
                return self._send(401, {"error": "unauthorized"})
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            try:
                reply = dispatch(json.loads(raw))
            except ValueError:
                reply = _error(None, -32700, "JSON invalide")
            if reply is None:
                return self._send(202)
            self._send(200, reply)

    return Handler


def serve_http(tools, handlers, server, log, host, port, token=None):
    serve_dispatch(
        lambda msg: handle(msg, tools, handlers, server, log), log, host, port, token
    )


def serve_dispatch(dispatch, log, host, port, token=None):
    httpd = ThreadingHTTPServer((host, port), dispatch_handler(dispatch, token))
    log(f"listening on http://{host}:{port}/mcp" + (" (bearer)" if token else ""))
    httpd.serve_forever()


def credential_token(env=None, name="token"):
    """The bearer token systemd passed with LoadCredential=<name>:…, or None."""
    directory = (os.environ if env is None else env).get("CREDENTIALS_DIRECTORY")
    path = Path(directory or "/nonexistent") / name
    return path.read_text().strip() if path.is_file() else None
