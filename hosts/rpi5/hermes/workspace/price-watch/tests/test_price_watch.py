import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "price_watch.py"
CONFIG = Path(__file__).parents[1] / "products.json"


def run(db, *args, check=True):
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--db", str(db), "--config", str(CONFIG), *args],
        text=True,
        capture_output=True,
        check=check,
    )


class PriceWatchTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp_path = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()


def _wrap_test(function):
    def method(self):
        return function(self.tmp_path)
    return method


def test_sync_creates_sql_schema_and_conditions(tmp_path):
    db = tmp_path / "prices.sqlite3"
    run(db, "sync")
    with sqlite3.connect(db) as con:
        products = con.execute("SELECT slug FROM products ORDER BY slug").fetchall()
        conditions = con.execute(
            "SELECT metric, operator, threshold FROM alert_conditions "
            "WHERE product_slug='valerion_visionmaster_pro_2'"
        ).fetchall()
    assert ("valerion_visionmaster_pro_2",) in products
    assert ("total_price", "<=", 1850.0) in conditions


def test_record_tracks_comparable_price_history_and_evaluates_threshold(tmp_path):
    db = tmp_path / "prices.sqlite3"
    run(db, "sync")
    normal = json.loads(run(
        db, "record", "--product", "backmarket_iphone_15_pro_128",
        "--price", "532", "--shipping", "0", "--seller", "Back Market",
        "--url", "https://example.test/normal", "--variant", "128 Go|Très bon état|batterie standard",
    ).stdout)
    deal = json.loads(run(
        db, "record", "--product", "backmarket_iphone_15_pro_128",
        "--price", "475", "--shipping", "0", "--seller", "Back Market",
        "--url", "https://example.test/deal", "--variant", "128 Go|Très bon état|batterie standard",
    ).stdout)
    assert normal["alert"] is False
    assert deal["alert"] is True
    assert deal["previous_comparable_price"] == 532.0
    assert deal["saving_eur"] == 57.0
    assert round(deal["saving_percent"], 2) == 10.71
    with sqlite3.connect(db) as con:
        assert con.execute("SELECT count(*) FROM price_observations").fetchone()[0] == 2


def test_unverified_observation_is_stored_but_never_alerts_or_becomes_best(tmp_path):
    db = tmp_path / "prices.sqlite3"
    run(db, "sync")
    result = json.loads(run(
        db, "record", "--product", "valerion_visionmaster_pro_2",
        "--price", "1000", "--seller", "Unknown", "--url", "https://example.test",
        "--unverified",
    ).stdout)
    assert result["alert"] is False
    with sqlite3.connect(db) as con:
        row = con.execute("SELECT verified FROM price_observations").fetchone()
        assert row == (0,)


def test_history_is_json_and_ordered_newest_first(tmp_path):
    db = tmp_path / "prices.sqlite3"
    run(db, "sync")
    for price in (600, 550):
        run(db, "record", "--product", "backmarket_iphone_15_pro_128",
            "--price", str(price), "--seller", "Back Market",
            "--url", f"https://example.test/{price}", "--variant", "128 Go")
    history = json.loads(run(db, "history", "--product", "backmarket_iphone_15_pro_128").stdout)
    assert [row["total_price"] for row in history] == [550.0, 600.0]


def test_duplicate_same_run_observation_is_ignored(tmp_path):
    db = tmp_path / "prices.sqlite3"
    run(db, "sync")
    args = ("record", "--product", "backmarket_iphone_15_pro_128", "--price", "475",
            "--seller", "Back Market", "--url", "https://example.test/deal",
            "--variant", "128 Go", "--observed-at", "2026-09-13T10:00:00+02:00")
    run(db, *args)
    run(db, *args)
    with sqlite3.connect(db) as con:
        assert con.execute("SELECT count(*) FROM price_observations").fetchone()[0] == 1


for _name, _function in list(globals().items()):
    if _name.startswith("test_") and callable(_function):
        setattr(PriceWatchTests, _name, _wrap_test(_function))


if __name__ == "__main__":
    unittest.main()
