"""
arkose-sync: pull Arkose+ (SocialBoulder) climbing sessions into a local store.

Auth is the app's own resume token, captured by the tailnet-mitm addon
(nicos_scripts.mitm.arkose) whenever the app opens. A systemd path unit starts
this on each capture and an hourly timer re-runs it; `should_sync` makes the
idle runs exit without touching the network:
  * a new capture since the last sync (the app was just opened),
  * the follow-up window after a capture (tops logged after that first open),
  * the daily fallback (opens made with Tailscale off).

Data comes over Meteor DDP (wss://plus.arkose.com/websocket), from the methods
the app itself calls (seen in a capture, 2026-10-20):
  _users.getUserSessions({userId, skip})          newest first, pages of 20
  _users.getUserSessionBoulders({sessionId, userId})
        -> {boulders, triedBoulders, retopBoulders, gym...}
Undocumented API: records are stored as received, minus pictures/avatars, so
fields not seen yet (how a flash is marked) are kept.

  ARKOSE_DIR             token.json + sessions.json   (default /var/lib/arkose-sync)
  ARKOSE_URL             DDP endpoint                 (default wss://plus.arkose.com/websocket)
  ARKOSE_FOLLOWUP_HOURS  re-sync window after a capture (default 3)
  ARKOSE_DAILY_HOURS     fallback interval              (default 24)
  ARKOSE_FREEREPS_URL    FreeReps base URL; when set, every sync pushes all
                         sessions to its /api/v1/ingest/climbing (unset: no push)
"""

import itertools
import json
import os
import sys
import time
import urllib.error
from dataclasses import dataclass
from datetime import datetime, timezone

from ..httpjson import post_json
from ..logs import logger
from ..secrets import env_int, env_str
from ..state import load_json, save_json

log = logger("arkose-sync")

PAGE = 20
MAX_PAGES = 50
# Sessions this recent are re-fetched every run: tops can still be added.
RECENT_S = 2 * 86400
COUNT_KEYS = ("tops", "flashs", "tried", "retops")
DROP_KEYS = frozenset({
    "picture", "setterProfile", "userAvatars", "userFacebookId", "userGender",
    "userName", "gymLogo", "gymLogoGym", "gymSpraywallPicture", "likers", "_isNew",
})


class ArkoseError(Exception):
    pass


@dataclass(frozen=True)
class Config:
    dir: str = "/var/lib/arkose-sync"
    url: str = "wss://plus.arkose.com/websocket"
    followup_s: int = 3 * 3600
    daily_s: int = 24 * 3600
    freereps_url: str = ""

    @classmethod
    def from_env(cls, env=None):
        return cls(
            dir=env_str("ARKOSE_DIR", cls.dir, env),
            url=env_str("ARKOSE_URL", cls.url, env),
            followup_s=env_int("ARKOSE_FOLLOWUP_HOURS", 3, env) * 3600,
            daily_s=env_int("ARKOSE_DAILY_HOURS", 24, env) * 3600,
            freereps_url=env_str("ARKOSE_FREEREPS_URL", "", env).rstrip("/"),
        )

    @property
    def token_file(self):
        return os.path.join(self.dir, "token.json")

    @property
    def store_file(self):
        return os.path.join(self.dir, "sessions.json")


def should_sync(token, last_sync, now, cfg):
    captured = token.get("capturedAt", 0)
    if not token.get("token"):
        return False
    return (captured > last_sync
            or now - captured < cfg.followup_s
            or now - last_sync >= cfg.daily_s)


def clean(value):
    """Drop images/profile noise, turn EJSON {"$date": ms} into ISO-8601 UTC."""
    if isinstance(value, dict):
        if set(value) == {"$date"}:
            return datetime.fromtimestamp(value["$date"] / 1000, timezone.utc).isoformat()
        return {k: clean(v) for k, v in value.items() if k not in DROP_KEYS}
    if isinstance(value, list):
        return [clean(v) for v in value]
    return value


def _start_ts(session):
    return datetime.fromisoformat(session["startDate"]).timestamp()


def needs_detail(session, stored, now):
    if session.get("isEmpty"):
        return False
    if stored is None or "boulders" not in stored:
        return True
    return (not session.get("isClosed")
            or now - _start_ts(session) < RECENT_S
            or _changed(session, stored))


class DDP:
    """Minimal DDP client over a websocket-like `conn` (send(str) / recv() -> str)."""

    def __init__(self, conn):
        self.conn = conn
        self.ids = itertools.count(1)

    def _recv(self):
        while True:
            m = json.loads(self.conn.recv())
            if m.get("msg") == "ping":
                self.conn.send(json.dumps({"msg": "pong", **({"id": m["id"]} if "id" in m else {})}))
                continue
            return m

    def connect(self):
        self.conn.send(json.dumps({"msg": "connect", "version": "1", "support": ["1"]}))
        while True:
            m = self._recv()
            if m.get("msg") == "connected":
                return
            if m.get("msg") == "failed":
                raise ArkoseError(f"DDP connect refused: {m}")

    def call(self, method, *params):
        mid = str(next(self.ids))
        self.conn.send(json.dumps({"msg": "method", "method": method, "params": list(params), "id": mid}))
        while True:
            m = self._recv()
            if m.get("msg") == "result" and m.get("id") == mid:
                if "error" in m:
                    raise ArkoseError(f"{method}: {m['error']}")
                return m.get("result")


def _changed(session, stored):
    return stored is None or any(session.get(k) != stored.get(k) for k in COUNT_KEYS)


def fetch_sessions(ddp, user_id, stored):
    """Session summaries, newest first.

    The next page is only fetched while the current one ends on an unknown or
    changed session, so a routine run costs one call.
    """
    out = []
    for page_no in range(MAX_PAGES):
        page = ddp.call("_users.getUserSessions", {"userId": user_id, "skip": page_no * PAGE}) or []
        page = [clean(s) for s in page]
        if out and page and page[0]["_id"] == out[-PAGE]["_id"]:
            log("server ignored skip, stopping pagination")
            break
        out.extend(page)
        last = page[-1] if page else None
        if len(page) < PAGE or not _changed(last, stored.get(last["_id"])):
            break
    return out


def sync(ddp, token, store, now):
    res = ddp.call("login", {"resume": token["token"]})
    user_id = res["id"]
    if user_id != token.get("userId"):
        raise ArkoseError(f"token belongs to {user_id}, expected {token.get('userId')}")
    if store.get("userId") not in (None, user_id):
        raise ArkoseError(f"store belongs to {store['userId']}, token to {user_id}")
    sessions = store.setdefault("sessions", {})
    fetched = 0
    for s in fetch_sessions(ddp, user_id, sessions):
        prev = sessions.get(s["_id"])
        if needs_detail(s, prev, now):
            detail = clean(ddp.call("_users.getUserSessionBoulders",
                                    {"sessionId": s["_id"], "userId": user_id}))
            for k in ("boulders", "triedBoulders", "retopBoulders"):
                s[k] = detail.get(k, [])
            fetched += 1
        elif prev:
            for k in ("boulders", "triedBoulders", "retopBoulders"):
                if k in prev:
                    s[k] = prev[k]
        sessions[s["_id"]] = s
    store["userId"] = user_id
    store["lastSyncAt"] = now
    return fetched


def _ascent(b, labels, result):
    label, sub = b.get("label"), b.get("grade")
    level = labels.get(str(label), str(label))
    try:
        rank = int(label) * 10 + int(sub)
    except (TypeError, ValueError):
        rank = None
    return {"route_id": b["_id"], "discipline": "boulder", "result": result,
            "grade": f"{level} {sub}" if sub else level, "grade_rank": rank,
            "name": str(b.get("boulderNum", ""))}


def to_freereps(store):
    """The climbing ingest payload (FreeReps server/specs/climbing-ingest.md).

    A route can be in both boulders and retopBoulders (seen 2026-09-30); a
    repeat wins, so each route is sent once.
    """
    out = []
    for s in sorted(store.get("sessions", {}).values(), key=lambda s: s["startDate"]):
        labels = s.get("gymLabels") or {}
        ascents, seen = [], set()
        lists = [("retopBoulders", lambda b: "repeat"),
                 ("boulders", lambda b: "flash" if b.get("flashed") else "top"),
                 ("triedBoulders", lambda b: "attempt")]
        for key, result in lists:
            for b in s.get(key) or []:
                if b["_id"] not in seen:
                    seen.add(b["_id"])
                    ascents.append(_ascent(b, labels, result(b)))
        out.append({"id": s["_id"], "start": s["startDate"], "end": s.get("endDate"),
                    "gym": s.get("gymName") or s.get("gym", ""), "ascents": ascents})
    return {"source": "Arkose+", "sessions": out}


def push(cfg, store, opener=None):
    try:
        status, body = post_json(f"{cfg.freereps_url}/api/v1/ingest/climbing",
                                 to_freereps(store), opener=opener)
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read().decode("utf-8", "replace")
    if status != 200:
        raise ArkoseError(f"FreeReps answered {status}: {body[:300]}")
    return json.loads(body)


def _open_ws(url):
    import websocket  # websocket-client; imported here so the module loads without it

    return websocket.create_connection(url, timeout=30)


def main(env=None, connect=None, clock=time.time, opener=None):
    cfg = Config.from_env(env)
    token = load_json(cfg.token_file, {})
    store = load_json(cfg.store_file, {})
    now = clock()
    if not should_sync(token, store.get("lastSyncAt", 0), now, cfg):
        return 0
    conn = (connect or _open_ws)(cfg.url)
    try:
        ddp = DDP(conn)
        ddp.connect()
        fetched = sync(ddp, token, store, now)
    except ArkoseError as e:
        # A 403 here means the app logged out: reopen it on the tailnet to recapture.
        log(f"FATAL {e}")
        return 1
    finally:
        conn.close()
    save_json(cfg.store_file, store, indent=1, sort_keys=True)
    total = sum(1 for s in store["sessions"].values() if not s.get("isEmpty"))
    log(f"{len(store['sessions'])} sessions ({total} with tops), {fetched} fetched")
    if cfg.freereps_url:
        # The local store is already saved, so a failed push is retried in full
        # by the next run.
        try:
            res = push(cfg, store, opener)
        except (ArkoseError, OSError) as e:
            log(f"FATAL FreeReps push: {e}")
            return 1
        log(f"pushed {res.get('climbing_sessions_received', 0)} sessions, "
            f"{res.get('climbing_ascents_inserted', 0)} ascents to FreeReps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
