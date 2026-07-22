#!/usr/bin/env python3
"""
steam-to-ryot: Steam library + playtime -> Ryot (Generic JSON sink).

Steam is NOT a native Ryot source (only `igdb`/`giant_bomb` exist for games), so
we resolve each Steam appid to an IGDB game id (via the Twitch/IGDB API) and push
a `CompleteExport` payload to Ryot's Generic JSON integration webhook. Ryot's
backend then resolves the IGDB id to full metadata (needs
VIDEO_GAMES_TWITCH_CLIENT_ID/SECRET in ryot-env) and files the game under a
collection, optionally with a play "seen".

Idempotency (the sink has no seen dedup — re-pushing the same seen duplicates it):
  * State in $STATE_DIR (steam-state.json) tracks, per appid, the last
    playtime_forever we've pushed and whether the game is already in the
    collection. A game is (re)sent only when it is new to the collection or when
    its total playtime has grown.
  * appid -> IGDB id resolutions are cached (steam-igdb-map.json) since IGDB is
    rate-limited; a "" value marks a known-unmapped appid so we don't re-query.

Playtime model (best-effort — Steam exposes only cumulative time, no sessions or
completion signal): each time playtime_forever grows by >= MIN_DELTA_MIN minutes
we emit ONE seen carrying that delta as `manual_time_spent` (seconds). Total time
spent therefore aggregates correctly; the trade-off is that each growth counts as
a "seen"/completion in Ryot. A v2 could switch to the GraphQL API to keep exactly
one evolving seen per game.

Stdlib only. Config via environment:
  STEAM_API_KEY           Steam Web API key (steamcommunity.com/dev/apikey)   [required]
  STEAM_ID64              64-bit SteamID of the profile to sync               [required]
  TWITCH_CLIENT_ID        Twitch/IGDB app client id                          [required]
  TWITCH_CLIENT_SECRET    Twitch/IGDB app client secret                      [required]
  RYOT_WEBHOOK_URL        Ryot Generic JSON integration URL (.../ryot/_i/<slug>) [required]
  STATE_DIR               state directory                 (default /var/lib/ryot-connectors)
  COLLECTION_NAME         collection to file games under  (default "Steam")
  MIN_DELTA_MIN           min playtime growth to log a seen, minutes (default 1)
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

STEAM_API_KEY = os.environ.get("STEAM_API_KEY", "")
STEAM_ID64 = os.environ.get("STEAM_ID64", "")
TWITCH_CLIENT_ID = os.environ.get("TWITCH_CLIENT_ID", "")
TWITCH_CLIENT_SECRET = os.environ.get("TWITCH_CLIENT_SECRET", "")
RYOT_WEBHOOK_URL = os.environ.get("RYOT_WEBHOOK_URL", "")
STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/ryot-connectors")
COLLECTION_NAME = os.environ.get("COLLECTION_NAME", "Steam")
MIN_DELTA_MIN = int(os.environ.get("MIN_DELTA_MIN", "1"))

STATE_FILE = os.path.join(STATE_DIR, "steam-state.json")
IGDB_MAP_FILE = os.path.join(STATE_DIR, "steam-igdb-map.json")

# IGDB external_games.category for Steam (EXTERNAL_GAME_CATEGORY_STEAM).
IGDB_STEAM_CATEGORY = 1


def log(msg):
    print(f"[steam-to-ryot] {msg}", flush=True)


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


def get_owned_games():
    params = urllib.parse.urlencode(
        {
            "key": STEAM_API_KEY,
            "steamid": STEAM_ID64,
            "include_appinfo": 1,
            "include_played_free_games": 1,
            "format": "json",
        }
    )
    url = (
        "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?" + params
    )
    data = http_json(urllib.request.Request(url))
    games = data.get("response", {}).get("games", [])
    log(f"Steam reports {len(games)} owned games")
    return games


def get_twitch_token():
    params = urllib.parse.urlencode(
        {
            "client_id": TWITCH_CLIENT_ID,
            "client_secret": TWITCH_CLIENT_SECRET,
            "grant_type": "client_credentials",
        }
    )
    req = urllib.request.Request(
        "https://id.twitch.tv/oauth2/token?" + params, method="POST"
    )
    return http_json(req)["access_token"]


def resolve_igdb_ids(appids, token, igdb_map):
    """Fill igdb_map for appids not already cached. Returns nothing (mutates map)."""
    todo = [a for a in appids if str(a) not in igdb_map]
    if not todo:
        return
    log(f"resolving {len(todo)} new appids against IGDB")
    headers = {
        "Client-ID": TWITCH_CLIENT_ID,
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
    }
    # IGDB caps queries at 500 results; chunk the appid list.
    for i in range(0, len(todo), 400):
        chunk = todo[i : i + 400]
        uids = ",".join(f'"{a}"' for a in chunk)
        body = (
            f"fields game,uid; "
            f"where category = {IGDB_STEAM_CATEGORY} & uid = ({uids}); "
            f"limit 500;"
        ).encode()
        req = urllib.request.Request(
            "https://api.igdb.com/v4/external_games", data=body, headers=headers
        )
        try:
            rows = http_json(req)
        except urllib.error.HTTPError as e:
            log(f"IGDB query failed ({e.code}); leaving chunk unresolved")
            continue
        found = {}
        for row in rows:
            uid = str(row.get("uid"))
            game = row.get("game")
            if uid and game is not None:
                found[uid] = str(game)
        for a in chunk:
            # "" marks a known-unmapped appid so we don't re-query it forever.
            igdb_map[str(a)] = found.get(str(a), "")
        time.sleep(0.3)  # stay well under IGDB's 4 req/s
    log(
        f"IGDB cache now has {sum(1 for v in igdb_map.values() if v)} mapped / "
        f"{len(igdb_map)} total"
    )


def build_payload(games, igdb_map, state):
    now = datetime.now(timezone.utc).isoformat()
    metadata = []
    pending = {}  # appid -> new state, applied only after a successful push
    for g in games:
        appid = str(g.get("appid"))
        igdb_id = igdb_map.get(appid)
        if not igdb_id:
            continue  # unmapped in IGDB — skip
        name = g.get("name", appid)
        playtime = int(g.get("playtime_forever", 0))  # minutes
        prev = state.get(appid, {})
        last_pt = int(prev.get("pt", 0))
        added = bool(prev.get("added", False))
        delta = playtime - last_pt

        seen = []
        if delta >= MIN_DELTA_MIN:
            seen = [
                {
                    "progress": 100,
                    "manual_time_spent": str(delta * 60),  # seconds, Decimal-as-string
                    "ended_on": now,
                    "providers_consumed_on": ["Steam"],
                }
            ]

        # Only (re)send a game when it's new to the collection or has new playtime.
        if added and not seen:
            continue

        metadata.append(
            {
                "lot": "video_game",
                "source": "igdb",
                "identifier": igdb_id,
                "source_id": name,
                # reviews is non-optional in ImportOrExportMetadataItem; omitting it
                # makes Ryot's strict deserialize drop the whole item.
                "reviews": [],
                "collections": [{"collection_name": COLLECTION_NAME}],
                "seen_history": seen,
            }
        )
        pending[appid] = {"pt": playtime, "added": True}
    return metadata, pending


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
        for k in ("STEAM_API_KEY", "STEAM_ID64", "RYOT_WEBHOOK_URL")
        if not os.environ.get(k)
    ]
    if missing:
        log(f"FATAL: missing env: {', '.join(missing)}")
        sys.exit(1)
    if not (TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET):
        # IGDB resolution (and the backend's) needs Twitch creds. Until they're
        # configured the connector is installed-but-dormant — skip cleanly rather
        # than fail the timer.
        log("Twitch/IGDB creds not set — Steam metadata can't resolve yet; skipping")
        return
    os.makedirs(STATE_DIR, exist_ok=True)

    state = load_json(STATE_FILE, {})
    igdb_map = load_json(IGDB_MAP_FILE, {})

    games = get_owned_games()
    if not games:
        log("no games returned (private profile or empty library?) — nothing to do")
        return

    appids = [g.get("appid") for g in games if g.get("appid") is not None]
    resolve_igdb_ids(appids, get_twitch_token(), igdb_map)
    save_json(IGDB_MAP_FILE, igdb_map)  # cache resolutions regardless of push outcome

    metadata, pending = build_payload(games, igdb_map, state)
    if not metadata:
        log("no new games or playtime since last run — nothing to push")
        return

    with_seen = sum(1 for m in metadata if m["seen_history"])
    log(f"pushing {len(metadata)} games ({with_seen} with new playtime)")
    try:
        status, resp = post_to_ryot(metadata)
    except (urllib.error.URLError, KeyError) as e:
        log(f"FATAL: push to Ryot failed: {e}")
        sys.exit(1)
    if status not in (200, 201, 202):
        log(f"FATAL: Ryot returned {status}: {resp[:300]}")
        sys.exit(1)

    state.update(pending)
    save_json(STATE_FILE, state)
    log(f"done (Ryot {status}); state persisted for {len(pending)} games")


if __name__ == "__main__":
    main()
