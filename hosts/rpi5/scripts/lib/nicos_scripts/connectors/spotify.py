#!/usr/bin/env python3
"""
spotify-to-ryot: Spotify listening history -> Ryot (Generic JSON sink).

Spotify `music` is a native Ryot source (the backend resolves a track by its raw
id via GET /v1/tracks/{id} — needs MUSIC_SPOTIFY_CLIENT_ID/SECRET in ryot-env).
We poll the user's recently-played tracks and push each new listen as a completed
music "seen" to Ryot's Generic JSON integration webhook.

Idempotency: Spotify's recently-played endpoint takes an `after` cursor (Unix ms).
We persist the newest `played_at` we've seen (spotify-cursor.json) and only ask
for tracks after it, so overlapping polls never re-push a listen.

Two-phase completion (mirrors Ryot's own YouTube Music integration): the generic
JSON sink runs on the *live-progress* path (is_import=false), so a track that is
new to Ryot lands as `in_progress@0` — Ryot resolves its metadata asynchronously
and can't finalize the seen in the same beat. So we push each listen, remember the
tracks we'd never pushed before (`known`/`pending` in the state file), and on the
NEXT run re-push those — by then the metadata exists, and the re-push flips the
seen to completed *in place* (no duplicate). Known tracks are never re-pushed, so
already-completed listens are never duplicated.

Stdlib only. Config via environment:
  SPOTIFY_CLIENT_ID       Spotify app client id                    [required]
  SPOTIFY_CLIENT_SECRET   Spotify app client secret                [required]
  SPOTIFY_REFRESH_TOKEN   OAuth refresh token, scope
                          user-read-recently-played                [required]
  RYOT_WEBHOOK_URL        Ryot Generic JSON URL (.../ryot/_i/<slug>) [required]
  STATE_DIR               state directory        (default /var/lib/ryot-connectors)
"""

import base64
import os
import sys
import urllib.error
import urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone

from .. import ryot
from ..httpjson import get_json, post_form
from ..logs import logger
from ..secrets import env_str, missing_env
from ..state import ensure_dir, load_json, save_json

log = logger("spotify-to-ryot")

DEFAULT_STATE_DIR = "/var/lib/ryot-connectors"
REQUIRED_ENV = (
    "SPOTIFY_CLIENT_ID",
    "SPOTIFY_CLIENT_SECRET",
    "SPOTIFY_REFRESH_TOKEN",
    "RYOT_WEBHOOK_URL",
)


@dataclass(frozen=True)
class Config:
    client_id: str = ""
    client_secret: str = ""
    refresh_token: str = ""
    webhook_url: str = ""
    state_dir: str = DEFAULT_STATE_DIR

    @classmethod
    def from_env(cls, env=None):
        return cls(
            client_id=env_str("SPOTIFY_CLIENT_ID", "", env),
            client_secret=env_str("SPOTIFY_CLIENT_SECRET", "", env),
            refresh_token=env_str("SPOTIFY_REFRESH_TOKEN", "", env),
            webhook_url=env_str("RYOT_WEBHOOK_URL", "", env),
            state_dir=env_str("STATE_DIR", DEFAULT_STATE_DIR, env),
        )

    @property
    def cursor_file(self):
        return os.path.join(self.state_dir, "spotify-cursor.json")


def get_access_token(cfg, opener=None):
    creds = base64.b64encode(
        f"{cfg.client_id}:{cfg.client_secret}".encode()
    ).decode()
    return post_form(
        "https://accounts.spotify.com/api/token",
        {"grant_type": "refresh_token", "refresh_token": cfg.refresh_token},
        headers={"Authorization": "Basic " + creds},
        opener=opener,
    )["access_token"]


def get_recently_played(token, after_ms, opener=None):
    query = {"limit": 50}
    if after_ms:
        query["after"] = after_ms
    url = (
        "https://api.spotify.com/v1/me/player/recently-played?"
        + urllib.parse.urlencode(query)
    )
    return get_json(
        url, headers={"Authorization": "Bearer " + token}, opener=opener
    ).get("items", [])


def music_item(identifier, source_id, ended_on):
    return ryot.metadata_item(
        "music",
        "spotify",
        identifier,
        source_id,
        [ryot.seen(ended_on, providers=["Spotify"])],
    )


def iso_to_ms(iso):
    # Spotify sends RFC3339 with optional millis and a trailing Z.
    s = iso.replace("Z", "+00:00")
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def build_payload(items, after_ms, known):
    """Return (metadata, new_cursor_ms, first_evers).

    Only listens newer than after_ms. `first_evers` are the {identifier, source_id,
    ended_on} of tracks never pushed before (not in `known`) — these land as
    in_progress@0 because Ryot resolves their metadata asynchronously (the sink runs
    on the live-progress path, not the import path), so they must be re-pushed once
    metadata exists (see main()). `known` is mutated with any new identifiers.
    """
    metadata = []
    first_evers = []
    newest = after_ms or 0
    for it in items:
        played_at = it.get("played_at")  # ISO8601, e.g. 2026-07-22T09:15:00.123Z
        track = it.get("track") or {}
        tid = track.get("id")
        if not played_at or not tid:
            continue
        ms = iso_to_ms(played_at)
        if after_ms and ms <= after_ms:
            continue
        newest = max(newest, ms)
        metadata.append(music_item(tid, track.get("name", tid), played_at))
        if tid not in known:
            known.add(tid)
            first_evers.append(
                {
                    "identifier": tid,
                    "source_id": track.get("name", tid),
                    "ended_on": played_at,
                }
            )
    return metadata, newest, first_evers


def main(env=None, opener=None):
    cfg = Config.from_env(env)
    missing = missing_env(REQUIRED_ENV, env)
    if missing:
        log(f"FATAL: missing env: {', '.join(missing)}")
        return 1
    ensure_dir(cfg.state_dir)

    state = load_json(cfg.cursor_file, {})
    after_ms = state.get("after_ms")
    known = set(state.get("known", []))
    prev_pending = state.get("pending", [])
    try:
        token = get_access_token(cfg, opener=opener)
        items = get_recently_played(token, after_ms, opener=opener)
    except (urllib.error.URLError, KeyError) as e:
        log(f"FATAL: Spotify API failed: {e}")
        return 1

    new_metadata, new_cursor, first_evers = build_payload(items, after_ms, known)

    # Second phase: re-push last run's first-ever tracks. Their metadata has since
    # resolved, so this flips their in_progress@0 seen to completed (updates in
    # place — no duplicate). Only genuinely-new tracks ever enter this list, so
    # already-completed listens of known tracks are never re-pushed/duplicated.
    repush = [
        music_item(p["identifier"], p["source_id"], p["ended_on"])
        for p in prev_pending
    ]

    all_meta = new_metadata + repush
    if not all_meta:
        log("no new listens and nothing to complete — nothing to push")
        return 0

    log(f"pushing {len(new_metadata)} new listens + {len(repush)} completions")
    try:
        status, resp = ryot.post_export(cfg.webhook_url, all_meta, opener=opener)
    except urllib.error.URLError as e:
        log(f"FATAL: push to Ryot failed: {e}")
        return 1
    if not ryot.is_ok(status):
        log(f"FATAL: Ryot returned {status}: {resp[:300]}")
        return 1

    save_json(
        cfg.cursor_file,
        {"after_ms": new_cursor, "known": sorted(known), "pending": first_evers},
    )
    log(
        f"done (Ryot {status}); cursor {new_cursor}; "
        f"{len(first_evers)} tracks pending completion next run"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
