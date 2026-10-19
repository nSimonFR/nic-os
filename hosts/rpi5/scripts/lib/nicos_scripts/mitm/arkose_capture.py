"""mitmproxy addon: log Arkose+ (SocialBoulder) DDP traffic to a JSONL file.

A temporary capture, to learn which subscriptions and methods the app uses for
session history. Every websocket frame and plain HTTP request to the Arkose+
hosts becomes one line; login secrets are blanked before anything is written.
"""

import json
import time

HOSTS = ("plus.arkose.com", "www.sboulder.com", "sboulder.com")
CAPTURE_FILE = "/var/lib/sumeria-mitm/arkose-capture.jsonl"

# Meteor login params (`resume`, `password.digest`) and its result (`token`).
SECRET_KEYS = frozenset({"resume", "password", "digest", "token", "hashedToken", "loginToken"})
REDACTED = "<redacted>"


def redact(value):
    if isinstance(value, dict):
        return {k: REDACTED if k in SECRET_KEYS else redact(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


def _json(s):
    try:
        return json.loads(s)
    except ValueError:
        return s


def decode_frame(text: str) -> list:
    """DDP messages in one frame: raw DDP, or SockJS ('o', 'h', 'a[...]', '[...]')."""
    if text in ("o", "h"):
        return []
    if text[:1] in ("a", "c") and text[1:2] == "[":
        text = text[1:]
    outer = _json(text)
    if isinstance(outer, list):
        return [_json(m) if isinstance(m, str) else m for m in outer]
    return [outer]


def _strip_query(path: str) -> str:
    # Query strings can carry a login token on redirect URLs.
    return path.split("?", 1)[0]


class ArkoseCapture:
    def __init__(self, path: str = CAPTURE_FILE, clock=time.time):
        self.path = path
        self.clock = clock

    def _write(self, record: dict):
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

    def request(self, flow):
        req = flow.request
        # In transparent mode req.host is the destination IP; pretty_host is the SNI.
        if req.pretty_host not in HOSTS:
            return
        self._write({"ts": self.clock(), "kind": "http", "host": req.pretty_host,
                     "method": req.method, "path": _strip_query(req.path)})

    def websocket_message(self, flow):
        if flow.request.pretty_host not in HOSTS:
            return
        msg = flow.websocket.messages[-1]
        text = msg.text if msg.is_text else msg.content.decode("utf-8", "replace")
        ddp = [redact(m) for m in decode_frame(text)]
        if not ddp:
            return
        self._write({"ts": self.clock(), "kind": "ws", "host": flow.request.pretty_host,
                     "dir": "c2s" if msg.from_client else "s2c", "ddp": ddp})
        for m in ddp:
            if isinstance(m, dict) and m.get("msg") in ("sub", "method"):
                print(f"[arkose-capture] {m['msg']} {m.get('name') or m.get('method')}", flush=True)


addons = [ArkoseCapture()]
