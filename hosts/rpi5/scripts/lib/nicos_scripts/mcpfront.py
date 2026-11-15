"""Catalog cache in front of a socket-activated, stateless HTTP MCP server.

`initialize`, `tools/list` and notifications go straight to the backend port
(not through the socket proxy) and the reply is cached; while the backend
sleeps they are answered from that cache, so the tool list never needs a wake.
`ping` is answered here. Everything else goes through the socket proxy, which
wakes the backend and holds the request until it is ready.

Cached replies only go to callers holding `token`; any other request is passed
through untouched, for the backend to refuse.
"""

import hmac
import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from nicos_scripts import state
from nicos_scripts.logs import logger

CACHED = ("initialize", "tools/list")
FORWARD_HEADERS = (
    "Authorization",
    "Content-Type",
    "Accept",
    "Host",
    "X-Forwarded-For",
    "X-Forwarded-Proto",
    "X-Real-IP",
)


@dataclass(frozen=True)
class Config:
    host: str = "127.0.0.1"
    port: int = 0
    wake_url: str = ""  # through the socket proxy
    direct_url: str = ""  # the backend's own port: refused while asleep
    cache_path: str = ""
    token: str = ""
    call_timeout: float = 300
    direct_timeout: float = 15

    @classmethod
    def from_env(cls, env):
        return cls(
            host=env.get("MCP_FRONT_HOST", "127.0.0.1"),
            port=int(env["MCP_FRONT_PORT"]),
            wake_url=env["MCP_FRONT_WAKE_URL"],
            direct_url=env["MCP_FRONT_DIRECT_URL"],
            cache_path=env["MCP_FRONT_CACHE"],
            token=env.get(env.get("MCP_FRONT_TOKEN_VAR", ""), ""),
        )


class Asleep(Exception):
    pass


def post(url, body, headers, timeout, opener=urllib.request.urlopen):
    """-> (status, content_type, bytes). Raises Asleep when the port refuses."""
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with opener(req, timeout=timeout) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read()
    except urllib.error.URLError as e:
        if isinstance(e.reason, ConnectionRefusedError):
            raise Asleep from e
        raise


def bearer(headers):
    auth = headers.get("Authorization") or ""
    return auth[7:].strip() if auth[:7].lower() == "bearer " else ""


class Front:
    def __init__(self, cfg, post=post, log=print):
        self.cfg, self.post, self.log = cfg, post, log

    def _cache(self):
        return state.load_json(self.cfg.cache_path, {})

    def _remember(self, method, status, body):
        if status != 200:
            return
        try:
            result = json.loads(body).get("result")
        except (ValueError, AttributeError):
            return
        if result is None:
            return
        cache = self._cache()
        if cache.get(method) != result:
            cache[method] = result
            state.save_json(self.cfg.cache_path, cache)
            self.log(f"cached {method}")

    def handle(self, raw, headers):
        """-> (status, content_type, bytes) for one POST body."""
        fwd = {k: headers[k] for k in FORWARD_HEADERS if headers.get(k)}
        try:
            msg = json.loads(raw)
        except ValueError:
            msg = None
        trusted = bool(self.cfg.token) and hmac.compare_digest(
            bearer(headers).encode(), self.cfg.token.encode()
        )
        if not trusted or not isinstance(msg, dict):
            return self.post(self.cfg.wake_url, raw, fwd, self.cfg.call_timeout)

        method, rid = msg.get("method"), msg.get("id")
        if method == "ping" and rid is not None:
            return 200, "application/json", _reply(rid, {})
        if rid is not None and method not in CACHED:
            return self.post(self.cfg.wake_url, raw, fwd, self.cfg.call_timeout)

        try:
            status, ctype, body = self.post(
                self.cfg.direct_url, raw, fwd, self.cfg.direct_timeout
            )
        except Asleep:
            if rid is None:
                return 202, "", b""
            cached = self._cache().get(method)
            if cached is None:
                return self.post(self.cfg.wake_url, raw, fwd, self.cfg.call_timeout)
            return 200, "application/json", _reply(rid, cached)
        if rid is not None:
            self._remember(method, status, body)
        return status, ctype, body


def _reply(rid, result):
    return json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}).encode()


def http_handler(front):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _send(self, status, ctype="", body=b""):
            self.send_response(status)
            if ctype:
                self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self._send(200 if self.path == "/health" else 405)

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            try:
                self._send(*front.handle(raw, self.headers))
            except Exception as e:  # noqa: BLE001 — one bad upstream call, not a dead front
                front.log(f"upstream failed: {type(e).__name__}: {e}")
                self._send(502)

    return Handler


def main(argv=None, env=None):
    del argv
    cfg = Config.from_env(os.environ if env is None else env)
    log = logger("mcp-catalog-front")
    front = Front(cfg, log=log)
    httpd = ThreadingHTTPServer((cfg.host, cfg.port), http_handler(front))
    log(f"listening on http://{cfg.host}:{cfg.port}")
    httpd.serve_forever()
    return 0
