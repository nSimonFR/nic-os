#!/usr/bin/env python3
"""
steam-to-ryot: Steam playtime -> Ryot V2 `complete` events on IGDB video games.

Ryot has no Steam integration, so each Steam appid is resolved to an IGDB game id
(Twitch/IGDB API), then to a Ryot `video-game` entity: an existing one by its IGDB
external id (RyotQL), else imported through the `video-game.igdb` provider.

Sessions: the timer runs every 5 min and reads the profile's presence
(GetPlayerSummaries `gameid`). When a game stops being played, the growth of its
cumulative `playtime_forever` is that session: ONE `complete` event via the
media plugin's `media-activity-log`, `timeSpent` = the growth in minutes,
occurring at `rtime_last_played` (set when the game is quit). Growth with no
session seen (offline play, a session under 5 min, the Pi down) is found by a
check every CHECK_EVERY_S and logged with `consumedOn: UNTIMED_ON`: its total
is right, its hours are not.

State, all in $STATE_DIR:
  * steam-state.json = {games:{appid:last_queued_total_min}, pending:[play],
    session:{appid,start,seen}, ended:[{appid,start,end}], checked:epoch}. A play
    is queued (and `games` advanced) before it is sent, so a Ryot outage delays
    plays but never merges them.
  * steam-igdb-map.json = appid -> IGDB id ("" = known-unmapped).
  * steam-ryot-entities.json = appid -> Ryot entity id.

Idempotency: the submissionId is `steam-<appid>-<new total>`, and Ryot keys the
event write on it. Resending it with the same payload replays the first write;
with a different one (a new occurredAt) Ryot refuses with mutation-conflict. So a
pending play is resent byte-identical.

Stdlib only. Config via environment:
  STEAM_API_KEY           Steam Web API key (steamcommunity.com/dev/apikey)   [required]
  STEAM_ID64              64-bit SteamID of the profile to sync               [required]
  TWITCH_CLIENT_ID        Twitch/IGDB app client id                          [required]
  TWITCH_CLIENT_SECRET    Twitch/IGDB app client secret                      [required]
  RYOT_API_KEY            Ryot V2 user API key (X-Api-Key)                   [required]
  RYOT_URL                Ryot V2 base URL, without /api  (default http://127.0.0.1:13350)
  STATE_DIR               state directory                 (default /var/lib/ryot-connectors)
  MIN_DELTA_MIN           min playtime growth to log a play, minutes (default 1)
"""

import json
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
DEFAULT_RYOT_URL = "http://127.0.0.1:13350"
REQUIRED_ENV = ("STEAM_API_KEY", "STEAM_ID64", "RYOT_API_KEY")

# IGDB external_games.external_game_source id for Steam (verified via
# /v4/external_game_sources: id 1 = "Steam"). The older `category` field is
# deprecated and no longer reliably matches Steam rows.
IGDB_STEAM_SOURCE = 1

# IGDB caps a query at 500 results and ~4 req/s.
IGDB_CHUNK = 400
IGDB_PAUSE_SEC = 0.3

MEDIA = "ryot/media"
IGDB_PROVIDER = "video-game.igdb"
# RyotQL returns at most 100 rows per query.
RYOTQL_CHUNK = 100
# Ryot API keys are limited to 60 req/min.
RYOT_PAUSE_SEC = 1.0
RATE_LIMIT_BACKOFF_SEC = 61
RATE_LIMIT_RETRIES = 2
# The import result endpoint long-polls ~20 s per request.
IMPORT_POLLS = 6

CONSUMED_ON = "Steam"
UNTIMED_ON = "Steam (non daté)"
CHECK_EVERY_S = 6 * 3600
# Steam may count a quit session a few minutes late; past this it never will.
ENDED_GRACE_S = 3600
# A play still unsaved after this fails the unit (systemd-failed-alert pages).
STALE_S = 3600


@dataclass(frozen=True)
class Config:
    steam_api_key: str = ""
    steam_id64: str = ""
    twitch_client_id: str = ""
    twitch_client_secret: str = ""
    ryot_url: str = DEFAULT_RYOT_URL
    ryot_api_key: str = ""
    state_dir: str = DEFAULT_STATE_DIR
    min_delta_min: int = 1

    @classmethod
    def from_env(cls, env=None):
        return cls(
            steam_api_key=env_str("STEAM_API_KEY", "", env),
            steam_id64=env_str("STEAM_ID64", "", env),
            twitch_client_id=env_str("TWITCH_CLIENT_ID", "", env),
            twitch_client_secret=env_str("TWITCH_CLIENT_SECRET", "", env),
            ryot_url=env_str("RYOT_URL", DEFAULT_RYOT_URL, env),
            ryot_api_key=env_str("RYOT_API_KEY", "", env),
            state_dir=env_str("STATE_DIR", DEFAULT_STATE_DIR, env),
            min_delta_min=env_int("MIN_DELTA_MIN", 1, env),
        )

    @property
    def state_file(self):
        return os.path.join(self.state_dir, "steam-state.json")

    @property
    def igdb_map_file(self):
        return os.path.join(self.state_dir, "steam-igdb-map.json")

    @property
    def entity_map_file(self):
        return os.path.join(self.state_dir, "steam-ryot-entities.json")


# ── Steam / IGDB ──────────────────────────────────────────────────────────────


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


def get_presence(cfg, opener=None):
    """The appid being played now, "" when none (or hidden by privacy)."""
    params = urllib.parse.urlencode(
        {"key": cfg.steam_api_key, "steamids": cfg.steam_id64, "format": "json"}
    )
    url = "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?" + params
    players = get_json(url, opener=opener).get("response", {}).get("players", [])
    return str(players[0].get("gameid") or "") if players else ""


def track_session(state, playing, t):
    """Fold one presence reading into state["session"]; a session that stops is
    appended to state["ended"]. `playing` None (presence unknown) changes nothing."""
    if playing is None:
        return
    cur = state.get("session")
    if cur and cur["appid"] == playing:
        cur["seen"] = t
        return
    if cur:
        state.setdefault("ended", []).append(
            {"appid": cur["appid"], "start": cur["start"], "end": cur["seen"]}
        )
        log(f"session of {cur['appid']} ended")
    if playing:
        state["session"] = {"appid": playing, "start": t, "seen": t}
    else:
        state.pop("session", None)


def get_twitch_token(cfg, opener=None):
    # Twitch wants the client-credentials params in the query string, not a form body.
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


def playtime_deltas(
    games, igdb_map, prev_games, min_delta_min=1, now="", playing="", timed=None
):
    """Plays to queue: games whose playtime grew by >= min_delta_min since the
    last queued total (`prev_games`, appid -> minutes); a smaller growth is left
    to accumulate, as is the game being `playing` now (logged once it stops).
    A play is `untimed` unless its appid is in `timed` (a session was seen end);
    `timed` None (no presence) leaves every play timed, as before sessions.
    """
    plays = []
    for g in games:
        appid = str(g.get("appid"))
        igdb_id = igdb_map.get(appid)
        if not igdb_id or appid == playing:
            continue  # unmapped in IGDB, or still being played
        total = int(g.get("playtime_forever", 0))
        delta = total - int(prev_games.get(appid, 0))
        if delta < min_delta_min:
            continue
        plays.append(
            {
                "appid": appid,
                "igdb_id": igdb_id,
                "name": g.get("name", appid),
                "total": total,
                "delta": delta,
                "submitted_at": now,
                "played_at": epoch_iso(g.get("rtime_last_played")),
                "untimed": timed is not None and appid not in timed,
            }
        )
    return plays


def migrate_inflight(state, igdb_map):
    """The pre-session `inflight` {appid: {total, submittedAt, playedAt}} as
    pending plays, resent byte-identical."""
    games = state.setdefault("games", {})
    for appid, sent in state.pop("inflight", {}).items():
        state.setdefault("pending", []).append(
            {
                "appid": appid,
                "igdb_id": igdb_map.get(appid, ""),
                "name": appid,
                "total": int(sent["total"]),
                "delta": int(sent["total"]) - int(games.get(appid, 0)),
                "submitted_at": sent["submittedAt"],
                "played_at": sent.get("playedAt", ""),
                "untimed": False,
            }
        )
        games[appid] = int(sent["total"])


# ── Ryot V2 ───────────────────────────────────────────────────────────────────


def _col(alias, field):
    return {"type": "column", "tableAlias": alias, "field": field}


def _eq(alias, field, value):
    return {
        "type": "comparison",
        "operator": "eq",
        "left": _col(alias, field),
        "right": {"type": "literal", "value": value},
    }


def provider_query():
    return {
        "p": {
            "from": {"table": "sandboxProvider", "alias": "p"},
            "where": _eq("p", "slug", IGDB_PROVIDER),
            "output": {
                "type": "rows",
                "pagination": {"limit": 1},
                "orderBy": [],
                "fields": [{"key": "id", "expr": _col("p", "id")}],
            },
        }
    }


def games_query(provider_id, igdb_ids):
    return {
        "g": {
            "from": {"table": "entity", "alias": "e"},
            "where": {
                "type": "and",
                "predicates": [
                    _eq("e", "entitySchemaSlug", "video-game"),
                    _eq("e", "providerId", provider_id),
                    {
                        "type": "in",
                        "expr": _col("e", "externalId"),
                        "values": [{"type": "literal", "value": i} for i in igdb_ids],
                    },
                ],
            },
            "output": {
                "type": "rows",
                "pagination": {"limit": RYOTQL_CHUNK},
                "orderBy": [{"direction": "asc", "expr": _col("e", "id")}],
                "fields": [
                    {"key": "id", "expr": _col("e", "id")},
                    {"key": "externalId", "expr": _col("e", "externalId")},
                ],
            },
        }
    }


def epoch_iso(t):
    """Steam's epoch seconds as Ryot's ISO instant; "" for none (0 = never played)."""
    if not t:
        return ""
    return (
        datetime.fromtimestamp(int(t), timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def submission_id(appid, total):
    return f"steam-{appid}-{total}"


def activity_payload(entity_id, play):
    return {
        # Keyed on (appid, new total): a retried run replays instead of re-logging.
        "submissionId": submission_id(play["appid"], play["total"]),
        "submittedAt": play["submitted_at"],
        "entry": {
            "kind": "complete",
            "entityId": entity_id,
            "when": {"kind": "date", "finishedOn": play["played_at"]}
            if play.get("played_at")
            else {"kind": "now"},
            "timeSpent": play["delta"],
            "consumedOn": UNTIMED_ON if play.get("untimed") else CONSUMED_ON,
        },
    }


def _is_rate_limited(err):
    cause = err.__cause__
    return isinstance(cause, urllib.error.HTTPError) and cause.code == 429


class RyotClient:
    """The few V2 calls this connector makes, paced under the API-key limit."""

    def __init__(self, cfg, opener=None, sleep=time.sleep):
        self.cfg = cfg
        self.opener = opener
        self.sleep = sleep
        self._calls = 0

    def _paced(self, call):
        for attempt in range(RATE_LIMIT_RETRIES + 1):
            if self._calls:
                self.sleep(RYOT_PAUSE_SEC)
            self._calls += 1
            try:
                return call()
            except RuntimeError as e:
                if not _is_rate_limited(e) or attempt == RATE_LIMIT_RETRIES:
                    raise
                log(f"Ryot rate limit hit; waiting {RATE_LIMIT_BACKOFF_SEC}s")
                self.sleep(RATE_LIMIT_BACKOFF_SEC)

    def post(self, path, payload):
        return self._paced(
            lambda: ryot.api_post(
                self.cfg.ryot_url,
                self.cfg.ryot_api_key,
                path,
                payload,
                opener=self.opener,
            )
        )

    def get(self, path):
        def call():
            req = urllib.request.Request(
                self.cfg.ryot_url.rstrip("/") + "/api" + path,
                headers={"X-Api-Key": self.cfg.ryot_api_key},
            )
            try:
                return http_json(
                    req, timeout=ryot.RYOT_WAKE_TIMEOUT, opener=self.opener
                )
            except urllib.error.HTTPError as e:
                raise RuntimeError(
                    f"Ryot {path} -> {e.code}: {e.read().decode()[:500]}"
                ) from e

        return self._paced(call)

    def query(self, queries):
        return self.post("/ryotql/execute", {"queries": queries}).get("data") or {}

    def provider_id(self):
        items = self.query(provider_query())["p"]["items"]
        if not items:
            raise RuntimeError(f"Ryot has no {IGDB_PROVIDER} provider")
        return items[0]["id"]

    def find_games(self, provider_id, igdb_ids):
        """IGDB id -> entity id for the ids Ryot already knows."""
        found = {}
        for i in range(0, len(igdb_ids), RYOTQL_CHUNK):
            chunk = igdb_ids[i : i + RYOTQL_CHUNK]
            for row in self.query(games_query(provider_id, chunk))["g"]["items"]:
                found[row["externalId"]] = row["id"]
        return found

    def import_game(self, provider_id, igdb_id):
        """Import an IGDB game; its entity id, or "" when the import failed."""
        job = self.post(
            "/entity-providers/imports",
            {"providerId": provider_id, "externalId": igdb_id},
        )["jobId"]
        for _ in range(IMPORT_POLLS):
            res = self.get(
                "/entity-providers/imports/" + urllib.parse.quote(job, safe="")
            )
            status = res.get("status")
            if status == "completed":
                return res["data"]["id"]
            if status in ("failed", "cancelled"):
                log(f"IGDB {igdb_id}: import {status}: {json.dumps(res)[:300]}")
                return ""
        raise RuntimeError(
            f"IGDB {igdb_id}: import still {status} after {IMPORT_POLLS} polls"
        )

    def log_play(self, entity_id, play):
        payload = activity_payload(entity_id, play)
        result = self.post(
            f"/plugins/{MEDIA}/operations/media-activity-log", {"payload": payload}
        )["result"]
        # Operations answer 200 even when they refuse.
        if not isinstance(result, dict) or result.get("status") != "saved":
            raise RuntimeError(f"Ryot did not save the play: {result}")


def resolve_entities(client, plays, entity_map):
    """Fill entity_map (appid -> entity id) for `plays`. Mutates the map."""
    todo = [p for p in plays if p["appid"] not in entity_map]
    if not todo:
        return
    provider_id = client.provider_id()
    known = client.find_games(provider_id, sorted({p["igdb_id"] for p in todo}))
    for p in todo:
        entity = known.get(p["igdb_id"])
        if entity is None:
            log(f"importing {p['name']} (IGDB {p['igdb_id']})")
            entity = client.import_game(provider_id, p["igdb_id"])
            known[p["igdb_id"]] = entity
        if entity:
            entity_map[p["appid"]] = entity


def now_iso():
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def iso_epoch(iso):
    """Epoch seconds of an ISO instant; 0 for anything else (an old stamp)."""
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return 0


def queue_plays(cfg, state, games, igdb_map, playing, t, now):
    """Queue the growth since the last queued totals; consumes the ended sessions
    it times and drops those Steam never counted."""
    ended = state.get("ended", [])
    plays = playtime_deltas(
        games,
        igdb_map,
        state.setdefault("games", {}),
        cfg.min_delta_min,
        now,
        playing or "",
        {e["appid"] for e in ended},
    )
    for p in plays:
        state.setdefault("pending", []).append(p)
        state["games"][p["appid"]] = p["total"]
        log(
            f"{p['name']}: queued {p['delta']} min"
            + (" (no session seen)" if p["untimed"] else "")
        )
    queued = {p["appid"] for p in plays}
    state["ended"] = [
        e for e in ended if e["appid"] not in queued and t - e["end"] < ENDED_GRACE_S
    ]
    state["checked"] = t


def send_pending(client, state, entity_map, save):
    """Send every pending play; a failed one stays for the next run. The count
    of failures."""
    failed = 0
    for p in list(state.get("pending", [])):
        entity = entity_map.get(p["appid"])
        if not entity:
            log(f"{p['name']}: no Ryot entity for IGDB {p['igdb_id']}; retrying")
            failed += 1
            continue
        try:
            client.log_play(entity, p)
        except (urllib.error.URLError, RuntimeError, KeyError) as e:
            log(f"{p['name']}: logging {p['delta']} min failed: {e}")
            failed += 1
            continue
        log(f"{p['name']}: logged {p['delta']} min (total {p['total']})")
        state["pending"].remove(p)
        save()
    return failed


def main(env=None, opener=None, sleep=time.sleep, now=None, clock=time.time):
    cfg = Config.from_env(env)
    missing = missing_env(REQUIRED_ENV, env)
    if missing:
        log(f"FATAL: missing env: {', '.join(missing)}")
        return 1
    if not (cfg.twitch_client_id and cfg.twitch_client_secret):
        # Installed-but-dormant until the IGDB creds exist: skip, don't fail the timer.
        log("Twitch/IGDB creds not set — Steam metadata can't resolve yet; skipping")
        return 0
    ensure_dir(cfg.state_dir)
    t = clock()
    now = now or now_iso()

    state = load_json(cfg.state_file, {})
    igdb_map = load_json(cfg.igdb_map_file, {})
    entity_map = load_json(cfg.entity_map_file, {})
    migrate_inflight(state, igdb_map)

    def save():
        for key in ("pending", "ended"):
            if not state.get(key):
                state.pop(key, None)
        save_json(cfg.state_file, state)

    try:
        playing = get_presence(cfg, opener=opener)
    except (OSError, ValueError, KeyError) as e:
        log(f"presence unavailable ({e}); sessions paused this run")
        playing = None
    track_session(state, playing, t)

    if state.get("ended") or t - state.get("checked", 0) >= CHECK_EVERY_S:
        games = get_owned_games(cfg, opener=opener)
        appids = [g.get("appid") for g in games if g.get("appid") is not None]
        if any(str(a) not in igdb_map for a in appids):
            resolve_igdb_ids(
                appids,
                get_twitch_token(cfg, opener=opener),
                igdb_map,
                cfg,
                opener=opener,
                sleep=sleep,
            )
            save_json(cfg.igdb_map_file, igdb_map)
        if games:
            queue_plays(cfg, state, games, igdb_map, playing, t, now)
    save()

    pending = state.get("pending", [])
    if not pending:
        return 0
    client = RyotClient(cfg, opener=opener, sleep=sleep)
    try:
        resolve_entities(client, pending, entity_map)
    except (urllib.error.URLError, RuntimeError, KeyError) as e:
        log(f"resolving Ryot entities failed: {e}")
    finally:
        save_json(cfg.entity_map_file, entity_map)
    failed = send_pending(client, state, entity_map, save)
    save()
    stale = [
        p
        for p in state.get("pending", [])
        if t - iso_epoch(p["submitted_at"]) >= STALE_S
    ]
    log(f"done; {failed} pending, {len(stale)} older than {STALE_S // 60} min")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
