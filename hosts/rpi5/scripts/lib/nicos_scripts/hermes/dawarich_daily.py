#!/usr/bin/env python3
"""
hermes-dawarich-daily: yesterday's location recap, sent as Telegram HTML.

  /api/v1/points  the timeline. Stops are clustered from points rather than read
                  from /api/v1/visits: Dawarich's nightly stop detector has
                  produced almost nothing since 2026-04-19, so a visits-based
                  recap reports an empty day on a day the user did move.
  /api/v1/tracks  transport. GeoJSON; `properties` has dominant_mode/duration/
                  distance.

Sends its own message (bold + a deep link, which stdout can't carry), so it prints
nothing on success — see the package docstring.

Env: DAWARICH_{API_KEY,BASE_URL,WEB_URL,DAY,GAP_MIN,SPARSE_AT},
TELEGRAM_{CHAT_ID,SEND}.
"""

import html
import subprocess
import sys
import urllib.error
import urllib.parse
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from ..httpjson import get_json
from ..logs import logger
from ..secrets import env_int, env_str

# stderr: stdout is the delivered message.
log = logger("hermes-dawarich-daily", lambda: sys.stderr)

TZ = ZoneInfo("Europe/Paris")
DEFAULT_BASE = "http://127.0.0.1:13900"
DEFAULT_WEB = "https://rpi5.gate-mintaka.ts.net:3900"


@dataclass(frozen=True)
class Config:
    api_key: str = ""
    base_url: str = DEFAULT_BASE
    web_url: str = DEFAULT_WEB
    chat_id: str = ""
    telegram_send: str = "telegram-send"
    day: str = ""
    gap_min: int = 60
    sparse_at: int = 50

    @classmethod
    def from_env(cls, env=None):
        return cls(
            api_key=env_str("DAWARICH_API_KEY", "", env),
            base_url=env_str("DAWARICH_BASE_URL", DEFAULT_BASE, env).rstrip("/"),
            web_url=env_str("DAWARICH_WEB_URL", DEFAULT_WEB, env).rstrip("/"),
            chat_id=env_str("TELEGRAM_CHAT_ID", "", env),
            telegram_send=env_str("TELEGRAM_SEND", "telegram-send", env),
            day=env_str("DAWARICH_DAY", "", env).strip(),
            gap_min=env_int("DAWARICH_GAP_MIN", 60, env),
            sparse_at=env_int("DAWARICH_SPARSE_AT", 50, env),
        )


def target_day(cfg, today=None):
    if cfg.day:
        return date.fromisoformat(cfg.day)
    return (today or datetime.now(TZ).date()) - timedelta(days=1)


def fetch_points(cfg, day, opener=None):
    """Points for `day`, oldest first. Local wall-clock bounds, per the API."""
    q = urllib.parse.urlencode(
        {
            "start_at": f"{day}T00:00:00",
            "end_at": f"{day}T23:59:59",
            "per_page": 1000,
        }
    )
    data = get_json(
        f"{cfg.base_url}/api/v1/points?{q}",
        {"Authorization": f"Bearer {cfg.api_key}"},
        opener=opener,
    )
    points = data if isinstance(data, list) else data.get("points") or []
    return sorted(points, key=lambda p: p.get("timestamp") or 0)


def fetch_tracks(cfg, day, opener=None):
    """Track `properties` for `day`, oldest first.

    Offset-qualified bounds (`+02:00`): /tracks matches on an absolute instant,
    so bare local timestamps slide the window and drop the day's edge segments.
    """
    offset = datetime.combine(day, datetime.min.time(), TZ).strftime("%z")
    stamp = f"{offset[:3]}:{offset[3:]}"
    q = urllib.parse.urlencode(
        {"start_at": f"{day}T00:00:00{stamp}", "end_at": f"{day}T23:59:59{stamp}"}
    )
    data = get_json(
        f"{cfg.base_url}/api/v1/tracks?{q}",
        {"Authorization": f"Bearer {cfg.api_key}"},
        opener=opener,
    )
    features = data.get("features", []) if isinstance(data, dict) else (data or [])
    props = [f.get("properties") or {} for f in features]
    return sorted(props, key=lambda p: p.get("start_at") or "")


def human_duration(seconds):
    """230min -> '3h50', 37min -> '37min'. Sub-minute rounds up to 1min."""
    mins = max(1, int(round(seconds / 60.0)))
    if mins < 60:
        return f"{mins}min"
    hours, rest = divmod(mins, 60)
    return f"{hours}h{rest:02d}" if rest else f"{hours}h"


def point_place(point):
    """City, else street, else coordinates."""
    props = (point.get("geodata") or {}).get("properties") or {}
    for key in ("city", "town", "village"):
        if point.get(key) or props.get(key):
            return str(point.get(key) or props[key])
    if props.get("street"):
        return str(props["street"])
    lat, lon = props.get("lat"), props.get("lon")
    if lat is not None and lon is not None:
        return f"{float(lat):.3f},{float(lon):.3f}"
    return "unknown"


def cluster_points(points, gap_min=60):
    """Group consecutive same-place points into stop candidates.

    Consecutive-and-same-label only, with a gap that splits even a matching label
    — so "home this morning" and "home tonight" stay two sightings rather than
    merging into one 14h blob. With 6 points a day there is no statistical stop
    to find, only a sequence of sightings, and the output should say so.
    """
    clusters = []
    for p in points:
        ts, label = p.get("timestamp"), point_place(p)
        if ts is None:
            continue
        last = clusters[-1] if clusters else None
        if last and last["place"] == label and int(ts) - last["end"] <= gap_min * 60:
            last.update(end=int(ts), n=last["n"] + 1)
        else:
            clusters.append({"place": label, "start": int(ts), "end": int(ts), "n": 1})
    return clusters


def place_line(points):
    """Distinct places in first-seen order, plus the country."""
    ordered = list(dict.fromkeys(point_place(p) for p in points))
    countries = (
        p.get("country") or (p.get("geodata") or {}).get("properties", {}).get("country")
        for p in points
    )
    country = next((c for c in countries if c), "")
    joined = " → ".join(ordered[:4])
    if len(ordered) > 4:
        joined += f" (+{len(ordered) - 4})"
    return f"{joined}, {country}" if country else joined


def track_line(props):
    """'12:12–13:01 · 49min · 🚗 driving · 6.2 km'."""
    start, end = _iso(props.get("start_at")), _iso(props.get("end_at"))
    bits = [f"{start:%H:%M}–{end:%H:%M}" if start and end else (f"{start:%H:%M}" if start else "?")]
    if props.get("duration"):
        bits.append(human_duration(float(props["duration"])))
    mode = html.escape(str(props.get("dominant_mode") or "unknown"))
    bits.append(f"{props.get('dominant_mode_emoji') or ''} {mode}".strip())
    metres = props.get("distance")
    if metres:
        km = float(metres) / 1000.0
        bits.append(f"{km:.1f} km" if km >= 0.1 else f"{int(float(metres))} m")
    return " · ".join(bits)


def _iso(value):
    try:
        return datetime.fromisoformat(str(value)).astimezone(TZ) if value else None
    except ValueError:
        return None


def build_message(cfg, day, points, tracks):
    """Telegram HTML. Only <b>/<a>, and `&` escaped even inside href."""
    link = f"{cfg.web_url}/map/v2?panel=timeline&amp;date={day}&amp;status=all"
    # strftime under systemd runs in the C locale, so this is reliably English.
    lines = [f'🗺 <b><a href="{link}">Dawarich · {day:%a %-d %b}</a></b>']

    if not points:
        return "\n".join(lines + ["", "No points recorded — the phone reported nothing."])

    sparse = " (sparse)" if len(points) < cfg.sparse_at else ""
    lines += [
        f"📍 <b>{html.escape(place_line(points))}</b> · {len(points)} pts{sparse}",
        "",
    ]

    clusters = cluster_points(points, cfg.gap_min)
    for c in clusters:
        start = datetime.fromtimestamp(c["start"], TZ)
        place = html.escape(c["place"])
        if c["n"] == 1:
            lines.append(f"• {start:%H:%M} · {place}")
        else:
            end = datetime.fromtimestamp(c["end"], TZ)
            lines.append(
                f"• {start:%H:%M}–{end:%H:%M} · {human_duration(c['end'] - c['start'])} · {place}"
            )

    if len(clusters) == len(points):
        # Nothing repeated a location, so there is no dwell to call a stop.
        lines += ["", "No confident stop — each point is a separate sighting."]

    lines.append("")
    if tracks:
        lines += ["<b>Transport</b>"] + [f"• {track_line(t)}" for t in tracks]
    else:
        lines.append("No transport segment detected.")
    return "\n".join(lines)


def send(cfg, body, run=None):
    """Hand the body to telegram-send.

    telegram-send always exits 0 by design (a notification must not fail its
    caller), so success is read off the API response, not the exit code.
    """
    runner = run or _run
    code, out = runner([cfg.telegram_send, "-c", cfg.chat_id, "-m", "html"], body)
    if code != 0:
        raise RuntimeError(f"{cfg.telegram_send} exited {code}: {out.strip()}")
    if '"ok":true' not in out.replace(" ", ""):
        raise RuntimeError(f"Telegram rejected the message: {out.strip()}")
    return out


def _run(argv, stdin_text):
    p = subprocess.run(argv, input=stdin_text, capture_output=True, text=True, timeout=60)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def main(argv=None, env=None):
    dry_run = "--dry-run" in (sys.argv[1:] if argv is None else argv)
    cfg = Config.from_env(env)
    if not cfg.api_key:
        log("FATAL: DAWARICH_API_KEY not set")
        return 1
    if not cfg.chat_id and not dry_run:
        log("FATAL: TELEGRAM_CHAT_ID not set")
        return 1

    day = target_day(cfg)
    try:
        points, tracks = fetch_points(cfg, day), fetch_tracks(cfg, day)
    except (urllib.error.URLError, ValueError, OSError) as e:
        log(f"FATAL: Dawarich API unreachable ({e})")
        return 1

    body = build_message(cfg, day, points, tracks)
    if dry_run:
        # The only path that prints — for a human at a terminal, never the job.
        print(body)
        return 0

    try:
        send(cfg, body)
    except (RuntimeError, OSError, subprocess.SubprocessError) as e:
        log(f"FATAL: delivery failed ({e})")
        return 1
    log(f"sent {day}: {len(points)} points, {len(tracks)} tracks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
