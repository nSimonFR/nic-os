"""
Calendar and weather lines for journal-daily.

Calendars are read from Nextcloud's own tables (oc_calendarobjects, as postgres
over the socket), recurrences expanded with recurring-ical-events. PERSONAL
calendars are listed event by event. WORK calendars give the meeting count,
time and distinct people, then the meetings themselves, collapsed.

A meeting = a timed work event with at least one other (non-room) attendee
that the calendar owner did not decline. The owner is the attendee on most of
the calendar's recent events, so their address is never configured.

Weather: Open-Meteo's daily summary (free, keyless) for where the day happened.
"""

import base64
import string
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
          AND o.deleted_at IS NULL  -- Nextcloud's trash bin keeps deleted events
          AND ((o.calendartype = 0 AND o.calendarid IN
                  (SELECT id FROM oc_calendars WHERE displayname IN ({sql}) AND deleted_at IS NULL))
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


def meetings(events, lo_dt, hi_dt, me):
    """[(start, end, event, other attendees)] clipped to the day."""
    out = []
    for e in events:
        if e.all_day:
            continue
        others = [m for m, c, _ in e.attendees if m != me and not _is_room(m, c)]
        declined = any(m == me and p == "DECLINED" for m, _, p in e.attendees)
        start, end = max(e.start, lo_dt), min(e.end, hi_dt)
        if others and not declined and end > start:
            out.append((start, end, e, others))
    return sorted(out, key=lambda m: m[0])


def meeting_lines(events, lo_dt, hi_dt, me, tz):
    """`- **10:00-10:30** Titre · 4 personnes`, one per meeting."""
    return [f"- **{s.astimezone(tz):%H:%M}-{e.astimezone(tz):%H:%M}** {ev.title or '(sans titre)'} · "
            f"{_plural(len(set(o)), 'personne')}"
            for s, e, ev, o in meetings(events, lo_dt, hi_dt, me)]


def work_summary(events, lo_dt, hi_dt, me):
    """(meetings, minutes, people) of the day, or None without meetings."""
    found = meetings(events, lo_dt, hi_dt, me)
    if not found:
        return None
    people = {o for *_, others in found for o in others}
    meetings_ = [(s, e) for s, e, *_ in found]
    minutes, cur_s, cur_e = 0, None, None
    for s, e in meetings_:  # union of the intervals: overlaps count once
        if cur_e is None or s > cur_e:
            if cur_e is not None:
                minutes += (cur_e - cur_s).total_seconds() / 60
            cur_s, cur_e = s, e
        else:
            cur_e = max(cur_e, e)
    minutes += (cur_e - cur_s).total_seconds() / 60
    return len(meetings_), round(minutes), len(people)


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


# The forecast API serves 92 days back (2026-10-26); older days need the archive.
WEATHER_FORECAST_DAYS = 85


def weather_line(day, lat, lon, opener=None, today=None):
    """`🌧 Pluie légère · 9-14 °C · 2,1 mm`, from Open-Meteo's daily summary."""
    q = urlencode({"latitude": f"{lat:.4f}", "longitude": f"{lon:.4f}",
                   "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum",
                   "timezone": "Europe/Paris", "start_date": day.isoformat(), "end_date": day.isoformat()})
    old = ((today or date.today()) - day).days > WEATHER_FORECAST_DAYS
    host = "https://archive-api.open-meteo.com/v1/archive" if old else "https://api.open-meteo.com/v1/forecast"
    d = get_json(f"{host}?{q}", opener=opener)["daily"]
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
    at: float = 0  # epoch s
    track: str = ""  # Spotify track id


def music_tracks(run, ids, db="ryot", runuser="runuser", psql="psql"):
    """{spotify track id: artists} from Ryot V1's metadata: V11 has artists
    only for the tracks it has finished populating (516 of 1744 on 2026-10-26)."""
    safe = [i for i in ids if i.isalnum()]  # Spotify ids are base62
    if not safe:
        return {}
    rows = psql_rows(run, f"""
        SELECT m.identifier,
               coalesce((SELECT string_agg(p.name, ', ' ORDER BY p.name)
                         FROM metadata_to_person mp JOIN person p ON p.id = mp.person_id
                         WHERE mp.metadata_id = m.id AND mp.role = 'Artist'), '')
        FROM metadata m
        WHERE m.lot = 'music' AND m.source = 'spotify'
          AND m.identifier IN ({", ".join(f"'{i}'" for i in sorted(set(safe)))})
    """, db, runuser, psql)
    return {r[0]: r[1] for r in rows if r[1]}


def music_listens(run, lo, hi, db="ryotv2", runuser="runuser", psql="psql"):
    """Every music play in [lo, hi) from Ryot V11, oldest first, stamped with
    Spotify's own played_at (spotify-to-ryot logs one complete per listen)."""
    rows = psql_rows(run, f"""
        SELECT e.name,
               coalesce((SELECT string_agg(p.name, ', ' ORDER BY coalesce((r.properties->>'order')::int, 0), p.name)
                         FROM relationship r JOIN entity p ON p.id = r.source_entity_id
                         WHERE r.target_entity_id = e.id AND r.relationship_schema_slug = 'person-to-music'), ''),
               coalesce((e.properties->>'duration')::int, 0),
               extract(epoch FROM ev.occurred_at), coalesce(e.external_id, '')
        FROM event ev JOIN entity e ON e.id = ev.entity_id
        WHERE e.entity_schema_slug = 'music' AND ev.event_schema_slug = 'complete'
          AND ev.occurred_at >= to_timestamp({int(lo)}) AND ev.occurred_at < to_timestamp({int(hi)})
        ORDER BY ev.occurred_at, ev.id
    """, db, runuser, psql)
    return [Listen(r[0], r[1], int(r[2] or 0), float(r[3]), r[4]) for r in rows]


def music_section(listens, top=5, per_artist=3, streaks=None):
    """(heading suffix, lines): `31 titres · 2 h 03`, then the most played
    artists with their tracks, replays first with their count:
    `- **Lomepal** · Un peu de sang (2), Club, Trop beau`. `streaks` =
    {artist: text} appended to that artist's line."""
    by_artist = {}
    for l in listens:
        by_artist.setdefault(l.artists or "Artiste inconnu", []).append(l.title)
    ranked = sorted(by_artist.items(), key=lambda kv: -len(kv[1]))  # stable: first heard wins ties
    lines = []
    for artist, titles in ranked[:top]:
        plays = sorted(Counter(titles).items(), key=lambda kv: -kv[1])  # replays first, then first heard
        uniq = [f"{t} ({n})" if n > 1 else t for t, n in plays]
        shown = ", ".join(uniq[:per_artist]) + (" …" if len(uniq) > per_artist else "")
        lines.append(f"- **{artist}** · {shown}" + (f" · {streaks[artist]}" if (streaks or {}).get(artist) else ""))
    if len(ranked) > top:
        n = len(ranked) - top
        lines.append(f"- *et {n} autre{'s' if n > 1 else ''} artiste{'s' if n > 1 else ''}*")
    h, m = divmod(round(sum(l.seconds for l in listens) / 60), 60)
    n = len(listens)
    head = f"{n} titre{'s' if n > 1 else ''}" + (f" · {h} h {m:02d}" if h else f" · {m} min")
    return head, lines


# Arkose hold colours (gymLabels names) -> emoji
HOLD_EMOJI = {"jaune": "🟡", "vert": "🟢", "bleu": "🔵", "rouge": "🔴", "noir": "⚫",
              "violet": "🟣", "orange": "🟠", "blanc": "⚪", "rose": "🩷", "marron": "🟤"}


def climbing_sessions(path, lo, hi):
    """Arkose sessions (arkose-sync's sessions.json) started in [lo, hi), oldest first."""
    import json

    with open(path) as f:
        sessions = json.load(f).get("sessions", {}).values()
    day = [s for s in sessions if not s.get("isEmpty")
           and lo <= datetime.fromisoformat(s["startDate"]).timestamp() < hi]
    return sorted(day, key=lambda s: s["startDate"])


def _plural(n, word, plural=None):
    return f"{n} {word if n == 1 else plural or word + 's'}"


def climbing_section(sessions):
    """(heading suffix, lines), one line per category (sessions of the day
    summed — in practice one): `Arkose Chevaleret · 7 tops · 38 m`, then
    `- 🔵 **Bleu**: 2`, `- 🟢 **Vert**: 5`, `- **Retops**: 1`, `- **Niveau**: vert ⬆️`."""
    names, by_label = {}, {}
    for s in sessions:
        names.update(s.get("gymLabels") or {})
        for label, n in (s.get("topsCountsByLabel") or {}).items():
            by_label[label] = by_label.get(label, 0) + n
    total = lambda key: sum(s.get(key) or 0 for s in sessions)
    # one line per level, hardest (highest label) first
    lines = [f"- {HOLD_EMOJI.get(names.get(l, l), '🪨')} **{names.get(l, l).capitalize()}**: {by_label[l]}"
             for l in sorted(by_label, key=int, reverse=True)]
    for key, title in (("flashs", "Flashs"), ("retops", "Retops"), ("tried", "Non topés")):
        if total(key):
            lines.append(f"- **{title}**: {total(key)}")
    last = sessions[-1]
    level = names.get(str((last.get("sessionLevel") or {}).get("label", "")))
    if level:
        lines.append(f"- **Niveau**: {level}" + (" ⬆️" if last.get("isLevelUp") else ""))
    gyms = list(dict.fromkeys(s.get("gymName") or s.get("gym", "?") for s in sessions))
    head = [*gyms, _plural(total("tops"), "top")]
    if total("climbedHeight"):
        head.append(f"{total('climbedHeight')} m")
    return " · ".join(head), lines


# Arkose+ web client: settings.public.S3Path + "/boulderPicsShare/<id>.jpg" is a
# public 1200 px square of the wall with the start hold circled (2026-10-25).
ARKOSE_S3 = "https://socialboulder.s3-eu-west-1.amazonaws.com"


CLIMB_ORDER = {"flash": 0, "": 0, "retop": 1, "tried": 2}


def climbing_pictures(sessions):
    """[(url, hold colour, status)] of the day's boulders, each once: tops
    ("flash" or ""), then "retop", then "tried" (not topped); hardest colour
    first within each. A retop's `flashed` is the first send's, so ignored."""
    out, seen = [], set()
    for s in sessions:
        names = s.get("gymLabels") or {}
        kinds = [(b, "flash" if b.get("flashed") else "") for b in s.get("boulders") or []]
        kinds += [(b, "retop") for b in s.get("retopBoulders") or []]
        kinds += [(b, "tried") for b in s.get("triedBoulders") or []]
        for b, status in kinds:
            pic = b.get("picture") or {}
            if b["_id"] in seen or not (pic.get("share") or pic.get("id")):
                continue
            seen.add(b["_id"])
            url = (f"{ARKOSE_S3}/boulderPicsShare/{pic['share']}.jpg" if pic.get("share")
                   else f"{ARKOSE_S3}/800/bouldersPics/{pic['id']}.jpg")
            out.append((CLIMB_ORDER[status], -int(b.get("label") or 0), url,
                        names.get(str(b.get("label")), ""), status))
    return [(url, colour, status) for *_, url, colour, status in sorted(out, key=lambda t: t[:2])]


def game_plays(run, lo, hi, db="ryotv2", v1_db="ryot", runuser="runuser", psql="psql"):
    """[(epoch s, title, seconds)] of the playtime landed for [lo, hi).
    steam-to-ryot pushes the playtime grown since its last run at 04:50, so a
    push stands for the journal day before it: the window is shifted a day.
    V11 holds the pushes since the switch (timeSpent in minutes); the V1
    migration folded each game's earlier sessions into one event (marked by
    its startedOn), so the days before come from V1's seens."""
    lo, hi = int(lo) + 86400, int(hi) + 86400
    rows = psql_rows(run, f"""
        SELECT extract(epoch FROM ev.occurred_at), e.name, ((ev.properties->>'timeSpent')::numeric * 60)::bigint
        FROM event ev JOIN entity e ON e.id = ev.entity_id
        WHERE e.entity_schema_slug = 'video-game' AND ev.event_schema_slug = 'complete'
          AND NOT ev.properties ? 'startedOn' AND (ev.properties->>'timeSpent')::numeric > 0
          AND ev.occurred_at >= to_timestamp({lo}) AND ev.occurred_at < to_timestamp({hi})
    """, db, runuser, psql)
    if v1_db:
        # Keyed on started_on (the push); finished_on is when Ryot completed it,
        # which for seens completed by hand is days later.
        rows += psql_rows(run, f"""
            SELECT extract(epoch FROM coalesce(s.started_on, s.finished_on)), m.title, s.manual_time_spent::bigint
            FROM seen s JOIN metadata m ON m.id = s.metadata_id
            WHERE m.lot = 'video_game' AND s.manual_time_spent > 0
              AND coalesce(s.started_on, s.finished_on) >= to_timestamp({lo})
              AND coalesce(s.started_on, s.finished_on) < to_timestamp({hi})
        """, v1_db, runuser, psql)
    return sorted((float(r[0]) - 86400, r[1], int(r[2])) for r in rows)


def game_sessions(plays):
    """[(title, seconds)] per game, most played first."""
    total = {}
    for _, title, sec in plays:
        total[title] = total.get(title, 0) + sec
    return sorted(total.items(), key=lambda kv: (-kv[1], kv[0]))


def _hm(seconds):
    h, m = divmod(round(seconds / 60), 60)
    return f"{h} h {m:02d}" if h else f"{m} min"


def game_section(games, streaks=None):
    """(heading suffix, lines): `2 h 15`, then `- **Stardew Valley** · 1 h 40`,
    plus that game's `streaks` text if any."""
    return _hm(sum(s for _, s in games)), [
        f"- **{t}** · {_hm(s)}" + (f" · {streaks[t]}" if (streaks or {}).get(t) else "") for t, s in games]


@dataclass(frozen=True)
class Screen:
    at: float  # epoch s, when it ended
    kind: str  # "movie" | "show-episode"
    title: str
    show: str = ""
    season: int = 0
    episode: int = 0
    year: str = ""
    minutes: int = 0


def screen_events(run, lo, hi, db="ryotv2", runuser="runuser", psql="psql"):
    """Films and episodes finished in [lo, hi) (Plex, through plex-to-ryot), oldest first."""
    rows = psql_rows(run, f"""
        SELECT extract(epoch FROM ev.occurred_at), e.entity_schema_slug, e.name,
               coalesce((SELECT s.name FROM entity s WHERE s.entity_schema_slug = 'show'
                         AND s.external_id = e.properties->>'parentShowExternalId' LIMIT 1), ''),
               coalesce(e.properties->>'seasonNumber', '0'), coalesce(e.properties->>'episodeNumber', '0'),
               coalesce(e.properties->>'publishYear', ''), coalesce(e.properties->>'runtime', '0')
        FROM event ev JOIN entity e ON e.id = ev.entity_id
        WHERE e.entity_schema_slug IN ('movie', 'show-episode') AND ev.event_schema_slug = 'complete'
          AND ev.occurred_at >= to_timestamp({int(lo)}) AND ev.occurred_at < to_timestamp({int(hi)})
        ORDER BY ev.occurred_at, ev.id
    """, db, runuser, psql)
    num = lambda x: int(float(x or 0))
    return [Screen(float(r[0]), r[1], r[2], r[3], num(r[4]), num(r[5]), r[6], num(r[7])) for r in rows]


def _caps(name):
    """TMDB gives some shows in capitals (INVINCIBLE): `Invincible`."""
    return string.capwords(name) if name.isupper() else name


def screen_section(screens, tz):
    """(heading suffix, lines): `1 film · 2 épisodes · 2 h 30`, then
    `- **21:03** 🎬 **Amélie** (2001)` / `- **19:58** 📺 **Invincible** · S03E08 · Title`.
    A show's episodes in a row share a line: `- **19:04-19:58** 📺 **Invincible** · S03E07-E08`."""
    films = sum(s.kind == "movie" for s in screens)
    eps = len(screens) - films
    head = ([_plural(films, "film")] if films else []) + ([_plural(eps, "épisode")] if eps else [])
    if all(s.minutes for s in screens):
        head.append(_hm(60 * sum(s.minutes for s in screens)))
    runs = []
    for s in screens:
        prev = runs[-1][-1] if runs else None
        if prev and s.kind == prev.kind == "show-episode" and s.show == prev.show and s.at - prev.at < 3 * 3600:
            runs[-1].append(s)
        else:
            runs.append([s])
    hm = lambda s: f"{datetime.fromtimestamp(s.at, tz):%H:%M}"
    code = lambda s: f"S{s.season:02d}E{s.episode:02d}" if s.season or s.episode else ""
    lines = []
    for run in runs:
        first, last = run[0], run[-1]
        at = f"**{hm(first)}**" if len(run) == 1 else f"**{hm(first)}-{hm(last)}**"
        if first.kind == "movie":
            lines.append(f"- {at} 🎬 **{first.title}**" + (f" ({first.year})" if first.year else ""))
        elif len(run) == 1:
            lines.append(f"- {at} 📺 " + " · ".join(x for x in (
                f"**{_caps(first.show or first.title)}**", code(first), _caps(first.title) if first.show else "") if x))
        else:
            span = code(first) + (f"-E{last.episode:02d}" if last.season == first.season else f"-{code(last)}")
            lines.append(f"- {at} 📺 **{_caps(first.show or first.title)}** · {span}")
    return " · ".join(head), lines


ACTIVITY_METRICS = ("step_count", "distance_walking_running", "flights_climbed", "active_energy")


def activity_totals(run, lo, hi, db="freereps", runuser="runuser", psql="psql"):
    """{metric: total} of the iPhone's own Health samples in [lo, hi).
    Apps writing to Health are left out (Geovelo adds a ride's kcal and
    floors, already in the bike section), and each hourly sample counts once:
    since FreeReps 2.2 the same hour is stored again with client freereps_ios."""
    names = ", ".join(f"'{m}'" for m in ACTIVITY_METRICS)
    rows = psql_rows(run, f"""
        SELECT metric_name, sum(qty) FROM (
            SELECT DISTINCT ON (metric_name, time) metric_name, qty
            FROM health_metrics
            WHERE metric_name IN ({names}) AND coalesce(source, '') = ''
              AND time >= to_timestamp({int(lo)}) AND time < to_timestamp({int(hi)})
            ORDER BY metric_name, time, client NULLS LAST
        ) hourly GROUP BY metric_name
    """, db, runuser, psql)
    return {r[0]: float(r[1] or 0) for r in rows}


def _int_fr(n):
    return f"{round(n):,}".replace(",", " ")


def activity_section(totals):
    """Heading suffix, like the bike section's: `2 970 pas · 2,2 km · 37
    étages · 128 kcal`; None without steps."""
    steps = totals.get("step_count", 0)
    if steps < 1:
        return None
    head = [f"{_int_fr(steps)} pas"]
    km = totals.get("distance_walking_running", 0) / 1000
    if km >= 0.1:
        head.append(f"{km:.1f} km".replace(".", ","))
    if totals.get("flights_climbed", 0) >= 1:
        head.append(_plural(round(totals["flights_climbed"]), "étage"))
    if totals.get("active_energy", 0) >= 1:
        head.append(f"{_int_fr(totals['active_energy'])} kcal")
    return " · ".join(head)


DISPATCH_VOICE = "concis, en français"


def clean_dispatch(md):
    """Markdown lines of an `entire dispatch`, fit for a collapsed block: no
    title, `## [owner/repo](url)` -> `**repo**`, `### Topic` -> `*Topic*`, and
    the closing paragraph after the last bullet dropped. [] when it covers no
    repo (an idle window still gets an "Aucune activité" edition)."""
    import re

    lines = md.splitlines()
    if not any(l.startswith("## [") for l in lines):
        return []
    out = []
    for l in lines:
        if l.startswith("# "):
            continue
        m = re.match(r"## \[([^\]]+)\]", l)
        if m:
            out.append(f"**{m.group(1).rsplit('/', 1)[-1]}**")
        elif l.startswith("### "):
            out.append(f"*{l[4:].strip()}*")
        else:
            out.append(l.rstrip())
    last = max((i for i, l in enumerate(out) if l.lstrip().startswith("- ")), default=len(out) - 1)
    out = out[:last + 1]
    while out and not out[0].strip():
        out.pop(0)
    return [l for i, l in enumerate(out) if l.strip() or (i and out[i - 1].strip())]


def dispatch_notes(run, repos, lo, hi, user="nsimon", runuser="runuser", git="git"):
    """Side-project notes for [lo, hi) from `entire dispatch --local` in each repo, run
    as `user` (the agent CLI's credentials are theirs). A repo with no commit
    in the window is skipped before the agent is called."""
    import shlex

    iso = lambda t: datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")
    notes = []
    for repo in repos:
        touched = run([runuser, "-u", user, "--", git, "-C", repo, "log", "--all",
                       f"--since=@{int(lo)}", f"--until=@{int(hi)}", "--format=%h", "-1"])
        if not touched.strip():
            continue
        md = run([runuser, "-l", user, "-c",
                  f"cd {shlex.quote(repo)} && entire dispatch --local --all-branches "
                  f"--since {iso(lo)} --until {iso(hi)} --voice {shlex.quote(DISPATCH_VOICE)}"])
        lines = clean_dispatch(md)
        if lines:
            notes += ([""] if notes else []) + lines
    return notes
