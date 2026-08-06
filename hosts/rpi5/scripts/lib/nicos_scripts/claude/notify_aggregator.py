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

This replaces the old per-machine /tmp coalescing (shared/agent-notify.nix, then
still named telegram-notify.nix),
which fired immediately on the first event in a 60s window and could not pool
across hosts — the source of the thousands-of-messages-a-day spam.

Config via environment:
  NOTIFY_PORT            listen port on 127.0.0.1          (default 8088)
  NOTIFY_QUIET_SECONDS   debounce window                   (default 300)
  NOTIFY_MAX_SECONDS     hard cap between digests          (default 900)
  NOTIFY_CHAT_ID         Telegram chat id (no sends if unset)
  NOTIFY_TOKEN_PATH      bot token file  (default /run/agenix/telegram-bot-token)
  NOTIFY_MAX_LINES       lines per digest                  (default 40)
"""

import json
import socket
import sys
import threading
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ..secrets import env_int, env_str, read_secret

DEFAULT_TOKEN_PATH = "/run/agenix/telegram-bot-token"
TELEGRAM_LIMIT = 3900
FLUSH_TICK_SECONDS = 5


@dataclass(frozen=True)
class Config:
    port: int = 8088
    quiet_seconds: int = 300
    max_seconds: int = 900
    chat_id: str = ""
    token_path: str = DEFAULT_TOKEN_PATH
    max_lines: int = 40
    # Short hostname of this box; used to decide whether to prefix a line with the
    # originating host (local events stay terse, remote events are disambiguated).
    self_host: str = ""

    @classmethod
    def from_env(cls, env=None):
        return cls(
            port=env_int("NOTIFY_PORT", 8088, env),
            quiet_seconds=env_int("NOTIFY_QUIET_SECONDS", 300, env),
            max_seconds=env_int("NOTIFY_MAX_SECONDS", 900, env),
            chat_id=env_str("NOTIFY_CHAT_ID", "", env),
            token_path=env_str("NOTIFY_TOKEN_PATH", DEFAULT_TOKEN_PATH, env),
            max_lines=env_int("NOTIFY_MAX_LINES", 40, env),
            self_host=socket.gethostname().split(".")[0].lower(),
        )


def telegram_send(cfg, text, opener=None):
    # Token read fresh on every flush so OAuth/token rotation is picked up
    # without a restart.
    try:
        token = read_secret(cfg.token_path)
    except OSError:
        token = ""
    if not token or not cfg.chat_id:
        return False
    data = urllib.parse.urlencode({"chat_id": cfg.chat_id, "text": text}).encode()
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    try:
        (opener or urllib.request.urlopen)(url, data=data, timeout=10).read()
        return True
    except Exception:  # noqa: BLE001
        return False  # best effort — drop on failure rather than retry/spam


class Aggregator:
    """The debounce buffer. Previously four module-level globals and a lock.

    `send(text)` and `now()` are the seams: tests pass a recorder and a clock they
    control, so the entire quiet/cap/dedup behaviour is exercised in milliseconds.
    """

    def __init__(self, cfg, send=None, now=time.time):
        self.cfg = cfg
        self.send = send or (lambda text: telegram_send(cfg, text))
        self.now = now
        self._lock = threading.Lock()
        # Insertion-ordered mapping: formatted-line -> occurrence count (dedup ×N).
        self._pending = {}
        self._first_ts = 0.0  # when the current batch started accumulating
        self._last_ts = 0.0   # most recent event (drives the quiet/debounce window)

    def format_line(self, host, project, message):
        host = (host or "unknown").split(".")[0]
        label = project or "unknown"
        if host.lower() != self.cfg.self_host:
            label = f"{host}/{label}"
        return f"📁 {label}: {message or 'waiting for input'}"

    def add(self, host, project, message, immediate=False):
        line = self.format_line(host, project, message)
        now = self.now()
        snapshot = None
        with self._lock:
            if not self._pending:
                self._first_ts = now
            self._pending[line] = self._pending.get(line, 0) + 1
            self._last_ts = now
            # A PushNotification is an explicit "interrupt me now" from the agent,
            # so flush the whole pending batch immediately instead of waiting out
            # the quiet window. Snapshot under the lock, send outside it.
            if immediate:
                snapshot = self._take()
        if snapshot is not None:
            self.send(self.build_text(snapshot))

    def _take(self):
        snapshot = dict(self._pending)
        self._pending.clear()
        return snapshot

    def due(self, now=None):
        """Is a digest owed? Quiet for long enough, or the hard cap reached."""
        now = self.now() if now is None else now
        if not self._pending:
            return False
        quiet = now - self._last_ts >= self.cfg.quiet_seconds
        capped = now - self._first_ts >= self.cfg.max_seconds
        return quiet or capped

    def flush_if_due(self):
        """-> the text sent, or None. Snapshot under the lock, send outside it."""
        with self._lock:
            if not self.due():
                return None
            snapshot = self._take()
        text = self.build_text(snapshot)
        self.send(text)
        return text

    def build_text(self, pending):
        lines = ["🤖 Claude Code"]
        items = list(pending.items())
        for line, count in items[:self.cfg.max_lines]:
            lines.append(line + (f" ×{count}" if count > 1 else ""))
        if len(items) > self.cfg.max_lines:
            lines.append(f"… +{len(items) - self.cfg.max_lines} more")
        text = "\n".join(lines)
        if len(text) > TELEGRAM_LIMIT:
            text = text[:TELEGRAM_LIMIT] + "\n… (truncated)"
        return text

    @property
    def pending(self):
        return dict(self._pending)


def flusher(agg, sleep=time.sleep, tick=FLUSH_TICK_SECONDS, forever=True):
    while True:
        sleep(tick)
        agg.flush_if_due()
        if not forever:
            return


def make_handler(agg):
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
            except Exception:  # noqa: BLE001
                self._respond(400, b"bad request")
                return
            agg.add(
                str(payload.get("host", "")),
                str(payload.get("project", "")),
                str(payload.get("message", "")),
                immediate=bool(payload.get("immediate", False)),
            )
            self._respond()

    return Handler


def main(env=None, server_class=ThreadingHTTPServer):
    cfg = Config.from_env(env)
    agg = Aggregator(cfg)
    threading.Thread(target=flusher, args=(agg,), daemon=True).start()
    server_class(("127.0.0.1", cfg.port), make_handler(agg)).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
