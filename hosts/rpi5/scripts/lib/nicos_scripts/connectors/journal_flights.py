"""
Flights for journal-daily, from AirTrail's database (as postgres).

A flight belongs to the journal day its departure falls in; one logged with
a date but no time, to that date. Times are shown at each airport's own
clock. The whole log is read (tens of rows) for the running totals.
"""

import math
from dataclasses import dataclass
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from ..pg import psql_rows

CLASSES = {"economy": "économie", "premium": "premium", "business": "affaires", "first": "première"}


@dataclass(frozen=True)
class Airport:
    iata: str
    name: str
    city: str
    country: str  # ISO 3166 alpha-2
    lat: float
    lon: float
    tz: str


@dataclass(frozen=True)
class Flight:
    id: int
    date: str
    dep: datetime  # aware, or None when only the date is known
    arr: datetime
    duration: int  # s
    number: str
    airline: str
    aircraft: str
    reg: str
    terminal: str
    frm: Airport
    to: Airport
    seat: str
    seat_class: str


def _city(raw, name):
    """`Paris (Roissy-en-France, Val-d'Oise)` -> `Paris`."""
    return (raw or name).split(" (")[0].strip()


def _when(raw):
    return datetime.fromisoformat(raw.replace("Z", "+00:00")) if raw else None


def all_flights(run, db="airtrail", runuser="runuser", psql="psql"):
    """Every flight, oldest first."""
    ap = lambda a: (f"coalesce({a}.iata, {a}.icao), {a}.name, coalesce({a}.municipality, ''), "
                    f"{a}.country, {a}.lat, {a}.lon, {a}.tz")
    rows = psql_rows(run, f"""
        SELECT f.id, f.date, coalesce(f.departure, ''), coalesce(f.arrival, ''),
               coalesce(f.duration, 0), coalesce(f.flight_number, ''), coalesce(al.name, ''),
               coalesce(ac.name, ''), coalesce(f.aircraft_reg, ''), coalesce(f.departure_terminal, ''),
               {ap('a1')}, {ap('a2')},
               coalesce(p.seat_number, ''), coalesce(p.seat_class, '')
        FROM flight f
        JOIN airport a1 ON a1.id = f.from_id
        JOIN airport a2 ON a2.id = f.to_id
        LEFT JOIN airline al ON al.id = f.airline_id
        LEFT JOIN aircraft ac ON ac.id = f.aircraft_id
        LEFT JOIN LATERAL (SELECT seat_number, seat_class FROM flight_passenger
                           WHERE flight_id = f.id AND user_id IS NOT NULL LIMIT 1) p ON true
        ORDER BY f.date, coalesce(f.departure, ''), f.id
    """, db, runuser, psql)
    out = []
    for r in rows:
        frm = Airport(r[10], r[11], _city(r[12], r[11]), r[13], float(r[14]), float(r[15]), r[16])
        to = Airport(r[17], r[18], _city(r[19], r[18]), r[20], float(r[21]), float(r[22]), r[23])
        dep, arr, duration = _when(r[2]), _when(r[3]), int(r[4] or 0)
        if dep and not arr and duration:
            arr = dep + timedelta(seconds=duration)
        out.append(Flight(int(r[0]), r[1], dep, arr, duration, r[5], r[6], r[7], r[8], r[9],
                          frm, to, r[24], r[25]))
    return out


def on_day(flights, day, lo, hi):
    """The flights departing in [lo, hi) (epoch s), or dated `day` without a time."""
    return [f for f in flights
            if (f.dep and lo <= f.dep.timestamp() < hi) or (not f.dep and f.date == day.isoformat())]


def km(f):
    """Great-circle distance between the two airports."""
    p1, p2 = math.radians(f.frm.lat), math.radians(f.to.lat)
    dl = math.radians(f.to.lon - f.frm.lon)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371.0 * 2 * math.asin(math.sqrt(a))


def great_circle(f, n=64):
    """[(lat, lon)] along the shortest path, for the map."""
    p1, l1, p2, l2 = map(math.radians, (f.frm.lat, f.frm.lon, f.to.lat, f.to.lon))
    d = km(f) / 6371.0
    if d < 1e-6:
        return [(f.frm.lat, f.frm.lon), (f.to.lat, f.to.lon)]
    pts = []
    for i in range(n + 1):
        t = i / n
        a, b = math.sin((1 - t) * d) / math.sin(d), math.sin(t * d) / math.sin(d)
        x = a * math.cos(p1) * math.cos(l1) + b * math.cos(p2) * math.cos(l2)
        y = a * math.cos(p1) * math.sin(l1) + b * math.cos(p2) * math.sin(l2)
        z = a * math.sin(p1) + b * math.sin(p2)
        pts.append((math.degrees(math.atan2(z, math.hypot(x, y))), math.degrees(math.atan2(y, x))))
    return pts


def local(dt, tz):
    return dt.astimezone(ZoneInfo(tz)) if dt else None


def flag(country):
    return "".join(chr(0x1F1E6 + ord(c) - 65) for c in country.upper()) if len(country) == 2 else ""


def _hm(seconds):
    h, m = divmod(round(seconds / 60), 60)
    return f"{h}h{m:02d}" if h else f"{m}min"


def _int_fr(n):
    return f"{round(n):,}".replace(",", " ")


def flight_section(today, flights):
    """(heading suffix, lines): `Paris → Rome · 1 106 km · 1h45`, then per
    flight its number, departure, arrival and seat, then the running totals."""
    cities = [today[0].frm.city] + [f.to.city for f in today]
    head = [" → ".join(c for i, c in enumerate(cities) if i == 0 or c != cities[i - 1]),
            f"{_int_fr(sum(km(f) for f in today))} km"]
    if all(f.duration for f in today):
        head.append(_hm(sum(f.duration for f in today)))
    lines = []
    for f in today:
        ident = [f"**{f.number}**" if f.number else "", f.airline,
                 " · ".join(x for x in (f.aircraft, f.reg) if x)]
        if any(ident):
            lines.append("- 🎫 " + " · ".join(x for x in ident if x))
        dep, arr = local(f.dep, f.frm.tz), local(f.arr, f.to.tz)
        lines.append("- 🛫 " + " · ".join(x for x in (
            f"**{dep:%H:%M}**" if dep else "", f"{f.frm.iata} {flag(f.frm.country)} {f.frm.city}",
            f"terminal {f.terminal}" if f.terminal else "") if x))
        lines.append("- 🛬 " + " · ".join(x for x in (
            f"**{arr:%H:%M}**" if arr else "", f"{f.to.iata} {flag(f.to.country)} {f.to.city}") if x))
        if f.seat or f.seat_class:
            lines.append("- 💺 " + " · ".join(x for x in (f.seat, CLASSES.get(f.seat_class, f.seat_class)) if x))
    last = flights.index(today[-1])
    before = flights[:flights.index(today[0])]
    total = sum(km(f) for f in flights[:last + 1])
    lines.append(f"- 📊 {last + 1}ᵉ vol · {_int_fr(total)} km en avion depuis {flights[0].date[:4]}")
    seen = {a.country for f in before for a in (f.frm, f.to)}
    new = list(dict.fromkeys(f.to.country for f in today if f.to.country not in seen))
    if before and new:
        lines.append(f"- 🆕 Premier vol vers {' '.join(flag(c) for c in new)}")
    return " · ".join(head), lines
