#!/usr/bin/env python3
"""
spotify-backfill: one-off import of Spotify's "Extended streaming history" export.

  spotify-backfill [--apply] Streaming_History_Audio_*.json ...

A record counts as a listen when it has a `spotify_track_uri` and
`ms_played >= 30000`; it becomes a `complete` on the track's music entity at
`ts` (the end of the play), with `startedOn` = ts - ms_played.

Overlap with listens already in Ryot (same track):
  * a complete at exactly `ts` — already done (a previous run, or the poller);
  * a Spotify complete in [ts - 5 min, ts + 90 min] — a listen migrated from V1,
    which stamped push time (up to ~65 min late): its `occurredAt`/`startedOn`
    are corrected in place (PATCH /events/{id}) instead of adding a duplicate.
Each existing event stands for at most one play. A corrected event then matches
exactly, so re-running is a no-op.

Dry run by default (nothing is written, not even imports); `--apply` writes.

New listens go through `POST /events` in batches rather than one
`media-activity-log` call each: the API key allows 60 requests/min, and an
export holds years of plays. Idempotency comes from the exact-timestamp check.

Config via environment: RYOT_API_KEY [required], RYOT_URL, STATE_DIR (shares
the poller's spotify-entities.json cache).
"""

import argparse
import json
import sys
import time
import urllib.error

from .. import ryot
from ..logs import logger
from ..secrets import missing_env
from ..state import ensure_dir, load_json, save_json
from . import spotify

log = logger("spotify-backfill")

MIN_MS_PLAYED = 30000
EARLY_SLACK_MS = 5 * 60 * 1000
# Ryot's own cap on one event-mutation batch.
EVENT_BATCH = 100
OPERATION_POLLS = 30


def parse_export(records):
    """Return (plays, filtered, duplicates). A play: {track_id, name, ms, ms_played}."""
    plays, seen = [], set()
    filtered = duplicates = 0
    for r in records:
        uri = r.get("spotify_track_uri") or ""
        ms_played = r.get("ms_played") or 0
        if not uri.startswith("spotify:track:") or ms_played < MIN_MS_PLAYED or not r.get("ts"):
            filtered += 1
            continue
        tid = uri.rsplit(":", 1)[1]
        ms = spotify.iso_to_ms(r["ts"])
        if (tid, ms) in seen:
            duplicates += 1
            continue
        seen.add((tid, ms))
        plays.append(
            {
                "track_id": tid,
                "name": r.get("master_metadata_track_name") or tid,
                "ms": ms,
                "ms_played": ms_played,
            }
        )
    plays.sort(key=lambda p: p["ms"])
    return plays, filtered, duplicates


def plan(plays, entity_map, completes):
    """Classify every play: (action, play, event) with action in
    exists / correct / new / unresolved. Pure."""
    claimed = set()
    actions = {}
    resolved = []
    for i, p in enumerate(plays):
        entity = entity_map.get(p["track_id"])
        if entity is None:
            actions[i] = ("unresolved", p, None)
            continue
        resolved.append(i)
        # Exact matches first, so an earlier play cannot claim a later one's event.
        for c in completes.get(entity, []):
            if c["id"] not in claimed and c["ms"] == p["ms"]:
                claimed.add(c["id"])
                actions[i] = ("exists", p, c)
                break
    for i in resolved:
        if i in actions:
            continue
        p = plays[i]
        near = [
            c
            for c in completes.get(entity_map[p["track_id"]], [])
            if c["id"] not in claimed
            and c.get("consumed_on") == spotify.CONSUMED_ON
            and p["ms"] - EARLY_SLACK_MS <= c["ms"] <= p["ms"] + spotify.V1_LAG_MS
        ]
        if near:
            best = min(near, key=lambda c: abs(c["ms"] - p["ms"]))
            claimed.add(best["id"])
            actions[i] = ("correct", p, best)
        else:
            actions[i] = ("new", p, None)
    return [actions[i] for i in range(len(plays))]


def started_on(p):
    return spotify.ms_to_iso(p["ms"] - p["ms_played"])


def new_event(entity_id, p):
    return {
        "entityId": entity_id,
        "eventSchemaSlug": "complete",
        "occurredAt": spotify.ms_to_iso(p["ms"]),
        "properties": {"consumedOn": spotify.CONSUMED_ON, "startedOn": started_on(p)},
    }


def correction(p):
    return {
        "occurredAt": spotify.ms_to_iso(p["ms"]),
        "properties": {"set": {"startedOn": started_on(p)}, "remove": []},
    }


def create_events(client, events, sleep=time.sleep, log=log):
    """POST one batch; the number written. Waits out a 202 (writes past ~35 s)."""
    res = client.request("POST", "/events", events)
    for _ in range(OPERATION_POLLS):
        if "count" in res:
            if res.get("failure"):
                log(f"batch stopped early: {json.dumps(res['failure'])[:300]}")
            return res["count"]
        if "result" in res:
            return res["result"].get("count", 0)
        sleep(2)
        res = client.request("GET", "/events/operations/" + res["operationId"])
    raise RuntimeError(f"event batch still pending: {res}")


def summarize(actions, filtered, duplicates, dry_run=False):
    counts = {"new": 0, "correct": 0, "exists": 0, "unresolved": 0}
    for action, _, _ in actions:
        counts[action] += 1
    # A dry run imports nothing, so a track Ryot lacks is not a failure yet.
    unresolved = "on tracks to import" if dry_run else "on unresolved tracks"
    return (
        f"{counts['new']} new, {counts['correct']} to correct (V1 overlap), "
        f"{counts['exists']} already in Ryot, {counts['unresolved']} {unresolved}, "
        f"{filtered} filtered (<30s or not a track), {duplicates} duplicate records"
    )


def load_records(paths):
    records = []
    for path in paths:
        with open(path) as f:
            records.extend(json.load(f))
    return records


def main(argv=None, env=None, opener=None, sleep=time.sleep, log=log):
    ap = argparse.ArgumentParser(
        prog="spotify-backfill", description="Backfill Spotify's extended streaming history into Ryot."
    )
    ap.add_argument("files", nargs="+", help="Streaming_History_Audio_*.json")
    ap.add_argument("--apply", action="store_true", help="write (default: dry run)")
    args = ap.parse_args(argv)
    dry_run = not args.apply

    cfg = spotify.Config.from_env(env)
    missing = missing_env(("RYOT_API_KEY",), env)
    if missing:
        log(f"FATAL: missing env: {', '.join(missing)}")
        return 1
    plays, filtered, duplicates = parse_export(load_records(args.files))
    if not plays:
        log(f"no plays to backfill ({filtered} filtered, {duplicates} duplicates)")
        return 0

    client = ryot.Client(cfg.ryot_url, cfg.ryot_api_key, opener=opener, sleep=sleep, log=log)
    entity_map = load_json(cfg.entity_map_file, {})
    try:
        spotify.resolve_entities(
            client, [p["track_id"] for p in plays], entity_map, import_missing=not dry_run, log=log
        )
        if not dry_run:
            ensure_dir(cfg.state_dir)
            save_json(cfg.entity_map_file, entity_map, sort_keys=True)
        ids = {entity_map[p["track_id"]] for p in plays if p["track_id"] in entity_map}
        completes = spotify.existing_completes(
            client, ids, plays[0]["ms"] - EARLY_SLACK_MS
        )
    except (urllib.error.URLError, RuntimeError, KeyError) as e:
        log(f"FATAL: Ryot failed: {e}")
        return 1

    actions = plan(plays, entity_map, completes)
    log(("dry run: " if dry_run else "plan: ") + summarize(actions, filtered, duplicates, dry_run))
    if dry_run:
        for action, p, ev in [a for a in actions if a[0] == "correct"][:10]:
            log(
                f"  correct {p['name']!r}: {spotify.ms_to_iso(ev['ms'])} -> "
                f"{spotify.ms_to_iso(p['ms'])}"
            )
        log("re-run with --apply to write")
        return 0

    corrected = created = 0
    try:
        for action, p, ev in actions:
            if action == "correct":
                client.request("PATCH", "/events/" + ev["id"], correction(p))
                corrected += 1
        news = [new_event(entity_map[p["track_id"]], p) for a, p, _ in actions if a == "new"]
        for i in range(0, len(news), EVENT_BATCH):
            created += create_events(client, news[i : i + EVENT_BATCH], sleep=sleep, log=log)
            log(f"created {created}/{len(news)}")
    except (urllib.error.URLError, RuntimeError, KeyError) as e:
        log(f"FATAL: Ryot failed after {corrected} corrections, {created} new: {e}")
        return 1
    log(f"done: {created} created, {corrected} corrected")
    return 0 if created == len(news) else 1


if __name__ == "__main__":
    sys.exit(main())
