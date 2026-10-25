#!/usr/bin/env python3
"""
workouts-to-memos: one Memos journal entry per day with workouts.

Stats come from FreeReps (Apple Health); the map is drawn from Dawarich's points
inside each workout's window, so it shows what freereps-to-dawarich put there.
Start/end labels are the nearest place the user named in Dawarich (source
`manual`) within PLACE_RADIUS_M, else the arrondissement/city of the nearest
geocoded point. A Home ↔ Work workout adds #commute.

Idempotent per day: the state file maps day -> (memo name, workout signature).
A day whose workouts changed (late route, new ride) has its memo deleted and
recreated; an unchanged day is skipped.

Env: JOURNAL_{DAY,DAYS,STATE,DRY_RUN,PLACE_RADIUS_M}, MEMOS_{URL,TOKEN_FILE},
DAWARICH_WEB_URL, PSQL_BIN, RUNUSER_BIN.
"""

import base64
import hashlib
import json
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from ..httpjson import http_json
from ..logs import logger
from ..pg import psql_rows
from ..secrets import env_int, env_str, read_secret
from ..state import load_json, save_json

TAG = "workouts-to-memos"
TZ = ZoneInfo("Europe/Paris")
DEFAULT_MEMOS = "http://127.0.0.1:13356"
DEFAULT_WEB = "https://rpi5.gate-mintaka.ts.net:3900"
COLORS = ["#2563eb", "#f97316", "#16a34a", "#9333ea", "#db2777", "#0891b2"]
# FreeReps workout name -> (emoji, title, noun, tag)
KINDS = {
    "Cycling": ("🚲", "Bike", "ride", "bike"),
    "Running": ("🏃", "Run", "run", "run"),
    "Walking": ("🚶", "Walk", "walk", "walk"),
    "Hiking": ("🥾", "Hike", "hike", "hike"),
}


@dataclass(frozen=True)
class Config:
    memos_url: str = DEFAULT_MEMOS
    token_file: str = "/run/agenix/memos-token"
    web_url: str = DEFAULT_WEB
    day: str = ""
    days: int = 3
    state_path: str = ""
    place_radius_m: int = 300
    dry_run: bool = True
    runuser: str = "runuser"
    psql: str = "psql"

    @classmethod
    def from_env(cls, env=None):
        return cls(
            memos_url=env_str("MEMOS_URL", DEFAULT_MEMOS, env).rstrip("/"),
            token_file=env_str("MEMOS_TOKEN_FILE", "/run/agenix/memos-token", env),
            web_url=env_str("DAWARICH_WEB_URL", DEFAULT_WEB, env).rstrip("/"),
            day=env_str("JOURNAL_DAY", "", env).strip(),
            days=env_int("JOURNAL_DAYS", 3, env),
            state_path=env_str("JOURNAL_STATE", "", env),
            place_radius_m=env_int("JOURNAL_PLACE_RADIUS_M", 300, env),
            dry_run=env_str("JOURNAL_DRY_RUN", "1", env) != "0",
            runuser=env_str("RUNUSER_BIN", "runuser", env),
            psql=env_str("PSQL_BIN", "psql", env),
        )


@dataclass(frozen=True)
class Workout:
    id: str
    name: str
    start: int  # epoch s
    end: int
    km: float
    minutes: float
    kcal: float


def _q(cfg, run, sql, db):
    return psql_rows(run, sql, db, cfg.runuser, cfg.psql)


def target_days(cfg, today=None):
    """JOURNAL_DAY alone, else the last JOURNAL_DAYS days ending yesterday."""
    if cfg.day:
        return [date.fromisoformat(cfg.day)]
    today = today or datetime.now(TZ).date()
    return [today - timedelta(days=n) for n in range(cfg.days, 0, -1)]


def day_bounds(day):
    start = datetime(day.year, day.month, day.day, tzinfo=TZ)
    return int(start.timestamp()), int((start + timedelta(days=1)).timestamp())


def workouts(cfg, run, day):
    lo, hi = day_bounds(day)
    rows = _q(cfg, run, f"""
        SELECT id, name, extract(epoch FROM start_time)::bigint,
               extract(epoch FROM end_time)::bigint, coalesce(distance, 0),
               coalesce(duration_sec, 0), coalesce(active_energy_burned, 0)
        FROM workouts
        WHERE start_time >= to_timestamp({lo}) AND start_time < to_timestamp({hi})
        ORDER BY start_time
    """, "freereps")
    return [Workout(r[0], r[1], int(r[2]), int(r[3]), float(r[4]) / 1000,
                    float(r[5]) / 60, float(r[6])) for r in rows]


def signature(ws, point_counts):
    raw = json.dumps([[w.id, n] for w, n in zip(ws, point_counts)])
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def dawarich_user(cfg, run):
    rows = _q(cfg, run, "SELECT id FROM users ORDER BY id", "dawarich")
    if len(rows) != 1:
        raise RuntimeError(f"expected one Dawarich user, found {len(rows)}")
    return int(rows[0][0])


def track(cfg, run, uid, w):
    """[(lat, lon)] of Dawarich's points inside the workout window."""
    rows = _q(cfg, run, f"""
        SELECT ST_Y(lonlat::geometry), ST_X(lonlat::geometry) FROM points
        WHERE user_id = {uid} AND timestamp BETWEEN {w.start} AND {w.end}
          AND anomaly IS NOT TRUE
        ORDER BY timestamp
    """, "dawarich")
    return [(float(r[0]), float(r[1])) for r in rows]


def arrondissement(postcode, city):
    if len(postcode) == 5 and postcode.startswith("75"):
        n = int(postcode[3:])
        return f"Paris {n}{'er' if n == 1 else 'e'}"
    return city.replace("-sur-Seine", "")


def place(cfg, run, uid, lat, lon):
    """Nearest user-named Dawarich place within the radius, else the area name."""
    here = f"ST_SetSRID(ST_MakePoint({float(lon)}, {float(lat)}), 4326)::geography"
    rows = _q(cfg, run, f"""
        SELECT name FROM places
        WHERE user_id = {uid} AND source = 0
          AND ST_DWithin(lonlat, {here}, {int(cfg.place_radius_m)})
        ORDER BY lonlat <-> {here} LIMIT 1
    """, "dawarich")
    if rows:
        return rows[0][0]
    rows = _q(cfg, run, f"""
        SELECT coalesce(geodata->'properties'->>'postcode', ''), coalesce(city, '')
        FROM points WHERE user_id = {uid} AND geodata ? 'properties'
        ORDER BY lonlat <-> {here} LIMIT 1
    """, "dawarich")
    return (arrondissement(*rows[0]) if rows else "") or "?"


def kind(name):
    return KINDS.get(name, ("🏅", name, "workout", name.lower().replace(" ", "")))


def _hm(minutes):
    h, m = divmod(round(minutes), 60)
    return f"{h} h {m:02d}" if h else f"{m} min"


def content(day, ws, legs, web_url):
    """Memo markdown. `legs` = [(from_label, to_label) or None] per workout."""
    kinds = {kind(w.name) for w in ws}
    emoji, title, noun, _ = next(iter(kinds)) if len(kinds) == 1 else ("🏅", "Workouts", "workout", "")
    total_km = sum(w.km for w in ws)
    head = [f"{len(ws)} {noun}{'s' if len(ws) > 1 else ''}"]
    if total_km:
        head.append(f"{total_km:.1f} km")
    head.append(_hm(sum(w.minutes for w in ws)))
    if sum(w.kcal for w in ws):
        head.append(f"{sum(w.kcal for w in ws):.0f} kcal")
    lines = [f"{emoji} **{title} — {' · '.join(head)}**", ""]
    tags = []
    for w, leg in zip(ws, legs):
        e, _, _, tag = kind(w.name)
        parts = [f"**{datetime.fromtimestamp(w.start, TZ):%H:%M}**"]
        if len(kinds) > 1:
            parts[0] = f"{e} {parts[0]}"
        route = f"{leg[0]} → {leg[1]}" if leg else w.name
        bits = [route]
        if w.km:
            bits.append(f"{w.km:.1f} km")
        bits.append(_hm(w.minutes))
        if w.km and w.minutes:
            bits.append(f"{w.km / (w.minutes / 60):.1f} km/h")
        lines.append(f"- {parts[0]} {' · '.join(bits)}")
        if tag not in tags:
            tags.append(tag)
        if leg and {leg[0].lower(), leg[1].lower()} == {"home", "work"} and "commute" not in tags:
            tags.append("commute")
    lines += ["", f"[Open the day in Dawarich]({web_url}/map/v2?panel=timeline&date={day})",
              "", " ".join(f"#{t}" for t in tags)]
    return "\n".join(lines) + "\n"


def render(tracks, path):
    """Map PNG: one colour per workout, white casing, start dot coloured, end dark."""
    from staticmap import CircleMarker, Line, StaticMap  # lazy: Pillow + requests

    m = StaticMap(800, 800, padding_x=20, padding_y=20,
                  url_template="https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                  headers={"User-Agent": "nicos-journal/1.0 (self-hosted, personal)"})
    for pts, color in zip(tracks, COLORS * 4):
        if len(pts) < 2:
            continue
        ll = [(lon, lat) for lat, lon in pts]
        m.add_line(Line(ll, "white", 8))
        m.add_line(Line(ll, color, 4))
        for at, fill in ((ll[0], color), (ll[-1], "#111827")):
            m.add_marker(CircleMarker(at, "white", 14))
            m.add_marker(CircleMarker(at, fill, 9))
    m.render().save(path)


class Memos:
    def __init__(self, base, token, opener=None):
        self.base, self.token, self.opener = base + "/api/v1", token, opener

    def call(self, method, path, body=None):
        req = urllib.request.Request(
            self.base + path, method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {self.token}",
                     "Content-Type": "application/json"})
        return http_json(req, opener=self.opener)

    def delete_memo(self, name):
        """Delete a memo and its attachments; a memo already gone is fine."""
        try:
            memo = self.call("GET", f"/{name}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return
            raise
        for att in memo.get("attachments", []):
            self.call("DELETE", f"/{att['name']}")
        self.call("DELETE", f"/{name}")

    def post(self, text, png, filename, when, lat, lon, label):
        att = self.call("POST", "/attachments", {
            "filename": filename, "type": "image/png",
            "content": base64.b64encode(png).decode()})
        memo = self.call("POST", "/memos", {
            "content": text, "visibility": "PRIVATE",
            "location": {"placeholder": label, "latitude": lat, "longitude": lon},
            "attachments": [{"name": att["name"]}]})
        # CreateMemo ignores createTime; only an update with this mask sets it.
        self.call("PATCH", f"/{memo['name']}?updateMask=create_time",
                  {"createTime": when})
        return memo["name"]


def journal_day(cfg, run, memos, state, day, uid, log, render_fn, tmpdir):
    """Create/refresh one day's memo. Returns the memo name, or None if no workouts."""
    ws = workouts(cfg, run, day)
    key = day.isoformat()
    if not ws:
        return None
    tracks = [track(cfg, run, uid, w) for w in ws]
    sig = signature(ws, [len(t) for t in tracks])
    if state.get(key, {}).get("sig") == sig:
        log(f"{key}: unchanged")
        return state[key]["memo"]
    legs = [(place(cfg, run, uid, *t[0]), place(cfg, run, uid, *t[-1])) if t else None
            for t in tracks]
    text = content(key, ws, legs, cfg.web_url)
    if cfg.dry_run:
        log(f"[dry-run] {key}: {len(ws)} workouts\n{text}")
        return None
    png_path = f"{tmpdir}/workouts-{key}.png"
    render_fn(tracks, png_path)
    with open(png_path, "rb") as f:
        png = f.read()
    last = next((t for t in reversed(tracks) if t), None)
    lat, lon = last[-1] if last else (0.0, 0.0)
    label = legs[tracks.index(last)][1] if last else ""
    when = datetime.fromtimestamp(ws[-1].end, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if key in state:
        memos.delete_memo(state[key]["memo"])
    name = memos.post(text, png, f"workouts-{key}.png", when, lat, lon, label)
    state[key] = {"memo": name, "sig": sig}
    log(f"{key}: {name} ({len(ws)} workouts)")
    return name


def main(env=None, run=None, opener=None, render_fn=None, today=None):
    import tempfile

    cfg = Config.from_env(env)
    log = logger(TAG)
    if run is None:
        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    try:
        token = "" if cfg.dry_run else read_secret(cfg.token_file)
        memos = Memos(cfg.memos_url, token, opener)
        state = load_json(cfg.state_path, {}) if cfg.state_path else {}
        uid = dawarich_user(cfg, run)
        with tempfile.TemporaryDirectory() as tmp:
            for day in target_days(cfg, today):
                journal_day(cfg, run, memos, state, day, uid, log, render_fn or render, tmp)
                if cfg.state_path and not cfg.dry_run:
                    save_json(cfg.state_path, state)
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as e:
        log(f"FATAL: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
