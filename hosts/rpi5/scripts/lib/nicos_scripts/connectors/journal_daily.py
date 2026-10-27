#!/usr/bin/env python3
"""
journal-daily: one Memos journal entry per day with workouts or photos.

Workouts: stats from FreeReps (Apple Health). Trips: every Dawarich track of
the day (walk, car, metro…), one colour per travel mode; a track overlapping a
workout takes the workout's kind, since Dawarich files some rides as runs.
Tracks that are not workouts get their own section. The map draws them all,
plus any workout Dawarich has no track for yet (from its points). Start/end labels are the nearest place the user named in Dawarich
(source `manual`) within PLACE_RADIUS_M, else the arrondissement/city of the
nearest geocoded point. A Home ↔ Work workout adds #commute.

Photos: the day's Immich timeline images (archived WhatsApp images and Live
Photo motion halves are not on the timeline), favourites first, then spread
over the day's hours, up to PHOTOS_MAX, as ONE collage attachment with each
photo's time on its tile — the Memos gallery shows no times, and one ~400 KB
sheet replaces ~2.5 MB of separate previews. Immich URL and key
come from Dawarich's integration settings (see immich_dawarich); if Immich is
unreachable the entry is written without photos and replaced once it answers.

A day runs 04:00 -> 04:00 Europe/Paris (DAY_START_H): late-night workouts and
photos count for the evening before. The timer runs after it, at 04:30.

Idempotent per day: the state file keeps, per day, the memo, a signature of
its inputs (workouts, their point counts, the chosen photos), and the text and
attachments we last wrote. A changed day is updated IN PLACE: our block of text
is swapped inside whatever the user added around it, our attachments replaced,
theirs kept. If the user rewrote our block itself, their text wins.

Calendar, weather, activity (FreeReps), music and games (Ryot) and climbing
(arkose-sync): see journal_sources. A day with only calendar events or a
climbing session still gets an entry; weather, activity, music or games alone
do not.

Side-project notes: `entire dispatch --local` over the day, per repo in
JOURNAL_DISPATCH_REPOS, in a collapsed "Projets perso" section (the repos on
the Pi are side projects, not work). Generated once per
finished day and cached in the state's `_dispatch` (an agent call each).

Env: JOURNAL_{DAY,DAYS,STATE,DRY_RUN,PLACE_RADIUS_M,PHOTOS_MAX,
PERSONAL_CALENDARS,WORK_CALENDARS,DISPATCH_REPOS,DISPATCH_USER}, GIT_BIN, MEMOS_{URL,TOKEN_FILE}, NEXTCLOUD_DB,
DAWARICH_WEB_URL, PSQL_BIN, RUNUSER_BIN.
"""

import base64
import dataclasses
import functools
import hashlib
import json
import math
import sqlite3
import subprocess
from collections import Counter
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from ..httpjson import http_json
from ..logs import logger
from ..pg import psql_rows
from ..secrets import env_int, env_str, read_secret
from ..state import load_json, save_json
from .immich_dawarich import immich_settings
from . import journal_family as fam
from . import journal_flights as fl
from . import journal_home as home
from . import journal_records as rec
from . import journal_spend as spend
from . import journal_summary as summ
from . import journal_sources as src

TAG = "journal-daily"
TZ = ZoneInfo("Europe/Paris")
DEFAULT_MEMOS = "http://127.0.0.1:13356"
DEFAULT_WEB = "https://rpi5.gate-mintaka.ts.net:3900"
# Memos' dark theme (web/src/themes/default-dark.css, oklch -> sRGB): the map
# sits in its cards, so the base is its card grey and route 1 its primary blue.
DARK_BG, DARK_CARD, DARK_MUTED_FG, DARK_FG = "#1d1f23", "#25282c", "#a2a5a9", "#dbdee2"
COLORS = ["#5b97d3", "#f2a65a", "#5fc19a", "#e57ba8", "#a78bfa", "#56c2d6"]
# A journal day runs 04:00 -> 04:00: a ride home at 01:00 belongs to the evening before.
DAY_START_H = 4
CLIMB_TILES_MAX = 16
FLASH_GOLD = (255, 200, 40)
MEMORY_JOB_WAIT_S = 10  # the generation took ~5 s on Oct 26
# FreeReps workout name -> (emoji, title, noun, tag); text in French, tags in English.
KINDS = {
    "Cycling": ("🚲", "Vélo", "trajet", "bike"),
    "Running": ("🏃", "Course", "course", "run"),
    "Walking": ("🚶", "Marche", "marche", "walk"),
    "Hiking": ("🥾", "Rando", "rando", "hike"),
}
# Dawarich Track::TRANSPORTATION_MODES (1.16) -> (emoji, map colour); 1 = stationary, dropped.
WALK, ROAD, TRANSIT, OTHER = "#5fc19a", "#f2a65a", "#e57ba8", "#a78bfa"
MODES = {0: ("🧭", OTHER), 2: ("🚶", WALK), 3: ("🏃", WALK), 4: ("🚲", COLORS[0]),
         5: ("🚗", ROAD), 6: ("🚌", TRANSIT), 7: ("🚆", TRANSIT), 8: ("✈️", "#56c2d6"),
         9: ("⛴", "#56c2d6"), 10: ("🏍", ROAD)}
WORKOUT_MODE = {"Cycling": 4, "Running": 3, "Walking": 2, "Hiking": 2}
# Shorter tracks are GPS jitter around a stop (Oct 12: three 0-100 m ones).
MIN_TRIP_M = 300


@dataclass(frozen=True)
class Config:
    memos_url: str = DEFAULT_MEMOS
    token_file: str = "/run/agenix/memos-token"
    web_url: str = DEFAULT_WEB
    day: str = ""
    days: int = 3
    state_path: str = ""
    place_radius_m: int = 300
    photos_max: int = 9
    personal_calendars: tuple = ("PERSO", "Google")
    work_calendars: tuple = ("TRUSK",)
    nextcloud_db: str = "nextcloud_production"
    ryot_db: str = "ryotv2"
    ryot_v1_db: str = "ryot"  # history before the V11 switch
    freereps_db: str = "freereps"
    dispatch_repos: tuple = ()
    dispatch_user: str = "nsimon"
    git: str = "git"
    arkose_sessions: str = "/var/lib/arkose-sync/sessions.json"
    birthday_calendars: tuple = ("Contact birthdays",)
    gramps_db: str = ""
    gramps_home: str = ""
    gramps_url: str = ""
    font: str = ""
    airtrail_db: str = "airtrail"
    airtrail_url: str = ""
    ha_db: str = ""
    immich_admin_key_file: str = ""
    spend_accounts: tuple = ()  # Sure account names; none = no spending section
    joint_accounts: tuple = ()
    sure_url: str = "http://127.0.0.1:13334/sure"
    sure_key_file: str = ""
    sure_public_url: str = ""  # the memo's link to the day's transactions
    gate_url: str = ""
    summary_model: str = "gpt-6-luna"
    home: tuple = (48.8566, 2.3522)  # weather when the day has no GPS
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
            photos_max=env_int("JOURNAL_PHOTOS_MAX", 9, env),
            personal_calendars=_names(env_str("JOURNAL_PERSONAL_CALENDARS", "PERSO,Google", env)),
            work_calendars=_names(env_str("JOURNAL_WORK_CALENDARS", "TRUSK", env)),
            nextcloud_db=env_str("NEXTCLOUD_DB", "nextcloud_production", env),
            arkose_sessions=env_str("ARKOSE_SESSIONS", "/var/lib/arkose-sync/sessions.json", env),
            ryot_db=env_str("RYOT_DB", "ryotv2", env),
            ryot_v1_db=env_str("RYOT_V1_DB", "ryot", env),
            birthday_calendars=_names(env_str("JOURNAL_BIRTHDAY_CALENDARS", "Contact birthdays", env)),
            gramps_db=env_str("GRAMPS_DB", "", env),
            gramps_home=env_str("GRAMPS_HOME_PERSON", "", env),
            gramps_url=env_str("GRAMPS_URL", "", env).rstrip("/"),
            font=env_str("JOURNAL_FONT", "", env),
            airtrail_db=env_str("AIRTRAIL_DB", "airtrail", env),
            airtrail_url=env_str("AIRTRAIL_URL", "", env).rstrip("/"),
            ha_db=env_str("HA_DB", "", env),
            immich_admin_key_file=env_str("IMMICH_ADMIN_KEY_FILE", "", env),
            spend_accounts=_names(env_str("JOURNAL_SPEND_ACCOUNTS", "", env)),
            joint_accounts=_names(env_str("JOURNAL_JOINT_ACCOUNTS", "", env)),
            sure_url=env_str("SURE_URL", "http://127.0.0.1:13334/sure", env).rstrip("/"),
            sure_key_file=env_str("SURE_API_KEY_FILE", "", env),
            sure_public_url=env_str("SURE_PUBLIC_URL", "", env).rstrip("/"),
            gate_url=env_str("TINY_LLM_GATE_URL", "", env).rstrip("/"),
            summary_model=env_str("JOURNAL_SUMMARY_MODEL", "gpt-6-luna", env),
            dispatch_repos=_names(env_str("JOURNAL_DISPATCH_REPOS", "", env)),
            dispatch_user=env_str("JOURNAL_DISPATCH_USER", "nsimon", env),
            git=env_str("GIT_BIN", "git", env),
            dry_run=env_str("JOURNAL_DRY_RUN", "1", env) != "0",
            runuser=env_str("RUNUSER_BIN", "runuser", env),
            psql=env_str("PSQL_BIN", "psql", env),
        )


def _names(raw):
    return tuple(n.strip() for n in raw.split(",") if n.strip())


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
    start = datetime(day.year, day.month, day.day, DAY_START_H, tzinfo=TZ)
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


def signature(ws, point_counts, photo_ids=(), extra=None):
    raw = json.dumps([[[w.id, n] for w, n in zip(ws, point_counts)], list(photo_ids), extra])
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


@dataclass(frozen=True)
class Trip:
    id: str
    start: int  # epoch s
    end: int
    km: float
    minutes: float
    mode: int  # Dawarich dominant_mode
    path: tuple  # ((lat, lon), ...)


def trips(cfg, run, uid, day):
    """The day's Dawarich tracks (by start), without stops and jitter."""
    lo, hi = day_bounds(day)
    rows = _q(cfg, run, f"""
        SELECT id, extract(epoch FROM start_at)::bigint, extract(epoch FROM end_at)::bigint,
               coalesce(distance, 0), coalesce(duration, 0), coalesce(dominant_mode, 0),
               ST_AsGeoJSON(original_path, 6)
        FROM tracks
        WHERE user_id = {uid} AND coalesce(distance, 0) >= {MIN_TRIP_M}
          AND coalesce(dominant_mode, 0) <> 1
          AND start_at >= to_timestamp({lo}) AT TIME ZONE 'UTC'
          AND start_at < to_timestamp({hi}) AT TIME ZONE 'UTC'
        ORDER BY start_at
    """, "dawarich")
    return [Trip(r[0], int(r[1]), int(r[2]), float(r[3]) / 1000, float(r[4]) / 60, int(r[5]),
                 tuple((lat, lon) for lon, lat in json.loads(r[6])["coordinates"]))
            for r in rows]


def _overlaps(t, w):
    return t.start < w.end and t.end > w.start


def map_lines(ws, tracks, day_trips):
    """[(points, colour)] in time order: every trip, coloured by its mode or
    by the kind of a workout it overlaps; then each workout no trip covers,
    from its own points (Dawarich rebuilds tracks after the nightly sync)."""
    lines = []
    for t in day_trips:
        w = next((w for w in ws if _overlaps(t, w)), None)
        mode = WORKOUT_MODE.get(w.name, t.mode) if w else t.mode
        lines.append((t.start, list(t.path), MODES.get(mode, MODES[0])[1]))
    for w, pts in zip(ws, tracks):
        if not any(_overlaps(t, w) for t in day_trips):
            lines.append((w.start, pts, MODES[WORKOUT_MODE.get(w.name, 0)][1]))
    return [(pts, c) for _, pts, c in sorted(lines, key=lambda l: l[0]) if len(pts) >= 2]


def other_trips(ws, day_trips):
    """Trips that are not one of the day's workouts."""
    return [t for t in day_trips if not any(_overlaps(t, w) for w in ws)]


def arrondissement(postcode, city):
    if len(postcode) == 5 and postcode.startswith("75"):
        n = int(postcode[3:])
        return f"Paris {n}{'er' if n == 1 else 'e'}"
    return city.replace("-sur-Seine", "")


@dataclass(frozen=True)
class Place:
    label: str
    tag: str = ""  # Dawarich tag name, e.g. Home / Work


def place(cfg, run, uid, lat, lon):
    """Nearest tagged or user-named Dawarich place within the radius (tagged
    first), else the area name. A tagged place the geocoder named ("93400 Rue
    Godillot 5 ()") reads as its tag instead: "💼 Work"."""
    here = f"ST_SetSRID(ST_MakePoint({float(lon)}, {float(lat)}), 4326)::geography"
    rows = _q(cfg, run, f"""
        SELECT p.name, p.source, coalesce(t.name, ''), coalesce(t.icon, '')
        FROM places p
        LEFT JOIN taggings g ON g.taggable_type = 'Place' AND g.taggable_id = p.id
        LEFT JOIN tags t ON t.id = g.tag_id
        WHERE p.user_id = {uid} AND (p.source = 0 OR t.id IS NOT NULL)
          AND ST_DWithin(p.lonlat, {here}, {int(cfg.place_radius_m)})
        ORDER BY t.id IS NULL, p.lonlat <-> {here} LIMIT 1
    """, "dawarich")
    if rows:
        name, source, tag, icon = rows[0]
        shown = name if source == "0" or not tag else tag
        return Place(f"{icon} {shown}".strip(), tag)
    rows = _q(cfg, run, f"""
        SELECT coalesce(geodata->'properties'->>'postcode', ''), coalesce(city, '')
        FROM points WHERE user_id = {uid} AND geodata ? 'properties'
        ORDER BY lonlat <-> {here} LIMIT 1
    """, "dawarich")
    return Place((arrondissement(*rows[0]) if rows else "") or "?")


def kind(name):
    return KINDS.get(name, ("🏅", name, "séance", name.lower().replace(" ", "")))


def _hm(minutes):
    h, m = divmod(round(minutes), 60)
    return f"{h} h {m:02d}" if h else f"{m} min"


def _hm_short(minutes):
    """`2h15` / `45min`."""
    h, m = divmod(round(minutes), 60)
    return f"{h}h{m:02d}" if h else f"{m}min"


def _n(x):
    """One decimal, French comma: 19,4."""
    return f"{x:.1f}".replace(".", ",")


def tile_label(asset):
    """(HH:MM, shots): drawn `14:29`, or `14:29 (8)` for a moment of 8."""
    return photo_time({"fileCreatedAt": asset.get("since", asset["fileCreatedAt"])}), asset.get("burst", 1)


def moment_time(m):
    """`14:29`, or `14:29-16:57` for a moment spanning minutes."""
    a = photo_time({"fileCreatedAt": m.get("since", m["fileCreatedAt"])})
    b = photo_time({"fileCreatedAt": m.get("until", m["fileCreatedAt"])})
    return a if a == b else f"{a}-{b}"


def photo_time(asset):
    """Local HH:MM a photo was taken."""
    t = datetime.fromisoformat(asset["fileCreatedAt"].replace("Z", "+00:00"))
    return f"{t.astimezone(TZ):%H:%M}"


def workout_section(ws, legs, web_url, day, badges=()):
    """(markdown lines, tags) of the workouts section; `badges` = record and
    streak lines, after the workouts."""
    kinds = {kind(w.name) for w in ws}
    emoji, title, noun, _ = next(iter(kinds)) if len(kinds) == 1 else ("🏅", "Sport", "séance", "")
    total_km = sum(w.km for w in ws)
    head = [f"{len(ws)} {noun}{'s' if len(ws) > 1 else ''}"]
    if total_km:
        head.append(f"{_n(total_km)} km")
    head.append(_hm(sum(w.minutes for w in ws)))
    if sum(w.kcal for w in ws):
        head.append(f"{sum(w.kcal for w in ws):.0f} kcal")
    lines, tags = [f"### {emoji} {title} - {' · '.join(head)}", ""], []
    for w, leg in zip(ws, legs):
        e, title_w, _, tag = kind(w.name)
        at = f"**{datetime.fromtimestamp(w.start, TZ):%H:%M}**"
        if len(kinds) > 1:
            at = f"{e} {at}"
        if not leg:
            bits = [title_w]
        elif leg[0].label == leg[1].label:
            bits = [f"autour de {leg[0].label}"]
        else:
            bits = [f"{leg[0].label} → {leg[1].label}"]
        if w.km:
            bits.append(f"{_n(w.km)} km")
        bits.append(_hm(w.minutes))
        if w.km and w.minutes:
            bits.append(f"{_n(w.km / (w.minutes / 60))} km/h")
        lines.append(f"- {at} {' · '.join(bits)}")
        if tag not in tags:
            tags.append(tag)
        if leg and {leg[0].tag, leg[1].tag} == {"Home", "Work"} and "commute" not in tags:
            tags.append("commute")
    lines += [*badges, "", f"[Voir la journée dans Dawarich]({web_url}/map/v2?panel=timeline&date={day})"]
    return lines, tags


def trip_section(day_trips, legs):
    """Markdown lines: `- **14:02** 🚗 Alfie → Des Terres · 13.9 km · 35 min`."""
    km = sum(t.km for t in day_trips)
    n = len(day_trips)
    lines = [f"### 🧭 Déplacements - {n} trajet{'s' if n > 1 else ''} · {_n(km)} km", ""]
    for t, (a, b) in zip(day_trips, legs):
        where = f"autour de {a.label}" if a.label == b.label else f"{a.label} → {b.label}"
        lines.append(f"- **{datetime.fromtimestamp(t.start, TZ):%H:%M}** {MODES.get(t.mode, MODES[0])[0]} "
                     f"{where} · {_n(t.km)} km · {_hm(t.minutes)}")
    return lines


def photo_lines(shots):
    """One line per moment: `- [14:29-16:57](url) · 🏡 Alfie · 8 photos`.
    `shots` = [(HH:MM or HH:MM-HH:MM, url, place label, photo count)]."""
    lines = []
    for hm, url, where, n in shots:
        bits = [f"[{hm}]({url})" if url else hm]
        if where:
            bits.append(where)
        if n > 1:
            bits.append(f"{n} photos")
        lines.append(f"- {' · '.join(bits)}")
    return lines


def content(day, ws, legs, web_url, photos=0, photos_url="", shots=(),
            weather=None, agenda=(), work=None, day_trips=(), trip_legs=(), music=None, climbing=None, games=None, activity=None, notes=(),
            memories=(), birthdays=(), genealogy=(), flights=None, flights_url="", energy=None,
            screens=None, badges=None, spending=None):
    """Memo markdown, in French (journal_day may prefix a one-line summary):
    the weather line, agenda, photos, then one
    `###` section per source; last come work, memories, home, genealogy.
    `legs` = [(from_label, to_label) or None] per workout, `trip_legs` the
    same per trip that is not a workout; `photos` = the
    day's timeline photo count, `shots` = its moments (see `photo_lines`),
    `photos_url` = the first of the day in Immich; `agenda` = personal
    calendar lines; `work` = (meetings, minutes, people[, meeting lines]) or None; `music` =
    (heading suffix, lines) from journal_sources.music_section, or None;
    `climbing` and `games` = the same from climbing_section / game_section;
    `activity` = the heading suffix from activity_section; `notes` = side-project
    notes (journal_sources.dispatch_notes), collapsed in their own section;
    `memories` = lines from memory_lines; `birthdays` and `genealogy` = the
    two lists from journal_family.family_sections; `flights` = (heading
    suffix, lines) from journal_flights.flight_section, linking `flights_url`;
    `energy` = the same from journal_home.energy_section, last of all;
    `screens` = the same from journal_sources.screen_section, `spending` from
    journal_spend.spend_section; `badges` =
    {"bike" | "activity" | "climbing" | "home": record and streak lines}."""
    badges = badges or {}
    sections, tags = [], []
    if weather:
        sections.append([weather])
    if agenda:
        sections.append(["### 📅 Agenda", "", *agenda])
    if birthdays:
        sections.append(["### 🎂 Anniversaires", "", *birthdays])
        tags.append("birthday")
    if flights:
        head, lines = flights
        sections.append([f"### ✈️ Vol - {head}", "", *lines,
                         *(["", f"[Voir dans AirTrail]({flights_url})"] if flights_url else [])])
        tags.append("flight")
    if photos:
        # Each line links into Immich, where swiping walks the rest of the day.
        lines = [f"### 📷 Photos - {photos}", "", *photo_lines(shots)]
        if photos_url and not shots:
            lines += [f"[Voir la journée dans Immich]({photos_url})"]
        sections.append(lines)
        tags.append("photos")
    if activity:
        sections.append([f"### 🚶 Activité - {activity}", *([""] + badges["activity"] if badges.get("activity") else [])])
    if ws:
        lines, wtags = workout_section(ws, legs, web_url, day, badges.get("bike", ()))
        sections.append(lines)
        tags += wtags
    if day_trips:
        lines = trip_section(day_trips, trip_legs)
        if not ws:  # else the workouts section carries it
            lines += ["", f"[Voir la journée dans Dawarich]({web_url}/map/v2?panel=timeline&date={day})"]
        sections.append(lines)
    if climbing:
        head, lines = climbing
        sections.append([f"### 🧗 Escalade - {head}", "", *lines, *badges.get("climbing", ())])
        tags.append("climbing")
    if music:
        head, lines = music
        sections.append([f"### 🎵 Musique - {head}", "", *lines])
        tags.append("music")
    if games:
        head, lines = games
        sections.append([f"### 🎮 Jeux - {head}", "", *lines])
        tags.append("gaming")
    if screens:
        head, lines = screens
        sections.append([f"### 📺 Écrans - {head}", "", *lines])
        tags.append("screen")
    if spending:
        head, lines = spending
        sections.append([f"### 💸 Dépenses - {head}", "", *lines])
        tags.append("spending")
    if notes:  # Memos keeps <details>/<summary> (GitHub's sanitize schema)
        sections.append(["### 🛠 Projets perso", "", "<details>", "<summary>Notes</summary>", "",
                         *notes, "", "</details>"])
        tags.append("projects")
    if work:
        n, minutes, people, *rest = work
        lines = [f"### 💼 Travail - {n} réunion{'s' if n > 1 else ''} ({_hm_short(minutes)}) "
                 f"{people} personne{'s' if people > 1 else ''}"]
        if rest and rest[0]:
            lines += ["", "<details>", "<summary>Réunions</summary>", "", *rest[0], "", "</details>"]
        sections.append(lines)
        tags.append("work")
    if memories:
        sections.append(["### 🕰 Souvenirs", "", *memories])
        tags.append("memories")
    if energy:
        head, lines = energy
        sections.append([f"### 🏠 Maison - ⚡ {head}",
                         *([""] + badges["home"] if badges.get("home") else []),
                         *(["", "<details>", "<summary>Électricité</summary>", "", *lines, "", "</details>"]
                           if lines else [])])
        tags.append("home")
    if genealogy:
        n = len(genealogy)
        head = f"### 🌳 Généalogie - {n} événement{'s' if n > 1 else ''}"
        sections.append([head, "", *genealogy] if n <= 3 else
                        [head, "", "<details>", "<summary>Ce jour-là</summary>", "", *genealogy, "", "</details>"])
        tags.append("genealogy")
    body = "\n\n".join("\n".join(lines) for lines in sections)
    return f"{body}\n\n___________\n\n{' '.join(f'#{t}' for t in tags)}\n"


def collage_grid(n):
    """(columns, rows) for n tiles: one row up to 3, then 2x2, 3x2, 3x3, then 4 wide."""
    if n <= 3:
        return n, 1
    if n == 4:
        return 2, 2
    if n > 9:
        return 4, (n + 3) // 4
    return 3, (n + 2) // 3


def render_collage(images, labels, path, tile=480, gap=6, font_path=""):
    """Square-cropped grid of `images` (bytes); each tile's (HH:MM, shots)
    label sits in its bottom-left corner — `14:29 (8)` for a burst. JPEG.
    A third label item marks a boulder: "flash" (gold frame and tag),
    "retop", or "tried" (greyed out, `non topé`). `font_path`: a TTF; Pillow's
    built-in font has no accents."""
    import io

    from PIL import Image, ImageDraw, ImageFont, ImageOps  # lazy: Pillow

    cols, rows = collage_grid(len(images))
    sheet = Image.new("RGB", (cols * tile + (cols - 1) * gap, rows * tile + (rows - 1) * gap), DARK_CARD)  # gaps and empty slots blend into Memos' dark cards
    try:
        font = ImageFont.truetype(font_path, tile // 14) if font_path else None
    except OSError:  # a missing font must not drop the collage
        font = None
    if font is None:
        try:
            font = ImageFont.load_default(size=tile // 14)
        except TypeError:  # Pillow < 10.1 has no sized default font
            font = ImageFont.load_default()
    for i, (raw, label) in enumerate(zip(images, labels)):
        hm, shots, status = (*label, "")[:3]
        img = ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert("RGB")
        img = ImageOps.fit(img, (tile, tile), Image.LANCZOS)
        if status == "tried":
            img = Image.blend(ImageOps.grayscale(img).convert("RGB"), Image.new("RGB", img.size), 0.35)
        draw = ImageDraw.Draw(img, "RGBA")
        text = hm if shots <= 1 else f"{hm} ({shots})"
        text += {"flash": " · flash", "retop": " · retop", "tried": " · non topé"}.get(status, "")
        x0, y0, x1, y1 = draw.textbbox((0, 0), text, font=font)
        pad = tile // 40
        box = (pad, tile - pad - (y1 - y0) - 2 * pad, pad + (x1 - x0) + 2 * pad, tile - pad)
        gold = status == "flash"
        draw.rounded_rectangle(box, radius=pad, fill=FLASH_GOLD + (235,) if gold else (0, 0, 0, 150))
        draw.text((box[0] + pad - x0, box[1] + pad - y0), text, font=font, fill="black" if gold else "white")
        if gold:
            draw.rectangle((0, 0, tile - 1, tile - 1), outline=FLASH_GOLD, width=tile // 40)
        sheet.paste(img, ((i % cols) * (tile + gap), (i // cols) * (tile + gap)))
    sheet.save(path, "JPEG", quality=85, optimize=True)


def map_size(tracks, long_side=1000):
    """(w, h) following the route's shape, clamped to 4:3 either way, so a
    north-south commute is not a thin line in a wide empty square."""
    pts = [p for t in tracks for p in t]
    lats, lons = [p[0] for p in pts], [p[1] for p in pts]
    h = max(lats) - min(lats)
    w = (max(lons) - min(lons)) * math.cos(math.radians(sum(lats) / len(lats)))
    ratio = max(0.75, min(4 / 3, (w or 1e-4) / (h or 1e-4)))
    if ratio >= 1:
        return long_side, round(long_side / ratio)
    return round(long_side * ratio), long_side


def dark_map(w, h, padding):
    """A staticmap.StaticMap whose OSM tiles are greyscaled, inverted and
    tinted between Memos' card grey and muted text."""
    from PIL import ImageOps  # lazy: Pillow
    from staticmap import StaticMap  # lazy

    class Dark(StaticMap):
        def _draw_base_layer(self, image):
            super()._draw_base_layer(image)
            inverted = ImageOps.invert(ImageOps.grayscale(image))
            image.paste(ImageOps.colorize(inverted, black=DARK_CARD, white=DARK_MUTED_FG,
                                          blackpoint=0, whitepoint=255, midpoint=150))

    return Dark(w, h, padding_x=padding, padding_y=padding,
                url_template="https://tile.openstreetmap.org/{z}/{x}/{y}.png",
                headers={"User-Agent": "nicos-journal/1.0 (self-hosted, personal)"})


def render(lines, path):
    """Map JPEG in Memos' dark palette: OSM tiles greyscaled, inverted and
    tinted between its card grey and muted text. `lines` = [(points, colour)]
    (see `map_lines`), each with a background-coloured casing; start = ring
    in its colour, end = light dot."""
    from PIL import ImageDraw, ImageFont  # lazy: Pillow
    from staticmap import CircleMarker, Line  # lazy

    m = dark_map(*map_size([pts for pts, _ in lines]), 60)
    lines = [([(lon, lat) for lat, lon in pts], c) for pts, c in lines]
    for ll, color in lines:
        m.add_line(Line(ll, DARK_BG, 11))
        m.add_line(Line(ll, color, 6))
    for ll, color in lines:  # markers above every line
        m.add_marker(CircleMarker(ll[0], color, 18))
        m.add_marker(CircleMarker(ll[0], DARK_CARD, 9))
        m.add_marker(CircleMarker(ll[-1], DARK_BG, 20))
        m.add_marker(CircleMarker(ll[-1], DARK_FG, 13))
    img = m.render().convert("RGB")
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.load_default(size=13)
    except TypeError:  # Pillow < 10.1
        font = ImageFont.load_default()
    note = "(c) contributeurs OpenStreetMap"
    x0, y0, x1, y1 = draw.textbbox((0, 0), note, font=font)
    draw.text((img.width - (x1 - x0) - 8, img.height - (y1 - y0) - 8), note, font=font, fill="#6b7076")
    # JPEG: a city map was 1.1 MB as PNG, 410 KB as JPEG (Oct 12).
    img.save(path, "JPEG", quality=85, optimize=True)


PASS_W, PASS_MAP_H, PASS_TICKET_H = 1000, 420, 350
MONTHS_SHORT = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]


def _font(path, size, weight="Regular"):
    from PIL import ImageFont  # lazy: Pillow

    try:
        font = ImageFont.truetype(path, size)
        try:
            font.set_variation_by_name(weight)
        except (OSError, ValueError):  # not a variable font
            pass
        return font
    except (OSError, ValueError, AttributeError):
        try:
            return ImageFont.load_default(size=size)
        except TypeError:  # Pillow < 10.1
            return ImageFont.load_default()


def flight_map(f):
    """The great-circle arc on the dark map, PASS_W x PASS_MAP_H."""
    from staticmap import CircleMarker, Line  # lazy

    m = dark_map(PASS_W, PASS_MAP_H, 40)
    arc = [(lon, lat) for lat, lon in fl.great_circle(f)]
    m.add_line(Line(arc, DARK_BG, 10))
    m.add_line(Line(arc, "#ffc828", 5))
    for ll in (arc[0], arc[-1]):
        m.add_marker(CircleMarker(ll, DARK_BG, 22))
        m.add_marker(CircleMarker(ll, DARK_FG, 13))
    return m.render().convert("RGB")


def _plane(draw, cx, cy, s, fill):
    """A plane silhouette pointing right, `s` px nose to tail."""
    half = [(1.0, 0), (0.62, -0.07), (0.12, -0.55), (-0.02, -0.55), (0.25, -0.07),
            (-0.42, -0.07), (-0.58, -0.28), (-0.68, -0.28), (-0.6, 0)]
    pts = half + [(x, -y) for x, y in reversed(half[1:-1])]
    draw.polygon([(cx + x * s / 2, cy + y * s / 2) for x, y in pts], fill=fill)


def boarding_pass(f, font_path="", map_fn=flight_map):
    """One flight as a card: its map over a boarding-pass stub."""
    from PIL import Image, ImageDraw  # lazy: Pillow

    card = Image.new("RGB", (PASS_W, PASS_MAP_H + PASS_TICKET_H), DARK_CARD)
    card.paste(map_fn(f), (0, 0))
    d = ImageDraw.Draw(card)
    t, pad = PASS_MAP_H, 50
    for x in range(30, PASS_W - 30, 22):  # perforation, notched at both ends
        d.line((x, t, x + 11, t), fill=DARK_BG, width=3)
    for x in (0, PASS_W):
        d.ellipse((x - 20, t - 20, x + 20, t + 20), fill=DARK_BG)

    def text(xy, s, font, fill, anchor="la"):
        d.text(xy, s, font=font, fill=fill, anchor=anchor)
        return d.textbbox(xy, s, font=font, anchor=anchor)

    small, big = _font(font_path, 18, "SemiBold"), _font(font_path, 96, "Bold")
    when = fl.local(f.dep, f.frm.tz)
    y, m, dd = map(int, f.date.split("-"))
    text((pad, t + 30), "CARTE D'EMBARQUEMENT", small, DARK_MUTED_FG)
    text((PASS_W - pad, t + 30), f"{dd} {MONTHS_SHORT[m - 1]} {y}".upper(), small, DARK_MUTED_FG, "ra")
    left = text((pad, t + 62), f.frm.iata, big, DARK_FG)
    right = text((PASS_W - pad, t + 62), f.to.iata, big, DARK_FG, "ra")
    mid_y = (left[1] + left[3]) / 2
    for x in range(left[2] + 30, right[0] - 30, 16):
        if abs(x - (left[2] + right[0]) / 2) > 34:
            d.line((x, mid_y, x + 7, mid_y), fill=DARK_MUTED_FG, width=3)
    _plane(d, (left[2] + right[0]) / 2, mid_y, 52, "#ffc828")
    city, hour = _font(font_path, 28), _font(font_path, 34, "SemiBold")
    text((pad, t + 178), f.frm.city, city, DARK_MUTED_FG)
    text((PASS_W - pad, t + 178), f.to.city, city, DARK_MUTED_FG, "ra")
    arr = fl.local(f.arr, f.to.tz)
    if when:
        text((pad, t + 214), f"{when:%H:%M}", hour, DARK_FG)
    if arr:
        text((PASS_W - pad, t + 214), f"{arr:%H:%M}", hour, DARK_FG, "ra")
    fields = [(k, v) for k, v in (("VOL", f.number), ("COMPAGNIE", f.airline), ("SIÈGE", f.seat),
                                  ("DURÉE", fl._hm(f.duration) if f.duration else ""),
                                  ("DISTANCE", f"{fl._int_fr(fl.km(f))} km"), ("APPAREIL", f.aircraft)) if v][:5]
    label, value = _font(font_path, 16, "SemiBold"), _font(font_path, 26, "SemiBold")
    widths = [max(d.textlength(k, font=label), d.textlength(v, font=value)) for k, v in fields]
    gap = (PASS_W - 2 * pad - sum(widths)) / max(len(fields) - 1, 1)
    x = pad
    for (k, v), w in zip(fields, widths):
        text((x, t + 270), k, label, DARK_MUTED_FG)
        text((x, t + 292), v, value, DARK_FG)
        x += w + gap
    return card


def render_boarding_passes(flights, path, font_path="", map_fn=flight_map):
    """The day's flights as stacked boarding-pass cards. JPEG."""
    from PIL import Image  # lazy: Pillow

    cards = [boarding_pass(f, font_path, map_fn) for f in flights]
    sheet = Image.new("RGB", (PASS_W, sum(c.height for c in cards) + 12 * (len(cards) - 1)), DARK_BG)
    y = 0
    for c in cards:
        sheet.paste(c, (0, y))
        y += c.height + 12
    sheet.save(path, "JPEG", quality=88, optimize=True)


class Immich:
    def __init__(self, url, key, opener=None, admin_key=""):
        # `key` (Dawarich's) reads assets; memories and jobs need `admin_key`.
        self.url, self.key, self.opener, self.admin_key = url, key, opener, admin_key

    def day(self, day):
        """The day's timeline images, oldest first."""
        return self.between(*day_bounds(day))

    def create_memories(self):
        """Queue Immich's memory generation (today ± 3 days). Its 03:00 cron
        misses while the socket-activated server sleeps: none after Oct 14 2026."""
        req = urllib.request.Request(
            f"{self.url}/api/jobs", method="POST", data=json.dumps({"name": "memory-create"}).encode(),
            headers={"x-api-key": self.admin_key, "Content-Type": "application/json"})
        with (self.opener or urllib.request.urlopen)(req, timeout=180):
            pass

    def memories(self, day):
        """[(year, images, memory id)] of Immich's "on this day" memories for
        `day`, newest year first; screenshots dropped."""
        req = urllib.request.Request(f"{self.url}/api/memories?for={day.isoformat()}",
                                     headers={"x-api-key": self.admin_key})
        out = []
        for m in http_json(req, timeout=180, opener=self.opener):
            year = (m.get("data") or {}).get("year")
            shots = [a for a in m.get("assets") or [] if not _screenshot(a)]
            if m.get("type") == "on_this_day" and year and shots and not m.get("isTrashed"):
                out.append((int(year), shots, m["id"]))
        return sorted(out, key=lambda x: -x[0])

    def city(self, asset_id):
        """The asset's EXIF city: the memories API sends assets without EXIF."""
        req = urllib.request.Request(f"{self.url}/api/assets/{asset_id}", headers={"x-api-key": self.key})
        try:
            return (http_json(req, timeout=60, opener=self.opener).get("exifInfo") or {}).get("city") or ""
        except (OSError, ValueError):
            return ""

    def memory_link(self, memory_id):
        return f"{self.url}/memories/{memory_id}"

    def between(self, lo, hi):
        iso = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        req = urllib.request.Request(
            f"{self.url}/api/search/metadata", method="POST",
            data=json.dumps({"takenAfter": iso(lo), "takenBefore": iso(hi - 1),
                             "type": "IMAGE", "visibility": "timeline",
                             "withExif": True, "size": 250}).encode(),
            headers={"x-api-key": self.key, "Content-Type": "application/json"})
        items = http_json(req, timeout=180, opener=self.opener).get("assets", {}).get("items", [])
        items = [a for a in items if a.get("type") == "IMAGE" and not a.get("isTrashed")
                 and a.get("visibility", "timeline") == "timeline"]
        return sorted(items, key=lambda a: a.get("fileCreatedAt", ""))

    def preview(self, asset_id):
        req = urllib.request.Request(
            f"{self.url}/api/assets/{asset_id}/thumbnail?size=preview",
            headers={"x-api-key": self.key})
        with (self.opener or urllib.request.urlopen)(req, timeout=60) as resp:
            return resp.read()

    def link(self, asset_id):
        return f"{self.url}/photos/{asset_id}"

    def search_link(self, lo, hi):
        """Immich's search page over [lo, hi) (epoch s): its `query` parameter
        is the search body as JSON (web 3.3)."""
        iso = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        q = json.dumps({"takenAfter": iso(lo), "takenBefore": iso(hi - 1)}, separators=(",", ":"))
        return f"{self.url}/search?query={urllib.parse.quote(q)}"


def fetch_image(url, opener=None):
    req = urllib.request.Request(url, headers={"User-Agent": "nicos-journal/1.0"})
    with (opener or urllib.request.urlopen)(req, timeout=60) as resp:
        return resp.read()


def _screenshot(asset):
    """A PNG with no camera: a phone screenshot (Oct 12 2021 was one)."""
    return (asset.get("originalFileName", "").lower().endswith(".png")
            and not (asset.get("exifInfo") or {}).get("make"))


def memory_lines(day, memories, link, city=None):
    """`- [Il y a 4 ans · 2022](url) · Bordeaux · 6 photos`, newest year first;
    `link(memory id)` opens the memory in Immich, `city(asset id)` names a
    place when the assets carry no EXIF."""
    lines = []
    for y, shots, mid in memories:
        ago = day.year - y
        cities = Counter(c for c in ((a.get("exifInfo") or {}).get("city") for a in shots) if c)
        if not cities and city:
            cities = Counter(c for c in [city(shots[len(shots) // 2]["id"])] if c)
        bits = [f"[Il y a {ago} an{'s' if ago > 1 else ''} · {y}]({link(mid)})"]
        if cities:
            bits.append(cities.most_common(1)[0][0])
        bits.append(f"{len(shots)} photo{'s' if len(shots) > 1 else ''}")
        lines.append(f"- {' · '.join(bits)}")
    return lines


def _taken(asset):
    return datetime.fromisoformat(asset["fileCreatedAt"].replace("Z", "+00:00")).timestamp()


BURST_GAP_S = 120


def groups(assets, n):
    """The day's photos (oldest first) in at most `n` moments: bursts (shots
    < BURST_GAP_S apart) first, then cut only at the n-1 longest pauses, so
    an afternoon walk stays one moment. Apr 30: 30 bursts in Rome, 9 lines."""
    if not assets or n <= 0:
        return []
    gaps = {i: _taken(b) - _taken(a) for i, (a, b) in enumerate(zip(assets, assets[1:]), 1)}
    cuts = []
    for _ in range(n - 1):
        def score(i):  # longest pause; on a tie, the cut leaving the most even halves
            lo = max([0, *(c for c in cuts if c < i)])
            hi = min([len(assets), *(c for c in cuts if c > i)])
            return gaps[i], min(i - lo, hi - i)
        free = [i for i, g in gaps.items() if g >= BURST_GAP_S and i not in cuts]
        if not free:
            break
        cuts.append(max(free, key=score))
    cuts.sort()
    return [assets[a:b] for a, b in zip([0, *cuts], [*cuts, len(assets)])]


def moments(assets, n=9):
    """One representative per group (see `groups`) — its favourite, else its
    middle shot — carrying `burst` = how many shots it stands for and `until`
    = its last shot's fileCreatedAt. Oldest first."""
    return [{**next((a for a in g if a.get("isFavorite")), g[len(g) // 2]),
             "burst": len(g), "since": g[0]["fileCreatedAt"], "until": g[-1]["fileCreatedAt"]}
            for g in groups(assets, n)]


def pick_photos(assets, n):
    """The collage: one tile per moment, the same moments as the text."""
    return moments(assets, n)


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

    def upload(self, files):
        """`files` = [(filename, mime, bytes, media_metadata or None)] ->
        attachment names, same order."""
        names = []
        for name, mime, data, meta in files:
            body = {"filename": name, "type": mime, "content": base64.b64encode(data).decode()}
            if meta:
                body["mediaMetadata"] = meta
            names.append(self.call("POST", "/attachments", body)["name"])
        return names

    def create(self, text, atts, when, location=None):
        body = {"content": text, "visibility": "PRIVATE",
                "attachments": [{"name": a} for a in atts]}
        if location:
            body["location"] = location
        memo = self.call("POST", "/memos", body)
        # CreateMemo ignores createTime; only an update with this mask sets it.
        self.call("PATCH", f"/{memo['name']}?updateMask=create_time", {"createTime": when})
        return memo["name"]

    def update(self, name, old_text, old_atts, text, atts, when, location=None):
        """Rewrite our part of an existing memo in place, keeping what the user
        added: text around the block we last wrote, and their attachments.
        Returns False if the memo is gone, None if the user rewrote our block
        (text left alone, attachments still refreshed), True otherwise."""
        try:
            memo = self.call("GET", f"/{name}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return False
            raise
        current = memo.get("content", "")
        if old_text is None:  # entries from before this state carried `text`
            new, kept = text, True
        elif old_text in current:
            new, kept = current.replace(old_text, text, 1), True
        else:
            new, kept = current, None
        ours = set(old_atts) if old_atts is not None else {a["name"] for a in memo.get("attachments", [])}
        theirs = [a["name"] for a in memo.get("attachments", []) if a["name"] not in ours]
        # Detached attachments are deleted by Memos itself.
        self.call("PATCH", f"/{name}/attachments",
                  {"name": name, "attachments": [{"name": a} for a in atts + theirs]})
        body, mask = {"name": name, "content": new, "createTime": when}, ["content", "create_time"]
        if location:
            body["location"], mask = location, mask + ["location"]
        self.call("PATCH", f"/{name}?updateMask={','.join(mask)}", body)
        return kept


def media_metadata(data, taken, location=None, camera=None):
    """Memos `mediaMetadata` for one of our images: what its details panel
    shows. `taken` = epoch s, rendered as Europe/Paris wall time + offset —
    from the UTC instant, since a screenshot's Immich local time is UTC.
    `location` = (lat, lon); `camera` = (make, model)."""
    local = datetime.fromtimestamp(taken, TZ)
    off = int(local.utcoffset().total_seconds() // 60)
    photo = {"captureTime": {"localDateTime": local.strftime("%Y-%m-%dT%H:%M:%S"),
                             "utcOffset": f"{'+' if off >= 0 else '-'}{abs(off) // 60:02d}:{abs(off) % 60:02d}"}}
    if location:
        photo["location"] = {"latitude": location[0], "longitude": location[1]}
    if camera and all((c or "").strip() for c in camera):
        photo["cameraMake"], photo["cameraModel"] = (c.strip() for c in camera)
    meta = {"photo": photo}
    try:
        import io

        from PIL import Image  # lazy: Pillow
        meta["width"], meta["height"] = Image.open(io.BytesIO(data)).size
    except Exception:  # size is optional; never lose the upload over it
        pass
    return meta


def photo_gps(asset):
    e = asset.get("exifInfo") or {}
    return (e["latitude"], e["longitude"]) if e.get("latitude") and e.get("longitude") else None


def _utc(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def day_calendar(cfg, run, day, log):
    """(personal agenda lines, work summary or None); empty on any failure."""
    lo, hi = day_bounds(day)
    lo_dt, hi_dt = datetime.fromtimestamp(lo, TZ), datetime.fromtimestamp(hi, TZ)
    blobs = lambda names, since: src.calendar_blobs(run, names, since, hi, cfg.nextcloud_db,
                                                    cfg.runuser, cfg.psql)
    try:
        agenda = src.personal_lines(
            src.expand(blobs(cfg.personal_calendars, lo), lo_dt, hi_dt, TZ), TZ) \
            if cfg.personal_calendars else []
        work = None
        if cfg.work_calendars:
            # 30 days back, to tell the owner apart from the day's few attendees
            wide = src.expand(blobs(cfg.work_calendars, lo - 30 * 86400),
                              lo_dt - timedelta(days=30), hi_dt, TZ)
            today = [e for e in wide if e.end > lo_dt and e.start < hi_dt]
            me = src.owner(wide)
            work = src.work_summary(today, lo_dt, hi_dt, me)
            if work:
                work = (*work, src.meeting_lines(today, lo_dt, hi_dt, me, TZ))
        return agenda, work
    except (OSError, ValueError, ImportError, subprocess.CalledProcessError) as e:
        log(f"{day}: calendar unavailable ({e})")
        return [], None


def day_family(cfg, run, tree, day, log):
    """(birthday lines, genealogy lines); contacts and tree each optional."""
    contacts = []
    if cfg.birthday_calendars:
        lo, hi = day_bounds(day)
        try:
            contacts = fam.contact_birthdays(src.calendar_blobs(
                run, cfg.birthday_calendars, lo, hi, cfg.nextcloud_db, cfg.runuser, cfg.psql), day)
        except (OSError, ValueError, ImportError, subprocess.CalledProcessError) as e:
            log(f"{day}: contact birthdays unavailable ({e})")
    return fam.family_sections(contacts, tree, day, cfg.gramps_url)


def day_flights(cfg, run, day, log):
    """(the day's flights, every flight); both empty on failure."""
    if not cfg.airtrail_db:
        return [], []
    try:
        every = fl.all_flights(run, cfg.airtrail_db, cfg.runuser, cfg.psql)
    except (OSError, ValueError, IndexError, subprocess.CalledProcessError) as e:
        log(f"{day}: flights unavailable ({e})")
        return [], []
    return fl.on_day(every, day, *day_bounds(day)), every


def day_energy(cfg, day, log):
    """(heading suffix, lines) or None: no recorder, or the meter's day not in yet."""
    if not cfg.ha_db:
        return None
    try:
        e = home.energy(cfg.ha_db, *day_bounds(day))
    except (OSError, sqlite3.Error, ValueError) as err:
        log(f"{day}: electricity unavailable ({err})")
        return None
    return home.energy_section(e) if e else None


def day_climbing(cfg, day, log):
    """Arkose sessions started that day; [] if arkose-sync has no store."""
    try:
        return src.climbing_sessions(cfg.arkose_sessions, *day_bounds(day))
    except FileNotFoundError:
        return []
    except (OSError, ValueError, KeyError) as e:
        log(f"{day}: climbing unavailable ({e})")
        return []


def day_notes(cfg, run, state, day, log, now=None):
    """The day's side-project notes: cached in state["_dispatch"], else generated once
    the day is over (an agent call per active repo). Not cached on failure,
    nor in dry run."""
    key = day.isoformat()
    cache = state.get("_dispatch", {})
    if key in cache:
        return cache[key]
    lo, hi = day_bounds(day)
    if not cfg.dispatch_repos or hi > (now or datetime.now(timezone.utc).timestamp()):
        return []
    try:
        notes = src.dispatch_notes(run, cfg.dispatch_repos, lo, hi, cfg.dispatch_user,
                                   cfg.runuser, cfg.git)
    except (OSError, subprocess.CalledProcessError) as e:
        log(f"{key}: project notes unavailable ({e})")
        return []
    if not cfg.dry_run:
        state.setdefault("_dispatch", {})[key] = notes
    return notes


def day_activity(cfg, run, day, log):
    """journal_sources.activity_section of the day, or None (no steps, or FreeReps unreadable)."""
    try:
        totals = src.activity_totals(run, *day_bounds(day), cfg.freereps_db, cfg.runuser, cfg.psql)
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        log(f"{day}: activity unavailable ({e})")
        return None
    return src.activity_section(totals)


STREAK_LOOKBACK_D = 45


def day_games(cfg, run, day, log):
    """journal_sources.game_section of the day, each game with its streak, or
    None (nothing played, or Ryot down)."""
    lo, hi = day_bounds(day)
    try:
        plays = src.game_plays(run, lo - STREAK_LOOKBACK_D * 86400, hi, cfg.ryot_db, cfg.ryot_v1_db,
                               cfg.runuser, cfg.psql)
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        log(f"{day}: games unavailable ({e})")
        return None
    games = src.game_sessions([p for p in plays if p[0] >= lo])
    days = {}
    for t, title, _ in plays:
        days.setdefault(title, set()).add(rec.journal_date(t))
    return src.game_section(games, {t: rec.streak_text(rec.streak(days[t], day)) for t, _ in games}) \
        if games else None


def day_music(cfg, run, day, log):
    """journal_sources.music_section of the day, each artist with its streak,
    or None (no plays, or Ryot down). Artists V11 lacks come from V1."""
    lo, hi = day_bounds(day)
    try:
        listens = src.music_listens(run, lo - STREAK_LOOKBACK_D * 86400, hi, cfg.ryot_db, cfg.runuser, cfg.psql)
        missing = [l.track for l in listens if not l.artists and l.track]
        if missing and cfg.ryot_v1_db:
            v1 = src.music_tracks(run, missing, cfg.ryot_v1_db, cfg.runuser, cfg.psql)
            listens = [dataclasses.replace(l, artists=v1.get(l.track, "")) if not l.artists else l
                       for l in listens]
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        log(f"{day}: music unavailable ({e})")
        return None
    today = [l for l in listens if l.at >= lo]
    if not today:
        return None
    days = {}
    for l in listens:
        if l.artists:
            days.setdefault(l.artists, set()).add(rec.journal_date(l.at))
    return src.music_section(today, streaks={a: rec.streak_text(rec.streak(d, day)) for a, d in days.items()})


def day_screens(cfg, run, day, log):
    """journal_sources.screen_section of the day, or None."""
    try:
        screens = src.screen_events(run, *day_bounds(day), cfg.ryot_db, cfg.runuser, cfg.psql)
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        log(f"{day}: films and series unavailable ({e})")
        return None
    return src.screen_section(screens, TZ) if screens else None


def sure_spends(cfg, opener=None):
    """day -> [Spend] through Sure's API, or None when no account is set."""
    if not (cfg.spend_accounts or cfg.joint_accounts):
        return None
    key = read_secret(cfg.sure_key_file) if cfg.sure_key_file else ""
    return lambda day: spend.day_spends(day, cfg.spend_accounts, cfg.joint_accounts, cfg.sure_url, key, opener)


def day_spend(spend_fn, day, log, today, cfg=None):
    """journal_spend.spend_section of the day, or None (no accounts set, nothing spent, Sure unreadable)."""
    if not spend_fn:
        return None
    try:
        spends = spend_fn(day)
    except (OSError, ValueError, KeyError, TypeError) as e:
        log(f"{day}: spending unavailable ({e})")
        return None
    link = (spend.detail_url(cfg.sure_public_url, day, cfg.spend_accounts + cfg.joint_accounts)
            if cfg and cfg.sure_public_url else "")
    return spend.spend_section(spends, (today - day).days, link)


def _today(now=None):
    return datetime.fromtimestamp(now, TZ).date() if now else datetime.now(TZ).date()


def day_badges(cfg, run, day, ws, climbs, activity, energy, log):
    """{section: record and streak lines}, each source on its own: one
    unreadable history drops only its own lines."""
    lo, hi = day_bounds(day)
    out = {}
    if any(w.name == "Cycling" for w in ws):
        try:
            out["bike"] = rec.ride_badges(rec.ride_history(run, hi, cfg.freereps_db, cfg.runuser, cfg.psql), day)
        except (OSError, ValueError, subprocess.CalledProcessError) as e:
            log(f"{day}: ride history unavailable ({e})")
    if activity:
        try:
            out["activity"] = rec.step_badges(rec.step_history(run, hi, cfg.freereps_db, cfg.runuser, cfg.psql), day)
        except (OSError, ValueError, subprocess.CalledProcessError) as e:
            log(f"{day}: step history unavailable ({e})")
    if climbs:
        try:
            out["climbing"] = rec.climbing_badges(src.climbing_sessions(cfg.arkose_sessions, 0, hi), day)
        except (OSError, ValueError, KeyError) as e:
            log(f"{day}: climbing history unavailable ({e})")
    if energy and cfg.ha_db:
        try:
            out["home"] = rec.energy_badges(rec.energy_history(cfg.ha_db, hi), day)
        except (OSError, sqlite3.Error, ValueError) as e:
            log(f"{day}: electricity history unavailable ({e})")
    return {k: v for k, v in out.items() if v}


def journal_day(cfg, run, memos, state, day, uid, log, render_fn, tmpdir, immich=None,
                collage_fn=render_collage, weather_fn=None, fetch_fn=fetch_image, now=None, tree=None,
                pass_fn=render_boarding_passes, summary_fn=None, spend_fn=None):
    """Create/refresh one day's memo. Returns the memo name, or None if nothing happened."""
    key = day.isoformat()
    ws = workouts(cfg, run, day)
    day_photos = []
    if immich:
        try:
            day_photos = immich.day(day)
        except (OSError, ValueError) as e:  # URLError/HTTPError are OSErrors
            log(f"{key}: Immich unavailable, no photos this run ({e})")
    agenda, work = day_calendar(cfg, run, day, log)
    day_trips = trips(cfg, run, uid, day)
    climbs = day_climbing(cfg, day, log)
    notes = day_notes(cfg, run, state, day, log, now)
    flights, every_flight = day_flights(cfg, run, day, log)
    if not (ws or day_trips or climbs or day_photos or agenda or work or notes or flights):
        return None
    photos = pick_photos(day_photos, cfg.photos_max)
    memories = []
    if immich and immich.admin_key:
        try:
            memories = immich.memories(day)
        except (OSError, ValueError) as e:
            log(f"{key}: Immich unavailable, no memories this run ({e})")
    birthdays, genealogy = day_family(cfg, run, tree, day, log)
    energy = day_energy(cfg, day, log)
    music = day_music(cfg, run, day, log)
    games = day_games(cfg, run, day, log)
    activity = day_activity(cfg, run, day, log)
    screens = day_screens(cfg, run, day, log)
    spending = day_spend(spend_fn, day, log, _today(now), cfg)
    badges = day_badges(cfg, run, day, ws, climbs, activity, energy, log)
    tracks = [track(cfg, run, uid, w) for w in ws]
    lines = map_lines(ws, tracks, day_trips)
    extra = other_trips(ws, day_trips)
    weather = None
    if weather_fn:
        first = next((pts[0] for pts, _ in lines), None) or next(
            (g for g in map(photo_gps, day_photos) if g), None) or cfg.home
        try:
            weather = weather_fn(day, *first)
        except (OSError, ValueError, KeyError, IndexError) as e:
            log(f"{key}: weather unavailable ({e})")
    sig = signature(ws, [len(t) for t in tracks], [p["id"] for p in day_photos],
                    [agenda, work, weather, [[t.id, len(t.path), t.mode] for t in day_trips], music, games, activity, notes,
                     [[c["_id"], c.get("tops"), c.get("tried"), c.get("retops")] for c in climbs],
                     len(src.climbing_pictures(climbs)), [[y, [a["id"] for a in m]] for y, m, _ in memories],
                     birthdays, genealogy, [f.id for f in flights], energy, screens, badges, spending])
    if state.get(key, {}).get("sig") == sig:
        log(f"{key}: unchanged")
        return state[key]["memo"]
    legs = [(place(cfg, run, uid, *t[0]), place(cfg, run, uid, *t[-1])) if t else None
            for t in tracks]
    trip_legs = [(place(cfg, run, uid, *t.path[0]), place(cfg, run, uid, *t.path[-1]))
                 for t in extra]
    link =immich.link(day_photos[0]["id"]) if day_photos else ""
    shots = []
    for m in moments(day_photos, cfg.photos_max):
        gps = photo_gps(m)
        lo, hi = _taken({"fileCreatedAt": m["since"]}), _taken({"fileCreatedAt": m["until"]})
        url = immich.link(m["id"]) if m["burst"] == 1 else immich.search_link(lo, hi + 1)
        shots.append((moment_time(m), url, place(cfg, run, uid, *gps).label if gps else "", m["burst"]))
    text = content(key, ws, legs, cfg.web_url, len(day_photos), link, shots,
                   weather, agenda, work, extra, trip_legs, music,
                   src.climbing_section(climbs) if climbs else None, games, activity, notes,
                   memory_lines(day, memories, immich.memory_link, immich.city) if memories else (), birthdays, genealogy,
                   fl.flight_section(flights, every_flight) if flights else None, cfg.airtrail_url, energy,
                   screens, badges, spending)
    summary, src_hash = None, summ.source_hash(text)
    if summary_fn:
        prev = state.get(key, {})
        summary = prev.get("summary") if prev.get("summary_src") == src_hash else summary_fn(text)
        if summary:
            text = f"*{summary}*\n\n{text}"
        else:  # gate down: a later run retries, as the signature won't match
            log(f"{key}: no summary this run")
            sig = f"{sig}|no-summary"
    if cfg.dry_run:
        log(f"[dry-run] {key}: {len(ws)} workouts, {len(day_trips)} trips, "
            f"{len(photos)}/{len(day_photos)} photos\n{text}")
        return None

    moved = max([w.end for w in ws] + [t.end for t in day_trips], default=None)
    files = []
    if lines:
        png_path = f"{tmpdir}/day-{key}.jpg"
        render_fn(lines, png_path)
        with open(png_path, "rb") as f:
            data = f.read()
        files.append((f"map-{key}.jpg", "image/jpeg", data,
                      media_metadata(data, moved, location=lines[-1][0][-1])))
    if photos:
        collage_path = f"{tmpdir}/photos-{key}.jpg"
        collage_fn([immich.preview(p["id"]) for p in photos],
                   [tile_label(p) for p in photos], collage_path)
        with open(collage_path, "rb") as f:
            data = f.read()
        gps = next((g for g in map(photo_gps, reversed(photos)) if g), None)
        cams = {((p.get("exifInfo") or {}).get("make"), (p.get("exifInfo") or {}).get("model"))
                for p in photos if (p.get("exifInfo") or {}).get("make")}
        files.append((f"photos-{key}.jpg", "image/jpeg", data,
                      media_metadata(data, _taken(photos[-1]), location=gps,
                                     camera=next(iter(cams)) if len(cams) == 1 else None)))

    tiles = []
    for url, colour, status in src.climbing_pictures(climbs)[:CLIMB_TILES_MAX]:
        try:
            tiles.append((fetch_fn(url), (colour, 1, status)))
        except OSError as e:  # one missing picture must not drop the mosaic
            log(f"{key}: boulder picture unavailable ({e})")
    if tiles:
        climb_path = f"{tmpdir}/climbing-{key}.jpg"
        collage_fn([t[0] for t in tiles], [t[1] for t in tiles], climb_path)
        with open(climb_path, "rb") as f:
            data = f.read()
        start = datetime.fromisoformat(climbs[0]["startDate"]).timestamp()
        files.append((f"climbing-{key}.jpg", "image/jpeg", data, media_metadata(data, start)))
    if flights:
        pass_path = f"{tmpdir}/flight-{key}.jpg"
        try:
            pass_fn(flights, pass_path)
            with open(pass_path, "rb") as f:
                data = f.read()
            dest, took_off = flights[-1].to, flights[0].dep
            files.append((f"flight-{key}.jpg", "image/jpeg", data,
                          media_metadata(data, took_off.timestamp() if took_off else day_bounds(day)[0] + 8 * 3600,
                                         location=(dest.lat, dest.lon))))
        except OSError as e:  # map tiles down: the text section still stands
            log(f"{key}: boarding pass unavailable ({e})")
    last = next((t for t in reversed(tracks) if t), None)
    if last:
        lat, lon = last[-1]
        location = {"placeholder": legs[tracks.index(last)][1].label, "latitude": lat, "longitude": lon}
    elif extra:
        lat, lon = extra[-1].path[-1]
        location = {"placeholder": trip_legs[-1][1].label, "latitude": lat, "longitude": lon}
    elif flights:
        dest = flights[-1].to
        location = {"placeholder": dest.city, "latitude": dest.lat, "longitude": dest.lon}
    else:
        gps = [p["exifInfo"] for p in reversed(day_photos)
               if (p.get("exifInfo") or {}).get("latitude")]
        location = gps and {"placeholder": gps[0].get("city") or "",
                            "latitude": gps[0]["latitude"], "longitude": gps[0]["longitude"]}
    if moved:
        when = _utc(moved)
    elif day_photos:
        when = day_photos[-1]["fileCreatedAt"].replace("+00:00", "Z")
    elif climbs:
        when = climbs[-1]["startDate"]
    elif flights and (flights[-1].arr or flights[-1].dep):
        when = _utc((flights[-1].arr or flights[-1].dep).timestamp())
    else:  # calendar-only day: noon
        when = _utc(day_bounds(day)[0] + 8 * 3600)

    atts = memos.upload(files)
    prev, name = state.get(key), None
    if prev:
        kept = memos.update(prev["memo"], prev.get("text"), prev.get("atts"),
                            text, atts, when, location or None)
        if kept is None:
            log(f"{key}: {prev['memo']} was edited by hand; text kept, attachments refreshed")
        if kept is not False:
            name = prev["memo"]
    if name is None:
        name = memos.create(text, atts, when, location or None)
    state[key] = {"memo": name, "sig": sig, "text": text, "atts": atts, "spend": spending,
                  **({"summary": summary, "summary_src": src_hash} if summary else {})}
    log(f"{key}: {name} ({len(ws)} workouts, {len(day_trips)} trips, {len(photos)} photos)")
    return name


def catchup_days(cfg, spend_fn, state, today=None, log=print):
    """Older days whose spending moved since their memo was written: banks
    deliver up to ~3 weeks late. Only days with a memo, and not under JOURNAL_DAY."""
    if cfg.day or not spend_fn:
        return []
    today = today or _today()
    days = []
    for n in range(cfg.days + 1, spend.CATCHUP_DAYS + 1):
        day = today - timedelta(days=n)
        prev = state.get(day.isoformat())
        if not prev:
            continue
        now = day_spend(spend_fn, day, log, today, cfg)
        if json.loads(json.dumps(now)) != prev.get("spend"):  # state round-trips tuples as lists
            days.append(day)
    return sorted(days)


def main(env=None, run=None, opener=None, render_fn=None, today=None, sleep=time.sleep):
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
        try:
            immich = Immich(*immich_settings(cfg, run, uid), opener,
                            read_secret(cfg.immich_admin_key_file) if cfg.immich_admin_key_file else "")
            if immich.admin_key:
                try:
                    immich.create_memories()
                    sleep(MEMORY_JOB_WAIT_S)
                except OSError as e:
                    log(f"memory generation not queued ({e})")
        except RuntimeError as e:
            log(f"no photos: {e}")
            immich = None
        tree = None
        if cfg.gramps_db:
            try:
                tree = fam.Tree.load(cfg.gramps_db, cfg.gramps_home)
            except (OSError, ValueError, KeyError, sqlite3.Error) as e:
                log(f"no family tree: {e}")
        spend_fn = sure_spends(cfg, opener)
        with tempfile.TemporaryDirectory() as tmp:
            for day in target_days(cfg, today) + catchup_days(cfg, spend_fn, state, today, log):
                journal_day(cfg, run, memos, state, day, uid, log,
                            render_fn or render, tmp, immich,
                            collage_fn=functools.partial(render_collage, font_path=cfg.font),
                            pass_fn=functools.partial(render_boarding_passes, font_path=cfg.font),
                            summary_fn=(lambda t: summ.summarize(cfg.gate_url, cfg.summary_model, t, opener))
                            if cfg.gate_url else None,
                            weather_fn=lambda d, lat, lon: src.weather_line(d, lat, lon, opener),
                            tree=tree, spend_fn=spend_fn)
                if cfg.state_path and not cfg.dry_run:
                    save_json(cfg.state_path, state)
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as e:
        log(f"FATAL: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
