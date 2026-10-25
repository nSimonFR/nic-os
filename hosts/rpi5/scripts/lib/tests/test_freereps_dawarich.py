import json

import pytest

from conftest import FakeOpener, json_reply
from nicos_scripts.connectors import freereps_dawarich as fd

W1 = "11111111-1111-1111-1111-111111111111"
W2 = "22222222-2222-2222-2222-222222222222"
SEP = "\x1f"


def fix(t, acc=5.0, lat=48.8, lon=2.3):
    return (t, lat, lon, 35.0, 4.2, 90.0, acc)


def north(t, metres, east=0.0):
    """A fix `metres` north (and `east`) of 48.8,2.3 at time t."""
    return fix(t, lat=48.8 + metres / 110_540, lon=2.3 + east / (111_320 * 0.6587))


class FakePg:
    """Answers psql_rows by matching on the SQL text."""

    def __init__(self, workouts, routes, users=(("1", "KEY"),), tracker="PHONE", corrected=False):
        self.workouts, self.routes, self.users, self.tracker = workouts, routes, users, tracker
        self.corrected = corrected
        self.sql = []

    def __call__(self, cmd):
        sql = cmd[cmd.index("-c") + 1]
        self.sql.append(sql)
        if "GROUP BY w.id" in sql:
            rows = self.workouts
        elif "FROM workout_routes" in sql:
            wid = sql.split("workout_id = '")[1][:36]
            rows = [(t, lat, lon, alt, sp, co, acc)
                    for t, lat, lon, alt, sp, co, acc in self.routes[wid]]
        elif "FROM users" in sql:
            rows = self.users
        elif "tracker_id FROM points" in sql:
            rows = [(self.tracker,)] if self.tracker else []
        elif "corrected_at IS NOT NULL" in sql:
            rows = [("1",)] if self.corrected else []
        elif "DELETE FROM points" in sql:
            rows = [("7",)]
        elif "DELETE FROM tracks" in sql:
            rows = [("41",)]
        else:
            raise AssertionError(sql)
        return "\n".join(SEP.join("" if v is None else str(v) for v in r) for r in rows)


def cfg(tmp_path, **kw):
    base = dict(state_path=str(tmp_path / "state.json"), dry_run=False)
    base.update(kw)
    return fd.Config(**base)


def ok_opener():
    return FakeOpener([json_reply({"data": [{}, {}]})])


def test_config_defaults_to_dry_run():
    assert fd.Config.from_env({}).dry_run is True
    assert fd.Config.from_env({"FREEREPS_DAWARICH_DRY_RUN": "0"}).dry_run is False


def test_simplify_keeps_only_the_ends_of_a_straight_line():
    pts = [north(t, t * 5) for t in range(0, 60)]
    assert [p[0] for p in fd.simplify(pts, 10, 120, 50)] == [0, 59]


def test_simplify_keeps_a_corner():
    pts = [north(t, t * 5) for t in range(0, 30)] + [north(t, 145, (t - 29) * 5) for t in range(30, 60)]
    assert [p[0] for p in fd.simplify(pts, 10, 120, 50)] == [0, 29, 59]


def test_simplify_keeps_a_fix_at_least_every_max_gap():
    pts = [north(t, t) for t in range(0, 301)]
    kept = [p[0] for p in fd.simplify(pts, 10, 120, 50)]
    assert kept[0] == 0 and kept[-1] == 300
    assert max(b - a for a, b in zip(kept, kept[1:])) <= 120


def test_payload_omits_apples_invalid_minus_one():
    props = fd.payload([(100, 48.8, 2.3, 30.0, -1.0, -1.0, 4.0)], "PHONE", W1)["locations"][0]["properties"]
    assert "speed" not in props and "course" not in props and props["altitude"] == 30.0


def test_simplify_drops_inaccurate_fixes():
    pts = [fix(0), fix(5, acc=200.0), fix(6, acc=None), fix(12, acc=-1.0)]
    assert [p[0] for p in fd.simplify(pts, 10, 120, 50)] == [0, 6]


def test_payload_is_lonlat_and_skips_missing_values():
    body = fd.payload([(100, 48.8, 2.3, None, 4.0, None, 3.0)], "PHONE", W1)
    f = body["locations"][0]
    assert f["geometry"]["coordinates"] == [2.3, 48.8]
    assert f["properties"] == {"timestamp": 100, "device_id": "PHONE", "source": "freereps",
                               "workout_id": W1, "speed": 4.0, "horizontal_accuracy": 3.0}


def test_pushes_new_routes_under_the_phone_tracker(tmp_path):
    pg = FakePg([(W1, "Cycling", 3)], {W1: [fix(0), fix(5), fix(10)]})
    op = ok_opener()
    assert fd.sync(cfg(tmp_path), pg, opener=op, log=lambda m: None, sleep=lambda s: None) == (1, 2)
    req = op.last
    assert req.full_url == "http://127.0.0.1:13900/api/v1/points"
    assert req.headers["Authorization"] == "Bearer KEY"
    assert op.body_of()["locations"][0]["properties"]["device_id"] == "PHONE"
    assert json.loads((tmp_path / "state.json").read_text()) == {W1: 3}


def test_clears_overlapping_tracks_before_the_push(tmp_path):
    pg = FakePg([(W1, "Cycling", 2)], {W1: [fix(100), fix(200)]})
    fd.sync(cfg(tmp_path), pg, opener=ok_opener(), log=lambda m: None, sleep=lambda s: None)
    clear = next(s for s in pg.sql if "DELETE FROM tracks" in s)
    assert "to_timestamp(100)" in clear and "to_timestamp(200)" in clear
    stale = next(s for s in pg.sql if "DELETE FROM points" in s)
    assert f"'workout_id' = '{W1}'" in stale and "NOT IN (100,200)" in stale
    assert pg.sql.index(clear) < pg.sql.index(stale)


def test_skips_a_ride_overlapping_a_hand_corrected_track(tmp_path):
    pg = FakePg([(W1, "Cycling", 1)], {W1: [fix(0)]}, corrected=True)
    op, lines = ok_opener(), []
    assert fd.sync(cfg(tmp_path), pg, opener=op, log=lines.append, sleep=lambda s: None) == (1, 0)
    assert op.requests == [] and not any("DELETE" in s for s in pg.sql)
    assert "hand-corrected" in lines[0]
    assert json.loads((tmp_path / "state.json").read_text()) == {W1: 1}


def test_dry_run_clears_no_tracks(tmp_path):
    pg = FakePg([(W1, "Cycling", 1)], {W1: [fix(0)]})
    fd.sync(cfg(tmp_path, dry_run=True), pg, opener=ok_opener(), log=lambda m: None)
    assert not any("DELETE" in s for s in pg.sql)


def test_skips_unchanged_and_resends_a_grown_route(tmp_path):
    (tmp_path / "state.json").write_text(json.dumps({W1: 3, W2: 1}))
    pg = FakePg([(W1, "Cycling", 3), (W2, "Cycling", 2)], {W2: [fix(0), fix(9)]})
    op = ok_opener()
    assert fd.sync(cfg(tmp_path), pg, opener=op, log=lambda m: None, sleep=lambda s: None) == (1, 2)
    assert len(op.requests) == 1 and op.body_of()["locations"][0]["properties"]["workout_id"] == W2


def test_nothing_new_touches_neither_dawarich_nor_its_db(tmp_path):
    (tmp_path / "state.json").write_text(json.dumps({W1: 3}))
    pg = FakePg([(W1, "Cycling", 3)], {})
    op = ok_opener()
    assert fd.sync(cfg(tmp_path), pg, opener=op, log=lambda m: None) == (0, 0)
    assert op.requests == [] and not any("users" in s for s in pg.sql)


def test_dry_run_posts_nothing_and_saves_nothing(tmp_path):
    pg = FakePg([(W1, "Cycling", 2)], {W1: [fix(0), fix(5)]})
    op, lines = ok_opener(), []
    fd.sync(cfg(tmp_path, dry_run=True), pg, opener=op, log=lines.append, sleep=lambda s: None)
    assert op.requests == [] and not (tmp_path / "state.json").exists()
    assert "[dry-run]" in lines[0]


def test_http_error_stops_without_recording_the_workout(tmp_path):
    pg = FakePg([(W1, "Cycling", 1)], {W1: [fix(0)]})
    op = FakeOpener([json_reply({"error": "x"}, status=500)])
    with pytest.raises(RuntimeError):
        fd.sync(cfg(tmp_path), pg, opener=op, log=lambda m: None, sleep=lambda s: None)
    assert not (tmp_path / "state.json").exists()
    assert not any("DELETE FROM points" in s for s in pg.sql)


def test_refuses_more_than_one_dawarich_user(tmp_path):
    pg = FakePg([(W1, "Cycling", 1)], {W1: [fix(0)]}, users=(("1", "A"), ("2", "B")))
    with pytest.raises(RuntimeError):
        fd.sync(cfg(tmp_path), pg, opener=ok_opener(), log=lambda m: None)


def test_route_rejects_a_non_uuid_id(tmp_path):
    with pytest.raises(ValueError):
        fd.route(cfg(tmp_path), FakePg([], {}), "x'; DROP TABLE workouts; --")
