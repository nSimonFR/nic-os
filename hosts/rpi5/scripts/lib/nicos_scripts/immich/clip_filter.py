#!/usr/bin/env python3
"""CLIP filter sidecar — the verdict service behind the `nic-clip` workflow step.

    POST /classify {"assetId", "profile", "threshold", "waitSec"}
      -> {"match": true,  "distance": 0.21, "waitedSec": 8}
      -> {"match": false, "distance": 0.55, "reason": "..."}

Why a sidecar exists at all: the WASM plugin's only escape hatch is Immich's
`httpRequest` host function, which returns `body: await res.text()`. No image
bytes can cross that, so the plugin cannot call CLIP and something outside it
must decide.

Why it runs no inference either: Immich's own SmartSearch job already embeds
every asset on beast and writes `smart_search.embedding`. Waiting for that row
costs nothing, avoids a second GPU pass, and sidesteps decoding HEIC originals
on the Pi. The cost is that the verdict is not available the instant the asset
lands — hence `waitSec`, and hence the honest failure mode below.

Fail-closed everywhere: an unknown profile, an unreachable database, an
embedding that never arrives — all answer `match: false`. A false negative
leaves a photo out of an album; a false positive files the entire camera roll.

Env:
  LISTEN_ADDR (default 127.0.0.1)   LISTEN_PORT (default 8351)
  IMMICH_PG_DB (default immich)     IMMICH_PG_HOST/PORT/USER (default: unix socket, peer)
  IMMICH_CLIP_PROFILE_DIR (default /var/lib/immich-clip/profiles)
  IMMICH_CLIP_MODEL       (the live clip.modelName; guards stale centroids)
  IMMICH_CLIP_MAX_WAIT    (default 120) — server-side cap on a step's waitSec
  IMMICH_CLIP_POLL_SEC    (default 2)
"""

import json
import re
import sys
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from ..logs import logger
from ..secrets import env_int, env_str
from .store import ProfileError, connect_pg, distance_to, load_profile

DEFAULT_PROFILE_DIR = "/var/lib/immich-clip/profiles"
UUID_RE = re.compile(r"^[0-9a-fA-F-]{32,36}$")

log = logger("immich-clip-filter")


@dataclass(frozen=True)
class Config:
    listen_addr: str = "127.0.0.1"
    listen_port: int = 8351
    profile_dir: str = DEFAULT_PROFILE_DIR
    model: str = ""
    max_wait_sec: int = 120
    poll_sec: int = 2
    pg: dict = field(default_factory=lambda: {"dbname": "immich"})

    @classmethod
    def from_env(cls, env=None):
        return cls(
            listen_addr=env_str("LISTEN_ADDR", "127.0.0.1", env),
            listen_port=env_int("LISTEN_PORT", 8351, env),
            profile_dir=env_str("IMMICH_CLIP_PROFILE_DIR", DEFAULT_PROFILE_DIR, env),
            model=env_str("IMMICH_CLIP_MODEL", "", env),
            max_wait_sec=env_int("IMMICH_CLIP_MAX_WAIT", 120, env),
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
    """Decide one asset. Pure except for the three injected seams."""
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

    # The step may ask for less than the cap but never more: a workflow config box
    # must not be able to pin one of the five workflow-queue slots indefinitely.
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
            distance = distance_to(cur, asset_id, profile["vector"])
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
                    f"no embedding after {waited}s — beast offline, or the "
                    f"smartSearch queue is behind; immich-clip-backfill can catch it up",
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


def make_handler(cfg, classify_fn=None, log=log):
    do_classify = classify_fn or (lambda req: classify(cfg, req))

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
                result = do_classify(req)
            except Exception as e:  # noqa: BLE001 - one bad asset must not kill the server
                result = no(f"unhandled: {e}")
            log(f"{req.get('assetId', '?')} -> {json.dumps(result)}")
            # Always 200: the plugin distinguishes on the body, and a non-2xx
            # would only turn a clean "not food" into an opaque transport error.
            self._reply(200, result)

        def do_GET(self):
            self._reply(200, {"ok": True, "service": "immich-clip-filter"})

    return H


def serve(cfg, server_class=ThreadingHTTPServer):
    log(f"listening {cfg.listen_addr}:{cfg.listen_port} "
        f"(profiles {cfg.profile_dir}, model {cfg.model or 'unchecked'})")
    server_class((cfg.listen_addr, cfg.listen_port), make_handler(cfg)).serve_forever()


def main(env=None, serve_fn=None):
    cfg = Config.from_env(env)
    if not cfg.model:
        # Not fatal: the guard is what stops a stale centroid being used after a
        # model change, and a missing guard should be loud rather than silent.
        log("WARNING: IMMICH_CLIP_MODEL unset — profiles will not be checked "
            "against the live CLIP model")
    (serve_fn or serve)(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
