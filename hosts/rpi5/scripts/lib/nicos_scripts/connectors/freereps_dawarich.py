#!/usr/bin/env python3
"""
freereps-to-dawarich: Apple Health workout routes (FreeReps) -> Dawarich points.

FreeReps holds each route at ~1 Hz; the phone's own Dawarich tracker logs every
~5 min. Points go in under the phone's tracker id: Dawarich builds tracks per
tracker, so a separate id would draw the ride as a second, parallel track.

Dawarich upserts on (user, timestamp, lonlat), so a re-push is harmless. The
state file ({workout_id: route_points}) only skips routes already sent, and
re-sends one whose route grew — Health Auto Export often delivers the workout
first and its route on a later push.

Dawarich only builds tracks from untracked points, so the phone's sparse track
for the same ride would stay beside the new one. Before a push, tracks
overlapping the ride are deleted (points detached) in SQL — there is no API for
it — and the push's own backfill job rebuilds the whole day. A ride overlapping
a track with a hand-corrected segment is skipped outright: Dawarich's rebuild
re-tracks those points and drops the old track, correction included (3 lost
that way on the 2026-10-25 backfill).

Both databases are reached as postgres over the socket; the API key comes from
Dawarich's users table, so no secret is copied anywhere.

Env: DAWARICH_{BASE_URL,TRACKER_ID}, FREEREPS_DAWARICH_{STATE,STEP_S,MAX_ACCURACY_M,
DRY_RUN}, PSQL_BIN, RUNUSER_BIN.
"""

import json
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass

from ..httpjson import post_json
from ..logs import logger
from ..pg import psql_rows
from ..secrets import env_int, env_str
from ..state import load_json, save_json

TAG = "freereps-to-dawarich"
DEFAULT_BASE = "http://127.0.0.1:13900"


@dataclass(frozen=True)
class Config:
    base_url: str = DEFAULT_BASE
    tracker_id: str = ""
    state_path: str = ""
    step_s: int = 5
    max_accuracy_m: int = 50
    dry_run: bool = True
    runuser: str = "runuser"
    psql: str = "psql"

    @classmethod
    def from_env(cls, env=None):
        return cls(
            base_url=env_str("DAWARICH_BASE_URL", DEFAULT_BASE, env).rstrip("/"),
            tracker_id=env_str("DAWARICH_TRACKER_ID", "", env),
            state_path=env_str("FREEREPS_DAWARICH_STATE", "", env),
            step_s=env_int("FREEREPS_DAWARICH_STEP_S", 5, env),
            max_accuracy_m=env_int("FREEREPS_DAWARICH_MAX_ACCURACY_M", 50, env),
            dry_run=env_str("FREEREPS_DAWARICH_DRY_RUN", "1", env) != "0",
            runuser=env_str("RUNUSER_BIN", "runuser", env),
            psql=env_str("PSQL_BIN", "psql", env),
        )


def _q(cfg, run, sql, db):
    return psql_rows(run, sql, db, cfg.runuser, cfg.psql)


def routed_workouts(cfg, run):
    """[(workout_id, name, route_points)], oldest first."""
    rows = _q(cfg, run, """
        SELECT w.id, w.name, count(*) FROM workouts w
        JOIN workout_routes r ON r.workout_id = w.id
        GROUP BY w.id, w.name ORDER BY min(r.time)
    """, "freereps")
    return [(r[0], r[1], int(r[2])) for r in rows]


def route(cfg, run, workout_id):
    """[(epoch_s, lat, lon, alt, speed, course, accuracy)] — floats or None."""
    wid = str(uuid.UUID(workout_id))  # interpolated into SQL below
    rows = _q(cfg, run, f"""
        SELECT floor(extract(epoch FROM time))::bigint, latitude, longitude,
               altitude, speed, course, horizontal_accuracy
        FROM workout_routes WHERE workout_id = '{wid}' ORDER BY time
    """, "freereps")
    num = lambda v: float(v) if v not in ("", None) else None
    return [(int(r[0]), *(num(v) for v in r[1:])) for r in rows]


def dawarich_identity(cfg, run):
    """(user_id, api_key, tracker_id) of the single Dawarich user."""
    users = _q(cfg, run, "SELECT id, api_key FROM users ORDER BY id", "dawarich")
    if len(users) != 1:
        raise RuntimeError(f"expected one Dawarich user, found {len(users)}")
    uid, api_key = int(users[0][0]), users[0][1]
    tracker = cfg.tracker_id
    if not tracker:
        # Latest live (non-imported) point = the phone app's id.
        rows = _q(cfg, run, f"""
            SELECT tracker_id FROM points
            WHERE user_id = {uid} AND import_id IS NULL AND tracker_id IS NOT NULL
            ORDER BY timestamp DESC LIMIT 1
        """, "dawarich")
        tracker = rows[0][0] if rows else TAG
    return uid, api_key, tracker


def _overlapping(uid, start, end):
    return f"""
        SELECT id FROM tracks WHERE user_id = {uid}
          AND (start_at, end_at) OVERLAPS (to_timestamp({int(start)}) AT TIME ZONE 'UTC',
                                           to_timestamp({int(end)}) AT TIME ZONE 'UTC')"""


def corrected_overlap(cfg, run, uid, start, end):
    """True when a hand-corrected track overlaps [start, end] (epoch s)."""
    return bool(_q(cfg, run, f"""
        SELECT 1 FROM track_segments
        WHERE corrected_at IS NOT NULL AND track_id IN ({_overlapping(uid, start, end)})
        LIMIT 1
    """, "dawarich"))


def clear_overlapping_tracks(cfg, run, uid, start, end):
    """Delete the user's tracks overlapping [start, end] (epoch s); ids deleted."""
    rows = _q(cfg, run, f"""
        WITH t AS ({_overlapping(uid, start, end)}
        ), p AS (
          UPDATE points SET track_id = NULL WHERE track_id IN (SELECT id FROM t)
        ), s AS (
          DELETE FROM track_segments WHERE track_id IN (SELECT id FROM t)
        )
        DELETE FROM tracks WHERE id IN (SELECT id FROM t) RETURNING id
    """, "dawarich")
    return [r[0] for r in rows]


def thin(points, step_s, max_accuracy_m):
    """One point per `step_s`, dropping fixes worse than `max_accuracy_m`.

    The last fix is always kept so the ride ends where it ended.
    """
    good = [p for p in points if p[6] is None or 0 <= p[6] <= max_accuracy_m]
    kept = []
    for p in good:
        if not kept or p[0] - kept[-1][0] >= step_s:
            kept.append(p)
    if good and kept[-1] is not good[-1]:
        kept.append(good[-1])
    return kept


def payload(points, tracker, workout_id):
    """Dawarich /api/v1/points body (Overland-style GeoJSON features).

    Apple marks an unknown speed/course as -1, and Health Auto Export sends
    every one that way; Dawarich reads a negative speed as a bad fix and leaves
    the track's mode unknown. Omitted, it derives speed from distance/time.
    """
    def feature(p):
        t, lat, lon, alt, speed, course, acc = p
        props = {"timestamp": t, "device_id": tracker,
                 "source": "freereps", "workout_id": workout_id}
        for key, val, floor in (("altitude", alt, None), ("speed", speed, 0),
                                ("course", course, 0), ("horizontal_accuracy", acc, 0)):
            if val is not None and (floor is None or val >= floor):
                props[key] = val
        return {"type": "Feature",
                "geometry": {"type": "Point", "coordinates": [lon, lat]},
                "properties": props}
    return {"locations": [feature(p) for p in points]}


def sync(cfg, run, opener=None, log=print, sleep=time.sleep):
    """Push every new or grown route. Returns (workouts_pushed, points_sent)."""
    state = load_json(cfg.state_path, {}) if cfg.state_path else {}
    todo = [w for w in routed_workouts(cfg, run) if state.get(w[0]) != w[2]]
    if not todo:
        log("nothing new")
        return 0, 0
    uid, api_key, tracker = dawarich_identity(cfg, run)
    pushed = sent = 0
    for wid, name, n in todo:
        pts = thin(route(cfg, run, wid), cfg.step_s, cfg.max_accuracy_m)
        day = time.strftime("%Y-%m-%d", time.gmtime(pts[0][0])) if pts else "?"
        if cfg.dry_run:
            log(f"[dry-run] {day} {name} {wid}: {n} fixes -> {len(pts)} points")
            continue
        if pts and corrected_overlap(cfg, run, uid, pts[0][0], pts[-1][0]):
            log(f"{day} {name} {wid}: skipped, overlaps a hand-corrected track")
            pts = []
        elif pts:
            cleared = clear_overlapping_tracks(cfg, run, uid, pts[0][0], pts[-1][0])
            status, body = post_json(
                f"{cfg.base_url}/api/v1/points", payload(pts, tracker, wid),
                headers={"Authorization": f"Bearer {api_key}"}, opener=opener)
            if status != 200:
                raise RuntimeError(f"{wid}: HTTP {status} {body[:200]}")
            log(f"{day} {name} {wid}: {n} fixes -> {len(pts)} points, "
                f"{len(json.loads(body).get('data', []))} upserted, "
                f"{len(cleared)} overlapping tracks cleared")
        state[wid] = n
        if cfg.state_path:
            save_json(cfg.state_path, state)
        pushed, sent = pushed + 1, sent + len(pts)
        sleep(1)  # Dawarich's per-request jobs run on one Sidekiq thread
    return pushed, sent


def main(env=None, run=None, opener=None):
    cfg = Config.from_env(env)
    log = logger(TAG)
    if run is None:
        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True,
                                  check=True).stdout
    try:
        pushed, sent = sync(cfg, run, opener=opener, log=log)
    except (RuntimeError, OSError, subprocess.CalledProcessError) as e:
        log(f"FATAL: {e}")
        return 1
    if pushed:
        log(f"done: {pushed} workouts, {sent} points")
    return 0


if __name__ == "__main__":
    sys.exit(main())
