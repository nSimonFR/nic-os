import sqlite3
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from nicos_scripts.connectors import journal_records as rec

TZ = ZoneInfo("Europe/Paris")
DAY = date(2026, 10, 19)


def history(values, start=date(2026, 1, 1), every=7):
    return [(start + timedelta(days=i * every), v) for i, v in enumerate(values)]


def at(d, h=12):
    return datetime(d.year, d.month, d.day, h, tzinfo=TZ).timestamp()


def test_journal_date_starts_at_four():
    assert rec.journal_date(at(DAY, 3)) == DAY - timedelta(days=1)
    assert rec.journal_date(at(DAY, 4)) == DAY


def test_best_all_time_then_last_year():
    old = [(date(2024, 6, 1), 50)] + history([10] * 10, start=date(2025, 11, 1), every=10)  # the 50 is over a year back
    assert rec.best(60, old, DAY) == "all"
    assert rec.best(20, old, DAY) == "year"
    assert rec.best(10, old, DAY) is None  # a tie is no record


def test_best_needs_enough_history():
    assert rec.best(99, history([1] * 7), DAY) is None  # too few values
    assert rec.best(99, history([1] * 10, start=DAY - timedelta(days=10), every=1), DAY) is None  # too short a span
    assert rec.best(99, history([1] * 10), DAY) == "all"


def test_best_ignores_what_came_after():
    later = history([1] * 10) + [(DAY + timedelta(days=3), 500)]
    assert rec.best(99, later, DAY) == "all"


def test_record_lines_group_by_level():
    assert rec.record_lines([("all", "a"), (None, "x"), ("year", "c"), ("all", "b")]) == [
        "- 🏆 **Record**: a · b", "- 🏆 **Meilleur depuis un an**: c"]


def test_streak_days_and_weeks():
    days = {DAY, DAY - timedelta(days=1), DAY - timedelta(days=2), DAY - timedelta(days=4)}
    assert rec.streak(days, DAY) == 3
    assert rec.streak(days, DAY + timedelta(days=1)) == 0
    weekly = {DAY, DAY - timedelta(days=6), DAY - timedelta(days=9)}  # Mon, the Tue before, the Sat before that
    assert rec.streak(weekly, DAY, weeks=True) == 3
    assert rec.streak_text(2) == "" and rec.streak_text(3) == "🔥 3ᵉ jour d'affilée"
    assert rec.streak_text(4, weeks=True) == "🔥 4ᵉ semaine d'affilée"


def test_ride_badges_records_and_streak():
    rides = [(at(date(2026, 1, 1) + timedelta(days=7 * i)), 10.0, 40.0) for i in range(10)]
    rides += [(at(DAY - timedelta(days=2)), 5.0, 20.0), (at(DAY - timedelta(days=1)), 5.0, 20.0)]
    rides += [(at(DAY, 8), 30.0, 60.0), (at(DAY, 18), 12.0, 40.0)]
    assert rec.ride_badges(rides, DAY) == [
        "- 🏆 **Record**: plus longue sortie (30,0 km) · plus grosse journée (42,0 km) · "
        "sortie la plus rapide (30,0 km/h)",
        "- 🔥 3ᵉ jour d'affilée"]


def test_ride_badges_skip_short_rides_for_speed():
    rides = [(at(date(2026, 1, 1) + timedelta(days=7 * i)), 10.0, 40.0) for i in range(10)]
    rides += [(at(DAY), 3.0, 5.0)]  # 36 km/h over 3 km: GPS noise
    assert rec.ride_badges(rides, DAY) == []


def test_step_badges():
    steps = {date(2026, 1, 1) + timedelta(days=i): 5000 for i in range(200)}
    steps.update({DAY - timedelta(days=2): 12000, DAY - timedelta(days=1): 11000, DAY: 25000})
    assert rec.step_badges(steps, DAY) == ["- 🏆 **Record**: plus de pas en un jour (25 000)",
                                           "- 🔥 3ᵉ jour d'affilée à 10 000 pas"]


def test_climbing_badges_sum_the_day_and_count_weeks():
    def session(d, tops, height):
        return {"startDate": datetime(d.year, d.month, d.day, 10, tzinfo=TZ).isoformat(),
                "tops": tops, "climbedHeight": height}
    sessions = [session(date(2026, 8, 3) + timedelta(days=7 * i), 5, 30) for i in range(11)]
    sessions += [session(DAY, 4, 20), session(DAY, 3, 20)]
    assert rec.climbing_badges(sessions, DAY) == [
        "- 🏆 **Record**: plus de tops en une séance (7) · plus haut grimpé en une séance (40 m)",
        "- 🔥 12ᵉ semaine d'affilée"]


def test_energy_history_reads_daily_then_hourly_rows(tmp_path):
    path = tmp_path / "ha.db"
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE statistics_meta (id INTEGER, statistic_id TEXT, source TEXT)")
    db.execute("CREATE TABLE statistics (metadata_id INTEGER, start_ts REAL, state REAL)")
    db.execute("INSERT INTO statistics_meta VALUES (1, 'linky:1', 'linky'), (2, 'linky:1_cost', 'linky')")
    jan = datetime(2026, 1, 10, tzinfo=TZ).timestamp()  # one row at local midnight = a whole day
    db.execute("INSERT INTO statistics VALUES (1, ?, 30000)", (jan,))
    lo = datetime(2026, 3, 10, 4, tzinfo=TZ).timestamp()
    db.executemany("INSERT INTO statistics VALUES (1, ?, 500)", [(lo + h * 3600,) for h in range(24)])
    db.executemany("INSERT INTO statistics VALUES (1, ?, 500)", [(lo + 86400 + h * 3600,) for h in range(5)])
    db.commit()
    assert rec.energy_history(str(path), lo + 10 * 86400) == {date(2026, 1, 10): 30.0, date(2026, 3, 10): 12.0}
