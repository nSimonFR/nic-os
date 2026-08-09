#!/usr/bin/env python3
"""Finish the verdicts the workflow could not reach — the beast-offline half.

The rpi5 has no GPU: CLIP runs on beast (hosts/beast/immich-ml.nix), and beast is
usually off. A photo uploaded in that window gets no embedding, so the workflow
step cannot decide anything about it and parks it on the pending queue instead of
guessing. This timer finishes the job.

Each pass:

  1. retire entries that aged out, or whose asset was deleted since;
  2. for everything now embedded, compute the distance and file the matches;
  3. if anything is STILL unembedded and the ML server is reachable, kick
     Immich's `smartSearch` queue with force=false.

Step 3 is the part that is easy to miss. Immich does not re-queue missing
embeddings on its own: `handleNightlyJobs` covers missing thumbnails and face
clustering, and nothing else. A SmartSearch job that failed while beast was down
stays failed, so the asset would wait here forever no matter how patient this
drainer is. Hence the kick — rate-limited, because it queues every unembedded
asset in the library, not just ours.

Safe by default: `apply` is False unless IMMICH_CLIP_DRAIN_APPLY says otherwise,
so a Config built from an empty environment reports and writes nothing.

Env: IMMICH_CLIP_QUEUE_DB, IMMICH_CLIP_PROFILE_DIR, IMMICH_CLIP_MODEL,
     IMMICH_URL, IMMICH_API_KEY_FILE, IMMICH_ML_URL, IMMICH_PG_*,
     IMMICH_CLIP_STATE_DIR, IMMICH_CLIP_MAX_AGE_DAYS (30),
     IMMICH_CLIP_REQUEUE_EVERY (3600), IMMICH_CLIP_DRAIN_APPLY
"""

import sys
import time
from dataclasses import dataclass, field

from ..logs import logger
from ..secrets import env_int, env_str, read_secret_env
from ..state import load_json, save_json
from . import api, queue
from .clip_filter import file_into_albums
from .store import (
    ProfileError,
    connect_pg,
    distance_to,
    existing_asset_ids,
    load_profile,
)

DEFAULT_PROFILE_DIR = "/var/lib/immich-clip/profiles"
DEFAULT_QUEUE_DB = "/var/lib/immich-clip/pending.sqlite"
DEFAULT_STATE_DIR = "/var/lib/immich-clip"
DEFAULT_KEY_FILE = "/run/agenix/immich-clip-api-key"

log = logger("immich-clip-drain")


@dataclass(frozen=True)
class Config:
    queue_db: str = DEFAULT_QUEUE_DB
    profile_dir: str = DEFAULT_PROFILE_DIR
    state_dir: str = DEFAULT_STATE_DIR
    model: str = ""
    immich_url: str = "http://127.0.0.1:2283"
    api_key: str = ""
    ml_url: str = ""
    max_age_days: int = 30
    requeue_every: int = 3600
    # SAFE default: nothing is written unless the unit asks for it.
    apply: bool = False
    pg: dict = field(default_factory=lambda: {"dbname": "immich"})

    @classmethod
    def from_env(cls, env=None):
        return cls(
            queue_db=env_str("IMMICH_CLIP_QUEUE_DB", DEFAULT_QUEUE_DB, env),
            profile_dir=env_str("IMMICH_CLIP_PROFILE_DIR", DEFAULT_PROFILE_DIR, env),
            state_dir=env_str("IMMICH_CLIP_STATE_DIR", DEFAULT_STATE_DIR, env),
            model=env_str("IMMICH_CLIP_MODEL", "", env),
            immich_url=env_str("IMMICH_URL", "http://127.0.0.1:2283", env).rstrip("/"),
            api_key=read_secret_env("IMMICH_API_KEY_FILE", DEFAULT_KEY_FILE, env) or "",
            ml_url=env_str("IMMICH_ML_URL", "", env).rstrip("/"),
            max_age_days=env_int("IMMICH_CLIP_MAX_AGE_DAYS", 30, env),
            requeue_every=env_int("IMMICH_CLIP_REQUEUE_EVERY", 3600, env),
            apply=env_str("IMMICH_CLIP_DRAIN_APPLY", "", env).lower()
            in ("1", "true", "yes"),
            pg={
                "dbname": env_str("IMMICH_PG_DB", "immich", env),
                "host": env_str("IMMICH_PG_HOST", "", env),
                "port": env_str("IMMICH_PG_PORT", "", env),
                "user": env_str("IMMICH_PG_USER", "", env),
            },
        )

    @property
    def stamp_path(self):
        return f"{self.state_dir}/drain-state.json"


def maybe_requeue_embeddings(cfg, waiting, now, opener=None, save=None, load=None):
    """Ask Immich to embed what it never retried — at most once per interval.

    Returns a short reason string for the log, so a quiet pass still says WHY it
    was quiet.
    """
    if not waiting:
        return "nothing waiting on embeddings"
    stamp = (load or load_json)(cfg.stamp_path, {})
    last = stamp.get("lastRequeue", 0)
    if now - last < cfg.requeue_every:
        return f"requeued {int(now - last)}s ago, holding off"
    if not api.ml_healthy(cfg, opener=opener):
        return "ML server unreachable — will retry next pass"
    if not cfg.apply:
        return f"would requeue smartSearch for {len(waiting)} waiting assets (dry run)"
    api.start_job(cfg, "smartSearch", force=False, opener=opener)
    (save or save_json)(cfg.stamp_path, dict(stamp, lastRequeue=int(now)))
    return f"requeued Immich smartSearch (missing) — {len(waiting)} assets waiting"


def run(cfg, connect=None, opener=None, queue_conn=None, now=None):
    now = time.time() if now is None else now
    conn_q = queue_conn if queue_conn is not None else queue.connect(cfg.queue_db)

    aged = queue.expire(conn_q, cfg.max_age_days, now)
    if aged:
        log(f"retired {len(aged)} entries older than {cfg.max_age_days}d "
            f"(never embedded): {aged[:3]}{' …' if len(aged) > 3 else ''}")

    items = queue.pending(conn_q)
    if not items:
        log("queue empty")
        return 0

    conn = (connect or connect_pg)(cfg)
    profiles, filed, decided, waiting = {}, 0, 0, []
    try:
        conn.autocommit = True
        cur = conn.cursor()

        alive = existing_asset_ids(cur, [i["assetId"] for i in items])
        gone = queue.drop_missing(conn_q, alive, [i["assetId"] for i in items])
        if gone:
            log(f"dropped {len(gone)} entries whose asset was deleted")
        items = [i for i in items if i["assetId"] in alive]

        for item in items:
            name = item["profile"]
            if name not in profiles:
                try:
                    profiles[name] = load_profile(cfg.profile_dir, name, cfg.model or None)
                except ProfileError as e:
                    profiles[name] = None
                    log(f"profile {name!r} unusable, leaving its entries queued: {e}")
            profile = profiles[name]
            if profile is None:
                continue

            distance = distance_to(cur, item["assetId"], profile["vector"])
            if distance is None:
                waiting.append(item["assetId"])
                queue.bump(conn_q, item["assetId"], item["profile"])
                continue

            decided += 1
            match = distance <= item["threshold"]
            if match and item["albumIds"]:
                if cfg.apply:
                    filed += file_into_albums(cfg, item["albumIds"], item["assetId"])
                else:
                    filed += 1  # counted, not written
            log(f"{item['assetId']} d={distance:.4f} "
                f"{'MATCH' if match else 'no'}{'' if cfg.apply else ' (dry run)'}")
            if cfg.apply:
                queue.resolve(conn_q, item["assetId"], item["profile"])
    finally:
        conn.close()

    log(f"decided {decided}, filed {filed}, still waiting {len(waiting)}"
        f"{'' if cfg.apply else ' — DRY RUN, nothing written'}")
    log(maybe_requeue_embeddings(cfg, waiting, now, opener=opener))
    return 0


def main(env=None, connect=None, opener=None, queue_conn=None):
    return run(Config.from_env(env), connect=connect, opener=opener, queue_conn=queue_conn)


if __name__ == "__main__":
    sys.exit(main())
