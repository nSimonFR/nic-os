#!/usr/bin/env python3
"""
steam-to-ryot: Steam library + playtime -> Ryot (Generic JSON sink).

Steam is NOT a native Ryot source (only `igdb`/`giant_bomb` exist for games), so
we resolve each Steam appid to an IGDB game id (via the Twitch/IGDB API) and push
a `CompleteExport` payload to Ryot's Generic JSON integration webhook. Ryot's
backend then resolves the IGDB id to full metadata (needs
VIDEO_GAMES_TWITCH_CLIENT_ID/SECRET in ryot-env). Games attach to the library via
a play "seen" — so only PLAYED games appear (the sink's `collections` field needs
a collection_id + timestamps we can't supply, and a bad entry drops the game).

Playtime model (best-effort — Steam exposes only cumulative time, no sessions or
completion signal): each time playtime_forever grows by >= MIN_DELTA_MIN minutes
we emit ONE seen carrying that delta as `manual_time_spent` (seconds). Total time
spent therefore aggregates correctly; the trade-off is that each growth counts as
a "seen" in Ryot.

Idempotency + completion (mirrors the spotify connector / Ryot's YouTube Music
integration):
  * State $STATE_DIR/steam-state.json = {games:{appid:last_playtime_min},
    pending:[...]}. A game is pushed only when its total playtime grew (the delta
    is one seen); already-synced playtime is never re-pushed (no dup).
  * A game new to Ryot lands as in_progress@0 because the backend resolves its
    IGDB metadata asynchronously. Such first-ever games go into `pending` and are
    re-pushed on the NEXT run — metadata now exists, so the re-push flips the seen
    to completed in place. Known games complete immediately, so they never enter
    pending and are never duplicated.
  * appid -> IGDB id resolutions are cached (steam-igdb-map.json) since IGDB is
    rate-limited; a "" value marks a known-unmapped appid so we don't re-query.

Stdlib only. Config via environment:
  STEAM_API_KEY           Steam Web API key (steamcommunity.com/dev/apikey)   [required]
  STEAM_ID64              64-bit SteamID of the profile to sync               [required]
  TWITCH_CLIENT_ID        Twitch/IGDB app client id                          [required]
  TWITCH_CLIENT_SECRET    Twitch/IGDB app client secret                      [required]
  RYOT_WEBHOOK_URL        Ryot Generic JSON integration URL (.../ryot/_i/<slug>) [required]
  STATE_DIR               state directory                 (default /var/lib/ryot-connectors)
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
MIN_DELTA_MIN = int(os.environ.get("MIN_DELTA_MIN", "1"))

STATE_FILE = os.path.join(STATE_DIR, "steam-state.json")
IGDB_MAP_FILE = os.path.join(STATE_DIR, "steam-igdb-map.json")

# IGDB external_games.external_game_source id for Steam (verified via
# /v4/external_game_sources: id 1 = "Steam"). The older `category` field is
# deprecated and no longer reliably matches Steam rows.
IGDB_STEAM_SOURCE = 1


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
            f"where external_game_source = {IGDB_STEAM_SOURCE} & uid = ({uids}); "
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


def game_seen(seconds, ended_on):
    return [
        {
            "progress": 100,
            "manual_time_spent": seconds,  # Decimal-as-string
            "ended_on": ended_on,
            "providers_consumed_on": ["Steam"],
        }
    ]


def game_item(igdb_id, name, seen):
    return {
        "lot": "video_game",
        "source": "igdb",
        "identifier": igdb_id,
        "source_id": name,
        # reviews + collections are non-optional in ImportOrExportMetadataItem;
        # omitting them makes Ryot's strict deserialize drop the whole item.
        # NOTE collections stays []: CollectionToEntityDetails needs collection_id +
        # timestamps we can't supply from here, and a bad collection entry drops the
        # whole game. Games therefore attach to the library via their seen (played
        # games only — an unplayed game has no seen and so does not persist).
        "reviews": [],
        "collections": [],
        "seen_history": seen,
    }


def build_payload(games, igdb_map, prev_games):
    """Return (metadata, new_games, first_evers).

    Push a game only when its total playtime grew (the delta is recorded as one
    play "seen"); an unplayed game has no seen and cannot persist via the sink, so
    it is skipped. `first_evers` are games never pushed before — they land as
    in_progress@0 (Ryot resolves IGDB metadata asynchronously), so they are
    re-pushed next run to complete (same two-phase trick the music connector uses).
    `prev_games` maps appid -> last pushed playtime_forever (minutes).
    """
    now = datetime.now(timezone.utc).isoformat()
    metadata = []
    new_games = dict(prev_games)
    first_evers = []
    for g in games:
        appid = str(g.get("appid"))
        igdb_id = igdb_map.get(appid)
        if not igdb_id:
            continue  # unmapped in IGDB — skip
        name = g.get("name", appid)
        playtime = int(g.get("playtime_forever", 0))  # minutes
        delta = playtime - int(prev_games.get(appid, 0))
        if delta < MIN_DELTA_MIN:
            continue  # no new playtime
        secs = str(delta * 60)
        metadata.append(game_item(igdb_id, name, game_seen(secs, now)))
        if appid not in prev_games:
            first_evers.append(
                {"identifier": igdb_id, "source_id": name, "seconds": secs, "ended_on": now}
            )
        new_games[appid] = playtime
    return metadata, new_games, first_evers


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
    prev_games = state.get("games", {})
    prev_pending = state.get("pending", [])
    igdb_map = load_json(IGDB_MAP_FILE, {})

    games = get_owned_games()
    if not games:
        log("no games returned (private profile or empty library?) — nothing to do")
        return

    appids = [g.get("appid") for g in games if g.get("appid") is not None]
    resolve_igdb_ids(appids, get_twitch_token(), igdb_map)
    save_json(IGDB_MAP_FILE, igdb_map)  # cache resolutions regardless of push outcome

    metadata, new_games, first_evers = build_payload(games, igdb_map, prev_games)

    # Second phase: complete last run's first-ever games (metadata now resolved),
    # flipping their in_progress@0 seen to completed in place (no duplicate).
    repush = [
        game_item(p["identifier"], p["source_id"], game_seen(p["seconds"], p["ended_on"]))
        for p in prev_pending
    ]

    all_meta = metadata + repush
    if not all_meta:
        log("no new playtime and nothing to complete — nothing to push")
        return

    log(f"pushing {len(metadata)} games with new playtime + {len(repush)} completions")
    try:
        status, resp = post_to_ryot(all_meta)
    except (urllib.error.URLError, KeyError) as e:
        log(f"FATAL: push to Ryot failed: {e}")
        sys.exit(1)
    if status not in (200, 201, 202):
        log(f"FATAL: Ryot returned {status}: {resp[:300]}")
        sys.exit(1)

    save_json(STATE_FILE, {"games": new_games, "pending": first_evers})
    log(
        f"done (Ryot {status}); {len(new_games)} games tracked, "
        f"{len(first_evers)} pending completion next run"
    )


if __name__ == "__main__":
    main()
