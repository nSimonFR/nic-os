#!/usr/bin/env python3
"""
hermes-calendar-digest: the next N days of the personal Nextcloud calendar.

Replaces the LLM cron job whose entire prompt was "Envoyer à Nico ses événements
personnels des 14 prochains jours" — a query, not a judgement.

Prints the digest to stdout and lets Hermes deliver it verbatim (plain text,
which is all a list of events needs). Contrast dawarich_daily, which sends its
own HTML and stays silent.

Two REPORTs, and the reason is a Nextcloud quirk worth stating plainly
----------------------------------------------------------------------
Recurrence expansion has to be the server's job: a plain `calendar-query`
returns a recurring event as its *master* component (DTSTART in 2025 plus an
RRULE), so a naive reader shows a 2025 date. Asking for `<C:expand>` fixes that
— Nextcloud returns one concrete instance per occurrence.

But `expand` stamps **every** returned DTSTART with a `Z`, including events whose
stored value is a *floating* local time. Measured against this server:

    stored                                   expanded      true local
    DTSTART;TZID=Europe/Paris:...T160000     ...T140000Z   16:00  (real UTC)
    DTSTART:...T180000        (floating)     ...T180000Z   18:00  (Z is a lie)

Treating that second row as UTC shifts it +2h — which is how the first draft of
this script reported an 18:00 Fest-Noz as 20:00, and a 19:22 OUIGO as 21:22.
Nothing in the expanded payload distinguishes the two cases.

So: two passes, joined on UID. The **unexpanded** pass supplies each event's time
*kind* (all-day / floating / absolute), which is a stable property of the series.
The **expanded** pass supplies the occurrences. Each instance's clock is then read
according to its series' kind. Recurrence overrides (a `Ménage` moved from 16:00
to 08:30) are handled for free, because the time comes from the instance, not the
master.

Config (all from the environment, read once in main()):

  CALDAV_BASE          calendar home  (default the Nextcloud dav URL for nsimon)
  CALDAV_USER          default "nsimon"
  CALDAV_PASSWORD      literal password; normally unset
  CALDAV_PASSWORD_FILE default /run/agenix/nextcloud-homepage-password
  CALDAV_CALENDAR      collection id  (default "personal")
  CALDAV_DAYS          window length in days (default 14)
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

# stderr, NOT the default stdout: stdout is the delivered message.
log = logger("hermes-calendar-digest", lambda: sys.stderr)

TZ = ZoneInfo("Europe/Paris")
UTC = ZoneInfo("UTC")

DEFAULT_BASE = (
    "https://rpi5.gate-mintaka.ts.net/nextcloud/remote.php/dav/calendars/nsimon/"
)
DEFAULT_PASSWORD_FILE = "/run/agenix/nextcloud-homepage-password"

WEEKDAYS_FR = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]
MONTHS_FR = [
    "janvier", "février", "mars", "avril", "mai", "juin",
    "juillet", "août", "septembre", "octobre", "novembre", "décembre",
]

CALDAV_NS = "urn:ietf:params:xml:ns:caldav"

# The three ways a DTSTART can mean something. `floating` is the one that makes
# this module more than a one-liner (see the module docstring).
KIND_DATE = "date"
KIND_FLOATING = "floating"
KIND_ABSOLUTE = "absolute"


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
            path = env_str("CALDAV_PASSWORD_FILE", DEFAULT_PASSWORD_FILE, env)
            try:
                password = read_secret(path)
            except OSError:
                password = ""
        return cls(
            base=env_str("CALDAV_BASE", DEFAULT_BASE, env).rstrip("/") + "/",
            user=env_str("CALDAV_USER", "nsimon", env),
            # `occ`-minted app passwords come out CRLF-terminated; a stray \r is
            # sent as part of the credential and reads back as a 401.
            password=password.strip(),
            calendar=env_str("CALDAV_CALENDAR", "personal", env),
            days=env_int("CALDAV_DAYS", 14, env),
        )


# ---------------------------------------------------------------- transport


def query_body(start, end, expand):
    """A calendar-query REPORT, optionally asking the server to expand recurrences."""
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
        '<c:filter><c:comp-filter name="VCALENDAR">'
        '<c:comp-filter name="VEVENT">'
        f'<c:time-range start="{lo}" end="{hi}"/>'
        "</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"
    )


def report(cfg, body, opener=None):
    """Issue the REPORT and return the response XML as text."""
    url = f"{cfg.base}{cfg.calendar}/"
    token = base64.b64encode(f"{cfg.user}:{cfg.password}".encode()).decode()
    req = urllib.request.Request(
        url,
        data=body.encode(),
        method="REPORT",
        headers={
            "Authorization": f"Basic {token}",
            "Content-Type": 'application/xml; charset="utf-8"',
            "Depth": "1",
        },
    )
    open_it = opener or urllib.request.urlopen
    with open_it(req, timeout=30) as resp:
        return resp.read().decode("utf-8", "replace")


def calendar_blobs(xml):
    """Every <calendar-data> payload in a multistatus response."""
    root = ElementTree.fromstring(xml)
    return [
        el.text
        for el in root.iter(f"{{{CALDAV_NS}}}calendar-data")
        if el.text and el.text.strip()
    ]


# ---------------------------------------------------------------- ICS parsing


def unfold(text):
    """Undo RFC 5545 line folding (a continuation starts with space or tab)."""
    out = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and out:
            out[-1] += raw[1:]
        else:
            out.append(raw)
    return out


def _split(line):
    """'DTSTART;TZID=Europe/Paris:20260211T160000' -> (key, params, value)."""
    name, _, value = line.partition(":")
    key, _, params = name.partition(";")
    return key.upper(), params.upper(), value.strip()


def dt_kind(params, value):
    """Which of the three DTSTART meanings this is."""
    if "VALUE=DATE" in params and "VALUE=DATE-TIME" not in params:
        return KIND_DATE
    if len(value) == 8 and value.isdigit():
        return KIND_DATE
    if value.endswith("Z") or "TZID=" in params:
        return KIND_ABSOLUTE
    return KIND_FLOATING


def parse_components(blob):
    """Raw VEVENTs: uid, the DTSTART/DTEND (params, value) pairs, and text fields."""
    events, current = [], None
    for line in unfold(blob):
        if line.startswith("BEGIN:VEVENT"):
            current = {}
            continue
        if line.startswith("END:VEVENT"):
            if current is not None and "dtstart" in current:
                events.append(current)
            current = None
            continue
        if current is None or ":" not in line:
            continue

        key, params, value = _split(line)
        if key == "DTSTART":
            current["dtstart"] = (params, value)
        elif key == "DTEND":
            current["dtend"] = (params, value)
        elif key == "UID":
            current["uid"] = value
        elif key in ("SUMMARY", "LOCATION"):
            current[key.lower()] = _unescape(value)
    return events


def _unescape(value):
    r"""ICS text escaping: \n, \, and \; are the ones that appear here."""
    return (
        value.replace("\\n", " ")
        .replace("\\N", " ")
        .replace("\\,", ",")
        .replace("\\;", ";")
        .replace("\\\\", "\\")
        .strip()
    )


def series_kinds(blobs):
    """uid -> time kind, from the UNEXPANDED pass.

    First component wins. A recurrence override may move an occurrence's clock
    but never changes whether the series is floating, zoned or all-day.
    """
    kinds = {}
    for blob in blobs:
        for comp in parse_components(blob):
            uid = comp.get("uid")
            if not uid or uid in kinds:
                continue
            params, value = comp["dtstart"]
            kinds[uid] = dt_kind(params, value)
    return kinds


def read_clock(params, value, kind):
    """Interpret one DTSTART/DTEND under its series' kind.

    `kind` overrides whatever the expanded payload claims — that is the entire
    point of the two-pass join. A floating series keeps its wall clock; an
    absolute series gets converted into Europe/Paris.
    """
    if kind == KIND_DATE:
        return date.fromisoformat(f"{value[0:4]}-{value[4:6]}-{value[6:8]}")

    naive = value[:-1] if value.endswith("Z") else value
    try:
        stamp = datetime.strptime(naive, "%Y%m%dT%H%M%S")
    except ValueError:
        # Not a date-time after all — fall back to the date reading rather than
        # dropping the event.
        return date.fromisoformat(f"{value[0:4]}-{value[4:6]}-{value[6:8]}")

    if kind == KIND_FLOATING:
        # The Z Nextcloud added is noise; this clock is already local.
        return stamp.replace(tzinfo=TZ)
    if value.endswith("Z"):
        return stamp.replace(tzinfo=UTC).astimezone(TZ)
    if "TZID=EUROPE/PARIS" in params:
        return stamp.replace(tzinfo=TZ)
    # A TZID we do not carry a rule for: treat as local rather than guess.
    return stamp.replace(tzinfo=TZ)


def build_instances(blobs, kinds):
    """Expanded components -> the event dicts the formatter consumes."""
    out = []
    for blob in blobs:
        for comp in parse_components(blob):
            uid = comp.get("uid", "")
            params, value = comp["dtstart"]
            # An unknown uid (present when expanded but not unexpanded) falls back
            # to the payload's own claim.
            kind = kinds.get(uid) or dt_kind(params, value)
            start = read_clock(params, value, kind)
            end = None
            if "dtend" in comp:
                end = read_clock(comp["dtend"][0], comp["dtend"][1], kind)
            out.append(
                {
                    "uid": uid,
                    "start": start,
                    "end": end,
                    "all_day": kind == KIND_DATE,
                    "summary": comp.get("summary"),
                    "location": comp.get("location"),
                }
            )
    return out


# ---------------------------------------------------------------- formatting


def event_day(event):
    start = event["start"]
    return start.date() if isinstance(start, datetime) else start


def in_window(event, start_day, end_day):
    return start_day <= event_day(event) <= end_day


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
        prefix = WEEKDAYS_FR[day.weekday()]
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
    if event.get("location"):
        line += f"\n  📍 {event['location']}"
    return line


def build_digest(events, today, days):
    """Group by day, French, plain text — Hermes delivers this verbatim."""
    if not events:
        return f"📅 Aucun événement personnel dans les {days} prochains jours."

    lines = [f"📅 Agenda personnel · {days} prochains jours", ""]
    current = None
    for event in sorted(events, key=sort_key):
        day = event_day(event)
        if day != current:
            if current is not None:
                lines.append("")
            lines.append(human_day(day, today))
            current = day
        lines.append(format_event(event))
    return "\n".join(lines).rstrip()


# ---------------------------------------------------------------- orchestration


def collect(cfg, today=None, opener=None):
    """Fetch both passes, join them, and return the window's instances."""
    start_day = today or datetime.now(TZ).date()
    end_day = start_day + timedelta(days=cfg.days)
    lo = datetime.combine(start_day, datetime.min.time(), UTC)
    hi = datetime.combine(end_day, datetime.min.time(), UTC)

    plain = calendar_blobs(report(cfg, query_body(lo, hi, expand=False), opener=opener))
    kinds = series_kinds(plain)

    expanded = calendar_blobs(
        report(cfg, query_body(lo, hi, expand=True), opener=opener)
    )
    events = build_instances(expanded, kinds)

    # The server filters on instants; re-filter on local calendar days so an
    # event at 01:00 Paris the day after the window does not sneak in.
    return [e for e in events if in_window(e, start_day, end_day)]


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
