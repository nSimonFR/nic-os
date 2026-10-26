"""
Records and streaks for journal-daily: plain comparisons against each source's
own history, nothing stored. Only what came before the day counts, so a
rewritten old memo says what was true that day, not what is true now.

A record = beats every earlier value (all-time), else every value of the last
365 days. It needs MIN_PRIOR earlier values over MIN_SPAN_DAYS, or the first
weeks of a source would be all records. A streak = consecutive days (or ISO
weeks) with the thing, shown from STREAK_MIN.
"""

import sqlite3
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from ..pg import psql_rows

TZ = ZoneInfo("Europe/Paris")
DAY_START_H = 4
MIN_PRIOR = 8
MIN_SPAN_DAYS = 30
STREAK_MIN = 3
STEP_GOAL = 10_000
FAST_RIDE_KM = 10  # speed records only on rides this long: short hops are GPS noise


def journal_date(t):
    """The journal day (04:00 -> 04:00 Paris) of epoch `t`."""
    return (datetime.fromtimestamp(t, TZ) - timedelta(hours=DAY_START_H)).date()


def best(value, history, day):
    """"all", "year" or None: `value` beats every earlier one of `history`
    ([(date, value)]), or every one of the 365 days before `day`."""
    prior = [(d, v) for d, v in history if d < day]
    if not value or len(prior) < MIN_PRIOR or (day - min(d for d, _ in prior)).days < MIN_SPAN_DAYS:
        return None
    if value > max(v for _, v in prior):
        return "all"
    recent = [v for d, v in prior if (day - d).days <= 365]
    if len(recent) >= MIN_PRIOR and value > max(recent):
        return "year"
    return None


def record_lines(found):
    """`- 🏆 **Record**: a · b`, then `- 🏆 **Meilleur depuis un an**: c`, from
    [(level, text)] (level from `best`, None dropped)."""
    lines = []
    for level, title in (("all", "Record"), ("year", "Meilleur depuis un an")):
        texts = [t for lvl, t in found if lvl == level]
        if texts:
            lines.append(f"- 🏆 **{title}**: {' · '.join(texts)}")
    return lines


def streak(dates, day, weeks=False):
    """How many consecutive days (ISO weeks) with an entry in `dates` end with
    `day`'s; 0 when `day` has none."""
    key = (lambda d: d - timedelta(days=d.weekday())) if weeks else (lambda d: d)
    have, step = {key(d) for d in dates if d <= day}, timedelta(weeks=1) if weeks else timedelta(days=1)
    n, cur = 0, key(day)
    while cur in have:
        n, cur = n + 1, cur - step
    return n


def streak_text(n, weeks=False, what=""):
    """`🔥 4ᵉ jour d'affilée` (+ `what`), or "" below STREAK_MIN."""
    if n < STREAK_MIN:
        return ""
    return f"🔥 {n}ᵉ {'semaine' if weeks else 'jour'} d'affilée{what}"


def _n(x):
    return f"{x:.1f}".replace(".", ",")


def _int_fr(n):
    return f"{round(n):,}".replace(",", " ")


# --- per source -----------------------------------------------------------

def ride_history(run, hi, db="freereps", runuser="runuser", psql="psql"):
    """[(epoch start, km, minutes)] of every ride started before `hi`."""
    rows = psql_rows(run, f"""
        SELECT extract(epoch FROM start_time)::bigint, coalesce(distance, 0), coalesce(duration_sec, 0)
        FROM workouts  -- ride history
        WHERE name = 'Cycling' AND start_time < to_timestamp({int(hi)})
    """, db, runuser, psql)
    return [(int(r[0]), float(r[1]) / 1000, float(r[2]) / 60) for r in rows]


def ride_badges(rides, day):
    """Lines for the bike section: records (longest ride, biggest day, fastest
    ride), then the streak of days on the bike."""
    today = [(km, mins) for t, km, mins in rides if journal_date(t) == day]
    if not today:
        return []
    before = [(journal_date(t), km, mins) for t, km, mins in rides if journal_date(t) < day]
    per_day = {}
    for d, km, _ in before:
        per_day[d] = per_day.get(d, 0) + km
    longest = max(km for km, _ in today)
    found = [(best(longest, [(d, km) for d, km, _ in before], day), f"plus longue sortie ({_n(longest)} km)")]
    if len(today) > 1:
        total = sum(km for km, _ in today)
        found.append((best(total, list(per_day.items()), day), f"plus grosse journée ({_n(total)} km)"))
    speed = lambda km, mins: km / (mins / 60) if km >= FAST_RIDE_KM and mins else 0
    fastest = max(speed(km, mins) for km, mins in today)
    if fastest:
        found.append((best(fastest, [(d, speed(km, m)) for d, km, m in before if speed(km, m)], day),
                      f"sortie la plus rapide ({_n(fastest)} km/h)"))
    lines = record_lines(found)
    s = streak_text(streak({journal_date(t) for t, _, _ in rides}, day))
    return lines + ([f"- {s}"] if s else [])


def step_history(run, hi, db="freereps", runuser="runuser", psql="psql"):
    """{journal day: steps} before `hi`, counted as activity_totals does."""
    rows = psql_rows(run, f"""
        SELECT (date_trunc('day', time AT TIME ZONE 'Europe/Paris' - interval '{DAY_START_H} hours'))::date, sum(qty)
        FROM (
            SELECT DISTINCT ON (time) time, qty FROM health_metrics  -- step history
            WHERE metric_name = 'step_count' AND coalesce(source, '') = ''
              AND time < to_timestamp({int(hi)})
            ORDER BY time, client NULLS LAST
        ) hourly GROUP BY 1
    """, db, runuser, psql)
    return {datetime.strptime(r[0], "%Y-%m-%d").date(): float(r[1] or 0) for r in rows}


def step_badges(steps, day):
    """Lines for the activity section: the step record, the 10 000-step streak."""
    if not steps.get(day):
        return []
    lines = record_lines([(best(steps[day], list(steps.items()), day),
                           f"plus de pas en un jour ({_int_fr(steps[day])})")])
    s = streak_text(streak({d for d, n in steps.items() if n >= STEP_GOAL}, day),
                    what=f" à {_int_fr(STEP_GOAL)} pas")
    return lines + ([f"- {s}"] if s else [])


def climbing_badges(sessions, day):
    """Lines for the climbing section from every Arkose session: records
    (tops in a day, metres climbed in a day), then the streak of weeks."""
    by_day = {}
    for s in sessions:
        d = journal_date(datetime.fromisoformat(s["startDate"]).timestamp())
        tops, height = by_day.get(d, (0, 0))
        by_day[d] = (tops + (s.get("tops") or 0), height + (s.get("climbedHeight") or 0))
    if day not in by_day:
        return []
    tops, height = by_day[day]
    found = [(best(tops, [(d, t) for d, (t, _) in by_day.items()], day), f"plus de tops en une séance ({tops})")]
    if height:
        found.append((best(height, [(d, h) for d, (_, h) in by_day.items()], day),
                      f"plus haut grimpé en une séance ({height} m)"))
    s = streak_text(streak(by_day, day, weeks=True), weeks=True)
    return record_lines(found) + ([f"- {s}"] if s else [])


def energy_history(path, hi, connect=sqlite3.connect):
    """{journal day: kWh} of the Linky meter's complete days before `hi`."""
    db = connect(f"file:{path}?mode=ro", uri=True)
    try:
        meter = db.execute("SELECT id FROM statistics_meta WHERE source = 'linky' "
                           "AND statistic_id NOT LIKE '%\\_cost' ESCAPE '\\'").fetchone()
        if not meter:
            return {}
        rows = db.execute("SELECT start_ts, state FROM statistics WHERE metadata_id = ? AND start_ts < ?",
                          (meter[0], hi)).fetchall()
    finally:
        db.close()
    # Until 2026-02 the meter has one row per calendar day (at local midnight),
    # hourly ones since: a lone row is a whole day, hours are summed per journal day.
    per_date = {}
    for t, _ in rows:
        d = datetime.fromtimestamp(t, TZ).date()
        per_date[d] = per_date.get(d, 0) + 1
    days, hours = {}, {}
    for t, wh in rows:
        local = datetime.fromtimestamp(t, TZ).date()
        d = local if per_date[local] == 1 else journal_date(t)
        days[d] = days.get(d, 0) + (wh or 0)
        hours[d] = hours.get(d, 0) + (24 if per_date[local] == 1 else 1)
    return {d: wh / 1000 for d, wh in days.items() if hours[d] >= 23}  # as energy(): one hour may be missing


def energy_badges(kwh, day):
    """The day's consumption record, if any."""
    if not kwh.get(day):
        return []
    return record_lines([(best(kwh[day], list(kwh.items()), day),
                          f"plus forte conso en un jour ({_n(kwh[day])} kWh)")])
