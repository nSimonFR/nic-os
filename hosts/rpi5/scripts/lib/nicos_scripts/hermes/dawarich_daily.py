#!/usr/bin/env python3
"""
hermes-dawarich-daily: yesterday's location recap, straight from the Dawarich API.

Replaces the LLM cron job that used to reason its way to the same message. The
job's prompt was already a specification rather than a question — "point count,
ordered place timeline from actual points, transport from tracks, deliver as
Telegram HTML" — so nothing here needs a model.

Two endpoints, deliberately:

  GET /api/v1/points  the timeline. Sparse-tracking reality (3-20 points/day) is
                      why stops are *clustered from points* rather than read from
                      /api/v1/visits: Dawarich's nightly DBSCAN stop detector has
                      produced almost nothing since 2026-04-19, so a visits-based
                      recap reports an empty day on a day the user did move.
  GET /api/v1/tracks  transport. GeoJSON FeatureCollection; each feature's
                      `properties` carries dominant_mode/duration/distance.
                      `mode_timeline` emoji is a segment indicator only, and the
                      per-point `mode` field is ignored — it is null in practice.

Delivery is a direct `telegram-send -m html`, not stdout: the message wants bold
text and a deep link into the day's timeline, and Hermes' verbatim stdout channel
is plain text. Hence the silence-on-success contract — printing the report as
well would post it twice.

Config (all from the environment, read once in main()):

  DAWARICH_API_KEY   required; re-exported by the shim from /run/agenix/agent-env
  DAWARICH_BASE_URL  API, loopback-only          (default http://127.0.0.1:13900)
  DAWARICH_WEB_URL   UI, for user-facing links   (default the Tailscale Serve URL)
  TELEGRAM_CHAT_ID   recipient                   (required unless --dry-run)
  TELEGRAM_SEND      sender binary               (default "telegram-send")
  DAWARICH_DAY       YYYY-MM-DD to report on     (default yesterday, Europe/Paris)
  DAWARICH_GAP_MIN   minutes between points that splits a cluster (default 60)
  DAWARICH_SPARSE_AT point count below which the day is flagged sparse (default 50)
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

# stderr, NOT the default stdout: under `no_agent` stdout is the Telegram message,
# so a log line on stdout would be delivered to the user as the report.
log = logger("hermes-dawarich-daily", lambda: sys.stderr)

TZ = ZoneInfo("Europe/Paris")

# Explicit, not locale-derived: this runs under systemd with LC_ALL unset, where
# %a/%b would silently switch language on a locale change.
WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MONTHS = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

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
    """The day to report on — explicit override, else yesterday in Europe/Paris."""
    if cfg.day:
        return date.fromisoformat(cfg.day)
    now = today or datetime.now(TZ).date()
    return now - timedelta(days=1)


# ---------------------------------------------------------------- fetching


def _auth(cfg):
    return {"Authorization": f"Bearer {cfg.api_key}"}


def fetch_points(cfg, day, opener=None):
    """Points for `day`, oldest first. Local wall-clock bounds, per the API."""
    q = urllib.parse.urlencode(
        {
            "start_at": f"{day.isoformat()}T00:00:00",
            "end_at": f"{day.isoformat()}T23:59:59",
            "per_page": 1000,
        }
    )
    data = get_json(f"{cfg.base_url}/api/v1/points?{q}", _auth(cfg), opener=opener)
    points = data if isinstance(data, list) else data.get("points") or []
    return sorted(points, key=lambda p: p.get("timestamp") or 0)


def fetch_tracks(cfg, day, opener=None):
    """Track segments for `day`. Returns the `properties` dicts, oldest first.

    Offset-qualified bounds (`+02:00`) because /tracks — unlike /points — matches
    on an absolute instant, so a bare local timestamp shifts the window by the
    UTC offset and drops the first/last segment of the day.
    """
    offset = datetime.combine(day, datetime.min.time(), TZ).strftime("%z")
    stamp = f"{offset[:3]}:{offset[3:]}"
    q = urllib.parse.urlencode(
        {
            "start_at": f"{day.isoformat()}T00:00:00{stamp}",
            "end_at": f"{day.isoformat()}T23:59:59{stamp}",
        }
    )
    data = get_json(f"{cfg.base_url}/api/v1/tracks?{q}", _auth(cfg), opener=opener)
    features = data.get("features", []) if isinstance(data, dict) else (data or [])
    props = [f.get("properties") or {} for f in features]
    return sorted(props, key=lambda p: p.get("start_at") or "")


# ---------------------------------------------------------------- formatting


def human_duration(seconds):
    """230min -> '3h50', 37min -> '37min'. Sub-minute rounds up to 1min."""
    mins = int(round(seconds / 60.0))
    if mins < 1:
        mins = 1
    if mins < 60:
        return f"{mins}min"
    hours, rest = divmod(mins, 60)
    return f"{hours}h{rest:02d}" if rest else f"{hours}h"


def human_date(day):
    return f"{WEEKDAYS[day.weekday()]} {day.day} {MONTHS[day.month - 1]}"


def point_place(point):
    """Best available label for a point: city, else street, else coordinates."""
    props = (point.get("geodata") or {}).get("properties") or {}
    for key in ("city", "town", "village"):
        val = point.get(key) or props.get(key)
        if val:
            return str(val)
    if props.get("street"):
        return str(props["street"])
    lat, lon = props.get("lat"), props.get("lon")
    if lat is not None and lon is not None:
        return f"{float(lat):.3f},{float(lon):.3f}"
    return "unknown"


def point_country(point):
    props = (point.get("geodata") or {}).get("properties") or {}
    return point.get("country") or props.get("country") or ""


def local_time(epoch):
    return datetime.fromtimestamp(int(epoch), TZ)


def cluster_points(points, gap_min=60):
    """Group consecutive points sharing a place label into stop candidates.

    Consecutive-and-same-label only — no spatial re-ordering. That keeps the
    timeline honest about what the phone actually reported: with 6 points in a
    day there is no statistical stop to find, just a sequence of sightings.
    A gap longer than `gap_min` splits the cluster even when the label matches,
    so "home in the morning" and "home at night" do not merge into one 14h blob.
    """
    gap = gap_min * 60
    clusters = []
    for p in points:
        ts = p.get("timestamp")
        if ts is None:
            continue
        label = point_place(p)
        last = clusters[-1] if clusters else None
        if last and last["place"] == label and int(ts) - last["end"] <= gap:
            last["end"] = int(ts)
            last["n"] += 1
        else:
            clusters.append(
                {"place": label, "start": int(ts), "end": int(ts), "n": 1}
            )
    return clusters


def place_line(points):
    """Distinct places in first-seen order, plus the country."""
    seen, ordered = set(), []
    for p in points:
        label = point_place(p)
        if label not in seen:
            seen.add(label)
            ordered.append(label)
    country = ""
    for p in points:
        if point_country(p):
            country = point_country(p)
            break
    joined = " → ".join(ordered[:4])
    if len(ordered) > 4:
        joined += f" (+{len(ordered) - 4})"
    return f"{joined}, {country}" if country else joined


def day_link(cfg, day):
    """Deep link into the day's timeline, ampersands HTML-escaped for parse_mode."""
    return (
        f"{cfg.web_url}/map/v2?panel=timeline"
        f"&amp;date={day.isoformat()}&amp;status=all"
    )


def build_message(cfg, day, points, tracks):
    """The Telegram HTML body. Only <b> and <a> — the tags Telegram accepts."""
    link = day_link(cfg, day)
    lines = [
        f'🗺 <b><a href="{link}">Dawarich · {human_date(day)}</a></b>',
    ]

    if not points:
        lines.append("")
        lines.append("No points recorded — the phone reported nothing this day.")
        return "\n".join(lines)

    sparse = " (sparse)" if len(points) < cfg.sparse_at else ""
    lines.append(
        f"📍 <b>{html.escape(place_line(points))}</b> · {len(points)} pts{sparse}"
    )
    lines.append("")

    clusters = cluster_points(points, cfg.gap_min)
    for c in clusters:
        start, end = local_time(c["start"]), local_time(c["end"])
        place = html.escape(c["place"])
        if c["n"] == 1 or c["end"] == c["start"]:
            lines.append(f"• {start:%H:%M} · {place}")
        else:
            span = human_duration(c["end"] - c["start"])
            lines.append(f"• {start:%H:%M}–{end:%H:%M} · {span} · {place}")

    if len(clusters) == len(points):
        # Every point got its own cluster: nothing repeated a location, so there
        # is no dwell to call a stop. Say so rather than implying these are stops.
        lines.append("")
        lines.append("No confident stop — each point is a separate sighting.")

    lines.append("")
    if tracks:
        lines.append("<b>Transport</b>")
        for t in tracks:
            lines.append(f"• {track_line(t)}")
    else:
        lines.append("No transport segment detected.")

    return "\n".join(lines)


def track_line(props):
    """'12:12–13:01 · 49min · 🚗 driving · 6.2 km' from a track's properties."""
    start = _parse_iso(props.get("start_at"))
    end = _parse_iso(props.get("end_at"))
    when = "?"
    if start and end:
        when = f"{start:%H:%M}–{end:%H:%M}"
    elif start:
        when = f"{start:%H:%M}"

    bits = [when]
    duration = props.get("duration")
    if duration:
        bits.append(human_duration(float(duration)))

    mode = props.get("dominant_mode") or "unknown"
    emoji = props.get("dominant_mode_emoji") or ""
    bits.append(f"{emoji} {html.escape(str(mode))}".strip())

    metres = props.get("distance")
    if metres:
        km = float(metres) / 1000.0
        bits.append(f"{km:.1f} km" if km >= 0.1 else f"{int(float(metres))} m")

    return " · ".join(bits)


def _parse_iso(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value)).astimezone(TZ)
    except ValueError:
        return None


# ---------------------------------------------------------------- delivery


def send(cfg, body, run=None):
    """Hand the HTML body to telegram-send. Returns its raw stdout.

    telegram-send always exits 0 by design (a notification must not fail its
    caller), so success is read off the API response body, not the exit code.
    """
    runner = run or _subprocess_run
    argv = [cfg.telegram_send, "-c", cfg.chat_id, "-m", "html"]
    code, out = runner(argv, body)
    if code != 0:
        raise RuntimeError(f"{cfg.telegram_send} exited {code}: {out.strip()}")
    if '"ok":true' not in out.replace(" ", ""):
        raise RuntimeError(f"Telegram rejected the message: {out.strip()}")
    return out


def _subprocess_run(argv, stdin_text):
    proc = subprocess.run(
        argv, input=stdin_text, capture_output=True, text=True, timeout=60
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


# ---------------------------------------------------------------- entry point


def main(argv=None, env=None):
    args = list(sys.argv[1:] if argv is None else argv)
    dry_run = "--dry-run" in args

    cfg = Config.from_env(env)
    if not cfg.api_key:
        log("FATAL: DAWARICH_API_KEY not set")
        return 1
    if not cfg.chat_id and not dry_run:
        log("FATAL: TELEGRAM_CHAT_ID not set")
        return 1

    day = target_day(cfg)

    try:
        points = fetch_points(cfg, day)
        tracks = fetch_tracks(cfg, day)
    except (urllib.error.URLError, ValueError, OSError) as e:
        log(f"FATAL: Dawarich API unreachable ({e})")
        return 1

    body = build_message(cfg, day, points, tracks)

    if dry_run:
        # The one path that prints: --dry-run is for a human at a terminal, and
        # is never how the cron job runs.
        print(body)
        return 0

    try:
        send(cfg, body)
    except (RuntimeError, OSError, subprocess.SubprocessError) as e:
        log(f"FATAL: delivery failed ({e})")
        return 1

    # Silence on success — see the module docstring. The report has already been
    # delivered as HTML; anything on stdout would post it a second time as text.
    log(f"sent {day.isoformat()}: {len(points)} points, {len(tracks)} tracks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
