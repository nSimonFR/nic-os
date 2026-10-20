"""mitmproxy addon: capture the Arkose+ (SocialBoulder) app's login token.

The app sends a Meteor `login` over DDP every time it opens. When the server
accepts one, the resume token and user id go to TOKEN_FILE, whose change starts
`arkose-sync` (a systemd path unit). The token expires in 2126, so it stays
valid until the app logs out.
"""

import json
import os
import time

HOSTS = ("plus.arkose.com", "www.sboulder.com", "sboulder.com")
TOKEN_FILE = "/var/lib/arkose-sync/token.json"
# The app re-logs in on every foreground, often 3-4 times in a few seconds.
MIN_REWRITE_S = 600


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


def _read(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


class ArkoseToken:
    def __init__(self, path: str = TOKEN_FILE, clock=time.time):
        self.path = path
        self.clock = clock
        self.pending = set()  # (flow id, DDP method id) of logins awaiting a result

    def _save(self, user_id, token):
        now = self.clock()
        old = _read(self.path)
        if (old.get("userId"), old.get("token")) == (user_id, token) \
                and now - old.get("capturedAt", 0) < MIN_REWRITE_S:
            return
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"userId": user_id, "token": token, "capturedAt": now}, f)
        # Read by arkose-sync (owner of the 0770 dir), not by this user's group.
        os.chmod(tmp, 0o644)
        os.replace(tmp, self.path)
        print(f"[arkose] token captured for {user_id}", flush=True)

    def websocket_message(self, flow):
        if flow.request.pretty_host not in HOSTS:
            return
        msg = flow.websocket.messages[-1]
        text = msg.text if msg.is_text else msg.content.decode("utf-8", "replace")
        for m in decode_frame(text):
            if not isinstance(m, dict):
                continue
            key = (flow.id, m.get("id"))
            if msg.from_client:
                if m.get("msg") == "method" and m.get("method") == "login":
                    self.pending.add(key)
            elif m.get("msg") == "result" and key in self.pending:
                self.pending.discard(key)
                res = m.get("result")
                if isinstance(res, dict) and res.get("token") and res.get("id"):
                    self._save(res["id"], res["token"])
                else:
                    print(f"[arkose] login refused: {m.get('error')}", flush=True)


addons = [ArkoseToken()]
