"""rootreq: run one command as root once the user approves it from their phone.

Agents run as nsimon with no sudo. `rootreq -- cmd args…` sends the argv over a
unix socket to `rootreq-broker` (root). The broker posts it to Telegram through
the existing bot, send-only: Hermes polls that bot, and a second getUpdates
consumer would knock it off. The message carries a link to a page the broker
serves on the tailnet; it only accepts a decision from the approver's phone,
identified by `tailscale whois` (node and login), so neither the rpi5 nor a host
an agent can SSH into (the Mac) can approve.
"""

import argparse
import html
import json
import os
import secrets
import shlex
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from nicos_scripts.httpjson import post_json
from nicos_scripts.logs import logger
from nicos_scripts.secrets import env_int, env_str, read_secret

MAX_ARGV = 64
MAX_ARG = 4096
MAX_OUTPUT = 512 * 1024
MAX_PENDING = 3
RUN_PATH = "/run/wrappers/bin:/run/current-system/sw/bin"


@dataclass(frozen=True)
class Config:
    socket_path: str
    listen_host: str
    listen_port: int
    public_url: str
    allowed_uid: int
    approver_login: str
    approver_node: str
    telegram_token_file: str
    telegram_chat_id: str
    timeout: int
    run_timeout: int

    @classmethod
    def from_env(cls, env=None):
        return cls(
            socket_path=env_str("ROOTREQ_SOCKET", "/run/rootreq/rootreq.sock", env),
            listen_host=env_str("ROOTREQ_LISTEN_HOST", "", env),
            listen_port=env_int("ROOTREQ_LISTEN_PORT", 8390, env),
            public_url=env_str("ROOTREQ_PUBLIC_URL", "", env).rstrip("/"),
            allowed_uid=env_int("ROOTREQ_ALLOWED_UID", -1, env),
            approver_login=env_str("ROOTREQ_APPROVER_LOGIN", "", env),
            approver_node=env_str("ROOTREQ_APPROVER_NODE", "", env),
            telegram_token_file=env_str("TELEGRAM_TOKEN_FILE", "", env),
            telegram_chat_id=env_str("TELEGRAM_CHAT_ID", "", env),
            timeout=env_int("ROOTREQ_TIMEOUT", 180, env),
            run_timeout=env_int("ROOTREQ_RUN_TIMEOUT", 600, env),
        )


def validate_request(req):
    """The parts of a client request the broker will act on, or a ValueError."""
    argv = req.get("argv") if isinstance(req, dict) else None
    if not isinstance(argv, list) or not 1 <= len(argv) <= MAX_ARGV:
        raise ValueError("argv must be a non-empty list")
    if not all(isinstance(a, str) and len(a) <= MAX_ARG and "\0" not in a for a in argv):
        raise ValueError("argv entries must be strings without NUL")
    cwd = req.get("cwd") or "/"
    reason = str(req.get("reason") or "")[:500]
    if not isinstance(cwd, str) or not cwd.startswith("/"):
        raise ValueError("cwd must be absolute")
    return argv, cwd, reason


def approver_ok(whois, cfg):
    """True when `tailscale whois --json` names the approver's login on their phone."""
    try:
        login = whois["UserProfile"]["LoginName"]
        node = whois["Node"]["Name"].rstrip(".")
    except (KeyError, TypeError, AttributeError):
        return False
    return bool(cfg.approver_login) and login == cfg.approver_login and node == cfg.approver_node


def tailscale_whois(ip, run=subprocess.run):
    out = run(["tailscale", "whois", "--json", ip], capture_output=True, text=True, timeout=10)
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except ValueError:
        return None


def describe(req_id, argv, cwd, reason):
    lines = [
        "🔐 <b>rootreq</b>: nsimon asks to run as root",
        f"<pre>{html.escape(shlex.join(argv))}</pre>",
        f"cwd <code>{html.escape(cwd)}</code>",
    ]
    if reason:
        lines.append(f"why: {html.escape(reason)}")
    lines.append(f"id <code>{req_id}</code>")
    return "\n".join(lines)


@dataclass
class Pending:
    argv: list
    cwd: str
    reason: str
    message_id: int = 0
    decided: threading.Event = field(default_factory=threading.Event)
    approved: bool = False
    approver: str = ""


class Broker:
    def __init__(self, cfg, opener=None, run=subprocess.run, log=None, clock=time.monotonic):
        self.cfg = cfg
        self.opener = opener
        self.run = run
        self.log = log or logger("rootreq", lambda: sys.stderr)
        self.clock = clock
        self.pending = {}
        self.lock = threading.Lock()

    # Telegram (send-only)
    def _tg(self, method, payload):
        token = read_secret(self.cfg.telegram_token_file)
        status, raw = post_json(f"https://api.telegram.org/bot{token}/{method}", payload,
                                opener=self.opener)
        data = json.loads(raw) if raw else {}
        if status != 200 or not data.get("ok"):
            raise RuntimeError(f"telegram {method}: {status}")
        return data.get("result") or {}

    def notify(self, req_id, p):
        url = f"{self.cfg.public_url}/r/{req_id}"
        res = self._tg("sendMessage", {
            "chat_id": self.cfg.telegram_chat_id,
            "text": describe(req_id, p.argv, p.cwd, p.reason),
            "parse_mode": "HTML",
            "reply_markup": {"inline_keyboard": [[{"text": "Review on nPhone", "url": url}]]},
        })
        p.message_id = res.get("message_id", 0)

    def settle_message(self, req_id, p, outcome):
        if not p.message_id:
            return
        try:
            self._tg("editMessageText", {
                "chat_id": self.cfg.telegram_chat_id,
                "message_id": p.message_id,
                "text": describe(req_id, p.argv, p.cwd, p.reason) + f"\n<b>{html.escape(outcome)}</b>",
                "parse_mode": "HTML",
            })
        except Exception as e:  # the command's result matters more than the edit
            self.log(f"{req_id}: edit failed: {e}")

    # Request lifecycle
    def request(self, argv, cwd, reason):
        """Block until decided or expired; return the client's result dict."""
        with self.lock:
            if len(self.pending) >= MAX_PENDING:
                return {"approved": False, "error": "too many pending requests"}
            req_id = secrets.token_urlsafe(16)
            p = Pending(argv, cwd, reason)
            self.pending[req_id] = p
        try:
            self.notify(req_id, p)
            self.log(f"{req_id}: asked {shlex.join(argv)}")
            if not p.decided.wait(self.cfg.timeout):
                self.settle_message(req_id, p, "⌛ expired")
                return {"approved": False, "error": "no decision before timeout"}
            if not p.approved:
                self.settle_message(req_id, p, "❌ denied")
                return {"approved": False, "error": "denied"}
            result = self.execute(argv, cwd)
            self.settle_message(req_id, p, f"✅ approved by {p.approver}, exit {result['rc']}")
            return {"approved": True, **result}
        finally:
            with self.lock:
                self.pending.pop(req_id, None)

    def decide(self, req_id, approve, whois):
        """Record a decision from the approval page. Returns an HTTP status."""
        with self.lock:
            p = self.pending.get(req_id)
        if p is None:
            return 404
        if not approver_ok(whois, self.cfg):
            self.log(f"{req_id}: decision refused from {(whois or {}).get('Node', {}).get('Name')}")
            return 403
        if p.decided.is_set():
            return 409
        p.approved = bool(approve)
        p.approver = whois["Node"]["Name"].rstrip(".")
        p.decided.set()
        self.log(f"{req_id}: {'approved' if approve else 'denied'} by {p.approver}")
        return 200

    def execute(self, argv, cwd):
        try:
            out = self.run(argv, cwd=cwd, env={"PATH": RUN_PATH}, capture_output=True,
                           timeout=self.cfg.run_timeout, stdin=subprocess.DEVNULL)
            rc, so, se = out.returncode, out.stdout, out.stderr
        except FileNotFoundError:
            rc, so, se = 127, b"", f"rootreq: {argv[0]}: not found\n".encode()
        except subprocess.TimeoutExpired:
            rc, so, se = 124, b"", b"rootreq: timed out\n"
        return {
            "rc": rc,
            "stdout": so[:MAX_OUTPUT].decode(errors="replace"),
            "stderr": se[:MAX_OUTPUT].decode(errors="replace"),
        }


def peer_uid(sock):
    creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", creds)[1]


def make_unix_handler(broker):
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            def reply(obj):
                self.wfile.write((json.dumps(obj) + "\n").encode())
                self.wfile.flush()

            if peer_uid(self.request) != broker.cfg.allowed_uid:
                return reply({"approved": False, "error": "uid not allowed"})
            try:
                argv, cwd, reason = validate_request(json.loads(self.rfile.readline(1 << 20)))
            except ValueError as e:
                return reply({"approved": False, "error": str(e)})
            reply({"event": "pending"})
            reply(broker.request(argv, cwd, reason))

    return Handler


def make_http_handler(broker, whois_fn):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _page(self, status, body):
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(f"<!doctype html><meta name=viewport content='width=device-width'>"
                             f"<body style='font:16px system-ui;margin:1.5em'>{body}".encode())

        def _req_id(self):
            parts = urllib.parse.urlparse(self.path).path.strip("/").split("/")
            return parts[1] if len(parts) == 2 and parts[0] == "r" else None

        def do_GET(self):
            req_id = self._req_id()
            with broker.lock:
                p = broker.pending.get(req_id) if req_id else None
            if p is None:
                return self._page(404, "No such pending request.")
            if not approver_ok(whois_fn(self.client_address[0]), broker.cfg):
                return self._page(403, "Only the approver's phone may decide.")
            form = ("<form method=post style='display:inline'><input type=hidden name=d value={v}>"
                    "<button style='font-size:1.2em;padding:.5em 1em'>{t}</button></form> ")
            self._page(200, describe(req_id, p.argv, p.cwd, p.reason).replace("\n", "<br>")
                       + "<p>" + form.format(v="approve", t="Approve") + form.format(v="deny", t="Deny"))

        def do_POST(self):
            req_id = self._req_id()
            n = min(int(self.headers.get("Content-Length") or 0), 1024)
            fields = urllib.parse.parse_qs(self.rfile.read(n).decode())
            status = broker.decide(req_id, fields.get("d") == ["approve"],
                                   whois_fn(self.client_address[0])) if req_id else 404
            self._page(status, {200: "Recorded.", 403: "Only the approver's phone may decide.",
                                409: "Already decided."}.get(status, "No such pending request."))

    return Handler


class _UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve(env=None):
    cfg = Config.from_env(env)
    missing = [k for k, v in {"ROOTREQ_LISTEN_HOST": cfg.listen_host,
                              "ROOTREQ_PUBLIC_URL": cfg.public_url,
                              "ROOTREQ_APPROVER_LOGIN": cfg.approver_login,
                              "ROOTREQ_APPROVER_NODE": cfg.approver_node,
                              "TELEGRAM_TOKEN_FILE": cfg.telegram_token_file,
                              "TELEGRAM_CHAT_ID": cfg.telegram_chat_id}.items() if not v]
    if missing or cfg.allowed_uid < 0:
        print(f"rootreq-broker: FATAL: missing {missing or ['ROOTREQ_ALLOWED_UID']}", file=sys.stderr)
        return 2
    broker = Broker(cfg)
    if os.path.exists(cfg.socket_path):
        os.unlink(cfg.socket_path)
    unix = _UnixServer(cfg.socket_path, make_unix_handler(broker))
    os.chown(cfg.socket_path, 0, int(env_str("ROOTREQ_SOCKET_GID", "100", env)))
    os.chmod(cfg.socket_path, 0o660)
    http = ThreadingHTTPServer((cfg.listen_host, cfg.listen_port),
                               make_http_handler(broker, tailscale_whois))
    threading.Thread(target=http.serve_forever, daemon=True).start()
    broker.log(f"listening on {cfg.socket_path} and {cfg.listen_host}:{cfg.listen_port}")
    unix.serve_forever()
    return 0


def client(argv=None, env=None, connect=None):
    ap = argparse.ArgumentParser(prog="rootreq", description=(
        "Run a command as root after the user approves it on their phone (Telegram)."))
    ap.add_argument("--reason", default="", help="shown to the approver")
    ap.add_argument("cmd", nargs=argparse.REMAINDER, help="-- command [args…]")
    a = ap.parse_args(argv)
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    if not cmd:
        ap.error("no command")
    path = env_str("ROOTREQ_SOCKET", "/run/rootreq/rootreq.sock", env)
    s = connect(path) if connect else socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    if not connect:
        s.connect(path)
    with s, s.makefile("rwb") as f:
        f.write((json.dumps({"argv": cmd, "cwd": os.getcwd(), "reason": a.reason}) + "\n").encode())
        f.flush()
        for line in f:
            msg = json.loads(line)
            if msg.get("event") == "pending":
                print("rootreq: waiting for approval on the phone…", file=sys.stderr, flush=True)
                continue
            if not msg.get("approved"):
                print(f"rootreq: {msg.get('error', 'refused')}", file=sys.stderr)
                return 1
            sys.stdout.write(msg.get("stdout", ""))
            sys.stderr.write(msg.get("stderr", ""))
            return int(msg.get("rc", 1))
    print("rootreq: broker closed the connection", file=sys.stderr)
    return 1


def main_broker():
    sys.exit(serve())


def main():
    sys.exit(client())
