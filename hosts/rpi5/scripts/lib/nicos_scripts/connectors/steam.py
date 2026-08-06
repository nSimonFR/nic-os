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
completion signal): each time playtime_forever grows by >= min_delta_min minutes
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

import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone

from .. import ryot
from ..httpjson import get_json, http_json
from ..logs import logger
from ..secrets import env_int, env_str, missing_env
from ..state import ensure_dir, load_json, save_json

log = logger("steam-to-ryot")

DEFAULT_STATE_DIR = "/var/lib/ryot-connectors"
REQUIRED_ENV = ("STEAM_API_KEY", "STEAM_ID64", "RYOT_WEBHOOK_URL")

# IGDB external_games.external_game_source id for Steam (verified via
# /v4/external_game_sources: id 1 = "Steam"). The older `category` field is
# deprecated and no longer reliably matches Steam rows.
IGDB_STEAM_SOURCE = 1

# IGDB caps a query at 500 results and ~4 req/s.
IGDB_CHUNK = 400
IGDB_PAUSE_SEC = 0.3


@dataclass(frozen=True)
class Config:
    steam_api_key: str = ""
    steam_id64: str = ""
    twitch_client_id: str = ""
    twitch_client_secret: str = ""
    webhook_url: str = ""
    state_dir: str = DEFAULT_STATE_DIR
    min_delta_min: int = 1

    @classmethod
    def from_env(cls, env=None):
        return cls(
            steam_api_key=env_str("STEAM_API_KEY", "", env),
            steam_id64=env_str("STEAM_ID64", "", env),
            twitch_client_id=env_str("TWITCH_CLIENT_ID", "", env),
            twitch_client_secret=env_str("TWITCH_CLIENT_SECRET", "", env),
            webhook_url=env_str("RYOT_WEBHOOK_URL", "", env),
            state_dir=env_str("STATE_DIR", DEFAULT_STATE_DIR, env),
            min_delta_min=env_int("MIN_DELTA_MIN", 1, env),
        )

    @property
    def state_file(self):
        return os.path.join(self.state_dir, "steam-state.json")

    @property
    def igdb_map_file(self):
        return os.path.join(self.state_dir, "steam-igdb-map.json")


def get_owned_games(cfg, opener=None):
    params = urllib.parse.urlencode(
        {
            "key": cfg.steam_api_key,
            "steamid": cfg.steam_id64,
            "include_appinfo": 1,
            "include_played_free_games": 1,
            "format": "json",
        }
    )
    url = "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?" + params
    data = get_json(url, opener=opener)
    games = data.get("response", {}).get("games", [])
    log(f"Steam reports {len(games)} owned games")
    return games


def get_twitch_token(cfg, opener=None):
    # Twitch wants the client-credentials params in the query string, not a form
    # body — kept verbatim from the working version rather than normalised to
    # httpjson.post_form.
    params = urllib.parse.urlencode(
        {
            "client_id": cfg.twitch_client_id,
            "client_secret": cfg.twitch_client_secret,
            "grant_type": "client_credentials",
        }
    )
    req = urllib.request.Request(
        "https://id.twitch.tv/oauth2/token?" + params, method="POST"
    )
    return http_json(req, opener=opener)["access_token"]


def resolve_igdb_ids(appids, token, igdb_map, cfg, opener=None, sleep=time.sleep):
    """Fill igdb_map for appids not already cached. Returns nothing (mutates map)."""
    todo = [a for a in appids if str(a) not in igdb_map]
    if not todo:
        return
    log(f"resolving {len(todo)} new appids against IGDB")
    headers = {
        "Client-ID": cfg.twitch_client_id,
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
    }
    for i in range(0, len(todo), IGDB_CHUNK):
        chunk = todo[i : i + IGDB_CHUNK]
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
            rows = http_json(req, opener=opener)
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
        sleep(IGDB_PAUSE_SEC)  # stay well under IGDB's 4 req/s
    log(
        f"IGDB cache now has {sum(1 for v in igdb_map.values() if v)} mapped / "
        f"{len(igdb_map)} total"
    )


def game_item(igdb_id, name, seconds, ended_on):
    return ryot.metadata_item(
        "video_game",
        "igdb",
        igdb_id,
        name,
        [
            ryot.seen(
                ended_on,
                # seconds is Decimal-as-string
                manual_time_spent=seconds,
                providers=["Steam"],
            )
        ],
    )


def build_payload(games, igdb_map, prev_games, min_delta_min=1, now=None):
    """Return (metadata, new_games, first_evers).

    Push a game only when its total playtime grew (the delta is recorded as one
    play "seen"); an unplayed game has no seen and cannot persist via the sink, so
    it is skipped. `first_evers` are games never pushed before — they land as
    in_progress@0 (Ryot resolves IGDB metadata asynchronously), so they are
    re-pushed next run to complete (same two-phase trick the music connector uses).
    `prev_games` maps appid -> last pushed playtime_forever (minutes).
    """
    now = now or datetime.now(timezone.utc).isoformat()
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
        if delta < min_delta_min:
            continue  # no new playtime
        secs = str(delta * 60)
        metadata.append(game_item(igdb_id, name, secs, now))
        if appid not in prev_games:
            first_evers.append(
                {
                    "identifier": igdb_id,
                    "source_id": name,
                    "seconds": secs,
                    "ended_on": now,
                }
            )
        new_games[appid] = playtime
    return metadata, new_games, first_evers


def main(env=None, opener=None):
    cfg = Config.from_env(env)
    missing = missing_env(REQUIRED_ENV, env)
    if missing:
        log(f"FATAL: missing env: {', '.join(missing)}")
        return 1
    if not (cfg.twitch_client_id and cfg.twitch_client_secret):
        # IGDB resolution (and the backend's) needs Twitch creds. Until they're
        # configured the connector is installed-but-dormant — skip cleanly rather
        # than fail the timer.
        log("Twitch/IGDB creds not set — Steam metadata can't resolve yet; skipping")
        return 0
    ensure_dir(cfg.state_dir)

    state = load_json(cfg.state_file, {})
    prev_games = state.get("games", {})
    prev_pending = state.get("pending", [])
    igdb_map = load_json(cfg.igdb_map_file, {})

    games = get_owned_games(cfg, opener=opener)
    if not games:
        log("no games returned (private profile or empty library?) — nothing to do")
        return 0

    appids = [g.get("appid") for g in games if g.get("appid") is not None]
    resolve_igdb_ids(
        appids, get_twitch_token(cfg, opener=opener), igdb_map, cfg, opener=opener
    )
    # Cache resolutions regardless of push outcome.
    save_json(cfg.igdb_map_file, igdb_map)

    metadata, new_games, first_evers = build_payload(
        games, igdb_map, prev_games, cfg.min_delta_min
    )

    # Second phase: complete last run's first-ever games (metadata now resolved),
    # flipping their in_progress@0 seen to completed in place (no duplicate).
    repush = [
        game_item(p["identifier"], p["source_id"], p["seconds"], p["ended_on"])
        for p in prev_pending
    ]

    all_meta = metadata + repush
    if not all_meta:
        log("no new playtime and nothing to complete — nothing to push")
        return 0

    log(f"pushing {len(metadata)} games with new playtime + {len(repush)} completions")
    try:
        status, resp = ryot.post_export(cfg.webhook_url, all_meta, opener=opener)
    except (urllib.error.URLError, KeyError) as e:
        log(f"FATAL: push to Ryot failed: {e}")
        return 1
    if not ryot.is_ok(status):
        log(f"FATAL: Ryot returned {status}: {resp[:300]}")
        return 1

    save_json(cfg.state_file, {"games": new_games, "pending": first_evers})
    log(
        f"done (Ryot {status}); {len(new_games)} games tracked, "
        f"{len(first_evers)} pending completion next run"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
