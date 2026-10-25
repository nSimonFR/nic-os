"""
Calendar and weather lines for journal-daily.

Calendars are read from Nextcloud's own tables (oc_calendarobjects, as postgres
over the socket), recurrences expanded with recurring-ical-events. PERSONAL
calendars are listed event by event. WORK calendars are only summed — meeting
time, count and distinct people — so no work meeting title reaches the journal.

A meeting = a timed work event with at least one other (non-room) attendee
that the calendar owner did not decline. The owner is the attendee on most of
the calendar's recent events, so their address is never configured.

Weather: Open-Meteo's daily summary (free, keyless) for where the day happened.
"""

import base64
from collections import Counter
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from urllib.parse import urlencode

from ..httpjson import get_json
from ..pg import psql_rows

# WMO weather code -> (emoji, label); Open-Meteo's `weather_code`.
WMO = {
    0: ("☀️", "Ciel dégagé"), 1: ("🌤", "Plutôt dégagé"), 2: ("⛅", "Partiellement nuageux"),
    3: ("☁️", "Couvert"), 45: ("🌫", "Brouillard"), 48: ("🌫", "Brouillard"),
    51: ("🌦", "Bruine légère"), 53: ("🌦", "Bruine"), 55: ("🌦", "Forte bruine"),
    56: ("🌧", "Bruine verglaçante"), 57: ("🌧", "Bruine verglaçante"),
    61: ("🌧", "Pluie légère"), 63: ("🌧", "Pluie"), 65: ("🌧", "Forte pluie"),
    66: ("🌧", "Pluie verglaçante"), 67: ("🌧", "Pluie verglaçante"),
    71: ("🌨", "Neige légère"), 73: ("🌨", "Neige"), 75: ("🌨", "Forte neige"), 77: ("🌨", "Grains de neige"),
    80: ("🌦", "Averses légères"), 81: ("🌦", "Averses"), 82: ("⛈", "Violentes averses"),
    85: ("🌨", "Averses de neige"), 86: ("🌨", "Averses de neige"),
    95: ("⛈", "Orage"), 96: ("⛈", "Orage avec grêle"), 99: ("⛈", "Orage avec grêle"),
}
ROOM_DOMAINS = ("resource.calendar.google.com", "group.calendar.google.com")


@dataclass(frozen=True)
class Event:
    title: str
    start: datetime  # aware
    end: datetime
    all_day: bool
    attendees: tuple = ()  # (email, cutype, partstat)


def _sql_list(names):
    return ", ".join("'" + n.replace("'", "''") + "'" for n in names) or "NULL"


def calendar_blobs(run, names, lo, hi, db="nextcloud_production", runuser="runuser", psql="psql"):
    """Raw iCalendar objects of the named calendars/subscriptions that may
    occur in [lo, hi) (epoch s; Nextcloud's own occurrence bounds)."""
    sql = _sql_list(names)
    rows = psql_rows(run, f"""
        SELECT replace(encode(o.calendardata, 'base64'), E'\\n', '')
        FROM oc_calendarobjects o
        WHERE o.componenttype = 'VEVENT'
          AND ((o.calendartype = 0 AND o.calendarid IN
                  (SELECT id FROM oc_calendars WHERE displayname IN ({sql})))
            OR (o.calendartype = 1 AND o.calendarid IN
                  (SELECT id FROM oc_calendarsubscriptions WHERE displayname IN ({sql}))))
          AND coalesce(o.firstoccurence, 0) < {int(hi)}
          AND coalesce(o.lastoccurence, 9999999999) > {int(lo)}
    """, db, runuser, psql)
    return [base64.b64decode(r[0]) for r in rows if r and r[0]]


def _attendees(ev):
    raw = ev.get("ATTENDEE")
    if raw is None:
        return ()
    out = []
    for a in raw if isinstance(raw, list) else [raw]:
        email = str(a).lower().removeprefix("mailto:").strip()
        out.append((email, str(a.params.get("CUTYPE", "")).upper(),
                    str(a.params.get("PARTSTAT", "")).upper()))
    return tuple(out)


def expand(blobs, lo_dt, hi_dt, tz):
    """Events of `blobs` overlapping [lo_dt, hi_dt), recurrences expanded,
    cancelled ones dropped, oldest first."""
    import icalendar  # lazy
    import recurring_ical_events  # lazy

    events = []
    for blob in blobs:
        try:
            cal = icalendar.Calendar.from_ical(blob)
            occurrences = recurring_ical_events.of(cal).between(lo_dt, hi_dt)
        except Exception:  # one malformed object must not hide the day
            continue
        for ev in occurrences:
            if str(ev.get("STATUS", "")).upper() == "CANCELLED":
                continue
            start = ev.decoded("DTSTART")
            end = ev.decoded("DTEND") if ev.get("DTEND") else None
            all_day = not isinstance(start, datetime)
            if all_day:
                start = datetime(start.year, start.month, start.day, tzinfo=tz)
                end = (datetime(end.year, end.month, end.day, tzinfo=tz) if isinstance(end, date)
                       else start + timedelta(days=1))
            else:
                start = start if start.tzinfo else start.replace(tzinfo=tz)
                end = (end if end.tzinfo else end.replace(tzinfo=tz)) if end else start
            events.append(Event(str(ev.get("SUMMARY", "")).strip(), start, end, all_day, _attendees(ev)))
    return sorted(events, key=lambda e: (not e.all_day, e.start))


def owner(events):
    """The attendee on most events: the calendar's owner."""
    seen = Counter(email for e in events for email, _, _ in set(e.attendees))
    return seen.most_common(1)[0][0] if seen else ""


def _is_room(email, cutype):
    return cutype in ("RESOURCE", "ROOM") or email.endswith(ROOM_DOMAINS)


def work_summary(events, lo_dt, hi_dt, me):
    """(meetings, minutes, people) of the day, or None without meetings."""
    meetings, people = [], set()
    for e in events:
        if e.all_day:
            continue
        others = [(m, c) for m, c, _ in e.attendees if m != me and not _is_room(m, c)]
        declined = any(m == me and p == "DECLINED" for m, _, p in e.attendees)
        if not others or declined:
            continue
        start, end = max(e.start, lo_dt), min(e.end, hi_dt)
        if end <= start:
            continue
        meetings.append((start, end))
        people.update(m for m, _ in others)
    if not meetings:
        return None
    minutes, cur_s, cur_e = 0, None, None
    for s, e in sorted(meetings):  # union of the intervals: overlaps count once
        if cur_e is None or s > cur_e:
            if cur_e is not None:
                minutes += (cur_e - cur_s).total_seconds() / 60
            cur_s, cur_e = s, e
        else:
            cur_e = max(cur_e, e)
    minutes += (cur_e - cur_s).total_seconds() / 60
    return len(meetings), round(minutes), len(people)


def dedupe(events):
    """One event per time slot when calendars mirror each other (PERSO and
    Google both carry "Heure de conduite", one with " — En Voiture Simone"):
    same start and end, and one title equal to or a prefix of the other; the
    fuller title wins."""
    kept = []
    for e in sorted(events, key=lambda e: -len(e.title)):
        if not any(k.start == e.start and k.end == e.end and k.all_day == e.all_day
                   and k.title.lower().startswith(e.title.lower()) for k in kept):
            kept.append(e)
    return sorted(kept, key=lambda e: (not e.all_day, e.start))


def personal_lines(events, tz):
    """`- **Journée** Titre` / `- **19:00-21:00** Titre`, mirrors merged."""
    lines = []
    for e in dedupe(events):
        title = e.title or "(sans titre)"
        if e.all_day:
            lines.append(f"- **Journée** {title}")
        else:
            lines.append(f"- **{e.start.astimezone(tz):%H:%M}-{e.end.astimezone(tz):%H:%M}** {title}")
    return lines


def weather_line(day, lat, lon, opener=None):
    """`🌧 Pluie légère · 9-14 °C · 2,1 mm`, from Open-Meteo's daily summary."""
    q = urlencode({"latitude": f"{lat:.4f}", "longitude": f"{lon:.4f}",
                   "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum",
                   "timezone": "Europe/Paris", "start_date": day.isoformat(), "end_date": day.isoformat()})
    d = get_json(f"https://api.open-meteo.com/v1/forecast?{q}", opener=opener)["daily"]
    emoji, label = WMO.get(d["weather_code"][0], ("🌡", "Météo"))
    bits = [f"{emoji} {label}",
            f"{round(d['temperature_2m_min'][0])}-{round(d['temperature_2m_max'][0])} °C"]
    rain = d["precipitation_sum"][0] or 0
    if rain >= 0.1:
        bits.append(f"{rain:.1f} mm".replace(".", ","))
    return " · ".join(bits)


@dataclass(frozen=True)
class Listen:
    title: str
    artists: str  # "A, B"; "" when Ryot has no artist
    seconds: int


def music_listens(run, lo, hi, db="ryot", runuser="runuser", psql="psql"):
    """The day's music plays from Ryot (fed hourly by spotify-to-ryot), oldest
    first. The seen's time is when the connector pushed it (:17 each hour),
    not the play itself: good for the day, too coarse for a per-track time."""
    rows = psql_rows(run, f"""
        SELECT m.title,
               coalesce((SELECT string_agg(p.name, ', ' ORDER BY p.name)
                         FROM metadata_to_person mp JOIN person p ON p.id = mp.person_id
                         WHERE mp.metadata_id = m.id AND mp.role = 'Artist'), ''),
               coalesce((m.music_specifics->>'duration')::int, 0)
        FROM seen s JOIN metadata m ON m.id = s.metadata_id
        WHERE m.lot = 'music'
          AND coalesce(s.finished_on, s.started_on) >= to_timestamp({int(lo)})
          AND coalesce(s.finished_on, s.started_on) < to_timestamp({int(hi)})
        ORDER BY coalesce(s.finished_on, s.started_on), s.id
    """, db, runuser, psql)
    return [Listen(r[0], r[1], int(r[2] or 0)) for r in rows]


def music_section(listens, top=5, per_artist=3):
    """(heading suffix, lines): `31 titres · 2 h 03`, then the most played
    artists with their tracks: `- **Lomepal** · Un peu de sang, Club, Trop beau`."""
    by_artist = {}
    for l in listens:
        by_artist.setdefault(l.artists or "Artiste inconnu", []).append(l.title)
    ranked = sorted(by_artist.items(), key=lambda kv: -len(kv[1]))  # stable: first heard wins ties
    lines = []
    for artist, titles in ranked[:top]:
        uniq = list(dict.fromkeys(titles))
        shown = ", ".join(uniq[:per_artist]) + (" …" if len(uniq) > per_artist else "")
        lines.append(f"- **{artist}** · {shown}")
    if len(ranked) > top:
        n = len(ranked) - top
        lines.append(f"- + {n} autre{'s' if n > 1 else ''} artiste{'s' if n > 1 else ''}")
    h, m = divmod(round(sum(l.seconds for l in listens) / 60), 60)
    n = len(listens)
    head = f"{n} titre{'s' if n > 1 else ''}" + (f" · {h} h {m:02d}" if h else f" · {m} min")
    return head, lines
