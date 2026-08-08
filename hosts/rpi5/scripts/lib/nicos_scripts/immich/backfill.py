#!/usr/bin/env python3
"""Calibrate a CLIP profile, and catch up whatever the live workflow missed.

    sudo -u immich immich-clip-backfill --profile food --album Food           # report
    sudo -u immich immich-clip-backfill --profile food --album Food --apply   # write

Two jobs, one query:

1. **Calibration.** The right threshold is not guessable — it depends on the
   profile and on your library. The dry run prints the distance histogram and the
   nearest N filenames, so the threshold can be read off the gap between "clearly
   food" and "clearly not".

2. **Catch-up.** The workflow step is best-effort by construction: it waits a
   bounded time for Immich's SmartSearch job, so a photo uploaded while the ML
   server was offline, or during an import that backed the queue up, is never
   added. Nothing retries that automatically — this is the retry, run by hand.

Dry run by default. `--apply` is the only thing that writes, and it only ever
adds; nothing here removes an asset from an album, so a threshold set too loose
is a cleanup job rather than data loss.
"""

import argparse
import sys
from dataclasses import dataclass, field

from ..logs import logger
from ..secrets import env_str, read_secret_env
from . import api
from .store import ProfileError, album_id_by_name, connect_pg, load_profile
from .vectors import format_vector

DEFAULT_PROFILE_DIR = "/var/lib/immich-clip/profiles"
DEFAULT_KEY_FILE = "/run/agenix/immich-clip-api-key"
log = logger("immich-clip-backfill")


@dataclass(frozen=True)
class Config:
    immich_url: str = "http://127.0.0.1:2283"
    api_key: str = ""
    ml_url: str = ""
    model: str = ""
    profile_dir: str = DEFAULT_PROFILE_DIR
    pg: dict = field(default_factory=lambda: {"dbname": "immich"})

    @classmethod
    def from_env(cls, env=None):
        return cls(
            immich_url=env_str("IMMICH_URL", "http://127.0.0.1:2283", env).rstrip("/"),
            api_key=read_secret_env("IMMICH_API_KEY_FILE", DEFAULT_KEY_FILE, env) or "",
            ml_url=env_str("IMMICH_ML_URL", "", env).rstrip("/"),
            model=env_str("IMMICH_CLIP_MODEL", "", env),
            profile_dir=env_str("IMMICH_CLIP_PROFILE_DIR", DEFAULT_PROFILE_DIR, env),
            pg={
                "dbname": env_str("IMMICH_PG_DB", "immich", env),
                "host": env_str("IMMICH_PG_HOST", "", env),
                "port": env_str("IMMICH_PG_PORT", "", env),
                "user": env_str("IMMICH_PG_USER", "", env),
            },
        )


# The MATERIALIZED CTE is load-bearing, not style. `smart_search.embedding` has a
# vchordrq index, which is an APPROXIMATE (ANN) index: it answers
# `ORDER BY embedding <=> const` by probing a subset of lists, and with probes=1
# it returned visibly out-of-order distances in testing. That is fine for "show
# me 20 similar photos" and wrong for "every asset at or under this threshold".
# It also raises `need 1 probes, but 0 probes provided` outright when the GUC is
# unset — at PLAN time, so `SET LOCAL enable_indexscan = off` does not avoid it
# (verified: the EXPLAIN itself still errors).
#
# Computing the distances inside a CTE with no ORDER BY leaves the index nothing
# to serve, so the plan is a plain Seq Scan; the sort then happens outside on an
# ordinary float column. Exact, and independent of planner GUCs. A few thousand
# rows is cheap.
SCAN_SQL = """
WITH scored AS MATERIALIZED (
    SELECT s."assetId" AS asset_id, s.embedding <=> %s::vector AS d
    FROM smart_search s
)
SELECT sc.asset_id, a."originalFileName", sc.d
FROM scored sc
JOIN asset a ON a.id = sc.asset_id
WHERE a."deletedAt" IS NULL
  AND a.type = 'IMAGE'
  AND a.visibility NOT IN ('hidden', 'locked')
  AND NOT EXISTS (
    SELECT 1 FROM album_asset aa WHERE aa."assetId" = sc.asset_id AND aa."albumId" = %s
  )
ORDER BY sc.d
"""


def scan(cur, vector, album_id):
    cur.execute(SCAN_SQL, (format_vector(vector), album_id))
    return [(str(r[0]), r[1], float(r[2])) for r in cur.fetchall()]


def histogram(rows, width=0.05, bars=48):
    """Distance distribution — where the threshold should be read off."""
    if not rows:
        return ["(nothing to score)"]
    buckets = {}
    for _, _, d in rows:
        buckets[int(d / width)] = buckets.get(int(d / width), 0) + 1
    peak = max(buckets.values())
    out = []
    for b in range(min(buckets), max(buckets) + 1):
        n = buckets.get(b, 0)
        out.append(f"  {b * width:.2f}–{(b + 1) * width:.2f}  {n:6d} "
                   f"{'#' * max(1, round(n * bars / peak)) if n else ''}")
    return out


def run(cfg, args, connect=None, opener=None):
    model = api.clip_model(cfg, opener=opener)
    try:
        profile = load_profile(cfg.profile_dir, args.profile, model)
    except ProfileError as e:
        raise SystemExit(str(e))

    conn = (connect or connect_pg)(cfg)
    try:
        conn.autocommit = False
        cur = conn.cursor()
        album_id = album_id_by_name(cur, args.album)
        if not album_id:
            if not args.create_album:
                raise SystemExit(
                    f"no album named {args.album!r} — create it, or pass --create-album"
                )
            if args.apply:
                album_id = api.create_album(
                    cfg, args.album, "Auto-filled by the nic-clip workflow step",
                    opener=opener,
                )
                log(f"created album {args.album!r} ({album_id})")
            else:
                # Keep the dry run genuinely read-only. A None album id simply
                # excludes nothing from the scan, which is the right answer for
                # an album that does not exist yet.
                log(f"album {args.album!r} does not exist yet — --apply would create it")
        rows = scan(cur, profile["vector"], album_id)
        conn.rollback()
    finally:
        conn.close()

    log(f"scored {len(rows)} candidate assets against profile {args.profile!r} "
        f"(built from {profile.get('built_from')})")
    for line in histogram(rows):
        print(line)

    print(f"\n  nearest {args.top}:")
    for asset_id, name, d in rows[: args.top]:
        print(f"  {d:.4f}  {name}  {asset_id}")

    hits = [(a, n, d) for a, n, d in rows if d <= args.threshold]
    print(f"\n  {len(hits)} of {len(rows)} at or under threshold {args.threshold}")

    if not args.apply:
        log("dry run — nothing written. Re-run with --apply once the threshold looks right.")
        return 0
    if not hits:
        log("nothing to add")
        return 0
    added = api.add_assets(cfg, album_id, [a for a, _, _ in hits], opener=opener, log=log)
    log(f"added {added} assets to {args.album!r}")
    return 0


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="immich-clip-backfill")
    ap.add_argument("--profile", required=True)
    ap.add_argument("--album", required=True)
    ap.add_argument("--threshold", type=float, default=0.28)
    ap.add_argument("--top", type=int, default=40, help="how many nearest to list")
    ap.add_argument("--create-album", action="store_true")
    # The safe default: a run with no flags reports and writes nothing.
    ap.add_argument("--apply", action="store_true", help="actually add the matches")
    return ap.parse_args(argv)


def main(argv=None, env=None, connect=None, opener=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    cfg = Config.from_env(env)
    if args.apply and not cfg.api_key:
        raise SystemExit("no Immich API key — set IMMICH_API_KEY_FILE")
    return run(cfg, args, connect=connect, opener=opener)


if __name__ == "__main__":
    sys.exit(main())
