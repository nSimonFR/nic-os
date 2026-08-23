#!/usr/bin/env python3
"""
spotify-to-ryot: Spotify listening history -> Ryot (Generic JSON sink).

Spotify `music` is a native Ryot source (the backend resolves a track by its raw
id via GET /v1/tracks/{id} — needs MUSIC_SPOTIFY_CLIENT_ID/SECRET in ryot-env).
We poll the user's recently-played tracks and push each new listen as a completed
music "seen" to Ryot's Generic JSON integration webhook.

Idempotency: we ask for the full window Spotify exposes (the last 50 plays) every
run and drop what we've already sent, keyed on (track id, played_at) in
spotify-cursor.json. We deliberately do NOT pass the endpoint's `after` cursor:
a play cached offline on the phone syncs hours later but keeps its *original*
`played_at`, so anchoring the request (or a floor) to the newest timestamp we'd
seen silently dropped every late arrival. Per-listen keys make an overlapping
poll safe without needing that floor.

Retention: keys are pruned to RETAIN_DAYS behind the high-water mark. Since the
endpoint only ever exposes 50 plays, the window it spans is far shorter than the
retention horizon at any realistic listening rate — a listener quiet enough for
50 plays to reach back past RETAIN_DAYS would see the oldest re-pushed, which
Ryot absorbs as an in-place update of the same seen (no duplicate).

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
# How far behind the high-water mark we remember per-listen keys. Only has to
# outlast the span of the 50 plays the endpoint returns; 30d is ~20x that at the
# observed rate.
RETAIN_DAYS = 30
RETAIN_MS = RETAIN_DAYS * 24 * 60 * 60 * 1000
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


def get_recently_played(token, opener=None):
    """The full window Spotify exposes — 50 plays, newest first.

    No `after` cursor on purpose: it is applied against `played_at`, so a play
    that syncs late from an offline device lands *behind* the cursor and would
    never be returned. Dedupe happens locally instead (see build_payload).
    """
    url = (
        "https://api.spotify.com/v1/me/player/recently-played?"
        + urllib.parse.urlencode({"limit": 50})
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


def listen_key(tid, ms):
    """Identity of a single listen. Track ids are base62, so `@` can't collide."""
    return f"{tid}@{ms}"


def key_ms(key):
    """The played_at ms back out of a key, or None if it doesn't parse."""
    _, _, tail = key.rpartition("@")
    try:
        return int(tail)
    except ValueError:
        return None


def prune_keys(keys, newest_ms):
    """Drop keys more than RETAIN_DAYS behind the high-water mark."""
    if not newest_ms:
        return sorted(keys)
    horizon = newest_ms - RETAIN_MS
    kept = (k for k in keys if (key_ms(k) or 0) >= horizon)
    return sorted(kept)


def build_payload(items, known, pushed, prev_newest=None, floor_ms=None):
    """Return (metadata, new_high_water_ms, first_evers).

    Skips listens already in `pushed` (keys of (track id, played_at)); `pushed` is
    mutated with the keys of everything returned here, so a caller that fails to
    deliver must discard it rather than persist it.

    `floor_ms` drops listens at or before that timestamp. Used only to bootstrap a
    state file written before per-listen keys existed — without keys, every play in
    the window looks new, and the floor stands in for the missing history exactly
    once. Passing it routinely would reintroduce the offline-sync gap.

    `first_evers` are the {identifier, source_id, ended_on} of tracks never pushed
    before (not in `known`) — these land as in_progress@0 because Ryot resolves
    their metadata asynchronously (the sink runs on the live-progress path, not the
    import path), so they must be re-pushed once metadata exists (see main()).
    `known` is mutated with any new identifiers.
    """
    metadata = []
    first_evers = []
    newest = prev_newest or 0
    for it in items:
        played_at = it.get("played_at")  # ISO8601, e.g. 2026-07-22T09:15:00.123Z
        track = it.get("track") or {}
        tid = track.get("id")
        if not played_at or not tid:
            continue
        ms = iso_to_ms(played_at)
        key = listen_key(tid, ms)
        if floor_ms and ms <= floor_ms:
            # Below the bootstrap floor: not ours to push, but recording the key
            # retires the floor — the next run needs no stand-in for history.
            pushed.add(key)
            continue
        if key in pushed:
            continue
        pushed.add(key)
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
    # `after_ms` is the pre-per-listen-key name for the high-water mark.
    prev_newest = state.get("newest_ms", state.get("after_ms"))
    known = set(state.get("known", []))
    prev_pending = state.get("pending", [])
    # A state file with no `pushed` predates per-listen keys; fall back to the
    # high-water mark as a floor for this run only, so the migration doesn't
    # re-push the whole window.
    legacy = "pushed" not in state
    pushed = set(state.get("pushed", []))
    try:
        token = get_access_token(cfg, opener=opener)
        items = get_recently_played(token, opener=opener)
    except (urllib.error.URLError, KeyError) as e:
        log(f"FATAL: Spotify API failed: {e}")
        return 1

    new_metadata, new_newest, first_evers = build_payload(
        items,
        known,
        pushed,
        prev_newest=prev_newest,
        floor_ms=prev_newest if legacy else None,
    )

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
        {
            "newest_ms": new_newest,
            "known": sorted(known),
            "pending": first_evers,
            "pushed": prune_keys(pushed, new_newest),
        },
    )
    log(
        f"done (Ryot {status}); newest {new_newest}; "
        f"{len(first_evers)} tracks pending completion next run"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
