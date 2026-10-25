#!/usr/bin/env python3
"""
journal-daily: one Memos journal entry per day with workouts or photos.

Workouts: stats from FreeReps (Apple Health); the map is drawn from Dawarich's
points inside each workout's window, so it shows what freereps-to-dawarich put
there. Start/end labels are the nearest place the user named in Dawarich
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

Env: JOURNAL_{DAY,DAYS,STATE,DRY_RUN,PLACE_RADIUS_M,PHOTOS_MAX},
MEMOS_{URL,TOKEN_FILE}, DAWARICH_WEB_URL, PSQL_BIN, RUNUSER_BIN.
"""

import base64
import hashlib
import json
import math
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
from .immich_dawarich import immich_settings

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
    photos_max: int = 9
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


def signature(ws, point_counts, photo_ids=()):
    raw = json.dumps([[[w.id, n] for w, n in zip(ws, point_counts)], list(photo_ids)])
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
    return KINDS.get(name, ("🏅", name, "workout", name.lower().replace(" ", "")))


def _hm(minutes):
    h, m = divmod(round(minutes), 60)
    return f"{h} h {m:02d}" if h else f"{m} min"


def tile_label(asset):
    """(HH:MM, shots): drawn `14:29`, or `14:29 (8 📸)` for a burst of 8."""
    return photo_time(asset), asset.get("burst", 1)


def photo_time(asset):
    """Local HH:MM a photo was taken."""
    t = datetime.fromisoformat(asset["fileCreatedAt"].replace("Z", "+00:00"))
    return f"{t.astimezone(TZ):%H:%M}"


def workout_section(ws, legs, web_url, day):
    """(markdown lines, tags) of the workouts section."""
    kinds = {kind(w.name) for w in ws}
    emoji, title, noun, _ = next(iter(kinds)) if len(kinds) == 1 else ("🏅", "Workouts", "workout", "")
    total_km = sum(w.km for w in ws)
    head = [f"{len(ws)} {noun}{'s' if len(ws) > 1 else ''}"]
    if total_km:
        head.append(f"{total_km:.1f} km")
    head.append(_hm(sum(w.minutes for w in ws)))
    if sum(w.kcal for w in ws):
        head.append(f"{sum(w.kcal for w in ws):.0f} kcal")
    lines, tags = [f"### {emoji} {title} — {' · '.join(head)}", ""], []
    for w, leg in zip(ws, legs):
        e, _, _, tag = kind(w.name)
        at = f"**{datetime.fromtimestamp(w.start, TZ):%H:%M}**"
        if len(kinds) > 1:
            at = f"{e} {at}"
        if not leg:
            bits = [w.name]
        elif leg[0].label == leg[1].label:
            bits = [f"around {leg[0].label}"]
        else:
            bits = [f"{leg[0].label} → {leg[1].label}"]
        if w.km:
            bits.append(f"{w.km:.1f} km")
        bits.append(_hm(w.minutes))
        if w.km and w.minutes:
            bits.append(f"{w.km / (w.minutes / 60):.1f} km/h")
        lines.append(f"- {at} {' · '.join(bits)}")
        if tag not in tags:
            tags.append(tag)
        if leg and {leg[0].tag, leg[1].tag} == {"Home", "Work"} and "commute" not in tags:
            tags.append("commute")
    lines += ["", f"[Open the day in Dawarich]({web_url}/map/v2?panel=timeline&date={day})"]
    return lines, tags


def content(day, ws, legs, web_url, photos=0, photos_url=""):
    """Memo markdown, one `###` section per source. `legs` = [(from_label,
    to_label) or None] per workout; `photos` = the day's timeline photo count,
    `photos_url` = the first of the day in Immich."""
    sections, tags = [], []
    if ws:
        lines, tags = workout_section(ws, legs, web_url, day)
        sections.append(lines)
    if photos:
        sections.append([f"### 📷 Photos — {photos}", "", f"[Open the day in Immich]({photos_url})"]
                        if photos_url else [f"### 📷 Photos — {photos}"])
        tags.append("photos")
    body = "\n\n".join("\n".join(lines) for lines in sections)
    return f"{body}\n\n{' '.join(f'#{t}' for t in tags)}\n"


def collage_grid(n):
    """(columns, rows) for n tiles: one row up to 3, then 2x2, 3x2, 3x3."""
    if n <= 3:
        return n, 1
    if n == 4:
        return 2, 2
    return 3, (n + 2) // 3


def _camera(draw, x, y, h, fill="white", lens=(30, 30, 30, 255)):
    """A camera glyph `h` px tall at (x, y); returns its width. Drawn, not
    typed: Pillow's default font has no emoji (📸 and × drew boxes)."""
    w = round(h * 1.35)
    draw.rounded_rectangle((x + w * 0.3, y + h * 0.08, x + w * 0.62, y + h * 0.35),
                           radius=max(1, h // 12), fill=fill)
    draw.rounded_rectangle((x, y + h * 0.25, x + w, y + h), radius=max(1, h // 6), fill=fill)
    cx, cy, r = x + w * 0.5, y + h * 0.62, h * 0.26
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=lens)
    return w


def render_collage(images, labels, path, tile=480, gap=6):
    """Square-cropped grid of `images` (bytes); each tile's (HH:MM, shots)
    label sits in its bottom-left corner — `14:29 (8 📸)` for a burst. JPEG."""
    import io

    from PIL import Image, ImageDraw, ImageFont, ImageOps  # lazy: Pillow

    cols, rows = collage_grid(len(images))
    sheet = Image.new("RGB", (cols * tile + (cols - 1) * gap, rows * tile + (rows - 1) * gap), "white")
    try:
        font = ImageFont.load_default(size=tile // 14)
    except TypeError:  # Pillow < 10.1 has no sized default font
        font = ImageFont.load_default()
    for i, (raw, (hm, shots)) in enumerate(zip(images, labels)):
        img = ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert("RGB")
        img = ImageOps.fit(img, (tile, tile), Image.LANCZOS)
        draw = ImageDraw.Draw(img, "RGBA")
        parts = [hm] if shots <= 1 else [f"{hm}  ({shots} ", "📷", ")"]
        _, top, _, bottom = draw.textbbox((0, 0), "0123456789:()", font=font)
        th, pad = bottom - top, tile // 40
        icon_h = round(th * 0.85)
        width = sum(round(icon_h * 1.35) + pad // 2 if p == "📷" else draw.textlength(p, font=font)
                    for p in parts)
        box = (pad, tile - pad - th - 2 * pad, pad + width + 2 * pad, tile - pad)
        draw.rounded_rectangle(box, radius=pad, fill=(0, 0, 0, 150))
        x = box[0] + pad
        for part in parts:
            if part == "📷":
                x += _camera(draw, x + pad // 4, box[1] + pad + (th - icon_h), icon_h) + pad // 2
            else:
                draw.text((x, box[1] + pad - top), part, font=font, fill="white")
                x += draw.textlength(part, font=font)
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


def render(tracks, path):
    """Map JPEG in Memos' dark palette: OSM tiles greyscaled, inverted and
    tinted between its card grey and muted text, one colour per workout with
    a background-coloured casing; start = ring in its colour, end = light dot."""
    from PIL import Image, ImageDraw, ImageFont, ImageOps  # lazy: Pillow
    from staticmap import CircleMarker, Line, StaticMap  # lazy

    class Dark(StaticMap):
        def _draw_base_layer(self, image):
            super()._draw_base_layer(image)
            inverted = ImageOps.invert(ImageOps.grayscale(image))
            image.paste(ImageOps.colorize(inverted, black=DARK_CARD, white=DARK_MUTED_FG,
                                          blackpoint=0, whitepoint=255, midpoint=150))

    drawn = [t for t in tracks if len(t) >= 2]
    m = Dark(*map_size(drawn), padding_x=60, padding_y=60,
             url_template="https://tile.openstreetmap.org/{z}/{x}/{y}.png",
             headers={"User-Agent": "nicos-journal/1.0 (self-hosted, personal)"})
    lines = [([(lon, lat) for lat, lon in t], c) for t, c in zip(tracks, COLORS * 4) if len(t) >= 2]
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
    note = "(c) OpenStreetMap contributors"
    x0, y0, x1, y1 = draw.textbbox((0, 0), note, font=font)
    draw.text((img.width - (x1 - x0) - 8, img.height - (y1 - y0) - 8), note, font=font, fill="#6b7076")
    # JPEG: a city map was 1.1 MB as PNG, 410 KB as JPEG (Oct 12).
    img.save(path, "JPEG", quality=85, optimize=True)


class Immich:
    def __init__(self, url, key, opener=None):
        self.url, self.key, self.opener = url, key, opener

    def day(self, day):
        """The day's timeline images, oldest first."""
        lo, hi = day_bounds(day)
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


def _taken(asset):
    return datetime.fromisoformat(asset["fileCreatedAt"].replace("Z", "+00:00")).timestamp()


BURST_GAP_S = 120


def pick_photos(assets, n):
    """One photo per burst (shots < BURST_GAP_S apart; its favourite, else its
    middle shot), then favourites first and the rest nearest evenly spaced
    instants of the day. Oct 12: a 7-shot burst at 14:29 had filled 7 of 9
    tiles. Each pick carries `burst` = how many shots it stands for. Oldest
    first."""
    bursts = []
    for a in assets:
        if bursts and _taken(a) - _taken(bursts[-1][-1]) < BURST_GAP_S:
            bursts[-1].append(a)
        else:
            bursts.append([a])
    reps = [{**next((a for a in b if a.get("isFavorite")), b[len(b) // 2]), "burst": len(b)}
            for b in bursts]
    picked = [a for a in reps if a.get("isFavorite")][:max(n, 0)]
    rest = [a for a in reps if not a.get("isFavorite")]
    k = min(n - len(picked), len(rest))
    if k > 0:
        lo, hi = _taken(rest[0]), _taken(rest[-1])
        for i in range(k):
            t = lo + (hi - lo) * (i + 0.5) / k
            free = [a for a in rest if a not in picked]
            picked.append(min(free, key=lambda a: abs(_taken(a) - t)))
    return sorted(picked, key=lambda a: a.get("fileCreatedAt", ""))


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
        """`files` = [(filename, mime, bytes)] -> attachment names, same order."""
        return [self.call("POST", "/attachments", {
            "filename": name, "type": mime,
            "content": base64.b64encode(data).decode()})["name"]
            for name, mime, data in files]

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


def _utc(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def journal_day(cfg, run, memos, state, day, uid, log, render_fn, tmpdir, immich=None,
                collage_fn=render_collage):
    """Create/refresh one day's memo. Returns the memo name, or None if nothing happened."""
    key = day.isoformat()
    ws = workouts(cfg, run, day)
    day_photos = []
    if immich:
        try:
            day_photos = immich.day(day)
        except (OSError, ValueError) as e:  # URLError/HTTPError are OSErrors
            log(f"{key}: Immich unavailable, no photos this run ({e})")
    if not ws and not day_photos:
        return None
    photos = pick_photos(day_photos, cfg.photos_max)
    tracks = [track(cfg, run, uid, w) for w in ws]
    sig = signature(ws, [len(t) for t in tracks], [p["id"] for p in photos])
    if state.get(key, {}).get("sig") == sig:
        log(f"{key}: unchanged")
        return state[key]["memo"]
    legs = [(place(cfg, run, uid, *t[0]), place(cfg, run, uid, *t[-1])) if t else None
            for t in tracks]
    link = immich.link(day_photos[0]["id"]) if day_photos else ""
    text = content(key, ws, legs, cfg.web_url, len(day_photos), link)
    if cfg.dry_run:
        log(f"[dry-run] {key}: {len(ws)} workouts, {len(photos)}/{len(day_photos)} photos\n{text}")
        return None

    files = []
    if any(len(t) >= 2 for t in tracks):
        png_path = f"{tmpdir}/day-{key}.jpg"
        render_fn(tracks, png_path)
        with open(png_path, "rb") as f:
            files.append((f"map-{key}.jpg", "image/jpeg", f.read()))
    if photos:
        collage_path = f"{tmpdir}/photos-{key}.jpg"
        collage_fn([immich.preview(p["id"]) for p in photos],
                   [tile_label(p) for p in photos], collage_path)
        with open(collage_path, "rb") as f:
            files.append((f"photos-{key}.jpg", "image/jpeg", f.read()))

    last = next((t for t in reversed(tracks) if t), None)
    if last:
        lat, lon = last[-1]
        location = {"placeholder": legs[tracks.index(last)][1].label, "latitude": lat, "longitude": lon}
    else:
        gps = [p["exifInfo"] for p in reversed(day_photos)
               if (p.get("exifInfo") or {}).get("latitude")]
        location = gps and {"placeholder": gps[0].get("city") or "",
                            "latitude": gps[0]["latitude"], "longitude": gps[0]["longitude"]}
    if ws:
        when = _utc(ws[-1].end)
    else:
        when = day_photos[-1]["fileCreatedAt"].replace("+00:00", "Z")

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
    state[key] = {"memo": name, "sig": sig, "text": text, "atts": atts}
    log(f"{key}: {name} ({len(ws)} workouts, {len(photos)} photos)")
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
        try:
            immich = Immich(*immich_settings(cfg, run, uid), opener)
        except RuntimeError as e:
            log(f"no photos: {e}")
            immich = None
        with tempfile.TemporaryDirectory() as tmp:
            for day in target_days(cfg, today):
                journal_day(cfg, run, memos, state, day, uid, log,
                            render_fn or render, tmp, immich)
                if cfg.state_path and not cfg.dry_run:
                    save_json(cfg.state_path, state)
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as e:
        log(f"FATAL: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
