import json
import sqlite3

from nicos_scripts.connectors import journal_home as jh

LO = 1792980000  # some 04:00
HI = LO + 86400


def make_ha(path, linky_hours=24, rooms=(("sensor.kitchen_cuisine_daily_consumption", "Cuisine", 9500),
                                          ("sensor.living_room_salon_daily_consumption", "Salon", 20))):
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE statistics_meta (id INTEGER PRIMARY KEY, statistic_id TEXT, source TEXT);
        CREATE TABLE statistics (id INTEGER PRIMARY KEY, metadata_id INT, start_ts REAL, state REAL, sum REAL);
        CREATE TABLE states_meta (metadata_id INTEGER PRIMARY KEY, entity_id TEXT);
        CREATE TABLE state_attributes (attributes_id INTEGER PRIMARY KEY, shared_attrs TEXT);
        CREATE TABLE states (state_id INTEGER PRIMARY KEY, metadata_id INT, attributes_id INT, last_updated_ts REAL);
    """)
    db.execute("INSERT INTO statistics_meta VALUES (1, 'linky:0723', 'linky'), (2, 'linky:0723_cost', 'linky')")
    for h in range(linky_hours):
        db.execute("INSERT INTO statistics (metadata_id, start_ts, state) VALUES (1, ?, 1000), (2, ?, 0.125)",
                   (LO + h * 3600, LO + h * 3600))
    for n, (sid, name, wh) in enumerate(rooms, 10):
        db.execute("INSERT INTO statistics_meta VALUES (?, ?, 'recorder')", (n, sid))
        # cumulative sum: 100 Wh before the day, +wh across it
        db.execute("INSERT INTO statistics (metadata_id, start_ts, sum) VALUES (?, ?, 100), (?, ?, ?)",
                   (n, LO - 3600, n, HI - 3600, 100 + wh))
        db.execute("INSERT INTO states_meta VALUES (?, ?)", (n, sid))
        db.execute("INSERT INTO state_attributes VALUES (?, ?)",
                   (n, json.dumps({"friendly_name": f"{name} Daily Consumption"})))
        db.execute("INSERT INTO states (metadata_id, attributes_id, last_updated_ts) VALUES (?, ?, 1)", (n, n))
    db.commit()
    db.close()
    return path


def test_day_total_cost_and_heating_by_room(tmp_path):
    e = jh.energy(make_ha(str(tmp_path / "ha.db")), LO, HI)
    assert e.kwh == 24 and e.cost == 3.0
    assert e.rooms == (("Cuisine", 9.5),)  # 20 Wh in the salon is noise
    assert jh.energy_section(e) == ("24,0 kWh · 3,00 €",
                                    ["- 🔥 **Chauffage**: 9,5 kWh · Cuisine 9,5", "- 💡 **Le reste**: 14,5 kWh"])


def test_incomplete_meter_day_waits(tmp_path):
    assert jh.energy(make_ha(str(tmp_path / "ha.db"), linky_hours=20), LO, HI) is None


def test_a_dst_day_missing_its_repeated_hour_still_counts(tmp_path):
    path = make_ha(str(tmp_path / "ha.db"), linky_hours=24, rooms=())
    assert jh.energy(path, LO, HI + 3600) is None  # 25 h asked, last hour absent
    db = sqlite3.connect(path)
    db.execute("INSERT INTO statistics (metadata_id, start_ts, state) VALUES (1, ?, 500)", (HI,))
    db.execute("DELETE FROM statistics WHERE metadata_id = 1 AND start_ts = ?", (LO + 22 * 3600,))
    db.commit()
    db.close()
    assert jh.energy(path, LO, HI + 3600).kwh == 23.5  # 24 rows of 25


def test_no_heating_is_just_the_total(tmp_path):
    e = jh.energy(make_ha(str(tmp_path / "ha.db"), rooms=()), LO, HI)
    assert jh.energy_section(e) == ("24,0 kWh · 3,00 €", [])
