#!/usr/bin/env python3
"""
immich-to-dawarich: geotagged Immich photos -> Dawarich points, nightly.

Dawarich's own "Import geodata from Immich" is a one-off from the web UI; the
mobile app's automatic photo import is paid. This keeps photo fixes flowing as
points under the phone's tracker id, so they fill gaps in its sparse track.

Immich URL and key come from the Dawarich user's own integration settings, so no
secret is copied anywhere. Immich search only returns that key owner's assets.

The first run backfills from the newest photo point already in Dawarich (the
web UI import); later runs ask for assets *updated* since the last run minus
OVERLAP_S, which also catches late uploads of old photos. Dawarich upserts on
(user, timestamp, lonlat), so re-sending a photo is harmless.

Env: DAWARICH_{BASE_URL,TRACKER_ID}, IMMICH_DAWARICH_{STATE,DRY_RUN},
PSQL_BIN, RUNUSER_BIN.
"""

import json
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone

from ..httpjson import post_json
from ..logs import logger
from ..pg import psql_rows
from ..secrets import env_str
from ..state import load_json, save_json
from .freereps_dawarich import dawarich_identity

TAG = "immich-to-dawarich"
DEFAULT_BASE = "http://127.0.0.1:13900"
OVERLAP_S = 2 * 86400
PAGE_SIZE = 250
BATCH = 500
TIMEOUT_S = 180  # a cold Immich search took ~20 s on the Pi


@dataclass(frozen=True)
class Config:
    base_url: str = DEFAULT_BASE
    tracker_id: str = ""
    state_path: str = ""
    dry_run: bool = True
    runuser: str = "runuser"
    psql: str = "psql"

    @classmethod
    def from_env(cls, env=None):
        return cls(
            base_url=env_str("DAWARICH_BASE_URL", DEFAULT_BASE, env).rstrip("/"),
            tracker_id=env_str("DAWARICH_TRACKER_ID", "", env),
            state_path=env_str("IMMICH_DAWARICH_STATE", "", env),
            dry_run=env_str("IMMICH_DAWARICH_DRY_RUN", "1", env) != "0",
            runuser=env_str("RUNUSER_BIN", "runuser", env),
            psql=env_str("PSQL_BIN", "psql", env),
        )


def _iso(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def immich_settings(cfg, run, uid):
    """(url, api_key) from the Dawarich user's integration settings."""
    rows = psql_rows(run, f"""
        SELECT settings->>'immich_url', settings->>'immich_api_key'
        FROM users WHERE id = {int(uid)}
    """, "dawarich", cfg.runuser, cfg.psql)
    url, key = (rows[0] + ["", ""])[:2] if rows else ("", "")
    if not url or not key:
        raise RuntimeError("Immich is not configured in Dawarich's integrations")
    return url.rstrip("/"), key


def backfill_start(cfg, run, uid):
    """Epoch of the newest point from a Dawarich Immich import, else 0."""
    rows = psql_rows(run, f"""
        SELECT coalesce(max(p.timestamp), 0) FROM points p
        JOIN imports i ON i.id = p.import_id
        WHERE p.user_id = {int(uid)} AND i.source = 5
    """, "dawarich", cfg.runuser, cfg.psql)  # 5 = immich_api
    return int(rows[0][0]) if rows else 0


def search(url, key, filters, opener=None):
    """Every asset matching `filters` (Immich metadata search, all pages)."""
    assets, page = [], 1
    while page:
        body = {**filters, "withExif": True, "size": PAGE_SIZE, "page": page}
        status, raw = post_json(f"{url}/api/search/metadata", body,
                                headers={"x-api-key": key}, timeout=TIMEOUT_S,
                                opener=opener)
        if status != 200:
            raise RuntimeError(f"Immich search HTTP {status} {raw[:200]}")
        found = json.loads(raw).get("assets", {})
        assets += found.get("items", [])
        page = int(found["nextPage"]) if found.get("nextPage") else None
    return assets


def fix(asset):
    """(epoch_s, lat, lon, asset_id), or None when the asset has no usable GPS."""
    exif = asset.get("exifInfo") or {}
    lat, lon = exif.get("latitude"), exif.get("longitude")
    when = asset.get("fileCreatedAt") or exif.get("dateTimeOriginal")
    if (asset.get("isTrashed") or asset.get("visibility") == "locked"
            or not lat or not lon or not when):
        return None
    t = datetime.fromisoformat(when.replace("Z", "+00:00"))
    return int(t.timestamp()), float(lat), float(lon), asset["id"]


def payload(fixes, tracker):
    return {"locations": [
        {"type": "Feature",
         "geometry": {"type": "Point", "coordinates": [lon, lat]},
         "properties": {"timestamp": t, "device_id": tracker,
                        "source": "immich", "asset_id": aid}}
        for t, lat, lon, aid in fixes]}


def sync(cfg, run, opener=None, log=print, now=time.time):
    """Push photo fixes new since the last run. Returns points sent."""
    state = load_json(cfg.state_path, {}) if cfg.state_path else {}
    uid, api_key, tracker = dawarich_identity(cfg, run)
    url, key = immich_settings(cfg, run, uid)
    started = int(now())
    if "last_run" in state:
        filters = {"updatedAfter": _iso(state["last_run"] - OVERLAP_S)}
    else:
        filters = {"takenAfter": _iso(backfill_start(cfg, run, uid))}
    fixes = sorted({f for f in map(fix, search(url, key, filters, opener)) if f})
    log(f"{filters}: {len(fixes)} geotagged photos")
    if cfg.dry_run:
        return 0
    for i in range(0, len(fixes), BATCH):
        status, body = post_json(
            f"{cfg.base_url}/api/v1/points", payload(fixes[i:i + BATCH], tracker),
            headers={"Authorization": f"Bearer {api_key}"}, opener=opener)
        if status != 200:
            raise RuntimeError(f"Dawarich HTTP {status} {body[:200]}")
    state["last_run"] = started
    if cfg.state_path:
        save_json(cfg.state_path, state)
    return len(fixes)


def main(env=None, run=None, opener=None):
    cfg = Config.from_env(env)
    log = logger(TAG)
    if run is None:
        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True,
                                  check=True).stdout
    try:
        sent = sync(cfg, run, opener=opener, log=log)
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as e:
        log(f"FATAL: {e}")
        return 1
    if sent:
        log(f"done: {sent} points")
    return 0


if __name__ == "__main__":
    sys.exit(main())
