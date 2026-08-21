#!/usr/bin/env python3
"""
hermes-calendar-digest: the next N days of the personal Nextcloud calendar.

Prints the digest; Hermes delivers stdout verbatim.

Two REPORTs joined on UID, because of one Nextcloud quirk. Expansion has to be the
server's job (a plain calendar-query returns a recurring event as its master —
DTSTART in 2025 plus an RRULE), but `<C:expand>` stamps EVERY returned DTSTART
with a `Z`, floating local times included:

    stored                                  expanded     true local
    DTSTART;TZID=Europe/Paris:...T160000    ...T140000Z  16:00 (real UTC)
    DTSTART:...T180000       (floating)     ...T180000Z  18:00 (Z is a lie)

Reading row 2 as UTC shifts it +2h — how the first draft reported an 18:00
Fest-Noz as 20:00. The payload cannot tell them apart, so the unexpanded pass
supplies each series' time *kind* and the expanded pass supplies the occurrences.
Overrides (a Ménage moved 16:00 -> 08:30) then come out right for free.

Env: CALDAV_{BASE,USER,PASSWORD,PASSWORD_FILE,CALENDAR,DAYS}.
"""

import base64
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from xml.etree import ElementTree
from zoneinfo import ZoneInfo

from ..logs import logger
from ..secrets import env_int, env_str, read_secret

# stderr: stdout is the delivered message.
log = logger("hermes-calendar-digest", lambda: sys.stderr)

TZ = ZoneInfo("Europe/Paris")
UTC = ZoneInfo("UTC")
CALDAV_NS = "urn:ietf:params:xml:ns:caldav"

DEFAULT_BASE = "https://rpi5.gate-mintaka.ts.net/nextcloud/remote.php/dav/calendars/nsimon/"
DEFAULT_PASSWORD_FILE = "/run/agenix/nextcloud-homepage-password"

# The C locale has no French names, so these are spelled out.
DAYS_FR = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
MONTHS_FR = [
    "janvier", "février", "mars", "avril", "mai", "juin",
    "juillet", "août", "septembre", "octobre", "novembre", "décembre",
]

KIND_DATE, KIND_FLOATING, KIND_ABSOLUTE = "date", "floating", "absolute"


@dataclass(frozen=True)
class Config:
    base: str = DEFAULT_BASE
    user: str = "nsimon"
    password: str = ""
    calendar: str = "personal"
    days: int = 14

    @classmethod
    def from_env(cls, env=None):
        password = env_str("CALDAV_PASSWORD", "", env)
        if not password:
            try:
                password = read_secret(
                    env_str("CALDAV_PASSWORD_FILE", DEFAULT_PASSWORD_FILE, env)
                )
            except OSError:
                password = ""
        return cls(
            base=env_str("CALDAV_BASE", DEFAULT_BASE, env).rstrip("/") + "/",
            user=env_str("CALDAV_USER", "nsimon", env),
            # `occ`-minted app passwords come out CRLF-terminated, and a stray \r
            # is sent as part of the credential — reads back as a 401.
            password=password.strip(),
            calendar=env_str("CALDAV_CALENDAR", "personal", env),
            days=env_int("CALDAV_DAYS", 14, env),
        )


def query_body(start, end, expand):
    fmt = "%Y%m%dT%H%M%SZ"
    lo, hi = start.strftime(fmt), end.strftime(fmt)
    data = (
        f'<c:calendar-data><c:expand start="{lo}" end="{hi}"/></c:calendar-data>'
        if expand
        else "<c:calendar-data/>"
    )
    return (
        '<?xml version="1.0" encoding="utf-8" ?>'
        '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        f"<d:prop>{data}</d:prop>"
        '<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT">'
        f'<c:time-range start="{lo}" end="{hi}"/>'
        "</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"
    )


def report(cfg, body, opener=None):
    """Issue the REPORT, return every <calendar-data> payload."""
    token = base64.b64encode(f"{cfg.user}:{cfg.password}".encode()).decode()
    req = urllib.request.Request(
        f"{cfg.base}{cfg.calendar}/",
        data=body.encode(),
        method="REPORT",
        headers={
            "Authorization": f"Basic {token}",
            "Content-Type": 'application/xml; charset="utf-8"',
            "Depth": "1",
        },
    )
    with (opener or urllib.request.urlopen)(req, timeout=30) as resp:
        xml = resp.read().decode("utf-8", "replace")
    root = ElementTree.fromstring(xml)
    return [
        el.text
        for el in root.iter(f"{{{CALDAV_NS}}}calendar-data")
        if el.text and el.text.strip()
    ]


def unfold(text):
    """Undo RFC 5545 folding (a continuation starts with space or tab)."""
    out = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and out:
            out[-1] += raw[1:]
        else:
            out.append(raw)
    return out


def parse_components(blob):
    """VEVENTs as {uid, dtstart: (params, value), dtend, summary, location}."""
    events, cur = [], None
    for line in unfold(blob):
        if line.startswith("BEGIN:VEVENT"):
            cur = {}
        elif line.startswith("END:VEVENT"):
            if cur is not None and "dtstart" in cur:
                events.append(cur)
            cur = None
        elif cur is not None and ":" in line:
            name, _, value = line.partition(":")
            key, _, params = name.partition(";")
            key = key.upper()
            if key in ("DTSTART", "DTEND"):
                cur[key.lower()] = (params.upper(), value.strip())
            elif key == "UID":
                cur["uid"] = value.strip()
            elif key in ("SUMMARY", "LOCATION"):
                cur[key.lower()] = _unescape(value.strip())
    return events


def _unescape(value):
    r"""ICS text escaping: \n, \, and \; are the ones that appear here."""
    for old, new in (("\\n", " "), ("\\N", " "), ("\\,", ","), ("\\;", ";")):
        value = value.replace(old, new)
    return value.replace("\\\\", "\\").strip()


def dt_kind(params, value):
    if ("VALUE=DATE" in params and "VALUE=DATE-TIME" not in params) or (
        len(value) == 8 and value.isdigit()
    ):
        return KIND_DATE
    return KIND_ABSOLUTE if value.endswith("Z") or "TZID=" in params else KIND_FLOATING


def series_kinds(blobs):
    """uid -> kind, from the UNEXPANDED pass. First component wins: an override
    may move an occurrence's clock, never the series' kind."""
    kinds = {}
    for blob in blobs:
        for comp in parse_components(blob):
            uid = comp.get("uid")
            if uid and uid not in kinds:
                kinds[uid] = dt_kind(*comp["dtstart"])
    return kinds


def read_clock(params, value, kind):
    """Interpret one DTSTART/DTEND under its series' kind — `kind` overrides
    whatever the expanded payload claims, which is the point of the join."""
    as_date = lambda: date.fromisoformat(f"{value[0:4]}-{value[4:6]}-{value[6:8]}")
    if kind == KIND_DATE:
        return as_date()
    try:
        stamp = datetime.strptime(value.removesuffix("Z"), "%Y%m%dT%H%M%S")
    except ValueError:
        return as_date()
    if kind == KIND_ABSOLUTE and value.endswith("Z"):
        return stamp.replace(tzinfo=UTC).astimezone(TZ)
    # Floating, or a TZID we carry no rule for: this clock is already local.
    return stamp.replace(tzinfo=TZ)


def build_instances(blobs, kinds):
    out = []
    for blob in blobs:
        for comp in parse_components(blob):
            uid = comp.get("uid", "")
            # An unknown uid falls back to the payload's own claim.
            kind = kinds.get(uid) or dt_kind(*comp["dtstart"])
            out.append(
                {
                    "uid": uid,
                    "start": read_clock(*comp["dtstart"], kind),
                    "end": read_clock(*comp["dtend"], kind) if "dtend" in comp else None,
                    "all_day": kind == KIND_DATE,
                    "summary": comp.get("summary"),
                    "location": comp.get("location"),
                }
            )
    return out


def event_day(event):
    start = event["start"]
    return start.date() if isinstance(start, datetime) else start


def sort_key(event):
    start = event["start"]
    if isinstance(start, datetime):
        return (start.date(), 1, start.strftime("%H:%M"))
    return (start, 0, "")


def human_day(day, today):
    if day == today:
        prefix = "aujourd'hui"
    elif day == today + timedelta(days=1):
        prefix = "demain"
    else:
        prefix = DAYS_FR[day.weekday()]
    return f"{prefix} {day.day} {MONTHS_FR[day.month - 1]}"


def format_event(event):
    start, end = event["start"], event.get("end")
    summary = event.get("summary") or "(sans titre)"
    if not isinstance(start, datetime):
        line = f"• toute la journée · {summary}"
    elif isinstance(end, datetime) and end > start:
        line = f"• {start:%H:%M}–{end:%H:%M} · {summary}"
    else:
        line = f"• {start:%H:%M} · {summary}"
    return line + (f"\n  📍 {event['location']}" if event.get("location") else "")


def build_digest(events, today, days):
    if not events:
        return f"📅 Aucun événement personnel dans les {days} prochains jours."
    lines, current = [f"📅 Agenda personnel · {days} prochains jours", ""], None
    for event in sorted(events, key=sort_key):
        day = event_day(event)
        if day != current:
            if current is not None:
                lines.append("")
            lines.append(human_day(day, today))
            current = day
        lines.append(format_event(event))
    return "\n".join(lines).rstrip()


def collect(cfg, today=None, opener=None):
    start_day = today or datetime.now(TZ).date()
    end_day = start_day + timedelta(days=cfg.days)
    lo = datetime.combine(start_day, datetime.min.time(), UTC)
    hi = datetime.combine(end_day, datetime.min.time(), UTC)

    kinds = series_kinds(report(cfg, query_body(lo, hi, expand=False), opener=opener))
    events = build_instances(
        report(cfg, query_body(lo, hi, expand=True), opener=opener), kinds
    )
    # The server filters on instants; re-filter on local days so an event at
    # 01:00 Paris the day after the window does not sneak in.
    return [e for e in events if start_day <= event_day(e) <= end_day]


def main(argv=None, env=None):
    del argv
    cfg = Config.from_env(env)
    if not cfg.password:
        log("FATAL: no CalDAV password (CALDAV_PASSWORD / CALDAV_PASSWORD_FILE)")
        return 1
    today = datetime.now(TZ).date()
    try:
        events = collect(cfg, today=today)
    except (urllib.error.URLError, OSError, ElementTree.ParseError) as e:
        log(f"FATAL: CalDAV query failed ({e})")
        return 1
    print(build_digest(events, today, cfg.days))
    log(f"{len(events)} events over {cfg.days} days")
    return 0


if __name__ == "__main__":
    sys.exit(main())
