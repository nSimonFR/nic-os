#!/usr/bin/env python3
"""
spotify-to-ryot: Spotify listening history -> Ryot (Generic JSON sink).

Spotify `music` is a native Ryot source (the backend resolves a track by its raw
id via GET /v1/tracks/{id} — needs MUSIC_SPOTIFY_CLIENT_ID/SECRET in ryot-env).
We poll the user's recently-played tracks and push each new listen as a completed
music "seen" to Ryot's Generic JSON integration webhook.

Idempotency: Spotify's recently-played endpoint takes an `after` cursor (Unix ms).
We persist the newest `played_at` we've seen (spotify-cursor.json) and only ask
for tracks after it, so overlapping polls never re-push a listen. Each play has a
real timestamp, so this is a clean append-only fit for the sink (no dedup needed
on Ryot's side).

Stdlib only. Config via environment:
  SPOTIFY_CLIENT_ID       Spotify app client id                    [required]
  SPOTIFY_CLIENT_SECRET   Spotify app client secret                [required]
  SPOTIFY_REFRESH_TOKEN   OAuth refresh token, scope
                          user-read-recently-played                [required]
  RYOT_WEBHOOK_URL        Ryot Generic JSON URL (.../ryot/_i/<slug>) [required]
  STATE_DIR               state directory        (default /var/lib/ryot-connectors)
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

SPOTIFY_CLIENT_ID = os.environ.get("SPOTIFY_CLIENT_ID", "")
SPOTIFY_CLIENT_SECRET = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
SPOTIFY_REFRESH_TOKEN = os.environ.get("SPOTIFY_REFRESH_TOKEN", "")
RYOT_WEBHOOK_URL = os.environ.get("RYOT_WEBHOOK_URL", "")
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/ryot-connectors")

CURSOR_FILE = os.path.join(STATE_DIR, "spotify-cursor.json")


def log(msg):
    print(f"[spotify-to-ryot] {msg}", flush=True)


def http_json(req, timeout=30):
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw else {}


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def get_access_token():
    creds = base64.b64encode(
        f"{SPOTIFY_CLIENT_ID}:{SPOTIFY_CLIENT_SECRET}".encode()
    ).decode()
    body = urllib.parse.urlencode(
        {"grant_type": "refresh_token", "refresh_token": SPOTIFY_REFRESH_TOKEN}
    ).encode()
    req = urllib.request.Request(
        "https://accounts.spotify.com/api/token",
        data=body,
        headers={
            "Authorization": "Basic " + creds,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    return http_json(req)["access_token"]


def get_recently_played(token, after_ms):
    query = {"limit": 50}
    if after_ms:
        query["after"] = after_ms
    url = (
        "https://api.spotify.com/v1/me/player/recently-played?"
        + urllib.parse.urlencode(query)
    )
    req = urllib.request.Request(
        url, headers={"Authorization": "Bearer " + token}
    )
    return http_json(req).get("items", [])


def build_payload(items, after_ms):
    """Return (metadata, new_cursor_ms). Only listens newer than after_ms."""
    metadata = []
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
        metadata.append(
            {
                "lot": "music",
                "source": "spotify",
                "identifier": tid,
                "source_id": track.get("name", tid),
                # reviews + collections are non-optional in ImportOrExportMetadataItem;
                # omitting them makes Ryot's strict deserialize drop the whole item.
                "reviews": [],
                "collections": [],
                "seen_history": [
                    {
                        "progress": 100,
                        "ended_on": played_at,
                        "providers_consumed_on": ["Spotify"],
                    }
                ],
            }
        )
    return metadata, newest


def iso_to_ms(iso):
    # Spotify sends RFC3339 with optional millis and a trailing Z.
    from datetime import datetime, timezone

    s = iso.replace("Z", "+00:00")
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def post_to_ryot(metadata):
    body = json.dumps({"metadata": metadata}).encode()
    req = urllib.request.Request(
        RYOT_WEBHOOK_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.status, resp.read().decode()


def main():
    missing = [
        k
        for k in (
            "SPOTIFY_CLIENT_ID",
            "SPOTIFY_CLIENT_SECRET",
            "SPOTIFY_REFRESH_TOKEN",
            "RYOT_WEBHOOK_URL",
        )
        if not os.environ.get(k)
    ]
    if missing:
        log(f"FATAL: missing env: {', '.join(missing)}")
        sys.exit(1)
    os.makedirs(STATE_DIR, exist_ok=True)

    after_ms = load_json(CURSOR_FILE, {}).get("after_ms")
    try:
        token = get_access_token()
        items = get_recently_played(token, after_ms)
    except (urllib.error.URLError, KeyError) as e:
        log(f"FATAL: Spotify API failed: {e}")
        sys.exit(1)

    metadata, new_cursor = build_payload(items, after_ms)
    if not metadata:
        log("no new listens since last run — nothing to push")
        return

    log(f"pushing {len(metadata)} new listens")
    try:
        status, resp = post_to_ryot(metadata)
    except urllib.error.URLError as e:
        log(f"FATAL: push to Ryot failed: {e}")
        sys.exit(1)
    if status not in (200, 201, 202):
        log(f"FATAL: Ryot returned {status}: {resp[:300]}")
        sys.exit(1)

    save_json(CURSOR_FILE, {"after_ms": new_cursor})
    log(f"done (Ryot {status}); cursor advanced to {new_cursor}")


if __name__ == "__main__":
    main()
