#!/usr/bin/env python3
"""Central debounced Telegram notifier for Claude Code / Pi agent notifications.

Every agent notification hook across every machine — the Claude Code
`Notification` hook and the Pi `agent_end` extension, on rpi5/BeAsT/nBookPro —
POSTs `{host, project, message, source}` to /notify here over the tailnet.

Events are pooled into a single shared stream and a digest is sent to Telegram
only after things go quiet (NOTIFY_QUIET_SECONDS), or, under continuous
activity, at most once every NOTIFY_MAX_SECONDS (so a never-idle fleet still
gets a periodic digest instead of being starved). Each new event *resets* the
quiet timer, so a flurry of sessions refreshing/finishing collapses into one
message.

This replaces the old per-machine /tmp coalescing (shared/telegram-notify.nix),
which fired immediately on the first event in a 60s window and could not pool
across hosts — the source of the thousands-of-messages-a-day spam.
"""
import json
import os
import socket
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("NOTIFY_PORT", "8088"))
QUIET_SECONDS = int(os.environ.get("NOTIFY_QUIET_SECONDS", "300"))
MAX_SECONDS = int(os.environ.get("NOTIFY_MAX_SECONDS", "900"))
CHAT_ID = os.environ.get("NOTIFY_CHAT_ID", "")
TOKEN_PATH = os.environ.get("NOTIFY_TOKEN_PATH", "/run/agenix/telegram-bot-token")
MAX_LINES = int(os.environ.get("NOTIFY_MAX_LINES", "40"))
TELEGRAM_LIMIT = 3900

# Short hostname of this box; used to decide whether to prefix a line with the
# originating host (local events stay terse, remote events are disambiguated).
SELF_HOST = socket.gethostname().split(".")[0].lower()

_lock = threading.Lock()
# Insertion-ordered mapping: formatted-line -> occurrence count (dedup with ×N).
_pending = {}
_first_ts = 0.0  # when the current batch started accumulating
_last_ts = 0.0   # most recent event (drives the quiet/debounce window)


def _read_token():
    # Read fresh every flush so OAuth/token rotation is picked up without a restart.
    try:
        with open(TOKEN_PATH) as f:
            return f.read().strip()
    except OSError:
        return ""


def _format_line(host, project, message):
    host = (host or "unknown").split(".")[0]
    label = project or "unknown"
    if host.lower() != SELF_HOST:
        label = f"{host}/{label}"
    return f"📁 {label}: {message or 'waiting for input'}"


def add_event(host, project, message, immediate=False):
    global _first_ts, _last_ts
    line = _format_line(host, project, message)
    now = time.time()
    snapshot = None
    with _lock:
        if not _pending:
            _first_ts = now
        _pending[line] = _pending.get(line, 0) + 1
        _last_ts = now
        # A PushNotification is an explicit "interrupt me now" from the agent,
        # so flush the whole pending batch immediately instead of waiting out
        # the quiet window. Snapshot under the lock, send outside it.
        if immediate:
            snapshot = dict(_pending)
            _pending.clear()
    if snapshot is not None:
        _send(_build_text(snapshot))


def _send(text):
    token = _read_token()
    if not token or not CHAT_ID:
        return
    data = urllib.parse.urlencode({"chat_id": CHAT_ID, "text": text}).encode()
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    try:
        urllib.request.urlopen(url, data=data, timeout=10).read()
    except Exception:
        pass  # best effort — drop on failure rather than retry/spam


def _build_text(pending):
    lines = ["🤖 Claude Code"]
    items = list(pending.items())
    for line, count in items[:MAX_LINES]:
        lines.append(line + (f" ×{count}" if count > 1 else ""))
    if len(items) > MAX_LINES:
        lines.append(f"… +{len(items) - MAX_LINES} more")
    text = "\n".join(lines)
    if len(text) > TELEGRAM_LIMIT:
        text = text[:TELEGRAM_LIMIT] + "\n… (truncated)"
    return text


def flusher():
    while True:
        time.sleep(5)
        now = time.time()
        with _lock:
            if not _pending:
                continue
            quiet = now - _last_ts >= QUIET_SECONDS
            capped = now - _first_ts >= MAX_SECONDS
            if not (quiet or capped):
                continue
            snapshot = dict(_pending)
            _pending.clear()
        _send(_build_text(snapshot))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # silence per-request stderr logging

    def _respond(self, code=200, body=b"ok"):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._respond()  # trivial health endpoint

    def do_POST(self):
        if self.path.rstrip("/") not in ("/notify", ""):
            self._respond(404, b"not found")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            self._respond(400, b"bad request")
            return
        add_event(
            str(payload.get("host", "")),
            str(payload.get("project", "")),
            str(payload.get("message", "")),
            immediate=bool(payload.get("immediate", False)),
        )
        self._respond()


def main():
    threading.Thread(target=flusher, daemon=True).start()
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
