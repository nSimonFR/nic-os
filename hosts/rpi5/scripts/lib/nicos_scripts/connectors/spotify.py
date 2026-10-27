#!/usr/bin/env python3
"""
spotify-to-ryot: Spotify listening history -> Ryot V2, one `complete` per listen.

We poll the user's recently-played tracks and log each new listen as a complete
event on the track's `music` entity through the media plugin's
`media-activity-log` operation, stamped with Spotify's own `played_at`.

Why not V2's built-in Spotify integration: it polls with an `after` cursor. A play
cached offline on the phone syncs hours later but keeps its *original* `played_at`,
so it lands behind any cursor and is dropped for good. We ask for the full window
Spotify exposes (the last 50 plays) every run instead, and dedupe per listen on
(track id, played_at):

  * `pushed` in spotify-cursor.json — keys already logged (shared with the V1
    connector's state file, so cutover does not re-log the window);
  * a RyotQL read of the tracks' existing completes — a listen whose exact
    timestamp is already there is recorded, not re-logged;
  * the operation's idempotency key, derived from the same pair — a retried run
    replays instead of writing twice.

Retention: keys are pruned to RETAIN_DAYS behind the high-water mark; the 50-play
window spans far less than that at any realistic listening rate.

Track -> entity: found by external id (RyotQL) else imported through the
`music.spotify` provider, then cached in spotify-entities.json.

Stdlib only. Config via environment:
  SPOTIFY_CLIENT_ID       Spotify app client id                    [required]
  SPOTIFY_CLIENT_SECRET   Spotify app client secret                [required]
  SPOTIFY_REFRESH_TOKEN   OAuth refresh token, scope
                          user-read-recently-played                [required]
  RYOT_API_KEY            Ryot V2 API key (X-Api-Key)              [required]
  RYOT_URL                Ryot V2 base URL, without /api (default http://127.0.0.1:13350)
  STATE_DIR               state directory        (default /var/lib/ryot-connectors)
"""

import base64
import os
import sys
import time
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
DEFAULT_RYOT_URL = "http://127.0.0.1:13350"
MEDIA = "ryot/media"
PROVIDER_SLUG = "music.spotify"
CONSUMED_ON = "Spotify"
# RyotQL returns at most 100 rows per query.
RYOTQL_CHUNK = 100
# Only has to outlast the span of the 50 plays the endpoint returns; 30d is ~20x
# that at the observed rate.
RETAIN_DAYS = 30
RETAIN_MS = RETAIN_DAYS * 24 * 60 * 60 * 1000
# V1 stamped a listen when its completion was re-pushed, up to ~65 min after the
# play; a V1 complete this close after a listen is that listen.
V1_LAG_MS = 90 * 60 * 1000
REQUIRED_ENV = (
    "SPOTIFY_CLIENT_ID",
    "SPOTIFY_CLIENT_SECRET",
    "SPOTIFY_REFRESH_TOKEN",
    "RYOT_API_KEY",
)


@dataclass(frozen=True)
class Config:
    client_id: str = ""
    client_secret: str = ""
    refresh_token: str = ""
    ryot_url: str = DEFAULT_RYOT_URL
    ryot_api_key: str = ""
    state_dir: str = DEFAULT_STATE_DIR

    @classmethod
    def from_env(cls, env=None):
        return cls(
            client_id=env_str("SPOTIFY_CLIENT_ID", "", env),
            client_secret=env_str("SPOTIFY_CLIENT_SECRET", "", env),
            refresh_token=env_str("SPOTIFY_REFRESH_TOKEN", "", env),
            ryot_url=env_str("RYOT_URL", DEFAULT_RYOT_URL, env),
            ryot_api_key=env_str("RYOT_API_KEY", "", env),
            state_dir=env_str("STATE_DIR", DEFAULT_STATE_DIR, env),
        )

    @property
    def cursor_file(self):
        return os.path.join(self.state_dir, "spotify-cursor.json")

    @property
    def entity_map_file(self):
        return os.path.join(self.state_dir, "spotify-entities.json")


# ── Spotify ───────────────────────────────────────────────────────────────────


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

    No `after` cursor on purpose: it filters on `played_at`, so a play that syncs
    late from an offline device would never be returned.
    """
    url = (
        "https://api.spotify.com/v1/me/player/recently-played?"
        + urllib.parse.urlencode({"limit": 50})
    )
    return get_json(
        url, headers={"Authorization": "Bearer " + token}, opener=opener
    ).get("items", [])


# ── listen identity ───────────────────────────────────────────────────────────


def iso_to_ms(iso):
    # Spotify sends RFC3339 with optional millis and a trailing Z.
    dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def ms_to_iso(ms):
    dt = datetime.fromtimestamp(ms / 1000, timezone.utc)
    return dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")


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
    return sorted(k for k in keys if (key_ms(k) or 0) >= horizon)


def submission_id(tid, ms):
    return f"spotify-{tid}-{ms}"


def listen(tid, name, ms, v1_overlap=False):
    return {
        "key": listen_key(tid, ms),
        "track_id": tid,
        "name": name,
        "ms": ms,
        "v1_overlap": v1_overlap,
    }


def new_listens(items, pushed, floor_ms=None):
    """Return (listens to log, keys to record without logging).

    `floor_ms` drops listens at or before that timestamp. Used only to bootstrap a
    state file written before per-listen keys existed; passing it routinely would
    reintroduce the offline-sync gap. Floored keys are still recorded, which
    retires the floor.
    """
    out, retired, seen = [], [], set()
    for it in items:
        played_at = it.get("played_at")
        track = it.get("track") or {}
        tid = track.get("id")
        if not played_at or not tid:
            continue
        ms = iso_to_ms(played_at)
        key = listen_key(tid, ms)
        if key in pushed or key in seen:
            continue
        seen.add(key)
        if floor_ms and ms <= floor_ms:
            retired.append(key)
            continue
        out.append(listen(tid, track.get("name", tid), ms))
    return out, retired


def v1_pending_listens(pending):
    """The V1 connector's last un-completed listens (it completed them a run later).

    V1 may or may not have completed them before cutover, so they are matched
    against V1-lagged completes rather than exact timestamps.
    """
    out = []
    for p in pending or []:
        try:
            ms = iso_to_ms(p["ended_on"])
        except (KeyError, ValueError):
            continue
        out.append(listen(p["identifier"], p.get("source_id", p["identifier"]), ms, True))
    return out


def already_logged(completes, lsn):
    """Whether one of the entity's completes (ms, ...) already stands for `lsn`."""
    for c in completes:
        if c["ms"] == lsn["ms"]:
            return True
        if lsn["v1_overlap"] and lsn["ms"] <= c["ms"] <= lsn["ms"] + V1_LAG_MS:
            return True
    return False


def activity_payload(entity_id, lsn):
    at = ms_to_iso(lsn["ms"])
    return {
        "submissionId": submission_id(lsn["track_id"], lsn["ms"]),
        # Must not vary on retry (a reused key with another payload is a 400), and
        # must be >= finishedOn.
        "submittedAt": at,
        "entry": {
            "kind": "complete",
            "entityId": entity_id,
            "when": {"kind": "date", "finishedOn": at},
            "consumedOn": CONSUMED_ON,
        },
    }


# ── Ryot reads ────────────────────────────────────────────────────────────────


def _col(alias, field):
    return {"type": "column", "tableAlias": alias, "field": field}


def _lit(value):
    return {"type": "literal", "value": value}


def _eq(alias, field, value):
    return {"type": "comparison", "operator": "eq", "left": _col(alias, field), "right": _lit(value)}


def _in(alias, field, values):
    return {"type": "in", "expr": _col(alias, field), "values": [_lit(v) for v in values]}


def _rows(table, alias, where, fields, limit=RYOTQL_CHUNK):
    return {
        "from": {"table": table, "alias": alias},
        "where": where,
        "output": {
            "type": "rows",
            "pagination": {"limit": limit},
            # Cursor pagination needs a total order.
            "orderBy": [{"direction": "asc", "expr": _col(alias, "id")}],
            "fields": [{"key": k, "expr": e} for k, e in fields.items()],
        },
    }


def provider_query():
    return _rows("sandboxProvider", "p", _eq("p", "slug", PROVIDER_SLUG), {"id": _col("p", "id")}, 1)


def tracks_query(track_ids):
    where = {
        "type": "and",
        "predicates": [_eq("e", "entitySchemaSlug", "music"), _in("e", "externalId", track_ids)],
    }
    fields = {
        "id": _col("e", "id"),
        "externalId": _col("e", "externalId"),
        "providerId": _col("e", "providerId"),
    }
    return _rows("entity", "e", where, fields)


def completes_query(entity_ids, since_ms):
    where = {
        "type": "and",
        "predicates": [
            _eq("v", "eventSchemaSlug", "complete"),
            _in("v", "entityId", entity_ids),
            {
                "type": "comparison",
                "operator": "gte",
                "left": _col("v", "occurredAt"),
                "right": {"type": "cast", "target": "date", "expr": _lit(ms_to_iso(since_ms))},
            },
        ],
    }
    fields = {
        "id": _col("v", "id"),
        "entityId": _col("v", "entityId"),
        "occurredAt": _col("v", "occurredAt"),
        "consumedOn": {"type": "jsonPath", "expr": _col("v", "properties"), "path": ["consumedOn"]},
    }
    return _rows("event", "v", where, fields)


def resolve_entities(client, track_ids, entity_map, import_missing=True, log=log):
    """Fill entity_map (track id -> entity id) for `track_ids`. Mutates the map.

    Returns the ids left unresolved (import failed, or `import_missing` is off).
    """
    todo = sorted({t for t in track_ids if t not in entity_map})
    if not todo:
        return []
    provider_id = None
    for i in range(0, len(todo), RYOTQL_CHUNK):
        chunk = todo[i : i + RYOTQL_CHUNK]
        data = client.query({"p": provider_query(), "t": tracks_query(chunk)})
        if not data["p"]["items"]:
            raise RuntimeError(f"Ryot has no {PROVIDER_SLUG} provider")
        provider_id = data["p"]["items"][0]["id"]
        for row in data["t"]["items"]:
            if row.get("providerId") == provider_id:
                entity_map[row["externalId"]] = row["id"]
    missing = [t for t in todo if t not in entity_map]
    if not import_missing:
        return missing
    unresolved = []
    for n, tid in enumerate(missing, 1):
        log(f"importing Spotify track {tid} ({n}/{len(missing)})")
        try:
            entity = client.import_entity(provider_id, tid)
        except ryot.ImportStalled as e:
            log(f"WARN: {e}")
            entity = ""
        if entity:
            entity_map[tid] = entity
        else:
            unresolved.append(tid)
    return unresolved


def existing_completes(client, entity_ids, since_ms):
    """entity id -> [{id, ms, consumed_on}] of its complete events since `since_ms`."""
    out = {}
    ids = sorted(set(entity_ids))
    for i in range(0, len(ids), RYOTQL_CHUNK):
        rows = client.query_all("c", completes_query(ids[i : i + RYOTQL_CHUNK], since_ms))
        for row in rows:
            out.setdefault(row["entityId"], []).append(
                {
                    "id": row["id"],
                    "ms": iso_to_ms(row["occurredAt"]),
                    "consumed_on": row.get("consumedOn"),
                }
            )
    return out


# ── main ──────────────────────────────────────────────────────────────────────


def log_listens(client, listens, entity_map, completes, pushed, log=log):
    """Log each listen not already in Ryot; returns (written, skipped, failed).

    `pushed` gains the key of every listen that is now in Ryot.
    """
    written = skipped = failed = 0
    for lsn in listens:
        entity_id = entity_map.get(lsn["track_id"])
        if not entity_id:
            failed += 1
            continue
        if already_logged(completes.get(entity_id, []), lsn):
            pushed.add(lsn["key"])
            skipped += 1
            continue
        payload = activity_payload(entity_id, lsn)
        result = client.operation(
            MEDIA, "media-activity-log", payload, idempotency_key=payload["submissionId"]
        )
        if isinstance(result, dict) and result.get("status") == "saved":
            pushed.add(lsn["key"])
            written += 1
        else:
            log(f"Ryot refused {lsn['name']!r} @ {ms_to_iso(lsn['ms'])}: {result}")
            failed += 1
    return written, skipped, failed


def main(env=None, opener=None, sleep=time.sleep, log=log):
    cfg = Config.from_env(env)
    missing = missing_env(REQUIRED_ENV, env)
    if missing:
        log(f"FATAL: missing env: {', '.join(missing)}")
        return 1
    ensure_dir(cfg.state_dir)

    state = load_json(cfg.cursor_file, {})
    # `after_ms` is the pre-per-listen-key name for the high-water mark.
    prev_newest = state.get("newest_ms", state.get("after_ms")) or 0
    # No `pushed` = a state file older than per-listen keys: floor this run only.
    legacy = bool(state) and "pushed" not in state
    pushed = set(state.get("pushed", []))
    try:
        token = get_access_token(cfg, opener=opener)
        items = get_recently_played(token, opener=opener)
    except (urllib.error.URLError, KeyError) as e:
        log(f"FATAL: Spotify API failed: {e}")
        return 1

    listens, retired = new_listens(items, pushed, floor_ms=prev_newest if legacy else None)
    pushed.update(retired)
    listens += [p for p in v1_pending_listens(state.get("pending")) if p["key"] not in pushed]

    def save():
        newest = max([prev_newest] + [key_ms(k) or 0 for k in pushed])
        save_json(cfg.cursor_file, {"newest_ms": newest, "pushed": prune_keys(pushed, newest)})

    if not listens:
        log("no new listens")
        if retired or legacy or "pending" in state:
            save()
        return 0

    client = ryot.Client(cfg.ryot_url, cfg.ryot_api_key, opener=opener, sleep=sleep, log=log)
    entity_map = load_json(cfg.entity_map_file, {})
    try:
        unresolved = resolve_entities(
            client, [x["track_id"] for x in listens], entity_map, log=log
        )
        save_json(cfg.entity_map_file, entity_map, sort_keys=True)
        ids = {entity_map[x["track_id"]] for x in listens if x["track_id"] in entity_map}
        completes = existing_completes(client, ids, min(x["ms"] for x in listens))
        written, skipped, failed = log_listens(
            client, listens, entity_map, completes, pushed, log=log
        )
    except (urllib.error.URLError, RuntimeError, KeyError) as e:
        log(f"FATAL: Ryot failed: {e}")
        save()  # keep the keys of whatever was logged before the failure
        return 1
    save()
    log(
        f"done: {written} logged, {skipped} already in Ryot, {failed} failed"
        + (f" (unresolved tracks: {', '.join(unresolved)})" if unresolved else "")
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
