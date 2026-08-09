#!/usr/bin/env python3
"""CLIP filter sidecar — the verdict service behind the `nic-clip` workflow step.

    POST /classify {"assetId", "profile", "threshold", "waitSec", "albumIds"}
      -> {"match": true,  "distance": 0.21, "filed": 1}
      -> {"match": false, "distance": 0.55, "reason": "over threshold"}
      -> {"match": false, "reason": "...", "undecided": true, "queued": true}

Why a sidecar exists at all: the WASM plugin's only escape hatch is Immich's
`httpRequest` host function, which returns `body: await res.text()`. No image
bytes can cross that, so the plugin cannot call CLIP and something outside it
must decide.

Why it runs no inference either: Immich's own SmartSearch job already embeds
every asset on beast and writes `smart_search.embedding`. Reading that costs
nothing, avoids a second GPU pass, and sidesteps decoding HEIC originals on the
Pi.

THREE outcomes, not two. An asset whose embedding does not exist yet is not
"not food" — it is *undecided*, and beast (the ML host) is usually offline, so
that is the common case rather than the edge case. Undecided assets go on the
pending queue and `immich-clip-drain` finishes them once Immich has embedded
them. Only a genuine over-threshold distance is a no.

Everything else still fails closed: an unknown profile, an unreachable database,
a malformed request all answer `match: false` without queueing. A false negative
leaves one photo out of an album; a false positive files the whole camera roll.

Env:
  LISTEN_ADDR (default 127.0.0.1)   LISTEN_PORT (default 8351)
  IMMICH_URL, IMMICH_API_KEY_FILE   (filing the matches)
  IMMICH_PG_DB (default immich)     IMMICH_PG_HOST/PORT/USER (default: unix socket, peer)
  IMMICH_CLIP_PROFILE_DIR (default /var/lib/immich-clip/profiles)
  IMMICH_CLIP_QUEUE_DB    (default /var/lib/immich-clip/pending.sqlite)
  IMMICH_CLIP_MODEL       (the live clip.modelName; guards stale centroids)
  IMMICH_CLIP_MAX_WAIT    (default 15) — server-side cap on a step's waitSec
  IMMICH_CLIP_POLL_SEC    (default 2)
"""

import json
import re
import sys
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ..logs import logger
from ..secrets import env_int, env_str, read_secret_env
from . import api, exclusions, queue
from .store import ProfileError, connect_pg, load_profile, score

DEFAULT_PROFILE_DIR = "/var/lib/immich-clip/profiles"
DEFAULT_QUEUE_DB = "/var/lib/immich-clip/pending.sqlite"
DEFAULT_KEY_FILE = "/run/agenix/immich-clip-api-key"
UUID_RE = re.compile(r"^[0-9a-fA-F-]{32,36}$")

log = logger("immich-clip-filter")


@dataclass(frozen=True)
class Config:
    listen_addr: str = "127.0.0.1"
    listen_port: int = 8351
    profile_dir: str = DEFAULT_PROFILE_DIR
    queue_db: str = DEFAULT_QUEUE_DB
    model: str = ""
    immich_url: str = "http://127.0.0.1:2283"
    api_key: str = ""
    # Short by default. Waiting is only useful while a SmartSearch job is
    # actually in flight; when beast is down no amount of waiting helps, and a
    # long wait pins one of the five workflow-queue slots for nothing.
    max_wait_sec: int = 15
    poll_sec: int = 2
    pg: dict = field(default_factory=lambda: {"dbname": "immich"})

    @classmethod
    def from_env(cls, env=None):
        return cls(
            listen_addr=env_str("LISTEN_ADDR", "127.0.0.1", env),
            listen_port=env_int("LISTEN_PORT", 8351, env),
            profile_dir=env_str("IMMICH_CLIP_PROFILE_DIR", DEFAULT_PROFILE_DIR, env),
            queue_db=env_str("IMMICH_CLIP_QUEUE_DB", DEFAULT_QUEUE_DB, env),
            model=env_str("IMMICH_CLIP_MODEL", "", env),
            immich_url=env_str("IMMICH_URL", "http://127.0.0.1:2283", env).rstrip("/"),
            api_key=read_secret_env("IMMICH_API_KEY_FILE", DEFAULT_KEY_FILE, env) or "",
            max_wait_sec=env_int("IMMICH_CLIP_MAX_WAIT", 15, env),
            poll_sec=env_int("IMMICH_CLIP_POLL_SEC", 2, env),
            pg={
                "dbname": env_str("IMMICH_PG_DB", "immich", env),
                "host": env_str("IMMICH_PG_HOST", "", env),
                "port": env_str("IMMICH_PG_PORT", "", env),
                "user": env_str("IMMICH_PG_USER", "", env),
            },
        )


def no(reason, **extra):
    return dict({"match": False, "reason": reason}, **extra)


def classify(cfg, req, connect=None, sleep=None, monotonic=None):
    """Decide one asset. Pure except for the three injected seams.

    Returns `undecided: True` when the embedding simply is not there yet — the
    caller queues those rather than treating them as a no.
    """
    do_connect = connect or connect_pg
    do_sleep = sleep or time.sleep
    clock = monotonic or time.monotonic

    asset_id = str(req.get("assetId") or "")
    if not UUID_RE.match(asset_id):
        return no(f"bad assetId {asset_id[:40]!r}")

    try:
        threshold = float(req.get("threshold"))
    except (TypeError, ValueError):
        return no("bad threshold")

    wait_sec = min(max(int(req.get("waitSec") or 0), 0), cfg.max_wait_sec)

    try:
        profile = load_profile(cfg.profile_dir, req.get("profile") or "", cfg.model or None)
    except ProfileError as e:
        return no(str(e))

    try:
        conn = do_connect(cfg)
    except Exception as e:  # noqa: BLE001 - a DB outage must not 500 the workflow
        return no(f"database unreachable: {e}")

    started = clock()
    try:
        conn.autocommit = True
        cur = conn.cursor()
        while True:
            distance = score(cur, asset_id, profile)
            waited = round(clock() - started, 1)
            if distance is not None:
                return {
                    "match": distance <= threshold,
                    "distance": round(distance, 4),
                    "waitedSec": waited,
                    "profile": profile["name"],
                    **({} if distance <= threshold else {"reason": "over threshold"}),
                }
            if waited >= wait_sec:
                return no(
                    "not embedded yet — queued until the ML server catches up",
                    undecided=True,
                    waitedSec=waited,
                )
            do_sleep(cfg.poll_sec)
    except Exception as e:  # noqa: BLE001
        return no(f"lookup failed: {e}")
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass


def file_into_albums(cfg, album_ids, asset_id, add_assets=None):
    """Add one asset to each configured album. Returns how many took it.

    Filing lives here, not in the WASM plugin, so the immediate path and the
    drained path share one implementation — and so it is testable in Python
    rather than only through a wasm harness.
    """
    do_add = add_assets or api.add_assets
    filed = 0
    for album_id in album_ids:
        filed += do_add(cfg, album_id, [asset_id], log=lambda m: None)
    return filed


def handle(cfg, req, classify_fn=None, queue_conn=None, add_assets=None, now=None):
    """One /classify request: decide, then file or queue.

    `queue_conn` is for tests. In production each call opens its own SQLite
    connection: this runs under ThreadingHTTPServer, and a connection is bound to
    the thread that created it — sharing one raises "SQLite objects created in a
    thread can only be used in that same thread" and silently loses the queue
    write. Connections are cheap and enqueues are rare, so per-call it is.
    """
    result = (classify_fn or (lambda r: classify(cfg, r)))(req)
    album_ids = req.get("albumIds") or []

    if result.get("undecided"):
        conn, owned = (queue_conn, False)
        try:
            if conn is None:
                conn, owned = queue.connect(cfg.queue_db), True
            queue.enqueue(
                conn,
                req["assetId"],
                req.get("profile") or "",
                req.get("threshold") or 0,
                album_ids,
                now if now is not None else time.time(),
            )
            return dict(result, queued=True)
        except Exception as e:  # noqa: BLE001 - failing to queue must not 500
            return dict(result, queued=False, queueError=str(e))
        finally:
            if owned and conn is not None:
                conn.close()

    if result.get("match") and album_ids:
        conn, owned = (queue_conn, False)
        try:
            if conn is None:
                conn, owned = queue.connect(cfg.queue_db), True
            # A photo taken out of this album by hand is never filed back into
            # it — see exclusions.py.
            wanted = exclusions.allowed(conn, req["assetId"], album_ids)
            skipped = len(album_ids) - len(wanted)
            result = dict(result, filed=file_into_albums(
                cfg, wanted, req["assetId"], add_assets=add_assets))
            if skipped:
                result = dict(result, excluded=skipped)
        except Exception as e:  # noqa: BLE001
            # The verdict stands even if filing failed; immich-clip-backfill
            # will pick it up. Do not turn this into a false negative.
            result = dict(result, filed=0, fileError=str(e))
        finally:
            if owned and conn is not None:
                conn.close()
    return result


def make_handler(cfg, handle_fn=None, log=log):
    do_handle = handle_fn or (lambda req: handle(cfg, req))

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _reply(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            n = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(n)
            try:
                req = json.loads(raw or b"{}")
            except ValueError:
                return self._reply(200, no("request body was not JSON"))
            try:
                result = do_handle(req)
            except Exception as e:  # noqa: BLE001 - one bad asset must not kill the server
                result = no(f"unhandled: {e}")
            log(f"{req.get('assetId', '?')} -> {json.dumps(result)}")
            # Always 200: the plugin distinguishes on the body, and a non-2xx
            # would only turn a clean verdict into an opaque transport error.
            self._reply(200, result)

        def do_GET(self):
            self._reply(200, {"ok": True, "service": "immich-clip-filter"})

    return H


def serve(cfg, server_class=ThreadingHTTPServer):
    log(f"listening {cfg.listen_addr}:{cfg.listen_port} "
        f"(profiles {cfg.profile_dir}, queue {cfg.queue_db}, "
        f"model {cfg.model or 'unchecked'})")
    server_class((cfg.listen_addr, cfg.listen_port), make_handler(cfg)).serve_forever()


def main(env=None, serve_fn=None, queue_connect=None):
    cfg = Config.from_env(env)
    if not cfg.model:
        log("WARNING: IMMICH_CLIP_MODEL unset — profiles will not be checked "
            "against the live CLIP model")
    # Create the file and schema once up front, on the main thread, so a request
    # never races the first CREATE TABLE. Each request opens its own connection.
    (queue_connect or queue.connect)(cfg.queue_db).close()
    (serve_fn or serve)(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
