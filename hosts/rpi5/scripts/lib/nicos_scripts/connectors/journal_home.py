"""
Electricity for journal-daily, from Home Assistant's recorder (SQLite, read-only).

The Linky meter's hourly statistics give the day's kWh and cost; Enedis
publishes them about a day late, so a day shows only once its last hour is
in (later runs fill it). The radiators' `*_daily_consumption` sensors give
the heating share per room, from their cumulative `sum`.
"""

import json
import sqlite3
from dataclasses import dataclass

ROOM_SUFFIX = "_daily_consumption"


@dataclass(frozen=True)
class Energy:
    kwh: float
    cost: float  # €, or None
    rooms: tuple  # ((room, kWh), ...), biggest first


def energy(path, lo, hi, connect=sqlite3.connect):
    """The [lo, hi) (epoch s) Energy, or None when the meter's day is incomplete."""
    db = connect(f"file:{path}?mode=ro", uri=True)
    try:
        def hourly(sid):
            return db.execute("""
                SELECT count(*), sum(s.state), max(s.start_ts) FROM statistics s
                JOIN statistics_meta m ON m.id = s.metadata_id
                WHERE m.statistic_id = ? AND s.start_ts >= ? AND s.start_ts < ?""", (sid, lo, hi)).fetchone()

        meter = db.execute("SELECT statistic_id FROM statistics_meta WHERE source = 'linky' "
                           "AND statistic_id NOT LIKE '%\\_cost' ESCAPE '\\'").fetchone()
        if not meter:
            return None
        hours, wh, last = hourly(meter[0])
        # Linky lands in whole days, so the last hour present = the day is in. One
        # row short is allowed: Oct 25 2026 had no row for the repeated 02:00.
        if not wh or last < hi - 3600 or hours < round((hi - lo) / 3600) - 1:
            return None
        _, cost, _ = hourly(f"{meter[0]}_cost")
        rooms = []
        for sid, in db.execute("SELECT statistic_id FROM statistics_meta WHERE statistic_id LIKE ?",
                               (f"sensor.%{ROOM_SUFFIX}",)):
            def total(before):
                row = db.execute("""
                    SELECT s.sum FROM statistics s JOIN statistics_meta m ON m.id = s.metadata_id
                    WHERE m.statistic_id = ? AND s.start_ts < ? ORDER BY s.start_ts DESC LIMIT 1""",
                                 (sid, before)).fetchone()
                return row[0] if row and row[0] is not None else None
            start, end = total(lo), total(hi)
            if start is None or end is None or end - start < 50:
                continue
            rooms.append((_room(db, sid), (end - start) / 1000))
    finally:
        db.close()
    return Energy(wh / 1000, cost, tuple(sorted(rooms, key=lambda r: -r[1])))


def _room(db, sid):
    """`Cuisine` from the sensor's friendly name `Cuisine Daily Consumption`."""
    row = db.execute("""
        SELECT a.shared_attrs FROM states s
        JOIN states_meta sm ON sm.metadata_id = s.metadata_id
        JOIN state_attributes a ON a.attributes_id = s.attributes_id
        WHERE sm.entity_id = ? ORDER BY s.last_updated_ts DESC LIMIT 1""", (sid,)).fetchone()
    name = json.loads(row[0]).get("friendly_name", "") if row else ""
    name = name.removesuffix(" Daily Consumption").strip()
    return name or sid.removeprefix("sensor.").removesuffix(ROOM_SUFFIX)


def _n(x):
    return f"{x:.1f}".replace(".", ",")


def energy_section(e):
    """(heading suffix, lines): `22,4 kWh · 2,79 €`, then the heating share."""
    head = f"{_n(e.kwh)} kWh" + (f" · {e.cost:.2f} €".replace(".", ",") if e.cost else "")
    heat = sum(k for _, k in e.rooms)
    if not heat:
        return head, []
    lines = [f"- 🔥 **Chauffage**: {_n(heat)} kWh · " + " · ".join(f"{r} {_n(k)}" for r, k in e.rooms)]
    if e.kwh - heat >= 0.05:
        lines.append(f"- 💡 **Le reste**: {_n(e.kwh - heat)} kWh")
    return head, lines
